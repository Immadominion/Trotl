import 'package:flutter_test/flutter_test.dart';
import 'package:throtl/src/wallet/flash_funding.dart';
import 'package:throtl_core/throtl_core.dart';

void main() {
  group('parseFlashPosition — the trusted real Flash position (never the ER)', () {
    test('reads side / size / entry from a live owner-state (M0.3 fixture shape)', () {
      final state = {
        'positionMetrics': {
          '8pAfDWb9Prg3FTV7WFuXG8hthmZdf7EG83hmxzWSKNxv': {
            'marketSymbol': 'SOL',
            'sideUi': 'Long',
            'sizeUsdUi': '10.99',
            'entryPriceUi': '67.08',
          },
        },
      };
      final pos = parseFlashPosition(state, 'SOL');
      expect(pos.side, Side.long);
      expect(pos.sizeUsd6, 10990000); // $10.99
      expect(pos.entryE9, 67080000000); // $67.08
      expect(pos.isFlat, isFalse);
    });

    test('flat when there is no position', () {
      expect(parseFlashPosition({'positionMetrics': <String, dynamic>{}}, 'SOL').isFlat, isTrue);
      expect(parseFlashPosition(<String, dynamic>{}, 'SOL').isFlat, isTrue);
    });

    test('ignores positions in other markets', () {
      final state = {
        'positionMetrics': {
          'k': {'marketSymbol': 'BTC', 'sideUi': 'Short', 'sizeUsdUi': '50', 'entryPriceUi': '60000'},
        },
      };
      expect(parseFlashPosition(state, 'SOL').isFlat, isTrue);
    });
  });
}
