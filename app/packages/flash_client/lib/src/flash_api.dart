/// The Flash Trade v2 hosted REST API (https://flashapi.trade/v2). No auth. Returns either a
/// preview quote (when `owner` is omitted) or `{ transactionBase64 }` (an UNSIGNED v0 tx with the
/// blockhash pre-filled for the correct chain). See services/flash-spec/openapi.v2.json.
library;

import 'dart:convert';

import 'package:flash_client/src/errors.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// A built, unsigned transaction returned by a tx-builder endpoint.
@immutable
class BuiltTx {
  const BuiltTx(this.transactionBase64);
  final String transactionBase64;
}

/// The preview quote from an owner-less open-position call.
@immutable
class OpenPreview {
  const OpenPreview(this.raw);
  final Map<String, dynamic> raw;

  String get newEntryPrice => raw['newEntryPrice'] as String? ?? '';
  String get newLiquidationPrice => raw['newLiquidationPrice'] as String? ?? '';
  String get entryFee => raw['entryFee'] as String? ?? '';
  String get youPayUsdUi => raw['youPayUsdUi'] as String? ?? '';
  String get youRecieveUsdUi => raw['youRecieveUsdUi'] as String? ?? ''; // (sic — Flash's spelling)
  String get availableLiquidity => raw['availableLiquidity'] as String? ?? '';
}

class FlashApi {
  FlashApi({this.baseUrl = 'https://flashapi.trade/v2', http.Client? client})
    : _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  static const _json = {'content-type': 'application/json'};

  void close() => _http.close();

  // ── read-only ──────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> health() async => _get('/health');

  Future<List<Map<String, dynamic>>> tokens() async {
    final r = await _getRaw('/tokens');
    final d = jsonDecode(r);
    final List<dynamic> list;
    if (d is List) {
      list = d;
    } else if (d is Map) {
      final inner = d['tokens'] ?? d['data'];
      list = inner is List ? inner : const [];
    } else {
      list = const [];
    }
    return list.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> price(String symbol) async => _get('/prices/$symbol');

  Future<Map<String, dynamic>> ownerState(String owner) async => _get('/owner/$owner');

  /// Anchor-deserialized basket account: `{ account: { debits[], pendingCredits[], positions[] } }`.
  Future<Map<String, dynamic>> rawBasket(String basketPubkey) async =>
      _get('/raw/baskets/$basketPubkey');

  /// Withdrawable balance (raw token units) of [mint] for a closed/flat basket. Per the protocol,
  /// `balance = deposits − debits + pendingCredits`; for a flat basket where the position consumed
  /// the full deposit (debits == deposits), the net is `pendingCredits` (research/flash.md §3).
  Future<int> withdrawableRaw(String basketPubkey, String mint) async {
    final basket = await rawBasket(basketPubkey);
    return computeWithdrawableRaw(basket['account'] as Map<String, dynamic>? ?? const {}, mint);
  }

  // ── preview (owner omitted ⇒ quote only, no tx) ──────────────────────────────

  Future<OpenPreview> previewOpen({
    required String inputTokenSymbol,
    required String outputTokenSymbol,
    required String inputAmountUi,
    required num leverage,
    required String tradeType, // LONG | SHORT
  }) async {
    final body = {
      'inputTokenSymbol': inputTokenSymbol,
      'outputTokenSymbol': outputTokenSymbol,
      'inputAmountUi': inputAmountUi,
      'leverage': leverage,
      'tradeType': tradeType,
    };
    final res = await _postJson('/transaction-builder/open-position', body);
    return OpenPreview(res);
  }

  // ── lifecycle tx-builders (return UNSIGNED v0 txs) ───────────────────────────

  Future<BuiltTx> initDepositLedger(String owner) =>
      _build('/transaction-builder/init-deposit-ledger', {'owner': owner});

  Future<BuiltTx> initBasket(String owner) =>
      _build('/transaction-builder/init-basket', {'owner': owner});

  Future<BuiltTx> delegateBasket({required String owner, required String payer}) =>
      _build('/transaction-builder/delegate-basket', {'owner': owner, 'payer': payer});

  Future<BuiltTx> depositDirect({
    required String owner,
    required String tokenMint,
    required String amountUi,
  }) => _build('/transaction-builder/deposit-direct', {
    'owner': owner,
    'tokenMint': tokenMint,
    'amount': amountUi,
  });

  /// Open or increase a position. Pass [owner] (owner-signed) OR [signer]+[sessionToken].
  Future<BuiltTx> openPosition({
    required String inputTokenSymbol,
    required String outputTokenSymbol,
    required String inputAmountUi,
    required num leverage,
    required String tradeType,
    String? owner,
    String? signer,
    String? sessionToken,
    String? stopLoss,
    String? takeProfit,
    String slippagePercentage = '0.5',
  }) => _build('/transaction-builder/open-position', {
    'inputTokenSymbol': inputTokenSymbol,
    'outputTokenSymbol': outputTokenSymbol,
    'inputAmountUi': inputAmountUi,
    'leverage': leverage,
    'tradeType': tradeType,
    'slippagePercentage': slippagePercentage,
    'owner': ?owner,
    'signer': ?signer,
    'sessionToken': ?sessionToken,
    'stopLoss': ?stopLoss,
    'takeProfit': ?takeProfit,
  });

  /// Close (partial or full). `inputUsdUi >= 97% of size` (or "0") ⇒ full close (research §2).
  Future<BuiltTx> closePosition({
    required String owner,
    required String marketSymbol,
    required String side, // LONG | SHORT
    required String inputUsdUi,
    required String withdrawTokenSymbol,
    String? signer,
    String? sessionToken,
    String slippagePercentage = '0.5',
  }) => _build('/transaction-builder/close-position', {
    'owner': owner,
    'marketSymbol': marketSymbol,
    'side': side,
    'inputUsdUi': inputUsdUi,
    'withdrawTokenSymbol': withdrawTokenSymbol,
    'slippagePercentage': slippagePercentage,
    'signer': ?signer,
    'sessionToken': ?sessionToken,
  });

  Future<BuiltTx> requestWithdrawal({
    required String owner,
    required String tokenMint,
    required String amountUi,
    bool includeCustodySettlement = true,
  }) => _build('/transaction-builder/request-withdrawal', {
    'owner': owner,
    'tokenMint': tokenMint,
    'amount': amountUi,
    'includeCustodySettlement': includeCustodySettlement,
  });

  Future<BuiltTx> executeWithdrawal({
    required String owner,
    required String tokenMint,
    bool includeCustodySettlement = true,
  }) => _build('/transaction-builder/execute-withdrawal', {
    'owner': owner,
    'tokenMint': tokenMint,
    'includeCustodySettlement': includeCustodySettlement,
  });

  // ── plumbing ─────────────────────────────────────────────────────────────────

  Future<BuiltTx> _build(String path, Map<String, dynamic> body) async {
    final res = await _postJson(path, body);
    final b64 = res['transactionBase64'];
    if (b64 is! String || b64.isEmpty) {
      // Owner supplied but no tx ⇒ a body-channel error (e.g. compute failure) or preview misuse.
      final err = res['err'] ?? res['error'] ?? 'no transactionBase64 in response';
      throw FlashError(FlashErrorChannel.bodyErr, '$path: $err');
    }
    return BuiltTx(b64);
  }

  Future<Map<String, dynamic>> _postJson(String path, Map<String, dynamic> body) async {
    final http.Response r;
    try {
      r = await _http.post(Uri.parse('$baseUrl$path'), headers: _json, body: jsonEncode(body));
    } on Object catch (e) {
      throw FlashError(FlashErrorChannel.transport, 'POST $path: $e');
    }
    if (r.statusCode == 400) {
      final msg = _tryDecode(r.body)?['error']?.toString() ?? r.body;
      throw FlashError(
        FlashErrorChannel.http400,
        'POST $path: $msg',
        httpStatus: 400,
        onChainCode: _extractCode(r.body),
      );
    }
    if (r.statusCode >= 500) {
      throw FlashError(
        FlashErrorChannel.http500,
        'POST $path: HTTP ${r.statusCode} ${r.body}',
        httpStatus: r.statusCode,
      );
    }
    final decoded = _tryDecode(r.body);
    if (decoded == null) {
      throw FlashError(FlashErrorChannel.transport, 'POST $path: non-JSON body: ${r.body}');
    }
    // Trading endpoints can return HTTP 200 with an `err` field.
    if (decoded['err'] != null) {
      throw FlashError(
        FlashErrorChannel.bodyErr,
        'POST $path: ${decoded['err']}',
        httpStatus: 200,
        onChainCode: _extractCode(decoded['err'].toString()),
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final body = await _getRaw(path);
    return _tryDecode(body) ??
        (throw FlashError(FlashErrorChannel.transport, 'GET $path: non-JSON'));
  }

  Future<String> _getRaw(String path) async {
    try {
      final r = await _http.get(Uri.parse('$baseUrl$path'));
      if (r.statusCode >= 400) {
        throw FlashError(
          FlashErrorChannel.transport,
          'GET $path: HTTP ${r.statusCode}',
          httpStatus: r.statusCode,
        );
      }
      return r.body;
    } on FlashError {
      rethrow;
    } on Object catch (e) {
      throw FlashError(FlashErrorChannel.transport, 'GET $path: $e');
    }
  }

  Map<String, dynamic>? _tryDecode(String body) {
    if (body.isEmpty) return null;
    try {
      final d = jsonDecode(body);
      return d is Map<String, dynamic> ? d : {'value': d};
    } on FormatException {
      return null;
    }
  }

  int? _extractCode(String s) => extractOnChainCode(s);
}

/// Withdrawable balance (raw token units) of [mint] from a decoded basket `account` object.
/// Per the protocol, `balance = deposits − debits + pendingCredits`; for a flat basket where the
/// position consumed the full deposit (debits == deposits) the net reduces to `pendingCredits`
/// (research/flash.md §3, confirmed live in the M0.3 spike: 10.994783 of 11.0). Clamped at 0.
int computeWithdrawableRaw(Map<String, dynamic> basketAccount, String mint) {
  final list = (basketAccount['pendingCredits'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  final credits = list
      .where((e) => e['mint'] == mint)
      .fold<int>(0, (a, e) => a + ((e['amount'] as num?)?.toInt() ?? 0));
  return credits < 0 ? 0 : credits;
}

/// Net basket adjustment for [mint] in raw units: `pendingCredits − debits`. Add
/// this to the deposit-ledger balance for the spendable total — the protocol's
/// `balance = deposits − debits + pendingCredits` (research/flash.md §3). The
/// deposit itself is NOT in the basket; it lives in the on-chain deposit ledger,
/// so a funded-but-not-yet-traded wallet has an all-zero basket and needs the
/// ledger read added on top.
int computeBasketNetRaw(Map<String, dynamic> basketAccount, String mint) =>
    _sumBasketMint(basketAccount, 'pendingCredits', mint) -
    _sumBasketMint(basketAccount, 'debits', mint);

int _sumBasketMint(Map<String, dynamic> account, String key, String mint) {
  final list = (account[key] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  return list
      .where((e) => e['mint'] == mint)
      .fold<int>(0, (a, e) => a + ((e['amount'] as num?)?.toInt() ?? 0));
}

/// Best-effort extraction of a Flash on-chain error code (e.g. "0x1784" → 6020, or a bare "6020").
int? extractOnChainCode(String s) {
  final hex = RegExp('0x([0-9a-fA-F]+)').firstMatch(s);
  if (hex != null) return int.tryParse(hex.group(1)!, radix: 16);
  final dec = RegExp(r'\b(60[0-9]{2}|61[0-9]{2})\b').firstMatch(s);
  return dec != null ? int.tryParse(dec.group(1)!) : null;
}
