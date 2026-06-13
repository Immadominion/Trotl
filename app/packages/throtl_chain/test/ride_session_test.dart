// Golden test for the RideSession decoder. The hex below is the REAL on-chain account produced by
// the compiled throtl-engine program in the litesvm mark-path test
// (programs/throtl-engine/.../tests/litesvm_suite.rs :: tick_full_mark_path_…): a ride armed with
// $500 fuel / 10x / −$200 floor, then ticked once to +5000 bps against a $67.866 SOL mark. Decoding
// these exact bytes and asserting the program-computed values pins the Dart layout to the Rust
// `#[repr(C)]` struct — any drift in either side breaks this test.
import 'package:test/test.dart';
import 'package:throtl_chain/throtl_chain.dart';

/// 272 bytes (8 disc + 264 struct), lower-case hex, captured verbatim from the program under litesvm.
const _rideHex =
    'c0b8cca158d74e79'
    '6400000000000000' // session_id = 100
    '10e0496b00000000' // expires_at = 1_800_003_600
    '0065cd1d00000000' // fuel_usd_6 = 500_000_000
    '00f9029500000000' // notional_usd_6 = 2_500_000_000
    '486020cd0f000000' // entry_vwap_e9 = 67_865_960_520
    '0000000000000000' // realized_pnl_6 = 0
    '486020cd0f000000' // last_mark_e9 = 67_865_960_520
    '00d2496b00000000' // last_mark_ts = 1_800_000_000
    '003e14f4ffffffff' // loss_floor_6 = −200_000_000
    '0100000000000000' // tick_count = 1
    'a0860100' // max_lev_bps = 100_000
    '88130000' // target_exp_bps = 5_000
    '88130000' // virt_exp_bps = 5_000
    '00000000' // flags = 0
    '0000' // market_id = 0
    '01' // version = 1
    'ff' // bump = 255
    '02' // status = 2 (RIDING)
    '00' // grip_mode = 0 (HOLD)
    '3d8e79fc237ec84bac82328b0b0ca4d5cde4976d5061aa420002629df3d11bea' // owner (32)
    'a70bcd7ebfec1b836acb4efe2acf4562901f6244c0b4827bb7f16ae55b5cd117' // session_key (32)
    '0707070707070707070707070707070707070707070707070707070707070707' // feed_id = [7;32]
    // _reserved[64] + _pad_tail[2] (all zero) = 66 bytes
    '0000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000'
    '0000';

List<int> _hex(String h) =>
    List<int>.generate(h.length ~/ 2, (i) => int.parse(h.substring(i * 2, i * 2 + 2), radix: 16));

void main() {
  group('RideSessionAccount.decode (golden vs real program bytes)', () {
    final bytes = _hex(_rideHex);

    test('hex fixture is exactly one account long', () {
      expect(bytes.length, RideSessionAccount.accountLen);
      expect(bytes.length, 272);
    });

    test('decodes every field to the program-computed value', () {
      final r = RideSessionAccount.decode(bytes);
      expect(r.sessionId, 100);
      expect(r.expiresAt, 1800003600);
      expect(r.fuelUsd6, 500000000);
      expect(r.notionalUsd6, 2500000000, reason: r'signed long notional = $2500');
      expect(r.entryVwapE9, 67865960520);
      expect(r.realizedPnl6, 0);
      expect(r.lastMarkE9, 67865960520, reason: 'Lazer expo-8 mark normalized to e9');
      expect(r.lastMarkTs, 1800000000);
      expect(r.lossFloor6, -200000000, reason: "negative i64 two's-complement");
      expect(r.tickCount, 1);
      expect(r.maxLevBps, 100000);
      expect(r.targetExpBps, 5000);
      expect(r.virtExpBps, 5000);
      expect(r.flags.bits, 0);
      expect(r.flags.isOracleStale, isFalse);
      expect(r.marketId, 0);
      expect(r.version, 1);
      expect(r.bump, 255);
      expect(r.status, RideStatus.riding);
      expect(r.gripMode, 0);
      expect(r.feedId, List<int>.filled(32, 7));
      expect(r.owner.length, 32);
      expect(r.sessionKey.length, 32);
    });

    test('signed-negative loss floor round-trips exactly (web-safe i64 path)', () {
      final r = RideSessionAccount.decode(bytes);
      // -200_000_000 must be exact, not the two\'s-complement unsigned blob.
      expect(r.lossFloor6.isNegative, isTrue);
      expect(r.lossFloor6, -200000000);
    });

    test('rejects a short buffer', () {
      expect(() => RideSessionAccount.decode(bytes.sublist(0, 100)), throwsFormatException);
    });

    test('flags bitfield helpers', () {
      const f = RideFlags(RideFlags.oracleStale | RideFlags.floorBreached);
      expect(f.isOracleStale, isTrue);
      expect(f.isFloorBreached, isTrue);
      expect(f.isBankrupt, isFalse);
    });
  });
}
