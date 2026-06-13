/// The live ER account-bytes stream (the only network-touching piece of the feed). Subscribes to a
/// RideSession PDA on its owning Ephemeral Rollup node over WebSocket and emits the raw account data
/// on every confirmed update — feed it straight into `ErRideFeed.transform`. Kept isolated so the
/// decode/observe logic stays solana-free and unit-testable.
library;

import 'dart:async';

import 'package:solana/dto.dart' hide Commitment;
import 'package:solana/solana.dart';

/// Resolve the ER WebSocket URL + subscribe to [rideAddress], yielding raw account bytes per update.
/// Closes the socket when the returned stream is cancelled.
Stream<List<int>> rideAccountBytes(String erWsUrl, String rideAddress) {
  final controller = StreamController<List<int>>();
  SubscriptionClient? ws;
  StreamSubscription<Account>? sub;

  controller
    ..onListen = () {
      ws = SubscriptionClient.connect(erWsUrl);
      sub = ws!
          .accountSubscribe(
            rideAddress,
            commitment: Commitment.confirmed,
            encoding: Encoding.base64,
          )
          .listen(
            (acc) {
              final data = acc.data;
              if (data is BinaryAccountData) controller.add(data.data);
            },
            onError: controller.addError,
          );
    }
    ..onCancel = () async {
      await sub?.cancel();
      ws?.close();
    };
  return controller.stream;
}
