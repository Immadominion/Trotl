/// The Magic Router's custom JSON-RPC methods (the ones a standard Solana RPC client does NOT have).
/// Endpoints: mainnet `https://router.magicblock.app`, devnet `https://devnet-router.magicblock.app`.
/// CORS `*`. Shapes live-verified 2026-06-13.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:magicblock_client/src/models.dart';

class RouterException implements Exception {
  RouterException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'RouterException($code): $message';
}

class RouterClient {
  RouterClient({this.url = 'https://devnet-router.magicblock.app', http.Client? client})
    : _http = client ?? http.Client();

  static const mainnet = 'https://router.magicblock.app';
  static const devnet = 'https://devnet-router.magicblock.app';

  final String url;
  final http.Client _http;

  void close() => _http.close();

  /// All ER validators (region, identity, fqdn, block time).
  Future<List<ErValidator>> getRoutes() async {
    final r = await _call('getRoutes', const []);
    return (r as List).cast<Map<String, dynamic>>().map(ErValidator.fromJson).toList();
  }

  /// Where (and whether) a PDA is delegated. `.fqdn` is the routing source of truth.
  Future<DelegationStatus> getDelegationStatus(String pubkey) async {
    final r = await _call('getDelegationStatus', [pubkey]);
    return DelegationStatus.fromJson(r as Map<String, dynamic>);
  }

  /// An ER-valid blockhash for a tx that touches the given (delegated) accounts.
  Future<BlockhashInfo> getBlockhashForAccounts(List<String> pubkeys) async {
    final r = await _call('getBlockhashForAccounts', [pubkeys]);
    return BlockhashInfo.fromJson(r as Map<String, dynamic>);
  }

  Future<String> getIdentity() async {
    final r = await _call('getIdentity', const []);
    return (r as Map<String, dynamic>)['identity'] as String;
  }

  /// Pick the validator with the lowest measured HTTP RTT (a quick `getIdentity` ping each).
  /// Used to choose a delegation target close to the client before delegating.
  Future<ErValidator> nearestValidator({int pings = 2}) async {
    final routes = await getRoutes();
    ErValidator? best;
    var bestMs = 1 << 30;
    for (final v in routes) {
      var min = 1 << 30;
      for (var i = 0; i < pings; i++) {
        final sw = Stopwatch()..start();
        try {
          await _http.post(
            Uri.parse(v.rpcUrl),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(
              {'jsonrpc': '2.0', 'id': 1, 'method': 'getIdentity', 'params': <Object?>[]},
            ),
          );
          sw.stop();
          if (sw.elapsedMilliseconds < min) min = sw.elapsedMilliseconds;
        } on Object {
          // unreachable validator — skip
        }
      }
      if (min < bestMs) {
        bestMs = min;
        best = v;
      }
    }
    if (best == null) throw RouterException(-1, 'no reachable ER validator');
    return best;
  }

  Future<Object> _call(String method, List<Object?> params) async {
    final res = await _http.post(
      Uri.parse(url),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final err = body['error'];
    if (err != null) {
      final e = err as Map<String, dynamic>;
      throw RouterException((e['code'] as num?)?.toInt() ?? 0, e['message']?.toString() ?? 'error');
    }
    final result = body['result'];
    if (result == null) throw RouterException(0, '$method returned no result');
    return result as Object;
  }
}
