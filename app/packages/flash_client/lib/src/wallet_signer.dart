/// Loads a wallet keypair, signs an UNSIGNED v0 transaction (one ed25519 signature placed at the
/// signer's index in the message's account keys, blockhash untouched), and submits/confirms it
/// against a given RPC. Encapsulates the two money-path traps from research:
///   * the silent session-fallback (if our key isn't a required signer, FAIL loudly), and
///   * the "don't replace the blockhash" rule (we only add a signature).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flash_client/src/errors.dart';
import 'package:solana/dto.dart' hide Commitment;
import 'package:solana/encoder.dart' show SignedTx;
import 'package:solana/solana.dart';

class WalletSigner {
  WalletSigner(this.keypair);

  final Ed25519HDKeyPair keypair;

  String get address => keypair.publicKey.toBase58();

  /// Load a Solana CLI keypair file (a JSON array of 64 bytes: 32-byte seed + 32-byte pubkey).
  static Future<WalletSigner> fromCliKeypairFile(String path) async {
    final raw = jsonDecode(File(path).readAsStringSync()) as List<dynamic>;
    final bytes = raw.cast<int>();
    if (bytes.length != 64 && bytes.length != 32) {
      throw FlashError(FlashErrorChannel.transport, 'unexpected keypair length ${bytes.length}');
    }
    final seed = bytes.sublist(0, 32); // ed25519 seed = first 32 bytes
    final kp = await Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: seed);
    return WalletSigner(kp);
  }

  /// Add our signature to an unsigned base64 v0 transaction and return the re-encoded base64.
  Future<String> signBase64(String base64Tx) async {
    final tx = SignedTx.decode(base64Tx);
    final msgBytes = tx.compiledMessage.toByteArray().toList();
    final myKey = keypair.publicKey.toBase58();
    // Ed25519HDPublicKey.toString() == toBase58(); interpolation avoids a dynamic-typed call.
    final idx = tx.compiledMessage.accountKeys.indexWhere((k) => '$k' == myKey);

    // The silent session-fallback / wrong-signer trap: if our key is not within the required-signer
    // slots, the builder did not wire us in — refuse rather than submit an unsignable tx.
    if (idx < 0 || idx >= tx.signatures.length) {
      throw FlashError(
        FlashErrorChannel.transport,
        '$myKey is not a required signer of this tx (signers=${tx.signatures.length}); '
        'refusing to submit (silent session-fallback?)',
      );
    }

    final sig = await keypair.sign(msgBytes);
    final sigs = [...tx.signatures]..[idx] = sig;
    return SignedTx(signatures: sigs, compiledMessage: tx.compiledMessage).encode();
  }
}

/// Submits and confirms transactions against one RPC endpoint (base layer or an ER node).
class RpcSubmitter {
  RpcSubmitter(this.url) : _client = RpcClient(url);

  final String url;
  final RpcClient _client;

  /// Submit an encoded (base64) transaction. Use [skipPreflight] = true on ER endpoints (they do
  /// not implement simulateTransaction).
  Future<String> submit(String encodedTx, {bool skipPreflight = false}) => _client.sendTransaction(
    encodedTx,
    skipPreflight: skipPreflight,
    preflightCommitment: Commitment.confirmed,
  );

  /// Poll until the signature reaches confirmed/finalized, or throw on failure / timeout.
  Future<void> confirm(
    String signature, {
    Duration timeout = const Duration(seconds: 60),
    Duration interval = const Duration(milliseconds: 800),
  }) async {
    final stop = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(stop)) {
      final res = await _client.getSignatureStatuses([signature], searchTransactionHistory: true);
      final s = res.value.isEmpty ? null : res.value.first;
      if (s != null) {
        if (s.err != null) {
          throw FlashError(FlashErrorChannel.transport, 'tx $signature failed on-chain: ${s.err}');
        }
        if (s.confirmationStatus == ConfirmationStatus.confirmed ||
            s.confirmationStatus == ConfirmationStatus.finalized) {
          return;
        }
      }
      await Future<void>.delayed(interval);
    }
    throw FlashError(FlashErrorChannel.transport, 'tx $signature not confirmed within $timeout');
  }
}
