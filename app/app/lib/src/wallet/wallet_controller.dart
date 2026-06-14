import 'dart:async';
import 'dart:convert';

import 'package:flash_client/flash_client.dart';
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
  String? _netError;
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

  /// A user-facing network error from the last balance read (DNS/socket failure),
  /// or null when the network is reachable. Shown so a dead connection isn't a
  /// silent $0.
  String? get networkError => _netError;
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
  /// For Flash trades, reads the Flash basket balance instead of wallet USDC.
  Future<void> refreshBalances() async {
    final o = _owner;
    if (o == null) return;
    if (_refreshing) return; // don't stack reads (poll + manual + resume)
    _refreshing = true;
    notifyListeners();
    final cfg = network;
    var rpc = RpcClient(cfg.baseRpc);
    try {
      try {
        // This device's DNS is INTERMITTENT (Starlink): the same RPC domain that
        // resolves when a tx goes through throws "Failed host lookup (errno=7)"
        // moments later. So retry through the flap — DNS/socket failures AND RPC
        // overload (504/-32504/429) — re-probing to a candidate that resolves
        // *now* after the first couple of misses.
        int? lamports;
        Object? lastErr;
        for (var attempt = 0; attempt < 5; attempt++) {
          try {
            lamports = (await rpc.getBalance(o)).value;
            break;
          } on Object catch (e) {
            lastErr = e;
            final s = '$e';
            final transient = s.contains('Failed host lookup') ||
                s.contains('No address associated') ||
                s.contains('SocketException') ||
                s.contains('Connection closed') ||
                s.contains('Connection reset') ||
                s.contains('-32504') ||
                s.contains('504') ||
                s.contains('429') ||
                s.contains('timed out') ||
                s.contains('TimeoutException');
            if (!transient) rethrow;
            if (attempt >= 1) {
              await resolveRpc(); // switch to a candidate that resolves now
              rpc = RpcClient(network.baseRpc);
            }
            await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          }
        }
        // ignore: only_throw_errors — re-surface the RPC's own error to the handler below
        if (lamports == null) throw lastErr ?? StateError('balance unavailable');
        _solLamports = lamports;
        _netError = null; // a good read clears any prior network error
      } on Object catch (e) {
        debugPrint('[wallet] SOL balance failed ($e)');
        final s = '$e';
        _netError = (s.contains('Failed host lookup') || s.contains('SocketException'))
            ? "Can't reach the network. Check the device's internet, and set "
                  'Private DNS → Off (Settings → Network → Private DNS).'
            : (s.contains('-32504') || s.contains('504') || s.contains('429') || s.contains('timed out'))
                ? 'RPC overloaded (timed out). Set your own endpoint: run with '
                      '--dart-define=THROTL_RPC=https://mainnet.helius-rpc.com/?api-key=YOUR_KEY'
                : 'RPC unreachable — try another endpoint.';
      }
      try {
        // For Flash trades, read the Flash basket balance (after funding)
        // Falls back to wallet USDC if no basket yet
        try {
          final api = FlashApi();
          final state = await api.ownerState(o);
          final basketPubkey = state['basketPubkey'] as String?;
          if (basketPubkey != null && basketPubkey.isNotEmpty) {
            final raw = await api.withdrawableRaw(basketPubkey, 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v');
            _usdc6 = raw;
            api.close();
            return; // use Flash basket balance, skip wallet USDC read
          }
          api.close();
        } on Object {
          // Fall through to wallet USDC if Flash read fails
        }

        // Fallback: read wallet USDC token account
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

  /// The robust money path: owner-**sign only** via MWA (no wallet
  /// simulate/submit — so no flaky "Simulation failed, can't predict balance
  /// changes"), then submit to [rpc] ourselves and return the signatures. The tx
  /// goes to the RIGHT RPC and WE see the real on-chain error (the wallet hides
  /// it). Matches the proven sol_new / Flash-trade signing pattern.
  Future<List<String>> signAndSubmit(
    List<Uint8List> txs,
    RpcClient rpc, {
    bool skipPreflight = false,
  }) async {
    final signed = await _mwa.signTransactions(txs, cluster: network.mwaCluster);
    final sigs = <String>[];
    for (final s in signed) {
      sigs.add(await _submitWithRetry(rpc, base64Encode(s), skipPreflight));
    }
    return sigs;
  }

  /// Broadcast a signed tx, surviving the **MWA resume-race**: the wallet
  /// round-trip backgrounds us, and on resume Android often hasn't re-bound the
  /// app's network yet, so the very first `getaddrinfo` throws "Failed host
  /// lookup … (errno = 7)" even though the device is online. The signed payload
  /// never left the device, so a re-send can't double-submit — we retry on
  /// DNS/socket/timeout failures (rotating to a healthier RPC) until the network
  /// settles. A real on-chain rejection (which means the tx *did* reach the RPC)
  /// is re-thrown immediately.
  Future<String> _submitWithRetry(RpcClient rpc, String b64, bool skipPreflight) async {
    var client = rpc;
    Object? lastErr;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        return await client.sendTransaction(b64, skipPreflight: skipPreflight);
      } on Object catch (e) {
        lastErr = e;
        final s = '$e';
        final retriable = s.contains('Failed host lookup') ||
            s.contains('No address associated') ||
            s.contains('SocketException') ||
            s.contains('Connection closed') ||
            s.contains('Connection reset') ||
            s.contains('-32504') ||
            s.contains('504') ||
            s.contains('429') ||
            s.contains('timed out') ||
            s.contains('TimeoutException');
        if (!retriable) rethrow; // reached the RPC → it's a real error, surface it
        await resolveRpc(); // re-probe; switch to a candidate that resolves now
        client = RpcClient(network.baseRpc);
        await Future<void>.delayed(Duration(milliseconds: 700 * (attempt + 1)));
      }
    }
    // ignore: only_throw_errors — re-surface the RPC's own network error
    throw lastErr ?? StateError('transaction submit failed');
  }
}
