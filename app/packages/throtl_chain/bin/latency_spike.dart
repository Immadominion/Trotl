// M0.1b — the REAL submit→WS-echo tick latency on a live devnet Ephemeral Rollup. The product's
// core bet: does the analog needle follow the thumb at ~tens of ms?
//
// Flow (no mocks): init_ride + delegate_ride on devnet base → wait for delegation → accountSubscribe
// to the RideSession PDA on the owning ER node → spam `tick` (session-signed, legacy, ER blockhash,
// skipPreflight) and measure submit → the WS echo whose tick_count reflects that tick.
//
//   dart run throtl_chain:latency_spike [ticks]
// ignore_for_file: depend_on_referenced_packages — dev-only spike; magicblock_client is a dev dep.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:magicblock_client/magicblock_client.dart';
import 'package:solana/dto.dart' hide Commitment;
import 'package:solana/solana.dart';
import 'package:throtl_chain/throtl_chain.dart';

const _baseRpc = 'https://rpc.magicblock.app/devnet';
const _ownerKeypair = '/Users/mac/.config/solana/id.json';
// tick_count is the 10th u64 of RideSession → byte offset 8(disc) + 9*8 = 80.
const _tickCountOffset = 80;

void _log(Object s) => stdout.writeln(s);

Future<Ed25519HDKeyPair> _loadCli(String path) async {
  final raw = (jsonDecode(File(path).readAsStringSync()) as List<dynamic>).cast<int>();
  return Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: raw.sublist(0, 32));
}

int _readTickCount(List<int> data) {
  if (data.length < _tickCountOffset + 8) return -1;
  return ByteData.sublistView(Uint8List.fromList(data)).getUint64(_tickCountOffset, Endian.little);
}

Future<void> main(List<String> args) async {
  final tickCount = args.isEmpty ? 40 : int.parse(args.first);
  final base = RpcClient(_baseRpc);
  final router = RouterClient();
  final program = ThrotlProgram();

  final owner = await _loadCli(_ownerKeypair);
  final session = await Ed25519HDKeyPair.random();
  final sessionId = DateTime.now().millisecondsSinceEpoch % 1000000000;
  final ride = await program.rideSession(owner.publicKey, sessionId);

  _log('owner:    ${owner.address}');
  _log('session:  ${session.address}');
  _log('ride PDA: ${ride.toBase58()}  (session_id $sessionId)\n');

  // ── pick the nearest validator to target the delegation ──────────────────────
  final near = await router.nearestValidator();
  _log('1) nearest ER: ${near.countryCode} ${near.fqdn} (${near.identity})');

  // ── init_ride + delegate_ride (one base-chain tx) ─────────────────────────────
  _log('2) init_ride + delegate_ride (devnet base)');
  final initIx = await program.initRide(
    owner: owner.publicKey,
    sessionId: sessionId,
    sessionKey: session.publicKey,
    marketId: 0,
    feedId: List<int>.filled(32, 0), // dummy feed: tick takes the staleness path but still updates
    gripMode: 0,
    fuelUsd6: 500000000,
    maxLevBps: 100000,
    lossFloor6: -200000000,
    expiresAt: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
  );
  final delIx = await program.delegateRide(
    owner: owner.publicKey,
    sessionId: sessionId,
    commitFrequencyMs: 30000,
    validator: Ed25519HDPublicKey.fromBase58(near.identity),
  );
  final baseBh = (await base.getLatestBlockhash()).value;
  final setupTx = await signTransaction(baseBh, Message(instructions: [initIx, delIx]), [owner]);
  final setupSig = await base.sendTransaction(
    setupTx.encode(),
    preflightCommitment: Commitment.confirmed,
  );
  _log('   sig=$setupSig — confirming…');
  await _confirm(base, setupSig);
  _log('   ✓ ride created + delegated');

  // ── wait until the router reports the ER host ─────────────────────────────────
  _log('3) waiting for delegation to land on an ER…');
  var erFqdn = near.fqdn;
  for (var i = 0; i < 30; i++) {
    final ds = await router.getDelegationStatus(ride.toBase58());
    if (ds.isDelegated && ds.fqdn != null) {
      erFqdn = ds.fqdn!;
      break;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  final erRpcUrl = erFqdn.replaceFirst(RegExp(r'/$'), '');
  final wsUrl = erRpcUrl.replaceFirst('https://', 'wss://');
  _log('   delegated to $erRpcUrl');

  // ── subscribe to the RideSession on the ER; track the latest tick_count ───────
  final ws = SubscriptionClient.connect(wsUrl);
  var latestCount = -1;
  final waiters = <int, Completer<void>>{};
  final sub = ws
      .accountSubscribe(
        ride.toBase58(),
        commitment: Commitment.confirmed,
        encoding: Encoding.base64,
      )
      .listen((acc) {
        final data = acc.data;
        if (data is BinaryAccountData) {
          final c = _readTickCount(data.data);
          if (c > latestCount) {
            latestCount = c;
            for (final e in waiters.entries.toList()) {
              if (e.key <= c) {
                e.value.complete();
                waiters.remove(e.key);
              }
            }
          }
        }
      });

  Future<void> awaitCount(int target, {Duration timeout = const Duration(seconds: 5)}) {
    if (latestCount >= target) return Future.value();
    final c = waiters.putIfAbsent(target, Completer<void>.new);
    return c.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException('echo for tick $target'),
    );
  }

  // ── tick loop: measure submit → echo ──────────────────────────────────────────
  _log('4) ticking $tickCount times on the ER (session-signed, legacy, skipPreflight)…\n');
  final erRpc = RpcClient(erRpcUrl);
  final oracle = Ed25519HDPublicKey.fromBase58(devnetSolPriceFeedPda);
  final totals = <int>[]; // submit → echo (full)
  final submits = <int>[]; // submit → sendTransaction returns (≈ client↔ER round trip)
  final echoes = <int>[]; // sendTransaction return → WS echo (≈ ER confirm + push, location-light)
  // Baseline network RTT: getAccountInfo round trip to this ER (no write).
  final rttSamples = <int>[];

  await Future<void>.delayed(const Duration(milliseconds: 500)); // let the WS settle

  for (var i = 1; i <= tickCount; i++) {
    final target = i.isEven ? 5000 : -5000; // alternate so the PDA changes every tick
    final erBh = await router.getBlockhashForAccounts([ride.toBase58()]);
    final tickIx = program.tick(
      ride: ride,
      priceFeed: oracle,
      sessionSigner: session.publicKey,
      targetExpBps: target,
    );
    final signed = await signTransaction(
      LatestBlockhash(blockhash: erBh.blockhash, lastValidBlockHeight: erBh.lastValidBlockHeight),
      Message(instructions: [tickIx]),
      [session],
    );
    final sw = Stopwatch()..start();
    try {
      await erRpc.sendTransaction(
        signed.encode(),
        skipPreflight: true,
        preflightCommitment: Commitment.confirmed,
      );
      final submitMs = sw.elapsedMilliseconds;
      await awaitCount(i);
      final totalMs = sw.elapsedMilliseconds;
      submits.add(submitMs);
      echoes.add(totalMs - submitMs);
      totals.add(totalMs);
      // Sample raw read RTT to attribute the network tax.
      final rtt = Stopwatch()..start();
      await erRpc.getLatestBlockhash(commitment: Commitment.confirmed);
      rttSamples.add(rtt.elapsedMilliseconds);
      if (i <= 3 || i % 10 == 0) {
        _log('   tick $i → submit ${submitMs}ms + echo ${totalMs - submitMs}ms = ${totalMs}ms');
      }
    } on Object catch (e) {
      _log('   tick $i FAILED after ${sw.elapsedMilliseconds}ms: $e');
      if (i == 1) rethrow; // first-tick failure is fatal (config issue, not a sample)
    }
  }

  await sub.cancel();
  ws.close();

  // ── report ────────────────────────────────────────────────────────────────────
  if (totals.isEmpty) {
    _log('\nNo successful ticks.');
    exit(1);
  }
  String stats(List<int> xs) {
    final s = [...xs]..sort();
    int p(int q) => s[((s.length - 1) * q / 100).floor()];
    return 'min=${s.first} p50=${p(50)} p90=${p(90)} p95=${p(95)} max=${s.last} ms';
  }

  _log('\n=== ${totals.length} ticks on $erRpcUrl (from this dev machine) ===');
  _log('  network RTT (getLatestBlockHeight): ${stats(rttSamples)}');
  _log('  submit (sendTransaction return):    ${stats(submits)}');
  _log('  echo (submit→WS account update):    ${stats(echoes)}');
  _log('  TOTAL submit→echo:                  ${stats(totals)}');
  _log(
    '\nReading: submit ≈ one client↔ER round trip; echo ≈ ER confirm (~1 block, 50ms) + push back.',
  );
  _log('The 50ms ER block time is NOT the bottleneck — end-to-end is dominated by client↔ER RTT.');
  _log('Product bar (p95 < 80ms felt) is reachable only with a low-RTT client near a regional ER');
  _log(
    '(the Seeker on good connectivity) + optimistic UI (show thumb immediately, reconcile on echo).',
  );
}

Future<void> _confirm(
  RpcClient rpc,
  String sig, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final stop = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(stop)) {
    final st = await rpc.getSignatureStatuses([sig], searchTransactionHistory: true);
    final s = st.value.isEmpty ? null : st.value.first;
    if (s != null) {
      if (s.err != null) throw StateError('tx $sig failed: ${s.err}');
      if (s.confirmationStatus == ConfirmationStatus.confirmed ||
          s.confirmationStatus == ConfirmationStatus.finalized) {
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  throw StateError('tx $sig not confirmed within $timeout');
}
