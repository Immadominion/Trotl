// End-to-end executor wiring: drives the REAL reconciler FSM (throtl_core) through the REAL
// executor against the deterministic SimGateway, asserting the safety-critical paths the product
// depends on. These exercise the same RideExecutor.onObservation code path production runs.
import 'package:test/test.dart';
import 'package:throtl_chain/throtl_chain.dart';
import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_runtime/throtl_runtime.dart';

const _mark = 67865960520; // $67.866 in priceE9
const _fullLong6 = 5000000000; // $5000 = $500 fuel × 10x
const _capDelta6 = 2500000000; // 50% max action delta = $2500

const _ride = RideConfig(
  fuelUsd6: 500000000,
  maxLevBps: 100000,
  lossFloor6: -200000000,
  marketId: 0,
);

RideSessionAccount _mkRide({
  required int notionalUsd6,
  int lastMarkE9 = _mark,
  int flagBits = 0,
  int statusByte = 2, // RIDING
}) => RideSessionAccount(
  sessionId: 1,
  expiresAt: 1 << 40,
  fuelUsd6: 500000000,
  notionalUsd6: notionalUsd6,
  entryVwapE9: lastMarkE9,
  realizedPnl6: 0,
  lastMarkE9: lastMarkE9,
  lastMarkTs: 0,
  lossFloor6: -200000000,
  tickCount: 1,
  maxLevBps: 100000,
  targetExpBps: 0,
  virtExpBps: 0,
  flags: RideFlags(flagBits),
  marketId: 0,
  version: 1,
  bump: 255,
  status: RideStatus.fromByte(statusByte),
  gripMode: 0,
  owner: List<int>.filled(32, 0),
  sessionKey: List<int>.filled(32, 0),
  feedId: List<int>.filled(32, 0),
);

RideObservation _obs({
  required int notional,
  required int now,
  int? guard,
  MarketSession session = MarketSession.regular,
  bool linkOk = true,
  int flagBits = 0,
}) => RideObservation(
  ride: _mkRide(notionalUsd6: notional, flagBits: flagBits),
  session: session,
  guardMarkE9: guard ?? _mark,
  nowMicros: now,
  linkOk: linkOk,
);

void main() {
  group('ramp flat → full long (bounded, multi-step, always stopped)', () {
    test('opens in ≤2 capped steps, never exceeds the cap, stop attached each time', () async {
      final gw = SimGateway();
      final ex = RideExecutor(ride: _ride, gateway: gw);

      // First obs starts the debounce (no action yet).
      expect(await ex.onObservation(_obs(notional: _fullLong6, now: 0)), isA<NoOp>());
      expect(ex.state, isA<Drifting>());
      expect(gw.applied, isEmpty);

      // Past the debounce → first capped open.
      final a1 = await ex.onObservation(_obs(notional: _fullLong6, now: 500000));
      expect(a1, isA<OpenIncrease>());
      expect((a1 as OpenIncrease).addUsd6, _capDelta6);
      expect(gw.settled.side, Side.long);
      expect(gw.settled.sizeUsd6, _capDelta6);
      expect(gw.settled.hasStop, isTrue, reason: 'open must carry a floor stop');

      // Fill reflected → second open to the cap.
      final a2 = await ex.onObservation(_obs(notional: _fullLong6, now: 600000));
      expect(a2, isA<OpenIncrease>());
      expect(gw.settled.sizeUsd6, _fullLong6);
      expect(gw.settled.sizeUsd6, lessThanOrEqualTo(_ride.maxNotionalAbs6));
      expect(gw.settled.hasStop, isTrue);

      // At the cap → synced, no further action.
      final a3 = await ex.onObservation(_obs(notional: _fullLong6, now: 700000));
      expect(a3, isA<NoOp>());
      expect(ex.state, isA<Synced>());
      expect(gw.applied.length, 2, reason: 'exactly two opens, no churn');
    });
  });

  group('snap-to-flat dead-zone', () {
    test(r'a sub-$12 virtual target opens nothing', () async {
      final gw = SimGateway();
      final ex = RideExecutor(ride: _ride, gateway: gw);
      final a = await ex.onObservation(_obs(notional: 5000000, now: 0)); // $5 < $12 floor
      expect(a, isA<NoOp>());
      expect(ex.state, isA<Synced>());
      expect(gw.applied, isEmpty);
    });
  });

  group('flip with inline stop', () {
    test('long → short flips and the new short is opened WITH a stop', () async {
      // Seed an established long.
      final seedStop = stopTriggerE9(
        side: Side.long,
        entryE9: _mark,
        sizeUsd6: _fullLong6,
        lossFloor6: _ride.lossFloor6,
      );
      final gw = SimGateway(
        initial: FlashPosition(
          side: Side.long,
          sizeUsd6: _fullLong6,
          entryE9: _mark,
          stopTriggerE9: seedStop,
        ),
      );
      final ex = RideExecutor(ride: _ride, gateway: gw, initial: const Synced(_fullLong6));

      // Thumb flips to full short — first obs debounces.
      expect(await ex.onObservation(_obs(notional: -_fullLong6, now: 0)), isA<NoOp>());
      // Past debounce → Flip.
      final a = await ex.onObservation(_obs(notional: -_fullLong6, now: 500000));
      expect(a, isA<Flip>());
      expect((a as Flip).toSide, Side.short);
      expect(gw.settled.side, Side.short);
      expect(
        gw.settled.hasStop,
        isTrue,
        reason: 'flip must never leave an open position unstopped',
      );
    });
  });

  group('stop-out → freeze → re-arm (layer-3 guardian)', () {
    test('refuses to re-open after a stop-out until the throttle is released', () async {
      final gw = SimGateway(
        initial: FlashPosition(
          side: Side.long,
          sizeUsd6: _capDelta6,
          entryE9: _mark,
          stopTriggerE9: stopTriggerE9(
            side: Side.long,
            entryE9: _mark,
            sizeUsd6: _capDelta6,
            lossFloor6: _ride.lossFloor6,
          ),
        ),
      );
      final ex = RideExecutor(ride: _ride, gateway: gw, initial: const Synced(_capDelta6));

      // The venue stop fires — position vanishes while the thumb still wants long.
      gw.injectStopOut();
      final a1 = await ex.onObservation(_obs(notional: _fullLong6, now: 100));
      expect(ex.state, isA<Frozen>());
      expect(a1, isA<NoOp>());
      expect(gw.applied, isEmpty, reason: 'no re-open into the adverse move');

      // Thumb still pinned → stay frozen, still no trade.
      await ex.onObservation(_obs(notional: _fullLong6, now: 200));
      expect(ex.state, isA<Frozen>());
      expect(gw.applied, isEmpty);

      // Throtl released (target flat) → re-armed.
      await ex.onObservation(_obs(notional: 0, now: 300));
      expect(ex.state, isA<Synced>());

      // Now a fresh push opens again (re-arm works): debounce then open.
      expect(await ex.onObservation(_obs(notional: _fullLong6, now: 400)), isA<NoOp>());
      final reopen = await ex.onObservation(_obs(notional: _fullLong6, now: 500000 + 400));
      expect(reopen, isA<OpenIncrease>());
      expect(gw.applied.length, 1);
    });
  });

  group('degraded gating (no settlement in any degraded mode)', () {
    test('oracle stale ⇒ Degraded, no action', () async {
      final gw = SimGateway();
      final ex = RideExecutor(ride: _ride, gateway: gw);
      final a = await ex.onObservation(
        _obs(notional: _fullLong6, now: 0, flagBits: RideFlags.oracleStale),
      );
      expect(a, isA<NoOp>());
      expect(ex.state, const Degraded(DegradeReason.oracleStale));
      expect(gw.applied, isEmpty);
    });

    test('link lost ⇒ Degraded, no action', () async {
      final gw = SimGateway();
      final ex = RideExecutor(ride: _ride, gateway: gw);
      final a = await ex.onObservation(_obs(notional: _fullLong6, now: 0, linkOk: false));
      expect(a, isA<NoOp>());
      expect(ex.state, const Degraded(DegradeReason.linkLost));
      expect(gw.applied, isEmpty);
    });

    test('market closed ⇒ Degraded, no action', () async {
      final gw = SimGateway();
      final ex = RideExecutor(ride: _ride, gateway: gw);
      final a = await ex.onObservation(
        _obs(notional: _fullLong6, now: 0, session: MarketSession.closed),
      );
      expect(a, isA<NoOp>());
      expect(ex.state, const Degraded(DegradeReason.marketClosed));
      expect(gw.applied, isEmpty);
    });

    test('ER-vs-guard price divergence ⇒ Degraded, no action', () async {
      final gw = SimGateway();
      final ex = RideExecutor(ride: _ride, gateway: gw);
      // guard mark 2% off the ER mark > 1% threshold.
      final a = await ex.onObservation(
        _obs(notional: _fullLong6, now: 0, guard: (_mark * 102) ~/ 100),
      );
      expect(a, isA<NoOp>());
      expect(ex.state, const Degraded(DegradeReason.priceDivergence));
      expect(gw.applied, isEmpty);
    });
  });

  group('settling double-submit guard', () {
    test('a deferred fill blocks a second open until it reflects or times out', () async {
      final gw = SimGateway();
      final ex = RideExecutor(ride: _ride, gateway: gw);

      await ex.onObservation(_obs(notional: _fullLong6, now: 0)); // debounce
      gw.deferNextFill = true; // the next open's fill won't reflect
      final a = await ex.onObservation(_obs(notional: _fullLong6, now: 500000));
      expect(a, isA<OpenIncrease>());
      expect(ex.state, isA<Settling>());
      expect(gw.applied.length, 1);
      expect(gw.settled.isFlat, isTrue, reason: 'fill deferred — settled still flat');

      // Within the settle timeout, fill not yet reflected → NO second open.
      final a2 = await ex.onObservation(_obs(notional: _fullLong6, now: 700000));
      expect(a2, isA<NoOp>());
      expect(gw.applied.length, 1, reason: 'no duplicate submit while settling');

      // Fill lands → executor resumes converging.
      gw.completePendingFill();
      final a3 = await ex.onObservation(_obs(notional: _fullLong6, now: 800000));
      expect(a3, isA<OpenIncrease>());
      expect(gw.applied.length, 2);
    });
  });
}
