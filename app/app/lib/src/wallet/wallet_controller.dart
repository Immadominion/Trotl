import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:solana/solana.dart';
import 'package:throtl/src/chain/network.dart';
import 'package:throtl/src/wallet/mwa_wallet.dart';

/// Connection lifecycle for the UI.
enum WalletStatus { disconnected, connecting, connected }

/// App-state for the connected wallet: owner pubkey, live SOL/USDC balances,
/// the active [AppCluster], and the per-ride ephemeral session keypair. Slow
/// app state (not the 60fps loop) → a plain [ChangeNotifier], mirrored on the
/// existing `ThemeController` pattern. The on-chain ride orchestration (Phase C)
/// reads `owner`, `sessionKey`, `network`, and signs owner txs via [signAndSend].
class WalletController extends ChangeNotifier {
  WalletController({MwaWallet? mwa}) : _mwa = mwa ?? MwaWallet() {
    _restore();
  }

  final MwaWallet _mwa;

  // Mainnet is the only network — Flash Trade (the settlement venue) is
  // mainnet-only, so "devnet" was never a real ride target. The practice vs
  // live distinction is funds (fake vs real), not the chain.
  final AppCluster _cluster = AppCluster.mainnet;
  WalletStatus _status = WalletStatus.disconnected;
  String? _owner;
  String? _walletName;
  int _solLamports = 0;
  int _usdc6 = 0;
  String? _error;
  bool _refreshing = false;
  Timer? _poll;
  Ed25519HDKeyPair? _sessionKey;

  /// How often to re-read balances while connected (so a USDC top-up shows up
  /// without a manual reload). App-resume also forces a refresh (see GameShell).
  static const _pollEvery = Duration(seconds: 20);

  // ── getters ──
  NetworkConfig get network => NetworkConfig.of(_cluster);
  AppCluster get cluster => _cluster;
  WalletStatus get status => _status;
  bool get isConnected => _status == WalletStatus.connected && _owner != null;
  bool get isConnecting => _status == WalletStatus.connecting;
  bool get mwaAvailable => _mwa.isAvailable;
  String? get owner => _owner;
  String? get walletName => _walletName;
  String? get error => _error;
  int get solLamports => _solLamports;
  int get usdc6 => _usdc6;
  double get solUi => _solLamports / 1e9;
  double get usdcUi => _usdc6 / 1e6;

  /// A balance read is in flight (drives the refresh spinner on the coin pill).
  bool get refreshing => _refreshing;

  Ed25519HDKeyPair? get sessionKey => _sessionKey;

  /// `Abc1…Wx9z` truncation for headers.
  String get ownerShort {
    final o = _owner;
    if (o == null || o.length < 8) return o ?? '';
    return '${o.substring(0, 4)}…${o.substring(o.length - 4)}';
  }

  void _restore() {
    unawaited(() async {
      await _mwa.loadPersisted();
      final pk = _mwa.publicKey;
      if (pk != null) {
        _owner = pk;
        _status = WalletStatus.connected;
        notifyListeners();
        unawaited(refreshBalances());
        _startPoll();
      }
    }());
  }

  /// Re-read balances on a gentle cadence while connected, so funding USDC in
  /// another app shows up without the user hunting for a reload button.
  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(_pollEvery, (_) {
      if (isConnected) unawaited(refreshBalances());
    });
  }

  void _stopPoll() {
    _poll?.cancel();
    _poll = null;
  }

  /// Connect via MWA on the active cluster.
  Future<bool> connect() async {
    if (!_mwa.isAvailable) {
      _error = 'Wallet connect needs an Android device with a wallet app';
      notifyListeners();
      return false;
    }
    _status = WalletStatus.connecting;
    _error = null;
    notifyListeners();
    final res = await _mwa.connect(cluster: network.mwaCluster);
    if (!res.success) {
      _status = _owner == null ? WalletStatus.disconnected : WalletStatus.connected;
      _error = res.error;
      notifyListeners();
      return false;
    }
    _owner = res.publicKey;
    _walletName = res.walletName;
    _status = WalletStatus.connected;
    notifyListeners();
    unawaited(refreshBalances());
    _startPoll();
    return true;
  }

  Future<void> disconnect() async {
    _stopPoll();
    await _mwa.disconnect();
    _owner = null;
    _walletName = null;
    _solLamports = 0;
    _usdc6 = 0;
    _sessionKey = null;
    _status = WalletStatus.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPoll();
    super.dispose();
  }

  /// Read live SOL + USDC balances for the owner on the active cluster.
  Future<void> refreshBalances() async {
    final o = _owner;
    if (o == null) return;
    if (_refreshing) return; // don't stack reads (poll + manual + resume)
    _refreshing = true;
    notifyListeners();
    final cfg = network;
    final rpc = RpcClient(cfg.baseRpc);
    try {
      try {
        final bal = await rpc.getBalance(o);
        _solLamports = bal.value;
      } on Object catch (e) {
        debugPrint('[wallet] SOL balance failed ($e)');
      }
      try {
        final ata = await findAssociatedTokenAddress(
          owner: Ed25519HDPublicKey.fromBase58(o),
          mint: Ed25519HDPublicKey.fromBase58(cfg.usdcMint),
        );
        final t = await rpc.getTokenAccountBalance(ata.toBase58());
        _usdc6 = int.tryParse(t.value.amount) ?? 0;
      } on Object {
        _usdc6 = 0; // no USDC token account yet
      }
    } finally {
      // always release the flag — a stuck `_refreshing` would freeze every
      // future read (poll + manual + resume).
      _refreshing = false;
      notifyListeners();
    }
  }

  /// Mint a fresh ephemeral session keypair for a ride (signs gasless ER ticks;
  /// never touches the wallet). One per ride.
  Future<Ed25519HDKeyPair> newSession() async {
    final key = await Ed25519HDKeyPair.random();
    _sessionKey = key;
    return key;
  }

  /// Owner-signs + broadcasts txs (init/delegate/close) via MWA on the cluster.
  Future<List<String>> signAndSend(List<Uint8List> txs) =>
      _mwa.signAndSend(txs, cluster: network.mwaCluster);

  /// Owner-signs txs without broadcasting (app submits).
  Future<List<Uint8List>> signTransactions(List<Uint8List> txs) =>
      _mwa.signTransactions(txs, cluster: network.mwaCluster);
}
