/// Turns a stream of raw ER `RideSession` account bytes into the `RideObservation`s the executor
/// consumes. Decoding is `throtl_chain`'s `RideSessionAccount` (byte-pinned to the program layout);
/// the independent guard mark, market session, and clock are sampled per update. This transform is
/// pure (no network/solana) so it is unit-tested deterministically; the live byte stream comes from
/// `er_subscription.dart`.
library;

import 'dart:async';

import 'package:throtl_chain/throtl_chain.dart';
import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_runtime/throtl_runtime.dart';

/// Independent guard-mark source (priceE9). MUST be a price the ER cannot forge — production: Hermes
/// / L1 Pyth. Returns `<= 0` when unavailable, which the reconciler treats as divergence (refuse to
/// settle) — never settle blind.
typedef GuardMark = int Function();

/// Current market session for the ride's symbol (from Flash `marketSession`).
typedef SessionSource = MarketSession Function();

/// Monotonic clock in microseconds.
typedef MicrosClock = int Function();

class ErRideFeed {
  ErRideFeed({
    required this.guardMark,
    required this.session,
    required this.now,
    this.staleAfterMicros = 2000000,
  });

  final GuardMark guardMark;
  final SessionSource session;
  final MicrosClock now;

  /// If no account update arrives within this window, the feed emits a `linkOk: false` observation
  /// off the last-known ride so the executor degrades honestly instead of acting on stale state.
  final int staleAfterMicros;

  /// Per-update transform: each raw account buffer → one fresh (`linkOk: true`) observation.
  /// Buffers shorter than a full account are skipped (a partial/!exists update is not a state).
  Stream<RideObservation> transform(Stream<List<int>> accountData) async* {
    await for (final bytes in accountData) {
      if (bytes.length < RideSessionAccount.accountLen) continue;
      yield _observe(RideSessionAccount.decode(bytes), linkOk: true);
    }
  }

  /// Transform with a liveness watchdog: in addition to a fresh observation per update, if the
  /// stream goes quiet for [staleAfterMicros] a `linkOk: false` observation is emitted off the last
  /// decoded ride (the executor then enters `Degraded(linkLost)` and stops settling). Requires a
  /// [tickEvery] heartbeat the caller pumps (e.g. a `Stream.periodic`), kept injectable so the
  /// watchdog is testable without real timers.
  Stream<RideObservation> transformWithWatchdog(
    Stream<List<int>> accountData,
    Stream<void> tickEvery,
  ) {
    final out = StreamController<RideObservation>();
    RideSessionAccount? last;
    var lastUpdateMicros = now();

    final dataSub = accountData.listen(
      (bytes) {
        if (bytes.length < RideSessionAccount.accountLen) return;
        last = RideSessionAccount.decode(bytes);
        lastUpdateMicros = now();
        out.add(_observe(last!, linkOk: true));
      },
      onError: out.addError,
    );

    final tickSub = tickEvery.listen((_) {
      final l = last;
      if (l != null && now() - lastUpdateMicros >= staleAfterMicros) {
        out.add(_observe(l, linkOk: false));
      }
    });

    out.onCancel = () async {
      await dataSub.cancel();
      await tickSub.cancel();
    };
    return out.stream;
  }

  RideObservation _observe(RideSessionAccount ride, {required bool linkOk}) => RideObservation(
    ride: ride,
    guardMarkE9: guardMark(),
    session: session(),
    nowMicros: now(),
    linkOk: linkOk,
  );
}
