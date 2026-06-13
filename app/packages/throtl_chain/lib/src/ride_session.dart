/// Decoder for the on-chain `RideSession` account (the ER-delegated PDA the tick loop writes).
///
/// Layout is pinned by `programs/throtl-engine/src/state.rs` (`#[account(zero_copy)] #[repr(C)]`,
/// fully dense, 264 bytes after Anchor's 8-byte discriminator = 272 total). Fields are read by fixed
/// little-endian byte offset; 64-bit values are assembled from two 32-bit words (NOT `getInt64`,
/// which throws on dart2js/dart2wasm) — exact for the ride's value ranges (all well under 2^53).
///
/// Cross-language pinned: the golden test decodes bytes produced by the real compiled program in the
/// litesvm mark-path test, so any drift in the Rust layout breaks the Dart test.
library;

import 'dart:typed_data';

/// Ride lifecycle status byte (mirror of `constants::status`).
enum RideStatus {
  init,
  armed,
  riding,
  frozen,
  settling,
  closed,
  unknown;

  static RideStatus fromByte(int b) => switch (b) {
    0 => RideStatus.init,
    1 => RideStatus.armed,
    2 => RideStatus.riding,
    3 => RideStatus.frozen,
    4 => RideStatus.settling,
    5 => RideStatus.closed,
    _ => RideStatus.unknown,
  };
}

/// `flags` bitfield (mirror of `constants::flags`).
class RideFlags {
  const RideFlags(this.bits);
  final int bits;

  static const int floorBreached = 1 << 0;
  static const int oracleStale = 1 << 1;
  static const int bankrupt = 1 << 2;

  bool get isFloorBreached => bits & floorBreached != 0;
  bool get isOracleStale => bits & oracleStale != 0;
  bool get isBankrupt => bits & bankrupt != 0;

  @override
  String toString() =>
      'RideFlags(floorBreached=$isFloorBreached, '
      'oracleStale=$isOracleStale, bankrupt=$isBankrupt)';
}

/// Decoded `RideSession` account. Only the fields the client/reconciler consume are surfaced; the
/// reserved tail is ignored. All amounts use the program's fixed-point conventions (usd6 / priceE9 /
/// signed bps).
class RideSessionAccount {
  const RideSessionAccount({
    required this.sessionId,
    required this.expiresAt,
    required this.fuelUsd6,
    required this.notionalUsd6,
    required this.entryVwapE9,
    required this.realizedPnl6,
    required this.lastMarkE9,
    required this.lastMarkTs,
    required this.lossFloor6,
    required this.tickCount,
    required this.maxLevBps,
    required this.targetExpBps,
    required this.virtExpBps,
    required this.flags,
    required this.marketId,
    required this.version,
    required this.bump,
    required this.status,
    required this.gripMode,
    required this.owner,
    required this.sessionKey,
    required this.feedId,
  });

  /// Decode a full account buffer (>= 272 bytes; the disc is not validated — the caller subscribed
  /// to a known PDA). Throws [FormatException] if the buffer is too short.
  factory RideSessionAccount.decode(List<int> bytes) {
    if (bytes.length < accountLen) {
      throw FormatException(
        'RideSession account too short: ${bytes.length} < $accountLen',
      );
    }
    final u8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final d = ByteData.sublistView(u8);
    List<int> slice(int off) => u8.sublist(off, off + 32);
    return RideSessionAccount(
      sessionId: _u64(d, _offSessionId),
      expiresAt: _i64(d, _offExpiresAt),
      fuelUsd6: _u64(d, _offFuel),
      notionalUsd6: _i64(d, _offNotional),
      entryVwapE9: _u64(d, _offEntryVwap),
      realizedPnl6: _i64(d, _offRealized),
      lastMarkE9: _u64(d, _offLastMark),
      lastMarkTs: _i64(d, _offLastMarkTs),
      lossFloor6: _i64(d, _offLossFloor),
      tickCount: _u64(d, _offTickCount),
      maxLevBps: d.getUint32(_offMaxLev, Endian.little),
      targetExpBps: d.getInt32(_offTargetExp, Endian.little),
      virtExpBps: d.getInt32(_offVirtExp, Endian.little),
      flags: RideFlags(d.getUint32(_offFlags, Endian.little)),
      marketId: d.getUint16(_offMarketId, Endian.little),
      version: u8[_offVersion],
      bump: u8[_offBump],
      status: RideStatus.fromByte(u8[_offStatus]),
      gripMode: u8[_offGrip],
      owner: slice(_offOwner),
      sessionKey: slice(_offSessionKey),
      feedId: slice(_offFeedId),
    );
  }

  // ── byte offsets (absolute, incl. the 8-byte Anchor discriminator) ────────────
  // Pinned to state.rs field order. The 264-byte struct is dense (no implicit padding).
  static const _discLen = 8;
  static const _offSessionId = 8;
  static const _offExpiresAt = 16;
  static const _offFuel = 24;
  static const _offNotional = 32;
  static const _offEntryVwap = 40;
  static const _offRealized = 48;
  static const _offLastMark = 56;
  static const _offLastMarkTs = 64;
  static const _offLossFloor = 72;
  static const _offTickCount = 80;
  static const _offMaxLev = 88;
  static const _offTargetExp = 92;
  static const _offVirtExp = 96;
  static const _offFlags = 100;
  static const _offMarketId = 104;
  static const _offVersion = 106;
  static const _offBump = 107;
  static const _offStatus = 108;
  static const _offGrip = 109;
  static const _offOwner = 110;
  static const _offSessionKey = 142;
  static const _offFeedId = 174;

  /// Total account length: 8 (disc) + 264 (struct).
  static const accountLen = 272;

  final int sessionId;
  final int expiresAt;
  final int fuelUsd6;

  /// Signed virtual notional (usd6): + long, − short. This is the advisory target the reconciler
  /// clamps and acts on — never a direct authorization.
  final int notionalUsd6;
  final int entryVwapE9;
  final int realizedPnl6;
  final int lastMarkE9;
  final int lastMarkTs;
  final int lossFloor6;
  final int tickCount;
  final int maxLevBps;
  final int targetExpBps;

  /// Confirmed settled virtual exposure (signed bps) — the needle.
  final int virtExpBps;
  final RideFlags flags;
  final int marketId;
  final int version;
  final int bump;
  final RideStatus status;
  final int gripMode;
  final List<int> owner;
  final List<int> sessionKey;
  final List<int> feedId;

  // Web-safe 64-bit reads: getInt64/getUint64 throw on dart2js/dart2wasm (no native i64). Combine two
  // 32-bit words instead — exact for the ride's value ranges (all well under 2^53; see codec.dart's
  // cross-platform discipline). usd6/priceE9 amounts and timestamps never approach that bound.
  static const _twoPow32 = 0x100000000;
  static int _u64(ByteData d, int off) =>
      d.getUint32(off, Endian.little) + d.getUint32(off + 4, Endian.little) * _twoPow32;
  static int _i64(ByteData d, int off) =>
      d.getUint32(off, Endian.little) + d.getInt32(off + 4, Endian.little) * _twoPow32;

  /// Discriminator length, exposed for callers that want to validate it separately.
  static int get discriminatorLen => _discLen;
}
