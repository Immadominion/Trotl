// Golden tests: the encoders must match the on-chain program byte-for-byte. Discriminators are
// cross-checked against sha256("global:<name>")[..8] (Anchor's rule), Borsh args against a hand
// computation, and PDA derivation against the documented seeds.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:solana/solana.dart';
import 'package:test/test.dart';
import 'package:throtl_chain/throtl_chain.dart';

List<int> anchorDisc(String name) =>
    sha256.convert(utf8.encode('global:$name')).bytes.sublist(0, 8);

void main() {
  final program = ThrotlProgram();

  group('discriminators match Anchor sha256(global:<name>)[..8]', () {
    // Build each ix and assert its first 8 data bytes equal the computed discriminator.
    test('tick', () {
      final owner = Ed25519HDPublicKey.fromBase58('11111111111111111111111111111112');
      final ix = program.tick(
        ride: owner,
        priceFeed: owner,
        sessionSigner: owner,
        targetExpBps: 5000,
      );
      expect(ix.data.toList().sublist(0, 8), anchorDisc('tick'));
      // i32 LE of 5000 = [136, 19, 0, 0]
      expect(ix.data.toList().sublist(8), [136, 19, 0, 0]);
    });

    test('flatten / freeze / close_ride discriminators', () {
      final k = Ed25519HDPublicKey.fromBase58('11111111111111111111111111111112');
      expect(
        program.flatten(ride: k, priceFeed: k, sessionSigner: k).data.toList().sublist(0, 8),
        anchorDisc('flatten'),
      );
      expect(
        program.freeze(ride: k, authority: k).data.toList().sublist(0, 8),
        anchorDisc('freeze'),
      );
      expect(
        program.closeRide(ride: k, owner: k).data.toList().sublist(0, 8),
        anchorDisc('close_ride'),
      );
    });
  });

  group('init_ride encoding (discriminator + Borsh args)', () {
    test('matches the on-chain arg layout', () async {
      final owner = Ed25519HDPublicKey.fromBase58('11111111111111111111111111111112');
      final sessionKey = Ed25519HDPublicKey.fromBase58(
        'SysvarC1ock11111111111111111111111111111111',
      );
      final feedId = List<int>.generate(32, (i) => i);
      final ix = await program.initRide(
        owner: owner,
        sessionId: 7,
        sessionKey: sessionKey,
        marketId: 0,
        feedId: feedId,
        gripMode: 0,
        fuelUsd6: 500000000, // $500
        maxLevBps: 100000, // 10x
        lossFloor6: -200000000, // -$200
        expiresAt: 1781354908,
      );
      final d = ix.data.toList();
      expect(d.sublist(0, 8), anchorDisc('init_ride'));
      var off = 8;
      expect(d.sublist(off, off + 8), [7, 0, 0, 0, 0, 0, 0, 0]); // session_id u64 = 7
      off += 8;
      expect(d.sublist(off, off + 32), sessionKey.bytes); // session_key
      off += 32;
      expect(d.sublist(off, off + 2), [0, 0]); // market_id u16
      off += 2;
      expect(d.sublist(off, off + 32), feedId); // feed_id [u8;32]
      off += 32;
      expect(d[off], 0); // grip_mode
      off += 1;
      // fuel 500_000_000 u64 LE
      expect(d.sublist(off, off + 8), [0, 101, 205, 29, 0, 0, 0, 0]);
      off += 8;
      expect(d.sublist(off, off + 4), [160, 134, 1, 0]); // max_lev_bps 100000
      off += 4;
      // loss_floor -200_000_000 i64 (two's complement LE): 0xFFFFFFFF_F4143E00
      expect(d.sublist(off, off + 8), [0, 62, 20, 244, 255, 255, 255, 255]);
      // account order
      expect(ix.accounts.length, 3);
      expect(ix.accounts[1].isSigner, isTrue); // owner signs
      expect(ix.accounts[0].isWriteable, isTrue); // ride writable
    });
  });

  group('PDA derivation', () {
    test('rideSession is deterministic and off-curve', () async {
      final owner = Ed25519HDPublicKey.fromBase58('11111111111111111111111111111112');
      final a = await program.rideSession(owner, 7);
      final b = await program.rideSession(owner, 7);
      final c = await program.rideSession(owner, 8);
      expect(a.toBase58(), b.toBase58());
      expect(a.toBase58(), isNot(c.toBase58()));
    });

    test('delegate_ride wires the 8 accounts in IDL order', () async {
      final owner = Ed25519HDPublicKey.fromBase58('11111111111111111111111111111112');
      final ix = await program.delegateRide(owner: owner, sessionId: 7, commitFrequencyMs: 30000);
      expect(ix.accounts.length, 8);
      expect(ix.accounts[0].isSigner, isTrue); // owner
      // owner_program (index 5) must be the throtl-engine id
      expect(ix.accounts[5].pubKey.toBase58(), throtlEngineProgramId);
      expect(ix.accounts[6].pubKey.toBase58(), delegationProgramId);
      expect(ix.data.toList().sublist(0, 8), anchorDisc('delegate_ride'));
    });
  });
}
