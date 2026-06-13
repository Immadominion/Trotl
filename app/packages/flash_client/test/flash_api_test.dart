// Real-data tests: every case runs against fixtures CAPTURED FROM THE LIVE MAINNET API during the
// M0.3 spike (fixtures/flash/*.json) — no mocked responses. They lock the parsing/computation that
// the live round-trip validated, so a regression fails CI without spending funds.
import 'dart:convert';
import 'dart:io';

import 'package:flash_client/flash_client.dart';
import 'package:test/test.dart';

// Fixtures live at <repo>/fixtures/flash; tests run from the package dir.
final String _fixturesDir =
    Platform.environment['FLASH_FIXTURES'] ?? '${Directory.current.path}/../../../fixtures/flash';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('$_fixturesDir/$name.json').readAsStringSync()) as Map<String, dynamic>;

const _usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

void main() {
  group('computeWithdrawableRaw (live-captured basket)', () {
    test('post-close basket nets to the real pendingCredits (10.994783 USDC)', () {
      final account = _fixture('raw_basket_after_close')['account'] as Map<String, dynamic>;
      expect(computeWithdrawableRaw(account, _usdc), 10994783);
    });

    test('a flat/empty basket is 0 (nothing to withdraw)', () {
      expect(computeWithdrawableRaw(const {}, _usdc), 0);
      expect(
        computeWithdrawableRaw(const {
          'pendingCredits': [
            {'amount': 0, 'mint': _usdc},
          ],
        }, _usdc),
        0,
      );
    });

    test('ignores other mints', () {
      final account = {
        'pendingCredits': [
          {'amount': 5000000, 'mint': 'So11111111111111111111111111111111111111112'},
          {'amount': 10994783, 'mint': _usdc},
        ],
      };
      expect(computeWithdrawableRaw(account, _usdc), 10994783);
    });
  });

  group('OpenPreview (live-captured quote)', () {
    test('parses the real preview response', () {
      final pv = OpenPreview(_fixture('preview_open'));
      // From the live spike: 11 USDC @2x LONG SOL.
      expect(double.parse(pv.youPayUsdUi), closeTo(11, 1)); // ~10.99
      expect(pv.newEntryPrice, isNotEmpty);
      expect(pv.newLiquidationPrice, isNotEmpty);
      expect(double.parse(pv.youRecieveUsdUi) > double.parse(pv.youPayUsdUi), isTrue);
    });
  });

  group('extractOnChainCode', () {
    test('decodes the real 0xbc4 withdrawal-timing error to 3012', () {
      // The exact string the live execute-withdrawal returned before the receipt crossed.
      const real = 'custom program error: 0xbc4 ... Error Number: 3012 ... AccountNotInitialized';
      expect(extractOnChainCode(real), 3012);
    });

    test('decodes a bare slippage code', () {
      expect(extractOnChainCode('MaxPriceSlippage (6020)'), 6020);
    });

    test('returns null when no code present', () {
      expect(extractOnChainCode('settlement is crossing'), isNull);
    });
  });

  group('tokens fixture (live)', () {
    test('SOL and USDC are present with expected mints/decimals', () {
      // /v2/tokens returns a JSON array.
      final raw = jsonDecode(File('$_fixturesDir/tokens.json').readAsStringSync()) as List<dynamic>;
      final tokens = raw.cast<Map<String, dynamic>>();
      final usdc = tokens.firstWhere((t) => t['symbol'] == 'USDC');
      final sol = tokens.firstWhere((t) => t['symbol'] == 'SOL');
      expect(usdc['mintKey'], _usdc);
      expect(usdc['decimals'], 6);
      expect(sol['mintKey'], 'So11111111111111111111111111111111111111112');
      expect(sol['decimals'], 9);
    });
  });
}
