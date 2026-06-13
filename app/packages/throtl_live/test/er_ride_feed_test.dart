// ErRideFeed transform: real RideSessionAccount decode + per-update guard/session/clock sampling +
// short-buffer skip + liveness watchdog. Pure (no network) — drives the feed with synthetic account
// buffers written at the program's documented offsets (the byte layout itself is golden-tested in
// throtl_chain against real program output).
import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:throtl_chain/throtl_chain.dart';
import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_live/throtl_live.dart';
import 'package:throtl_runtime/throtl_runtime.dart';

const _mark = 67865960520; // $67.866 priceE9

/// A 272-byte RideSession buffer with the observation-relevant fields set at their real offsets
/// (notional@32 i64, last_mark@56 u64, flags@100 u32, status@108 byte). Everything else zero.
Uint8List _rideBytes({
  required int notionalUsd6,
  int lastMarkE9 = _mark,
  int flags = 0,
  int status = 2, // RIDING
}) {
  final b = Uint8List(RideSessionAccount.accountLen);
  ByteData.sublistView(b)
    ..setInt64(32, notionalUsd6, Endian.little)
    ..setUint64(56, lastMarkE9, Endian.little)
    ..setUint32(100, flags, Endian.little);
  b[108] = status;
  return b;
}

void main() {
  group('ErRideFeed.transform', () {
    test('decodes each update into an observation with sampled guard/session/clock', () async {
      var t = 1000;
      final feed = ErRideFeed(
        guardMark: () => _mark,
        session: () => MarketSession.regular,
        now: () => t += 1000, // advances each sample
      );
      final input = Stream<List<int>>.fromIterable([
        _rideBytes(notionalUsd6: 2500000000),
        _rideBytes(notionalUsd6: -1000000000, flags: RideFlags.oracleStale),
      ]);

      final obs = await feed.transform(input).toList();
      expect(obs.length, 2);

      expect(obs[0].ride.notionalUsd6, 2500000000);
      expect(obs[0].ride.lastMarkE9, _mark);
      expect(obs[0].guardMarkE9, _mark);
      expect(obs[0].session, MarketSession.regular);
      expect(obs[0].linkOk, isTrue);
      expect(obs[0].ride.flags.isOracleStale, isFalse);

      expect(obs[1].ride.notionalUsd6, -1000000000);
      expect(obs[1].ride.flags.isOracleStale, isTrue);
      expect(obs[1].nowMicros, greaterThan(obs[0].nowMicros));
    });

    test('skips a short / non-existent account buffer', () async {
      final feed = ErRideFeed(
        guardMark: () => _mark,
        session: () => MarketSession.regular,
        now: () => 0,
      );
      final input = Stream<List<int>>.fromIterable([
        <int>[1, 2, 3], // partial / account-doesn't-exist — not a state
        _rideBytes(notionalUsd6: 100),
      ]);
      final obs = await feed.transform(input).toList();
      expect(obs.length, 1, reason: 'the 3-byte buffer is skipped');
      expect(obs.single.ride.notionalUsd6, 100);
    });

    test('end-to-end through the executor: a real long open is decided from decoded bytes', () async {
      // Prove the feed → executor wiring: decoded on-chain virtual notional drives a real reconcile.
      const ride = RideConfig(
        fuelUsd6: 500000000,
        maxLevBps: 100000,
        lossFloor6: -200000000,
        marketId: 0,
      );
      final gw = SimGateway();
      final ex = RideExecutor(ride: ride, gateway: gw);
      var t = 0;
      final feed = ErRideFeed(
        guardMark: () => _mark,
        session: () => MarketSession.regular,
        now: () => t,
      );
      final updates = Stream<List<int>>.fromIterable([
        _rideBytes(notionalUsd6: 5000000000), // ER says full long
        _rideBytes(notionalUsd6: 5000000000),
      ]);

      final actions = <Object>[];
      await for (final obs in feed.transform(updates)) {
        t += 500000; // advance past the debounce between updates
        actions.add(await ex.onObservation(obs));
      }
      // First decoded update debounces; second opens a real (capped) long with a stop.
      expect(actions.last, isA<OpenIncrease>());
      expect(gw.settled.side, Side.long);
      expect(gw.settled.hasStop, isTrue);
    });
  });

  group('ErRideFeed.transformWithWatchdog', () {
    test('emits a linkOk=false observation when the stream goes quiet', () async {
      var clock = 0;
      final feed = ErRideFeed(
        guardMark: () => _mark,
        session: () => MarketSession.regular,
        now: () => clock,
      );
      final data = StreamController<List<int>>();
      final ticks = StreamController<void>();
      final out = <RideObservation>[];
      final sub = feed.transformWithWatchdog(data.stream, ticks.stream).listen(out.add);

      data.add(_rideBytes(notionalUsd6: 3000000000)); // live update at t=0
      await Future<void>.delayed(Duration.zero);
      expect(out.single.linkOk, isTrue);

      clock = 3000000; // 3s later, no new update
      ticks.add(null); // heartbeat fires the watchdog
      await Future<void>.delayed(Duration.zero);

      expect(out.length, 2);
      expect(out[1].linkOk, isFalse, reason: 'gone quiet past staleAfterMicros');
      expect(out[1].ride.notionalUsd6, 3000000000, reason: 'off the last-known ride');

      await sub.cancel();
      await data.close();
      await ticks.close();
    });
  });
}
