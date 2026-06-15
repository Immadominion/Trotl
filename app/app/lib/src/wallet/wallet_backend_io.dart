import 'package:throtl/src/wallet/mwa_wallet.dart';
import 'package:throtl/src/wallet/wallet_backend.dart';

/// Native (Android / desktop) wallet backend: Mobile Wallet Adapter. This file is
/// selected by the conditional import in `wallet_backend.dart` on every non-web
/// target, so `solana_mobile_client` never enters the web bundle.
WalletBackend makeWalletBackend() => MwaWallet();
