import 'dart:typed_data';

import 'package:magicblock_client/magicblock_client.dart';
import 'package:test/test.dart';

void main() {
  group('parsePriceUpdateV2 (synthetic PriceUpdateV2 buffer, offsets pinned to oracle.rs)', () {
    Uint8List buildFeed({required int priceRaw, required int expo, required int publishTime}) {
      final buf = Uint8List(150);
      ByteData.sublistView(buf)
        ..setInt64(73, priceRaw, Endian.little) // price
        ..setInt32(89, expo, Endian.little) // exponent
        ..setInt64(93, publishTime, Endian.little); // publish_time
      return buf;
    }

    test('Lazer exponent 8 ⇒ price_e9 (the real devnet convention, live-verified)', () {
      // Live SOL feed: mantissa 6786596052, exponent 8 → \$67.866 → e9 = ×10 = 67865960520.
      final p = parsePriceUpdateV2(
        buildFeed(priceRaw: 6786596052, expo: 8, publishTime: 1781354908),
      );
      expect(p, isNotNull);
      expect(p!.priceE9, 67865960520);
      expect(p.expo, 8);
      expect(p.publishTime, 1781354908);
      expect(p.ui, closeTo(67.866, 0.001));
    });

    test('exponent 9 is identity (×1)', () {
      final p = parsePriceUpdateV2(buildFeed(priceRaw: 147123456789, expo: 9, publishTime: 1));
      expect(p!.priceE9, 147123456789);
    });

    test('exponent 10 divides by 10', () {
      final p = parsePriceUpdateV2(buildFeed(priceRaw: 1471234567890, expo: 10, publishTime: 1));
      expect(p!.priceE9, 147123456789);
    });

    test('too-short buffer ⇒ null', () {
      expect(parsePriceUpdateV2(Uint8List(50)), isNull);
    });

    test('non-positive price ⇒ null', () {
      expect(parsePriceUpdateV2(buildFeed(priceRaw: 0, expo: 8, publishTime: 1)), isNull);
    });
  });

  group('router JSON parsing (live-verified shapes)', () {
    test('ErValidator.fromJson', () {
      final v = ErValidator.fromJson(const {
        'identity': 'MUS3hc9TCw4cGC12vHNoYcCGzJG1txjgQLZWVoeNHNd',
        'fqdn': 'https://devnet-us.magicblock.app/',
        'baseFee': 0,
        'blockTimeMs': 50,
        'countryCode': 'USA',
      });
      expect(v.identity, 'MUS3hc9TCw4cGC12vHNoYcCGzJG1txjgQLZWVoeNHNd');
      expect(v.rpcUrl, 'https://devnet-us.magicblock.app');
      expect(v.wsUrl, 'wss://devnet-us.magicblock.app');
      expect(v.blockTimeMs, 50);
    });

    test('DelegationStatus.fromJson (delegated)', () {
      final d = DelegationStatus.fromJson(const {
        'isDelegated': true,
        'fqdn': 'https://devnet-as.magicblock.app/',
        'delegationRecord': {
          'authority': 'MAS1Dt9qreoRMQ14YQuhg8UTZMMzDdKhmkZMECCzk57',
          'owner': 'GpcXtob64TmsL9gGCk44EBoQWS8SSej9vU1kJgFVE4se',
          'delegationSlot': 328952996,
          'lamports': 3981120,
        },
      });
      expect(d.isDelegated, isTrue);
      expect(d.fqdn, 'https://devnet-as.magicblock.app/');
      expect(d.authority, 'MAS1Dt9qreoRMQ14YQuhg8UTZMMzDdKhmkZMECCzk57');
    });

    test('DelegationStatus.fromJson (undelegated)', () {
      final d = DelegationStatus.fromJson(const {'isDelegated': false});
      expect(d.isDelegated, isFalse);
      expect(d.fqdn, isNull);
    });

    test('BlockhashInfo.fromJson', () {
      final b = BlockhashInfo.fromJson(const {
        'blockhash': 'E7dYdoggHF8GtmG35nHPXSXkcnjYBjChLUKMcSebnzMr',
        'lastValidBlockHeight': 456996824,
      });
      expect(b.blockhash, 'E7dYdoggHF8GtmG35nHPXSXkcnjYBjChLUKMcSebnzMr');
      expect(b.lastValidBlockHeight, 456996824);
    });
  });
}
