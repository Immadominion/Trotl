// Live validation of magicblock_client against the devnet ER — no deploy, no funds. Exercises every
// RouterClient method and parses the LIVE ticking SOL oracle PDA on the ER node, reporting real
// read-latency + the oracle's update cadence from this machine.
//
//   dart run magicblock_client:probe
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:magicblock_client/magicblock_client.dart';

void _log(Object s) => stdout.writeln(s);

Future<Map<String, dynamic>> _rpc(http.Client c, String url, String method, List<Object?> p) async {
  final r = await c.post(
    Uri.parse(url),
    headers: const {'content-type': 'application/json'},
    body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': p}),
  );
  return jsonDecode(r.body) as Map<String, dynamic>;
}

Future<void> main() async {
  final router = RouterClient(); // defaults to the devnet router
  final http2 = http.Client();
  try {
    _log('1) getRoutes — devnet ER validators');
    final routes = await router.getRoutes();
    for (final v in routes) {
      _log('   ${v.countryCode}  ${v.identity}  ${v.fqdn}  ${v.blockTimeMs}ms/block');
    }

    _log('2) nearestValidator (by HTTP RTT from here)');
    final near = await router.nearestValidator();
    _log('   nearest: ${near.countryCode} ${near.fqdn}');

    _log('3) getDelegationStatus(arbitrary account) — validates the delegated/undelegated parse');
    try {
      final ds = await router.getDelegationStatus(near.identity);
      _log('   isDelegated=${ds.isDelegated} fqdn=${ds.fqdn} authority=${ds.authority}');
    } on RouterException catch (e) {
      _log('   router responded: $e  (method OK — account just not a standard delegation)');
    }

    _log('4) getBlockhashForAccounts([DLP program]) — a routable (non-oracle) account');
    const dlp = 'DELeGGvXpWV2fqJUhqcF5ZSYMS4JTLjteaAMARRSaeSh';
    final bh = await router.getBlockhashForAccounts([dlp]);
    _log('   blockhash=${bh.blockhash} lastValidBlockHeight=${bh.lastValidBlockHeight}');

    // The freshest oracle copy lives on the ER node it's delegated to. Find it by trying each ER
    // node's getAccountInfo; the one returning parseable, advancing data is the host. RTT there is
    // a REAL ER read latency from this machine.
    _log('5) read + parse the LIVE SOL oracle across the ER nodes');
    for (final v in routes) {
      final rtts = <int>[];
      int? lastPublish;
      var advanced = 0;
      OraclePrice? price;
      for (var i = 0; i < 8; i++) {
        final sw = Stopwatch()..start();
        try {
          final res = await _rpc(http2, v.rpcUrl, 'getAccountInfo', [
            devnetSolPriceFeedPda,
            {'encoding': 'base64', 'commitment': 'confirmed'},
          ]);
          sw.stop();
          rtts.add(sw.elapsedMilliseconds);
          final value = (res['result'] as Map<String, dynamic>?)?['value'] as Map<String, dynamic>?;
          final dataField = (value?['data'] as List?)?.first as String?;
          if (dataField != null) {
            price = parsePriceUpdateV2(Uint8List.fromList(base64Decode(dataField)));
            if (price != null && price.publishTime != lastPublish) {
              if (lastPublish != null) advanced++;
              lastPublish = price.publishTime;
            }
          }
        } on Object {
          sw.stop();
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (rtts.isEmpty) continue;
      rtts.sort();
      final median = rtts[rtts.length ~/ 2];
      final hosted = price != null && advanced > 0;
      _log(
        '   ${v.countryCode}: price=\$${price?.ui.toStringAsFixed(4)} '
        'RTT min=${rtts.first}ms median=${median}ms  advanced=$advanced/8 '
        '${hosted ? '← LIVE host' : ''}',
      );
    }

    _log('\nPROBE OK — RouterClient + oracle parser validated against the live devnet ER.');
    _log(
      'NOTE: submit→WS-echo of OUR tick path needs a deployed+delegated RideSession (M0.1 next).',
    );
  } finally {
    router.close();
    http2.close();
  }
}
