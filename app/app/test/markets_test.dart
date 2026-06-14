import 'package:flutter_test/flutter_test.dart';
import 'package:throtl/src/chain/markets.dart';

void main() {
  group('fuelLadder — round numbers scaled to your portfolio', () {
    test(r'$5 portfolio → $1 / $2 / $3 / MAX($5)', () {
      final l = fuelLadder(5000000);
      expect(l.map((e) => e.$2).toList(), [1000000, 2000000, 3000000, 5000000]);
      expect(l.first.$1, r'$1');
      expect(l.last.$1, 'MAX');
    });

    test(r'$20 portfolio → $5 / $10 / $15 / MAX($20)', () {
      final l = fuelLadder(20000000);
      expect(l.map((e) => e.$2).toList(), [5000000, 10000000, 15000000, 20000000]);
    });

    test(r'$250 portfolio → $50 / $100 / $150 / MAX($250)', () {
      final l = fuelLadder(250000000);
      expect(l.map((e) => e.$2).toList(), [50000000, 100000000, 150000000, 250000000]);
    });

    test('zero balance → empty ladder', () => expect(fuelLadder(0), isEmpty));
  });

  group('Flash minimum gating', () {
    final min = Market.sol.minCollateralUsd6; // \$11

    test(r'$5 portfolio: every option is below the $11 floor → cannot ride for real', () {
      expect(fuelLadder(5000000).every((e) => e.$2 < min), isTrue);
    });

    test(r'$20 portfolio: only $15 and MAX($20) clear the floor', () {
      final ok = fuelLadder(20000000).where((e) => e.$2 >= min).map((e) => e.$2).toList();
      expect(ok, [15000000, 20000000]);
    });
  });
}
