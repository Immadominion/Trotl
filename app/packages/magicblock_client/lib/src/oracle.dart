/// Parses a MagicBlock ephemeral-oracle `PriceUpdateV2` account (Pyth Lazer feeds, in the ER) by
/// raw byte offset — the SAME layout the on-chain `throtl-engine` reads (oracle.rs). Keep them in
/// lock-step: price i64@73, conf u64@81, expo i32@89, publish_time i64@93 (after the 8-byte disc).
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Oracle program id (devnet + mainnet) and the live devnet SOL feed PDA (verified actively ticking).
const String oracleProgramId = 'PriCems5tHihc6UDXDjzjeawomAwBduWMGAi8ZUjppd';
const String devnetSolPriceFeedPda = 'ENYwebBThHzmzwPLAQvCucUTsjyfBSZdD9ViXksS4jPu';

/// The feed-id seed encoding: the Pyth Lazer id rendered as a DECIMAL STRING (SOL lazerId = 6 → "6").
String lazerFeedSeed(int lazerId) => '$lazerId';

const _offPrice = 73;
const _offExpo = 89;
const _offPublishTime = 93;
const int _minLen = _offPublishTime + 8; // 101

@immutable
class OraclePrice {
  const OraclePrice({required this.priceE9, required this.expo, required this.publishTime});

  /// Price normalized to 1e9 fixed-point (matches the program's `price_e9`).
  final int priceE9;
  final int expo;
  final int publishTime;

  double get ui => priceE9 / 1000000000;
}

/// Decode a `PriceUpdateV2` account's data bytes. Returns null if too short / non-positive.
OraclePrice? parsePriceUpdateV2(Uint8List data) {
  if (data.length < _minLen) return null;
  final bd = ByteData.sublistView(data);
  final priceRaw = bd.getInt64(_offPrice, Endian.little);
  final expo = bd.getInt32(_offExpo, Endian.little);
  final publishTime = bd.getInt64(_offPublishTime, Endian.little);
  if (priceRaw <= 0) return null;
  final priceE9 = _normalizeToE9(priceRaw, expo);
  if (priceE9 == null || priceE9 <= 0) return null;
  return OraclePrice(priceE9: priceE9, expo: expo, publishTime: publishTime);
}

/// `price * 10^(9 - expo)` → int (price_e9).
///
/// IMPORTANT: MagicBlock's ephemeral-oracle (PriceUpdateV3) stores the **Pyth Lazer** exponent,
/// which is a POSITIVE number of decimals: `real = mantissa × 10^(-exponent)`. Verified live on the
/// devnet SOL feed: mantissa 6786596052, exponent 8 → $67.866. (NOT the standard Pyth `× 10^+expo`.)
/// Uses BigInt to match the program's wide intermediate exactly.
int? _normalizeToE9(int price, int expo) {
  final target = 9 - expo;
  final p = BigInt.from(price);
  final BigInt v;
  if (target >= 0) {
    v = p * BigInt.from(10).pow(target);
  } else {
    v = p ~/ BigInt.from(10).pow(-target);
  }
  if (v > (BigInt.one << 63) - BigInt.one) return null;
  return v.toInt();
}
