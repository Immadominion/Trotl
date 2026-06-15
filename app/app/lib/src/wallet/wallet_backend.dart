import 'dart:typed_data';

import 'package:throtl/src/wallet/wallet_backend_io.dart'
    if (dart.library.js_interop) 'package:throtl/src/wallet/wallet_backend_web.dart';

/// The platform-agnostic wallet edge the app signs through. Two implementations,
/// chosen at COMPILE time (via the conditional import above) so each platform's
/// deps stay isolated:
///   • mobile/desktop → `MwaWallet` (Mobile Wallet Adapter; `solana_mobile_client`)
///   • web            → `WebWallet` (browser wallet: Phantom / Solflare / Backpack)
///
/// Everything above this edge — `WalletController`, the arming/funding flows, the
/// ephemeral co-sign — is platform-agnostic and unchanged: both backends speak the
/// same sign-only-then-app-submits contract, so the proven money path is identical
/// on Android and on web.
abstract interface class WalletBackend {
  /// Whether this runtime can connect a wallet at all.
  bool get isAvailable;

  /// Connected owner pubkey (base58), or null.
  String? get publicKey;

  /// The connected account's label, if the wallet provides one.
  String? get walletName;

  /// Restore a persisted session at boot (best-effort).
  Future<void> loadPersisted();

  /// Wallets the user can choose from. On web this enumerates every injected
  /// browser wallet (Phantom / Solflare / Backpack / …) for the connect picker;
  /// on mobile the OS shows its own chooser, so this returns a single entry.
  Future<List<WalletOption>> listWallets();

  /// Pop the wallet and authorize on [cluster]; returns the result. [walletId]
  /// selects a specific wallet from [listWallets] (web picker); ignored on mobile.
  Future<WalletConnectResult> connect({required String cluster, String? walletId});

  /// Sign + broadcast serialized txs via the wallet; returns base58 signatures.
  Future<List<String>> signAndSend(List<Uint8List> txs, {required String cluster});

  /// Sign (don't send) serialized txs; returns the signed payloads — the app
  /// submits them itself (bypassing wallet-side simulation/broadcast). Partial
  /// signing is fine: a second in-memory signer (the Flash session key) is injected
  /// afterwards, so the returned payload may still have an empty signer slot.
  Future<List<Uint8List>> signTransactions(List<Uint8List> txs, {required String cluster});

  /// Clear the session.
  Future<void> disconnect();
}

/// Resolve the platform wallet backend (mobile MWA or web browser-wallet). Defined
/// in `wallet_backend_io.dart` / `wallet_backend_web.dart` and bound by the
/// conditional import above.
WalletBackend createWalletBackend() => makeWalletBackend();

/// Result of a connect attempt — shared across backends (keeps the field names the
/// UI already reads: `success` / `publicKey` / `walletName` / `error`).
class WalletConnectResult {
  const WalletConnectResult._({
    required this.success,
    this.publicKey,
    this.walletName,
    this.error,
  });
  factory WalletConnectResult.ok({required String publicKey, String? walletName}) =>
      WalletConnectResult._(success: true, publicKey: publicKey, walletName: walletName);
  factory WalletConnectResult.fail(String error) =>
      WalletConnectResult._(success: false, error: error);

  final bool success;
  final String? publicKey;
  final String? walletName;
  final String? error;
}

/// A wallet the user can pick in the connect sheet (a browser wallet on web, or
/// the OS chooser on mobile). [id] is passed back to [WalletBackend.connect].
class WalletOption {
  const WalletOption({required this.id, required this.name});
  final String id;
  final String name;
}
