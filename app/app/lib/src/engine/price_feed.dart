import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:magicblock_client/magicblock_client.dart';
import 'package:throtl/src/chain/go_live.dart';

/// A SOL/USD price source for the ride. Emits a `priceE9` (1e9 fixed-point int,
/// the engine's mark unit) and keeps a rolling history the race scene reads for
/// grade + altitude. Three implementations: [SyntheticFeed] (always-works
/// random walk), [LivePythFeed] (real in-ER Pyth via Magic Router, native),
/// and [GuardianPriceFeed] (a CORS-safe proxy for web).
abstract class PriceFeed extends ChangeNotifier {
  final List<int> _history = [];
  int _priceE9 = 162400000000; // $162.40 seed (matches the design)
  int _prevE9 = 162400000000;

  int get priceE9 => _priceE9;
  int get prevE9 => _prevE9;
  double get ui => _priceE9 / 1e9;

  /// Rolling priceE9 history, newest last (capped at 220, like the design sim).
  List<int> get history => List.unmodifiable(_history);

  bool get isLive;

  /// Ticker label: "LIVE" when fed by the real oracle, "PRACTICE" otherwise.
  String get label => isLive ? 'LIVE' : 'PRACTICE';

  /// Begin emitting.
  void start();

  @protected
  void push(int priceE9) {
    _prevE9 = _priceE9;
    _priceE9 = priceE9;
    _history.add(priceE9);
    if (_history.length > 220) _history.removeAt(0);
    notifyListeners();
  }
}

/// A faithful port of the design's `sim.js` SOL-PERP random walk — gives the
/// full game feel with zero network, so the cockpit always works (offline,
/// flaky links, CI). Volatility/trend are tunable from the dev tweaks.
class SyntheticFeed extends PriceFeed {
  SyntheticFeed({this.volatility = 1.2, this.trend = 0});

  double volatility;
  double trend; // -1 bear .. +1 bull (scaled like the design)

  final math.Random _rng = math.Random();
  Timer? _timer;
  double _price = 162.4;
  int _t = 0;
  double _burst = 0;

  @override
  bool get isLive => false;

  @override
  void start() {
    _timer ??= Timer.periodic(const Duration(milliseconds: 90), (_) => _step());
    // Seed the history so the road has shape immediately.
    for (var i = _history.length; i < 160; i++) {
      _history.add((_price * 1e9).round());
    }
  }

  void _step() {
    _t++;
    if (_rng.nextDouble() < 0.012) _burst = 10 + _rng.nextDouble() * 24;
    final v = volatility * (_burst > 0 ? 3.2 : 1);
    if (_burst > 0) _burst--;
    final drift = trend * 0.004;
    final shock = (_rng.nextDouble() * 2 - 1) * 0.05 * v;
    final wave = (math.sin(_t / 47) * 0.011 + math.sin(_t / 13) * 0.007) * volatility;
    _price = math.max(20, _price * (1 + (drift + shock + wave) / 100));
    push((_price * 1e9).round());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Live in-ER Pyth Lazer mark via the Magic Router (native / where CORS allows).
/// Finds an ER node, then polls its `getAccountInfo` for the SOL feed and
/// decodes with [parsePriceUpdateV2]. Falls silent on error (caller can keep a
/// [SyntheticFeed] as the resilient default).
class LivePythFeed extends PriceFeed {
  LivePythFeed({
    this.routerUrl = RouterClient.devnet,
    this.oracleFeedPda = devnetSolPriceFeedPda,
  });

  final String routerUrl;

  /// In-ER SOL feed PDA for this cluster.
  final String oracleFeedPda;
  final http.Client _http = http.Client();
  Timer? _timer;
  String? _erRpcUrl;
  bool _live = false;

  @override
  bool get isLive => _live;

  @override
  void start() {
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      final router = RouterClient(url: routerUrl, client: _http);
      final node = await router.nearestValidator();
      _erRpcUrl = node.rpcUrl;
      router.close();
      _timer = Timer.periodic(const Duration(milliseconds: 600), (_) => _poll());
    } on Object catch (e) {
      debugPrint('LivePythFeed: bootstrap failed ($e)');
    }
  }

  Future<void> _poll() async {
    final url = _erRpcUrl;
    if (url == null) return;
    try {
      final bytes = await _getAccountInfo(url, oracleFeedPda);
      if (bytes == null) return;
      final price = parsePriceUpdateV2(bytes);
      if (price != null && price.priceE9 > 0) {
        _live = true;
        push(price.priceE9);
      }
    } on Object catch (_) {
      // transient — keep last good value
    }
  }

  Future<Uint8List?> _getAccountInfo(String rpcUrl, String pubkey) async {
    final res = await _http.post(
      Uri.parse(rpcUrl),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'getAccountInfo',
        'params': [
          pubkey,
          {'encoding': 'base64'},
        ],
      }),
    );
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final result = body['result'] as Map<String, dynamic>?;
    final value = result?['value'] as Map<String, dynamic>?;
    final data = value?['data'] as List<dynamic>?;
    if (data == null || data.isEmpty) return null;
    return base64Decode(data.first as String);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _http.close();
    super.dispose();
  }
}

/// CORS-safe live price for web — polls the guardian's `GET /price/sol` proxy.
class GuardianPriceFeed extends PriceFeed {
  GuardianPriceFeed({required this.guardianBaseUrl});

  final String guardianBaseUrl;
  final http.Client _http = http.Client();
  Timer? _timer;
  bool _live = false;

  @override
  bool get isLive => _live;

  @override
  void start() {
    _timer = Timer.periodic(const Duration(milliseconds: 800), (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final res = await _http.get(Uri.parse('$guardianBaseUrl/price/sol'));
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final e9 = int.tryParse('${body['priceE9']}');
      if (e9 != null && e9 > 0) {
        _live = true;
        push(e9);
      }
    } on Object catch (_) {
      // transient
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _http.close();
    super.dispose();
  }
}

/// Live SOL/USD from Flash's mainnet Pyth-Lazer HTTP price API (`/v2/prices/SOL`).
/// Needs no wallet and is CORS-open — the home ticker + practice rides show the
/// REAL price (label "LIVE"), never a synthetic walk. Holds the seed until the
/// first poll lands.
class FlashPriceFeed extends PriceFeed {
  final http.Client _http = http.Client();
  Timer? _timer;
  bool _live = false;

  @override
  bool get isLive => _live;

  @override
  void start() {
    unawaited(_poll());
    // 1s cadence so the live PnL visibly ticks (with the sub-cent precision in the
    // race HUD) instead of jumping every 2s. Still the Flash venue price — keeps
    // PnL honest against where the trade actually settles.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    try {
      final res = await _http.get(Uri.parse('$flashApiBase/prices/SOL'));
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final ui = double.tryParse('${body['priceUi'] ?? ''}');
      if (ui != null && ui > 0) {
        _live = true;
        push((ui * 1e9).round());
      }
    } on Object catch (_) {
      // transient — keep the last price
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _http.close();
    super.dispose();
  }
}
