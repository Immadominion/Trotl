// RealFlashGateway orchestration: a bounded reconciler action → planned Flash calls → unsigned tx via
// flash_client → sign+submit → trusted-position re-read. The FlashApi is driven by a MockClient (no
// network); sign+submit and the settled-read are injected fakes. Asserts the plan→API param mapping,
// the flip ordering (close then open), the settled re-read, and that ReplaceStop is surfaced not dropped.
import 'dart:convert';

import 'package:flash_client/flash_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_live/throtl_live.dart';

const _mark = 67865960520;
const ride = RideConfig(
  fuelUsd6: 500000000,
  maxLevBps: 100000, // 10x
  lossFloor6: -200000000,
  marketId: 0,
);

/// Records every tx-builder request body, keyed by endpoint path, and returns a canned unsigned tx.
class _Recorder {
  final List<({String path, Map<String, dynamic> body})> calls = [];
  MockClient client() => MockClient((req) async {
    calls.add((path: req.url.path, body: jsonDecode(req.body) as Map<String, dynamic>));
    return http.Response(jsonEncode({'transactionBase64': 'dHg=' /* "tx" */}), 200);
  });
}

void main() {
  group('RealFlashGateway.apply', () {
    test(
      'OpenIncrease → open-position with planned collateral/leverage/stop, then re-reads settled',
      () async {
        final rec = _Recorder();
        final api = FlashApi(client: rec.client());
        final signed = <BuiltTx>[];
        const filled = FlashPosition(
          side: Side.long,
          sizeUsd6: 2500000000,
          entryE9: _mark,
          stopTriggerE9: 62000000000,
        );
        final gw = RealFlashGateway(
          api: api,
          owner: 'OWNER1111111111111111111111111111111111111',
          signSubmit: (tx) async {
            signed.add(tx);
            return 'sig_${signed.length}';
          },
          readSettled: () async => filled,
        );

        await gw.apply(
          const OpenIncrease(Side.long, 2500000000),
          ride: ride,
          markE9: _mark,
          nowMicros: 0,
        );

        expect(rec.calls.length, 1);
        expect(rec.calls.single.path, endsWith('/open-position'));
        final body = rec.calls.single.body;
        expect(body['tradeType'], 'LONG');
        expect(body['inputAmountUi'], '250'); // $2500 notional / 10x
        expect((body['leverage'] as num).toDouble(), 10);
        expect(body['stopLoss'], isNotNull);
        expect(body['stopLoss'], isNot('0'));
        expect(body['outputTokenSymbol'], 'SOL');

        expect(signed.length, 1, reason: 'one tx signed+submitted');
        expect(gw.submittedSignatures, ['sig_1']);
        expect(gw.settled, filled, reason: 'settled re-read from the trusted source');
      },
    );

    test('Flip → close (full) THEN open opposite-with-stop, two submits, one re-read', () async {
      final rec = _Recorder();
      final api = FlashApi(client: rec.client());
      var reads = 0;
      final gw = RealFlashGateway(
        api: api,
        owner: 'OWNER1111111111111111111111111111111111111',
        initial: const FlashPosition(side: Side.long, sizeUsd6: 5000000000, entryE9: _mark),
        signSubmit: (tx) async => 'sig',
        readSettled: () async {
          reads++;
          return const FlashPosition(side: Side.short, sizeUsd6: 2500000000, entryE9: _mark);
        },
      );

      await gw.apply(
        const Flip(Side.short, 2500000000),
        ride: ride,
        markE9: _mark,
        nowMicros: 0,
      );

      expect(rec.calls.length, 2);
      expect(rec.calls[0].path, endsWith('/close-position'));
      expect(rec.calls[0].body['side'], 'LONG');
      expect(rec.calls[0].body['inputUsdUi'], '0'); // full close of the old side
      expect(rec.calls[1].path, endsWith('/open-position'));
      expect(rec.calls[1].body['tradeType'], 'SHORT');
      expect(rec.calls[1].body['stopLoss'], isNot('0'));
      expect(gw.submittedSignatures.length, 2);
      expect(reads, 1, reason: 'one trusted re-read after the flip completes');
      expect(gw.settled.side, Side.short);
    });

    test('session-signed: uses signer+sessionToken, omits owner on open', () async {
      final rec = _Recorder();
      final api = FlashApi(client: rec.client());
      final gw = RealFlashGateway(
        api: api,
        owner: 'OWNER1111111111111111111111111111111111111',
        signer: 'SESSIONKEYpubkey11111111111111111111111111',
        sessionToken: 'tok123',
        signSubmit: (tx) async => 'sig',
        readSettled: () async => const FlashPosition.flat(),
      );

      await gw.apply(
        const OpenIncrease(Side.long, 2500000000),
        ride: ride,
        markE9: _mark,
        nowMicros: 0,
      );
      final body = rec.calls.single.body;
      expect(body['signer'], 'SESSIONKEYpubkey11111111111111111111111111');
      expect(body['sessionToken'], 'tok123');
      expect(body.containsKey('owner'), isFalse, reason: 'session-signed open omits owner');
    });

    test('ReplaceStop is surfaced (Flash REST gap), not silently dropped', () async {
      final rec = _Recorder();
      final api = FlashApi(client: rec.client());
      final gw = RealFlashGateway(
        api: api,
        owner: 'OWNER1111111111111111111111111111111111111',
        initial: const FlashPosition(side: Side.long, sizeUsd6: 2500000000, entryE9: _mark),
        signSubmit: (tx) async => 'sig',
        readSettled: () async => const FlashPosition.flat(),
      );

      await expectLater(
        gw.apply(const ReplaceStop(Side.long), ride: ride, markE9: _mark, nowMicros: 0),
        throwsA(isA<FlashGatewayUnsupported>()),
      );
      expect(rec.calls, isEmpty);
    });

    test('NoOp does nothing (no calls, no re-read)', () async {
      final rec = _Recorder();
      final api = FlashApi(client: rec.client());
      var reads = 0;
      final gw = RealFlashGateway(
        api: api,
        owner: 'OWNER1111111111111111111111111111111111111',
        signSubmit: (tx) async => 'sig',
        readSettled: () async {
          reads++;
          return const FlashPosition.flat();
        },
      );
      await gw.apply(const NoOp(), ride: ride, markE9: _mark, nowMicros: 0);
      expect(rec.calls, isEmpty);
      expect(reads, 0);
    });
  });
}
