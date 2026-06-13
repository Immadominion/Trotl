// Live end-to-end ride against the REAL devnet throtl-engine — the whole stack with no mocks on the
// on-chain half: init+delegate a ride on devnet base → tick it on its Ephemeral Rollup against the
// REAL in-ER Pyth Lazer SOL oracle (full mark path) → the RideSession account-subscription feed
// decodes each live update (throtl_chain) → the RideExecutor runs the real reconciler FSM and drives
// a position. The Flash settlement is the SimGateway here ONLY because Flash Trade is mainnet-only
// (devnet has no Flash deployment); the Flash leg itself is proven live on mainnet by M0.3. So:
// program + ER + oracle + WS + decode + reconciler = 100% live; Flash venue = simulated on devnet.
//
//   dart run throtl_live:live_ride [ticks]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:magicblock_client/magicblock_client.dart';
import 'package:solana/dto.dart' hide Commitment;
import 'package:solana/solana.dart';
import 'package:throtl_chain/throtl_chain.dart';
import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_live/throtl_live.dart';
import 'package:throtl_runtime/throtl_runtime.dart';

const _baseRpc = 'https://rpc.magicblock.app/devnet';
const _ownerKeypair = '/Users/mac/.config/solana/id.json';

// Ride economics for the demo (matches the on-chain validations + the executor's cap math).
const _fuelUsd6 = 500000000; // $500
const _maxLevBps = 100000; // 10x
const _lossFloor6 = -200000000; // −$200

void _log(Object s) => stdout.writeln(s);
int _nowMicros() => DateTime.now().microsecondsSinceEpoch;

Future<Ed25519HDKeyPair> _loadCli(String path) async {
  final raw = (jsonDecode(File(path).readAsStringSync()) as List<dynamic>).cast<int>();
  return Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: raw.sublist(0, 32));
}

Future<void> main(List<String> args) async {
  final base = RpcClient(_baseRpc);
  final router = RouterClient();
  final program = ThrotlProgram();

  final owner = await _loadCli(_ownerKeypair);
  final session = await Ed25519HDKeyPair.random();
  final sessionId = DateTime.now().millisecondsSinceEpoch % 1000000000;
  final ride = await program.rideSession(owner.publicKey, sessionId);
  final oracle = Ed25519HDPublicKey.fromBase58(devnetSolPriceFeedPda);

  _log('owner:    ${owner.address}');
  _log('session:  ${session.address}');
  _log('ride PDA: ${ride.toBase58()}  (session_id $sessionId)\n');

  // ── read the live oracle's feed_id so the ride marks against the REAL SOL price (full mark path) ──
  final oracleAcc = await base.getAccountInfo(
    devnetSolPriceFeedPda,
    encoding: Encoding.base64,
    commitment: Commitment.confirmed,
  );
  final oracleData = (oracleAcc.value?.data as BinaryAccountData?)?.data;
  if (oracleData == null || oracleData.length < 73) {
    _log('FATAL: could not read devnet SOL oracle $devnetSolPriceFeedPda');
    exit(1);
  }
  final feedId = oracleData.sublist(41, 73); // PriceUpdateV3 feed_id @ offset 41
  _log('oracle:   $devnetSolPriceFeedPda  (feed_id read; live SOL price comes from the ER)');

  // ── init_ride (real feed) + delegate_ride, one base-chain tx ──────────────────
  _log('\n1) init_ride + delegate_ride (devnet base)');
  final near = await router.nearestValidator();
  final initIx = await program.initRide(
    owner: owner.publicKey,
    sessionId: sessionId,
    sessionKey: session.publicKey,
    marketId: 0,
    feedId: feedId,
    gripMode: 0,
    fuelUsd6: _fuelUsd6,
    maxLevBps: _maxLevBps,
    lossFloor6: _lossFloor6,
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
  await _confirm(base, setupSig);
  _log('   ✓ ride created + delegated (sig $setupSig)');

  // ── wait for the ER host ───────────────────────────────────────────────────────
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
  final erWsUrl = erRpcUrl.replaceFirst('https://', 'wss://');
  final erRpc = RpcClient(erRpcUrl);
  _log('   delegated to $erRpcUrl\n');

  // ── guard mark: an independent read of the SOL price for the ER-vs-truth divergence check. On
  //    devnet the only LIVE SOL feed is the in-ER oracle, so we read it via the ER RPC — a separate
  //    read from the program's in-ER mark (weakly independent). PRODUCTION wires a truly independent
  //    Hermes / L1 Pyth guard here; the divergence logic in throtl_core is identical either way.
  Future<int> readErMark() async {
    try {
      final a = await erRpc.getAccountInfo(devnetSolPriceFeedPda, encoding: Encoding.base64);
      final d = (a.value?.data as BinaryAccountData?)?.data;
      final p = d == null ? null : parsePriceUpdateV2(Uint8List.fromList(d));
      return p?.priceE9 ?? 0;
    } on Object {
      return 0; // transient RPC hiccup — caller keeps the last guard mark
    }
  }

  var guardE9 = await readErMark();
  final guardPoll = Timer.periodic(const Duration(milliseconds: 600), (_) async {
    final m = await readErMark();
    if (m > 0) guardE9 = m;
  });

  // ── the executor: real reconciler FSM + SimGateway (Flash venue is mainnet-only) ────────────────
  const cfg = RideConfig(
    fuelUsd6: _fuelUsd6,
    maxLevBps: _maxLevBps,
    lossFloor6: _lossFloor6,
    marketId: 0,
  );
  final gw = SimGateway();
  final executor = RideExecutor(ride: cfg, gateway: gw);
  final feed = ErRideFeed(
    guardMark: () => guardE9,
    session: () => MarketSession.regular,
    now: _nowMicros,
  );

  // ── consume the LIVE RideSession stream → decode → reconcile → drive the (sim) position ─────────
  _log('2) live reconcile: each row is a REAL on-chain RideSession update driving the executor\n');
  _log(r'   tick │ virt_exp │ notional($) │ er_mark │ reconciler action → settled');
  _log('   ─────┼──────────┼─────────────┼─────────┼─────────────────────────────');
  var lastTick = -1;
  final feedSub = feed.transform(rideAccountBytes(erWsUrl, ride.toBase58())).listen((obs) async {
    final r = obs.ride;
    if (r.tickCount == lastTick) return; // only act on a new tick
    lastTick = r.tickCount;
    final action = await executor.onObservation(obs);
    final notionalUi = (r.notionalUsd6 / 1e6).toStringAsFixed(2);
    final markUi = (r.lastMarkE9 / 1e9).toStringAsFixed(2);
    final s = gw.settled;
    final settledStr = s.isFlat
        ? 'flat'
        : '${s.side.name} \$${(s.sizeUsd6 / 1e6).toStringAsFixed(0)}'
              '${s.hasStop ? ' (stop)' : ' (NO STOP!)'}';
    _log(
      '   ${r.tickCount.toString().padLeft(4)} │ ${r.virtExpBps.toString().padLeft(8)} │ '
      '${notionalUi.padLeft(11)} │ ${markUi.padLeft(7)} │ ${_actName(action)} → $settledStr',
    );
  });

  // Submit one tick to the ER, retrying once on a transient ER/router error (devnet infra resets).
  Future<void> submitTick(int target) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final erBh = await router.getBlockhashForAccounts([ride.toBase58()]);
        final tickIx = program.tick(
          ride: ride,
          priceFeed: oracle,
          sessionSigner: session.publicKey,
          targetExpBps: target,
        );
        final signed = await signTransaction(
          LatestBlockhash(
            blockhash: erBh.blockhash,
            lastValidBlockHeight: erBh.lastValidBlockHeight,
          ),
          Message(instructions: [tickIx]),
          [session],
        );
        await erRpc.sendTransaction(
          signed.encode(),
          skipPreflight: true,
          preflightCommitment: Commitment.confirmed,
        );
        return;
      } on Object catch (e) {
        if (attempt == 1) _log('   (tick retry failed: $e)');
      }
    }
  }

  // A HELD schedule (each level repeated so the reconciler's 400ms debounce clears at the 700ms
  // cadence and it acts): ease to a near-full LONG → drag through flat to full SHORT (the flip) →
  // release to flat. This is the signature analog interaction, driven entirely by on-chain state.
  const schedule = [0, 9000, 9000, 9000, 9000, 9000, -9000, -9000, -9000, -9000, -9000, 0, 0, 0];
  await Future<void>.delayed(
    const Duration(milliseconds: 700),
  ); // let the WS + first guard poll settle
  for (final target in schedule) {
    await submitTick(target);
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }
  await Future<void>.delayed(const Duration(seconds: 1)); // drain the last echoes

  // ── cleanup: flatten the virtual position (full request_settle + close_ride is the M4 teardown
  //    path — it needs the MagicBlock commit-context account wiring). The ride auto-expires in 1h. ──
  _log('\n3) cleanup: flatten the virtual position → 0');
  try {
    final erBh = await router.getBlockhashForAccounts([ride.toBase58()]);
    final flatIx = program.flatten(ride: ride, priceFeed: oracle, sessionSigner: session.publicKey);
    final flatTx = await signTransaction(
      LatestBlockhash(blockhash: erBh.blockhash, lastValidBlockHeight: erBh.lastValidBlockHeight),
      Message(instructions: [flatIx]),
      [session],
    );
    await erRpc.sendTransaction(flatTx.encode(), skipPreflight: true);
    _log('   ✓ flatten submitted');
  } on Object catch (e) {
    _log('   cleanup note: $e');
  }

  await feedSub.cancel();
  guardPoll.cancel();
  _log('\nDone. The on-chain half ran live; Flash settlement was simulated (mainnet-only venue).');
  exit(0);
}

String _actName(ReconcilerAction a) => switch (a) {
  OpenIncrease(:final side, :final addUsd6) =>
    'open ${side.name} +\$${(addUsd6 / 1e6).toStringAsFixed(0)}',
  ReducePartial(:final side, :final reduceUsd6) =>
    'reduce ${side.name} −\$${(reduceUsd6 / 1e6).toStringAsFixed(0)}',
  FullClose(:final side) => 'close ${side.name}',
  Flip(:final toSide, :final openUsd6) =>
    'FLIP→${toSide.name} \$${(openUsd6 / 1e6).toStringAsFixed(0)}',
  ReplaceStop(:final side) => 're-stop ${side.name}',
  NoOp() => '·',
};

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
