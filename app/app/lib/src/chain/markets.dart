/// The markets a ride can open, plus the portfolio-scaled fuel ladder for the
/// Starting Grid. Curated (no free search) — the three game tracks, which are
/// the top crypto perp majors. SOL is live; BTC/ETH light up once their mainnet
/// in-ER Pyth Lazer feed PDAs are wired (see [Market.live]).
library;

/// One tradeable market. `minCollateralUsd6` is Flash Trade's per-position floor
/// (~$10 on-chain; we use $11 so the floor-stop placement clears after entry fees).
class Market {
  const Market({
    required this.id,
    required this.symbol,
    required this.track,
    required this.minCollateralUsd6,
    required this.live,
    required this.feedPda,
  });

  /// `marketId` carried into `RideConfig` / `init_ride`.
  final int id;

  /// Flash output symbol ('SOL' / 'BTC' / 'ETH').
  final String symbol;

  /// The game track name shown in the garage + grid.
  final String track;

  /// Minimum fuel to open a real position on this market (Flash floor).
  final int minCollateralUsd6;

  /// Tradeable for real now (its oracle feed is confirmed live on the ER). BTC/ETH
  /// are curated-but-coming until their feed is confirmed on the mainnet ER (the
  /// arm-time check gates this); their devnet feed PDAs are wired for that check.
  final bool live;

  /// The MagicBlock in-ER Pyth Lazer feed account the program marks against. Read
  /// inside the ER (on L1 it shows DLP-delegated). NOT derivable from the lazerId —
  /// these are MagicBlock-managed addresses (devnet-confirmed; mainnet via the
  /// arm-time freshness check).
  final String feedPda;

  String get minLabel => '\$${(minCollateralUsd6 / 1e6).toStringAsFixed(0)}';

  static const sol = Market(
    id: 0,
    symbol: 'SOL',
    track: 'SOL SPEEDWAY',
    minCollateralUsd6: 11000000,
    live: true,
    feedPda: 'ENYwebBThHzmzwPLAQvCucUTsjyfBSZdD9ViXksS4jPu',
  );
  static const btc = Market(
    id: 1,
    symbol: 'BTC',
    track: 'BTC SUMMIT',
    minCollateralUsd6: 11000000,
    live: false,
    feedPda: '71wtTRDY8Gxgw56bXFt2oc6qeAbTxzStdNiC425Z51sr',
  );
  static const eth = Market(
    id: 2,
    symbol: 'ETH',
    track: 'ETH CIRCUIT',
    minCollateralUsd6: 11000000,
    live: false,
    feedPda: '5vaYr1hpv8yrSpu8w3K95x22byYxUJCCNCSYJtqVWPvG',
  );

  /// The curated, theme-first list (no user search).
  static const List<Market> all = [sol, btc, eth];

  static Market byId(int id) => all.firstWhere((m) => m.id == id, orElse: () => sol);
}

/// A round-number fuel ladder scaled to the wallet's USDC, so the stakes always
/// make sense for *your* portfolio. `$5 → [$1, $2, $3, MAX $5]`;
/// `$250 → [$50, $100, $150, MAX $250]`. The last entry is always MAX (full balance).
/// Returns `(label, usd6)` pairs; an empty list when there's no balance.
List<(String, int)> fuelLadder(int balanceUsd6) {
  if (balanceUsd6 <= 0) return const [];
  final base6 = _niceFloor(balanceUsd6 ~/ 4);
  final steps = <int>{};
  for (final m in const [1, 2, 3]) {
    final v = base6 * m;
    if (v > 0 && v < balanceUsd6) steps.add(v);
  }
  steps.add(balanceUsd6); // MAX
  final sorted = steps.toList()..sort();
  return [for (final v in sorted) (v == balanceUsd6 ? 'MAX' : fmtFuel(v), v)];
}

/// Largest "nice" number ({1,2,5}×10^k, in usd6) ≤ [x6], floored at $1.
int _niceFloor(int x6) {
  const dollar = 1000000;
  if (x6 <= dollar) return dollar;
  var best = dollar;
  var unit = dollar;
  while (unit <= x6) {
    for (final n in const [1, 2, 5]) {
      final cand = unit * n;
      if (cand <= x6 && cand > best) best = cand;
    }
    unit *= 10;
  }
  return best;
}

/// `$1,204.20` / `$50` — trims a clean integer, keeps cents otherwise.
String fmtFuel(int usd6) {
  final ui = usd6 / 1e6;
  if (ui >= 100) return '\$${ui.toStringAsFixed(0)}';
  return ui == ui.roundToDouble() ? '\$${ui.toStringAsFixed(0)}' : '\$${ui.toStringAsFixed(2)}';
}
