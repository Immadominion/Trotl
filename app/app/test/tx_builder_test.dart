import 'package:flutter_test/flutter_test.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:throtl/src/chain/tx_builder.dart';
import 'package:throtl_chain/throtl_chain.dart';

void main() {
  test('buildUnsignedLegacyTx → MWA-ready wire format (round-trips)', () async {
    final owner = await Ed25519HDKeyPair.random();
    final session = await Ed25519HDKeyPair.random();
    final oracle = await Ed25519HDKeyPair.random();
    final program = ThrotlProgram();
    final ride = await program.rideSession(owner.publicKey, 42);

    // A real throtl `tick` ix signed by the session key (the gasless hot path).
    final ix = program.tick(
      ride: ride,
      priceFeed: oracle.publicKey,
      sessionSigner: session.publicKey,
      targetExpBps: 5000,
    );

    // The system-program id is a valid all-zero 32-byte base58 — fine as a stand-in blockhash.
    const blockhash = '11111111111111111111111111111111';
    final bytes = buildUnsignedLegacyTx(
      instructions: [ix],
      recentBlockhash: blockhash,
      feePayer: session.publicKey,
    );

    // Decodes back to a valid transaction (the format the wallet will parse).
    final decoded = SignedTx.fromBytes(bytes);
    expect(decoded.compiledMessage.recentBlockhash, blockhash);

    // Exactly one signer slot (the session key as fee payer), left zeroed for the wallet to fill.
    expect(decoded.signatures.length, 1);
    expect(decoded.signatures.first.bytes.length, 64);
    expect(decoded.signatures.first.bytes.every((b) => b == 0), isTrue);

    // The fee payer is account[0] — the slot the wallet signs.
    expect(decoded.compiledMessage.accountKeys.first.toBase58(), session.publicKey.toBase58());
  });
}
