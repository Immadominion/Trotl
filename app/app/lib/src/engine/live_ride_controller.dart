import 'dart:async';
import 'dart:math' as math;

import 'package:flash_client/flash_client.dart';
import 'package:flutter/foundation.dart';
import 'package:magicblock_client/magicblock_client.dart';
import 'package:solana/dto.dart' hide Commitment;
import 'package:solana/encoder.dart' as enc show Instruction;
import 'package:solana/solana.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/chain/go_live.dart';
import 'package:throtl/src/chain/markets.dart';
import 'package:throtl/src/chain/network.dart';
import 'package:throtl/src/chain/rent_reclaim.dart';
import 'package:throtl/src/chain/tx_builder.dart';
import 'package:throtl/src/engine/price_feed.dart';
import 'package:throtl/src/engine/ride_controller.dart';
import 'package:throtl/src/wallet/flash_funding.dart';
import 'package:throtl/src/wallet/flash_session.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl_chain/throtl_chain.dart';
import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_live/throtl_live.dart';
import 'package:throtl_runtime/throtl_runtime.dart';

/// Where a live ride is in its lifecycle (surfaced to the cockpit).
enum LiveRideStatus { arming, riding, degraded, error, ended }

/// A REAL on-chain ride — the [RideEngine] the cockpit binds to when a wallet is
/// connected. A faithful adaptation of `throtl_live/bin/live_ride.dart`:
///
///   • arm → generate an ephemeral session key → `init_ride` + `delegate_ride`
///     in one base-chain tx that the **OWNER signs via MWA** (the only wallet
///     popup) → confirm → wait for the ER host → subscribe to the RideSession.
///   • ride → the thumb writes a signed `target_exp_bps` via **gasless,
///     session-signed `tick`** ixs on the ER (no popup); each WS echo decodes
///     the live RideSession (throtl_chain) and drives the real reconciler
///     ([RideExecutor]); the needle reads the on-chain state.
///   • end → `flatten` the virtual position. (Full `request_settle`/`close_ride`
///     teardown is Phase D.)
///
/// On devnet the Flash settlement leg is the deterministic [SimGateway] (Flash
/// is mainnet-only); program + ER + oracle + WS + decode + reconciler are 100%
/// live. The bookkeeping (realized/open PnL, streaks, feed rows) mirrors the
/// practice [RideController] so the cockpit renders identically.
class LiveRideController extends ChangeNotifier implements RideEngine {
  LiveRideController({
    required this.wallet,
    required this.network,
    required this.config,
  });

  final WalletController wallet;
  final NetworkConfig network;
  final RideConfig config;

  // ── chain plumbing ──
  final ThrotlProgram _program = ThrotlProgram();
  late final RouterClient _router = RouterClient(url: network.routerUrl);
  final FlashApi _flashApi = FlashApi();
  // Default to the simulated venue; a real-money go-live ride swaps in a
  // session-signed RealFlashGateway during _arm (after minting the Flash session).
  FlashGateway _gateway = SimGateway();
  late RideExecutor _executor = RideExecutor(ride: config, gateway: _gateway);

  Ed25519HDKeyPair? _session;
  Ed25519HDPublicKey? _ride;
  Ed25519HDPublicKey? _oracle;
  RpcClient? _erRpc;
  StreamSubscription<RideObservation>? _feedSub;
  Timer? _guardPoll;
  Timer? _tickPacer;
  int _sessionId = 0;
  int _guardE9 = 0;
  bool _submitting = false;

  // ── settle / teardown ──
  SettlePhase _settlePhase = SettlePhase.none;
  String? _settleNote;
  String? _settleSig;
  bool _tearingDown = false;
  bool _disposed = false;

  // ── ride state (mirrors RideController) ──
  final _LiveMarkFeed _markFeed = _LiveMarkFeed();
  final Stopwatch _clock = Stopwatch()..start();
  LiveRideStatus _status = LiveRideStatus.arming;
  String? _error;
  String? _armNote; // human "what's happening now" line for the Arming screen
  bool _armed = false;
  bool _running = false;

  double _throttle = 0;
  bool _coasting = false;
  double _coastFrom = 0;
  int _coastStartMs = 0;
  int _panicAtMs = -10000;

  int _markE9 = 162400000000;
  int _realized6 = 0;
  int _openPnl6 = 0;
  int _ticks = 0;
  double _xp = 0;
  int _streak = 0;
  int _bestStreak = 0;
  int _trades = 0;
  int _wins = 0;
  double _peakLev = 0;
  int _lastEchoTick = -1;
  final List<TickRow> _feed = [];
  final math.Random _rng = math.Random();

  static const _b58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  /// Lifecycle for the cockpit (arming overlay / degraded banner).
  LiveRideStatus get status => _status;
  String? get error => _error;

  /// The current arming step ("Confirm in your wallet…", "Waiting for the
  /// rollup…") so the Arming screen can tell the user what's happening.
  String? get armNote => _armNote;

  /// notifyListeners that is a no-op once disposed — the arming/teardown futures
  /// can outlive the screen (user navigates away mid-flight) and a notify on a
  /// disposed ChangeNotifier throws.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _setArm(String note) {
    _armNote = note;
    _notify();
  }

  @override
  SettlePhase get settlePhase => _settlePhase;
  @override
  String? get settleNote => _settleNote;
  @override
  String? get settleSig => _settleSig;

  bool get panicActive => _panicAtMs > 0 && _clock.elapsedMilliseconds - _panicAtMs < 900;

  @override
  PriceFeed get feed => _markFeed;

  @override
  RideSnapshot get snapshot {
    final eq = effectiveEquity6(config.fuelUsd6, _realized6, _openPnl6);
    return RideSnapshot(
      throttle: _throttle,
      markE9: _markE9,
      position: _gateway.settled,
      fsm: _executor.state,
      openPnl6: _openPnl6,
      realizedPnl6: _realized6,
      equity6: eq,
      floorBreached: eq <= config.lossFloor6,
      ticks: _ticks,
      xp: _xp,
      streak: _streak,
      bestStreak: _bestStreak,
      peakLev: _peakLev,
      panicActive: panicActive,
      maxLevBps: config.maxLevBps,
      feed: List.unmodifiable(_feed),
    );
  }

  @override
  void start() {
    if (_running) return;
    _running = true;
    _markFeed.start();
    unawaited(_arm());
  }

  @override
  void stop() {
    _running = false;
    _tickPacer?.cancel();
    _guardPoll?.cancel();
    unawaited(_feedSub?.cancel());
  }

  @override
  void setThrottle(double value) {
    _coasting = false;
    _throttle = value.clamp(-1.0, 1.0);
    notifyListeners();
  }

  @override
  void release() {
    _coasting = true;
    _coastFrom = _throttle;
    _coastStartMs = _clock.elapsedMilliseconds;
  }

  @override
  void spinOut() {
    _throttle = 0;
    _coasting = false;
    _panicAtMs = _clock.elapsedMilliseconds;
    sfx
      ..skid()
      ..eject();
    unawaited(_submitFlatten());
    notifyListeners();
  }

  @override
  SessionStats finish() {
    if (_tearingDown) return _statsNow();
    _tearingDown = true;
    stop(); // freeze the live feed/pacer; the teardown below is feed-independent
    // Realize the still-open position into the banked total — the flatten closes it on-chain.
    if (!_gateway.settled.isFlat) {
      _realized6 += _openPnl6;
      _openPnl6 = 0;
    }
    _status = LiveRideStatus.ended;
    unawaited(_teardown());
    return _statsNow();
  }

  SessionStats _statsNow() => SessionStats(
    realized6: _realized6,
    ticks: _ticks,
    bestStreak: _bestStreak,
    peakLev: _peakLev,
    winRate: _trades > 0 ? (100 * _wins / _trades).round() : 0,
  );

  @override
  void dispose() {
    _disposed = true;
    stop();
    _router.close();
    _flashApi.close();
    _markFeed.dispose();
    super.dispose();
  }

  // ── arming: init + delegate (owner via MWA) → ER subscribe ───────────────
  Future<void> _arm() async {
    try {
      _setArm('Preparing your ride…');
      final ownerStr = wallet.owner;
      if (ownerStr == null) throw StateError('wallet not connected');
      final owner = Ed25519HDPublicKey.fromBase58(ownerStr);
      final session = await wallet.newSession();
      _session = session;
      _sessionId = DateTime.now().millisecondsSinceEpoch % 1000000000;
      final ride = await _program.rideSession(owner, _sessionId);
      _ride = ride;
      _oracle = Ed25519HDPublicKey.fromBase58(Market.byId(config.marketId).feedPda);

      // Fetch the three independent inputs CONCURRENTLY — the oracle feed id, the
      // nearest rollup validator, and a recent blockhash. Serially these were the
      // slow wait *before* the wallet popup; in parallel it's one round-trip.
      _setArm('Reading the live oracle + nearest rollup…');
      final base = RpcClient(network.baseRpc);
      final feedIdF = _readFeedId(base);
      final nearF = _router.nearestValidator();
      final bhF = base.getLatestBlockhash();
      // Await them together so a rejection in ANY of the three is observed right
      // here. A staggered `await a; await b;` would jump to catch on the first
      // failure and orphan the others — their later rejections become unhandled
      // zone errors (red spam), which a flaky mainnet RPC triggers all at once.
      await Future.wait([feedIdF, nearF, bhF]);
      final feedId = await feedIdF;
      final near = await nearF;

      final initIx = await _program.initRide(
        owner: owner,
        sessionId: _sessionId,
        sessionKey: session.publicKey,
        marketId: config.marketId,
        feedId: feedId,
        gripMode: 0,
        fuelUsd6: config.fuelUsd6,
        maxLevBps: config.maxLevBps,
        lossFloor6: config.lossFloor6,
        expiresAt: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      );
      final delIx = await _program.delegateRide(
        owner: owner,
        sessionId: _sessionId,
        commitFrequencyMs: 30000,
        validator: Ed25519HDPublicKey.fromBase58(near.identity),
      );

      // OWNER signs init+delegate via MWA (the single wallet popup of the ride).
      final bh = (await bhF).value;
      final unsignedTx = buildUnsignedLegacyTx(
        instructions: [initIx, delIx],
        recentBlockhash: bh.blockhash,
        feePayer: owner,
      );
      _setArm('Confirm in your wallet — this opens your ride session on-chain.');
      final sigs = await wallet.signAndSend([unsignedTx]);
      _setArm('Confirming on Solana…');
      await _confirm(base, sigs.first);

      // Connected = real money: mint a gasless Flash session key (the one extra owner
      // popup) and swap the SimGateway for a session-signed RealFlashGateway. After
      // this, every Flash trade is signed in-memory by the ephemeral key — no popups.
      _setArm('Confirm the Flash session key in your wallet…');
      await _armFlashSession(owner, base);

      _setArm('Handing your ride to the rollup…');

      // wait for the ER host to pick up the delegation
      var erFqdn = near.fqdn;
      for (var i = 0; i < 30 && _running; i++) {
        final ds = await _router.getDelegationStatus(ride.toBase58());
        if (ds.isDelegated && ds.fqdn != null) {
          erFqdn = ds.fqdn!;
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (!_running || _disposed) return;
      final erRpcUrl = erFqdn.replaceFirst(RegExp(r'/$'), '');
      final erWsUrl = erRpcUrl.replaceFirst('https://', 'wss://');
      _erRpc = RpcClient(erRpcUrl);

      // independent guard mark (drives the road + the reconciler's price cross-check)
      _guardE9 = await _readErMark();
      // CANCEL can land during the await above — bail before pushing into the
      // (now disposed) feed and before spawning the poll/sub/pacer below, or they
      // become orphaned forever-running timers + a leaked websocket.
      if (!_running || _disposed) return;
      if (_guardE9 > 0) _markFeed.pushMark(_guardE9);

      // Real-money safety: never trade against a dead feed. If this market's oracle
      // isn't live on this rollup, block the ride with a clear message (vs marking blind).
      if (_guardE9 <= 0) {
        final sym = Market.byId(config.marketId).symbol;
        _error =
            "$sym's live oracle feed isn't available on this rollup yet — "
            "can't trade real money against a dead feed. Try SOL, or check back.";
        _status = LiveRideStatus.error;
        _notify();
        return;
      }
      _guardPoll = Timer.periodic(const Duration(milliseconds: 600), (_) async {
        if (_disposed) return; // never push into a disposed feed
        final m = await _readErMark();
        if (_disposed) return;
        if (m > 0) {
          _guardE9 = m;
          _markFeed.pushMark(m);
        }
      });

      // subscribe to the live RideSession → decode → reconcile
      final erFeed = ErRideFeed(
        guardMark: () => _guardE9,
        session: () => MarketSession.regular,
        now: () => DateTime.now().microsecondsSinceEpoch,
      );
      _feedSub = erFeed
          .transform(rideAccountBytes(erWsUrl, ride.toBase58()))
          .listen(_onObservation, onError: (Object _) => _degrade());

      _tickPacer = Timer.periodic(const Duration(milliseconds: 140), (_) => unawaited(_pace()));
      _armed = true;
      _armNote = null;
      _status = LiveRideStatus.riding;
      _notify();
    } on Object catch (e) {
      _error = '$e';
      _status = LiveRideStatus.error;
      _notify();
    }
  }

  // Mint a Flash session key (owner-signed, base chain) and swap the SimGateway for a
  // session-signed RealFlashGateway — after this, Flash trades are gasless (no popups).
  Future<void> _armFlashSession(Ed25519HDPublicKey owner, RpcClient base) async {
    final flashSession = await Ed25519HDKeyPair.random();
    final validUntil = DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000;
    final sessionIx = await createSessionV2Ix(
      owner: owner,
      sessionSigner: flashSession.publicKey,
      validUntilUnix: validUntil,
    );
    final bh = (await base.getLatestBlockhash()).value;
    final unsigned = buildUnsignedLegacyTx(
      instructions: [sessionIx],
      recentBlockhash: bh.blockhash,
      feePayer: owner,
    );
    final sigs = await wallet.signAndSend([unsigned]);
    await _confirm(base, sigs.first);

    final token = await sessionTokenV2Pda(sessionSigner: flashSession.publicKey, authority: owner);
    final erRpc = RpcClient(flashErRpc);
    _gateway = RealFlashGateway(
      api: _flashApi,
      owner: owner.toBase58(),
      signer: flashSession.publicKey.toBase58(),
      sessionToken: token.toBase58(),
      signSubmit: flashSessionSignSubmit(flashSession, erRpc),
      readSettled: flashReadSettled(
        _flashApi,
        owner.toBase58(),
        Market.byId(config.marketId).symbol,
      ),
    );
    _executor = RideExecutor(ride: config, gateway: _gateway);
  }

  // ── the live RideSession echo → reconcile → bookkeeping ──────────────────
  Future<void> _onObservation(RideObservation obs) async {
    final r = obs.ride;
    final mark = r.lastMarkE9 != 0 ? r.lastMarkE9 : _guardE9;
    if (mark > 0) _markE9 = mark;

    final before = _gateway.settled;
    await _executor.onObservation(obs);
    final after = _gateway.settled;

    final realizedDelta = _realizedBetween(before, after, _markE9);
    if (realizedDelta != 0) {
      _realized6 += realizedDelta;
      _trades++;
      if (realizedDelta > 5000) {
        _wins++;
        _streak++;
        _bestStreak = math.max(_bestStreak, _streak);
      } else if (realizedDelta < -5000) {
        _streak = 0;
      }
      _feed.insert(0, TickRow.settle(sig: _sig(), pnl6: realizedDelta, panic: panicActive));
    }
    _openPnl6 = unrealizedPnl6(after.signedUsd6, after.entryE9, _markE9);

    // a new on-chain tick landed → stream a lap-ticker row off the real lev
    if (r.tickCount != _lastEchoTick) {
      _lastEchoTick = r.tickCount;
      _ticks = r.tickCount;
      final lev = (r.virtExpBps / bpsScale) * (config.maxLevBps / bpsScale);
      _xp += 1 + lev.abs() * 0.2;
      _peakLev = math.max(_peakLev, lev.abs());
      _feed.insert(0, TickRow.tick(n: _ticks, sig: _sig(), lev: lev, ms: 28 + _rng.nextInt(22)));
    }
    if (_feed.length > 24) _feed.removeRange(24, _feed.length);
    if (_status == LiveRideStatus.degraded) _status = LiveRideStatus.riding;
    _notify();
  }

  // ── the tick pacer: session-signed `tick` to the ER (gasless, no popup) ──
  Future<void> _pace() async {
    if (!_armed || !_running) return;
    if (_coasting) {
      final dt = _clock.elapsedMilliseconds - _coastStartMs;
      final k = (dt / 500).clamp(0.0, 1.0);
      _throttle = _coastFrom * (1 - k);
      if (k >= 1) {
        _throttle = 0;
        _coasting = false;
      }
      notifyListeners();
    }
    final target = _throttle.abs() < 0.05 ? 0 : (_throttle * 10000).round();
    // keep ticking while levered (so the program keeps marking PnL) or whenever
    // the settled position isn't yet flat (so a release drains to zero on-chain)
    if (target == 0 && _gateway.settled.isFlat) return;
    await _submitTick(target);
  }

  Future<void> _submitTick(int targetExpBps) async {
    final ride = _ride;
    final session = _session;
    final oracle = _oracle;
    final erRpc = _erRpc;
    if (ride == null || session == null || oracle == null || erRpc == null) return;
    if (_submitting) return; // never overlap ER submits
    _submitting = true;
    try {
      final erBh = await _router.getBlockhashForAccounts([ride.toBase58()]);
      final ix = _program.tick(
        ride: ride,
        priceFeed: oracle,
        sessionSigner: session.publicKey,
        targetExpBps: targetExpBps,
      );
      final signed = await signTransaction(
        LatestBlockhash(blockhash: erBh.blockhash, lastValidBlockHeight: erBh.lastValidBlockHeight),
        Message(instructions: [ix]),
        [session],
      );
      await erRpc.sendTransaction(signed.encode(), skipPreflight: true);
    } on Object {
      _degrade(); // transient ER/router hiccup — show degraded, keep trying
    } finally {
      _submitting = false;
    }
  }

  Future<void> _submitFlatten() async {
    final ride = _ride;
    final session = _session;
    final oracle = _oracle;
    final erRpc = _erRpc;
    if (ride == null || session == null || oracle == null || erRpc == null) return;
    try {
      final erBh = await _router.getBlockhashForAccounts([ride.toBase58()]);
      final ix = _program.flatten(ride: ride, priceFeed: oracle, sessionSigner: session.publicKey);
      final signed = await signTransaction(
        LatestBlockhash(blockhash: erBh.blockhash, lastValidBlockHeight: erBh.lastValidBlockHeight),
        Message(instructions: [ix]),
        [session],
      );
      await erRpc.sendTransaction(signed.encode(), skipPreflight: true);
    } on Object catch (_) {
      // ride auto-expires in 1h; a missed flatten is bounded by the loss floor.
    }
  }

  // ── settle teardown: flatten → request_settle → undelegate → close_ride ──────
  // Called once from finish(). Feed-independent (finish() already cancelled the live
  // feed/pacer), so it survives the cockpit calling stop(). The money is settled once
  // request_settle lands; the final owner-signed close_ride (the 2nd & last popup) just
  // reclaims the ride PDA's rent — so a declined close is non-fatal.
  Future<void> _teardown() async {
    final ride = _ride;
    final session = _session;
    final oracle = _oracle;
    final erRpc = _erRpc;
    final ownerStr = wallet.owner;
    if (ride == null || ownerStr == null) {
      _setSettle(SettlePhase.failed, note: 'ride was not armed');
      return;
    }
    final owner = Ed25519HDPublicKey.fromBase58(ownerStr);
    final base = RpcClient(network.baseRpc);

    try {
      // 1) flatten the virtual position on the ER (gasless, session-signed)
      _setSettle(SettlePhase.flattening);
      if (session != null && oracle != null && erRpc != null) {
        await _sendErSession(
          [_program.flatten(ride: ride, priceFeed: oracle, sessionSigner: session.publicKey)],
          session,
          ride,
          erRpc,
        );
        await Future<void>.delayed(const Duration(milliseconds: 700)); // let the ER apply it
      }

      // 2) request_settle: commit the final ER state to L1 + undelegate (gasless, session-signed)
      _setSettle(SettlePhase.committing);
      if (session != null && erRpc != null) {
        final magicContext = Ed25519HDPublicKey.fromBase58(magicContextId);
        await _sendErSession(
          [
            _program.requestSettle(
              payer: session.publicKey,
              ride: ride,
              magicContext: magicContext,
            ),
          ],
          session,
          ride,
          erRpc,
        );
      }

      // 3) wait for the delegation program to bring the PDA back to L1
      _setSettle(SettlePhase.undelegating);
      await _awaitUndelegation(ride);

      // 4) close_ride on L1 — OWNER signs via MWA (the 2nd & final wallet popup), rent → owner
      _setSettle(SettlePhase.closing);
      final closeIx = _program.closeRide(ride: ride, owner: owner);
      final bh = (await base.getLatestBlockhash()).value;
      final unsigned = buildUnsignedLegacyTx(
        instructions: [closeIx],
        recentBlockhash: bh.blockhash,
        feePayer: owner,
      );
      final sigs = await wallet.signAndSend([unsigned]);
      await _confirm(base, sigs.first);
      // The rent was reclaimed by this close — drop any stale pending entry.
      unawaited(RentReclaimStore.remove(ride.toBase58()));
      _setSettle(SettlePhase.settled, sig: sigs.first);
    } on Object catch (e) {
      // The position is closed + state settled once request_settle lands; only the
      // rent-reclaiming close is left. A declined/failed close is non-fatal — we
      // remember this ride PDA so the rent can be reclaimed later from Settings.
      if (_settlePhase == SettlePhase.closing) {
        unawaited(RentReclaimStore.add(ride.toBase58()));
        _setSettle(
          SettlePhase.done,
          note: "Settled. The close wasn't confirmed — reclaim the ride rent anytime from Settings.",
        );
      } else {
        _setSettle(SettlePhase.failed, note: '$e');
      }
    }
  }

  void _setSettle(SettlePhase phase, {String? note, String? sig}) {
    if (_disposed) return; // teardown outlived the screen — don't notify a dead notifier
    _settlePhase = phase;
    _settleNote = note; // null clears the note on a fresh phase
    if (sig != null) _settleSig = sig;
    notifyListeners();
  }

  Future<void> _sendErSession(
    List<enc.Instruction> ixs,
    Ed25519HDKeyPair signer,
    Ed25519HDPublicKey ride,
    RpcClient erRpc,
  ) async {
    final erBh = await _router.getBlockhashForAccounts([ride.toBase58()]);
    final signed = await signTransaction(
      LatestBlockhash(blockhash: erBh.blockhash, lastValidBlockHeight: erBh.lastValidBlockHeight),
      Message(instructions: ixs),
      [signer],
    );
    await erRpc.sendTransaction(signed.encode(), skipPreflight: true);
  }

  /// Poll the router until the ride PDA is no longer delegated (the DLP returned it to L1).
  /// Bounded; close_ride is the real gate, so we proceed to attempt it even on timeout.
  Future<void> _awaitUndelegation(Ed25519HDPublicKey ride) async {
    final stop = DateTime.now().add(const Duration(seconds: 120));
    while (DateTime.now().isBefore(stop)) {
      try {
        final ds = await _router.getDelegationStatus(ride.toBase58());
        if (!ds.isDelegated) return;
      } on Object {
        return; // router no longer tracks it ⇒ treat as undelegated; close_ride verifies
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  void _degrade() {
    if (_status == LiveRideStatus.riding) {
      _status = LiveRideStatus.degraded;
      _notify();
    }
  }

  // ── helpers (mirrors live_ride.dart) ──
  int _realizedBetween(FlashPosition before, FlashPosition after, int mark) {
    if (before.isFlat) return 0;
    int closedAbs;
    if (after.isFlat || after.side != before.side) {
      closedAbs = before.sizeUsd6;
    } else if (after.sizeUsd6 < before.sizeUsd6) {
      closedAbs = before.sizeUsd6 - after.sizeUsd6;
    } else {
      return 0;
    }
    if (closedAbs <= 0) return 0;
    return unrealizedPnl6(before.side.sign * closedAbs, before.entryE9, mark);
  }

  /// Read the oracle's 32-byte feed_id (PriceUpdateV3 layout) so the ride marks
  /// against the real SOL price (offset 41..73).
  Future<List<int>> _readFeedId(RpcClient base) async {
    final acc = await base.getAccountInfo(
      network.oracleFeedPda,
      encoding: Encoding.base64,
      commitment: Commitment.confirmed,
    );
    final data = (acc.value?.data as BinaryAccountData?)?.data;
    if (data == null || data.length < 73) {
      throw StateError('could not read SOL oracle ${network.oracleFeedPda}');
    }
    return data.sublist(41, 73);
  }

  Future<int> _readErMark() async {
    final erRpc = _erRpc;
    final base = erRpc ?? RpcClient(network.baseRpc);
    try {
      final a = await base.getAccountInfo(network.oracleFeedPda, encoding: Encoding.base64);
      final d = (a.value?.data as BinaryAccountData?)?.data;
      final p = d == null ? null : parsePriceUpdateV2(Uint8List.fromList(d));
      return p?.priceE9 ?? 0;
    } on Object {
      return 0;
    }
  }

  Future<void> _confirm(RpcClient rpc, String sig) async {
    final stop = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(stop)) {
      final st = await rpc.getSignatureStatuses([sig], searchTransactionHistory: true);
      final s = st.value.isEmpty ? null : st.value.first;
      if (s != null) {
        if (s.err != null) throw StateError('init+delegate failed: ${s.err}');
        if (s.confirmationStatus == ConfirmationStatus.confirmed ||
            s.confirmationStatus == ConfirmationStatus.finalized) {
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    throw StateError('init+delegate not confirmed within 60s');
  }

  String _sig() => '${_chunk(4)}…${_chunk(4)}';
  String _chunk(int n) =>
      String.fromCharCodes(List.generate(n, (_) => _b58.codeUnitAt(_rng.nextInt(_b58.length))));
}

/// The cockpit's road feed for a live ride — the independent guard mark pushed
/// in every ~600ms. Seeded flat so the road has shape before the first read.
class _LiveMarkFeed extends PriceFeed {
  bool _live = false;

  @override
  bool get isLive => _live;

  @override
  void start() {
    for (var i = 0; i < 80; i++) {
      push(priceE9);
    }
  }

  void pushMark(int priceE9) {
    _live = true;
    push(priceE9);
  }
}
