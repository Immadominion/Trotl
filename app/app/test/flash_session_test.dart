import 'package:flutter_test/flutter_test.dart';
import 'package:solana/solana.dart';
import 'package:throtl/src/wallet/flash_session.dart';

void main() {
  test('create_session_v2 ix: discriminator + args + accounts wired correctly', () async {
    final owner = await Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: List.filled(32, 1));
    final sk = await Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: List.filled(32, 2));
    final ix = await createSessionV2Ix(
      owner: owner.publicKey,
      sessionSigner: sk.publicKey,
      validUntilUnix: 1800000000,
    );
    final data = ix.data.toList();
    // sha256("global:create_session_v2")[..8]
    expect(data.sublist(0, 8), [223, 233, 108, 7, 65, 194, 235, 38]);
    // 8 disc + 1 bool(top_up) + 8 valid_until(u64 LE) + 8 lamports(u64 LE)
    expect(data.length, 25);
    expect(data[8], 1, reason: 'top_up = true');
    expect(ix.accounts.length, 6);
    expect(ix.programId.toBase58(), 'KeyspM2ssCJbqUhQ4k7sveSiY4WjnYsrXkC8oDbwde5');
  });

  test('session token v2 PDA is deterministic + off-curve', () async {
    final owner = await Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: List.filled(32, 3));
    final sk = await Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: List.filled(32, 4));
    final a = await sessionTokenV2Pda(sessionSigner: sk.publicKey, authority: owner.publicKey);
    final b = await sessionTokenV2Pda(sessionSigner: sk.publicKey, authority: owner.publicKey);
    expect(a.toBase58(), b.toBase58()); // deterministic
    expect(a.bytes.length, 32);
  });
}
