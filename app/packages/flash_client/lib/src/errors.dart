/// Flash v2 surfaces errors on THREE different channels (research/flash.md §2). We normalize them
/// into one typed error so callers handle them uniformly.
library;

import 'package:meta/meta.dart';

enum FlashErrorChannel {
  /// Trading / preview: HTTP 200 with an `err` field in the body.
  bodyErr,

  /// Trigger / limit: HTTP 400 with `{ "error": ... }`.
  http400,

  /// Setup / withdrawal: bare HTTP 500 with an empty body.
  http500,

  /// Transport / decode / submit failures.
  transport,
}

@immutable
class FlashError implements Exception {
  const FlashError(this.channel, this.message, {this.httpStatus, this.onChainCode});

  final FlashErrorChannel channel;
  final String message;
  final int? httpStatus;

  /// Flash on-chain error code (6000–6111) when extractable (e.g. 6020 MaxPriceSlippage).
  final int? onChainCode;

  @override
  String toString() =>
      'FlashError(${channel.name}${httpStatus != null ? ' $httpStatus' : ''}'
      '${onChainCode != null ? ' code=$onChainCode' : ''}): $message';
}
