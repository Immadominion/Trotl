import 'dart:typed_data';

import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

/// Build an **unsigned** legacy transaction in the wire format the Mobile Wallet
/// Adapter expects: a compact-array of zeroed 64-byte signature placeholders
/// (one per required signer) followed by the compiled message. The wallet fills
/// in the fee-payer's signature and broadcasts.
///
/// This is the inverse of `flash_client`'s `WalletSigner`, which *consumes* an
/// unsigned tx in exactly this shape — so the format is already proven on the
/// settlement path. The blockhash is compiled in and must not be touched after.
Uint8List buildUnsignedLegacyTx({
  required List<Instruction> instructions,
  required String recentBlockhash,
  required Ed25519HDPublicKey feePayer,
}) {
  final compiled = Message(instructions: instructions).compile(
    recentBlockhash: recentBlockhash,
    feePayer: feePayer,
  );
  final placeholders = <Signature>[
    for (var i = 0; i < compiled.requiredSignatureCount; i++)
      Signature(List<int>.filled(64, 0), publicKey: compiled.accountKeys[i]),
  ];
  final tx = SignedTx(compiledMessage: compiled, signatures: placeholders);
  return Uint8List.fromList(tx.toByteArray().toList());
}
