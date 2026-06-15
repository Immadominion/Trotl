import 'dart:async';
import 'dart:convert';

import 'package:flash_client/flash_client.dart';
import 'package:flutter/foundation.dart';
import 'package:solana/solana.dart';
import 'package:throtl/src/chain/network.dart';
import 'package:throtl/src/wallet/flash_session.dart';
import 'package:throtl/src/wallet/wallet_backend.dart';

/// Connection lifecycle for the UI.
enum WalletStatus { disconnected, connecting, connected }

/// App-state for the connected wallet: owner pubkey, live SOL/USDC balances,
/// the active [AppCluster], and the per-ride ephemeral session keypair. Slow
/// app state (not the 60fps loop) → a plain [ChangeNotifier], mirrored on the
/// existing `ThemeController` pattern. The on-chain ride orchestration (Phase C)
/// reads `owner`, `sessionKey`, `network`, and signs owner txs via [signAndSend].
class WalletController extends ChangeNotifier {
  WalletController({WalletBackend? backend}) : _backend = backend ?? createWalletBackend() {
    _restore();
  }

  final WalletBackend _backend;

  // Mainnet is the only network — Flash Trade (the settlement venue) is
  // mainnet-only, so "devnet" was never a real ride target. The practice vs
  // live distinction is funds (fake vs real), not the chain.
  final AppCluster _cluster = AppCluster.mainnet;
  WalletStatus _status = WalletStatus.disconnected;
  String? _owner;
  String? _walletName;
  int _solLamports = 0;
  int _usdc6 = 0;
  int _walletUsdc6 = 0;
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
  bool get mwaAvailable => _backend.isAvailable;
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

  /// Spendable USDC sitting in the wallet itself (available to deposit) — distinct
  /// from [usdcUi], the Flash fuel. Refreshed alongside the other balances.
  int get walletUsdc6 => _walletUsdc6;
  double get walletUsdcUi => _walletUsdc6 / 1e6;

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
      await _backend.loadPersisted();
      final pk = _backend.publicKey;
      if (pk != null) {
        _owner = pk;
        _walletName = _backend.walletName;
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

  /// Wallets the user can pick from (browser wallets on web; one OS entry on mobile).
  Future<List<WalletOption>> listWallets() => _backend.listWallets();

  /// Connect on the active cluster. [walletId] selects a specific browser wallet
  /// (the web picker); on mobile the OS chooser handles it.
  Future<bool> connect({String? walletId}) async {
    if (!_backend.isAvailable) {
      _error = 'Wallet connect needs an Android device with a wallet app';
      notifyListeners();
      return false;
    }
    _status = WalletStatus.connecting;
    _error = null;
    notifyListeners();
    final res = await _backend.connect(cluster: network.mwaCluster, walletId: walletId);
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

  /// Fully clear the session so a different wallet can log in cleanly: stop the
  /// poll, wipe the MWA token + persisted pubkey, and reset ALL per-wallet state
  /// (balances, name, errors, ephemeral session key, in-flight flag).
  Future<void> disconnect() async {
    _stopPoll();
    await _backend.disconnect();
    _owner = null;
    _walletName = null;
    _solLamports = 0;
    _usdc6 = 0;
    _walletUsdc6 = 0;
    _netError = null;
    _error = null;
    _refreshing = false;
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
            final transient =
                s.contains('Failed host lookup') ||
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
        if (_owner != o) return; // wallet switched mid-read — drop stale values
        _solLamports = lamports;
        _netError = null; // a good read clears any prior network error
      } on Object catch (e) {
        debugPrint('[wallet] SOL balance failed ($e)');
        final s = '$e';
        _netError = (s.contains('Failed host lookup') || s.contains('SocketException'))
            ? "Can't reach the network. Check the device's internet, and set "
                  'Private DNS → Off (Settings → Network → Private DNS).'
            : (s.contains('-32504') ||
                  s.contains('504') ||
                  s.contains('429') ||
                  s.contains('timed out'))
            ? 'RPC overloaded (timed out). Set your own endpoint: run with '
                  '--dart-define=THROTL_RPC=https://mainnet.helius-rpc.com/?api-key=YOUR_KEY'
            : 'RPC unreachable — try another endpoint.';
      }
      try {
        // Flash "fuel" = available collateral = deposit-ledger balance − basket
        // debits + basket pendingCredits (research/flash.md §3). The deposit lives
        // in the on-chain UserDepositLedger PDA — NOT the basket and NOT a wallet
        // ATA — so a funded-but-not-yet-traded wallet must read the ledger directly
        // or it shows $0. Verified on mainnet: ledger TVPZ… holds the 11 USDC.
        final owner = Ed25519HDPublicKey.fromBase58(o);
        final deposits = await flashLedgerBalanceRaw(rpc, owner, cfg.usdcMint);
        var net = 0; // pendingCredits − debits, once a basket exists
        final api = FlashApi();
        try {
          final state = await api.ownerState(o);
          final basketPubkey = state['basketPubkey'] as String?;
          if (basketPubkey != null && basketPubkey.isNotEmpty) {
            final raw = await api.rawBasket(basketPubkey);
            net = computeBasketNetRaw(
              raw['account'] as Map<String, dynamic>? ?? const {},
              cfg.usdcMint,
            );
          }
        } on Object {
          // no basket yet / API blip — the ledger deposit is still the right base
        } finally {
          api.close();
        }
        final bal = deposits + net;
        if (_owner != o) return; // wallet switched mid-read — drop stale values
        _usdc6 = bal < 0 ? 0 : bal;
      } on Object {
        // Flash collateral read failed entirely (DNS/RPC) — keep the last good
        // value rather than flashing a wrong $0; the next poll retries.
      }
      // Wallet USDC (what's available to deposit) — shown alongside Flash fuel.
      try {
        final ata = await findAssociatedTokenAddress(
          owner: Ed25519HDPublicKey.fromBase58(o),
          mint: Ed25519HDPublicKey.fromBase58(cfg.usdcMint),
        );
        final t = await rpc.getTokenAccountBalance(ata.toBase58());
        if (_owner == o) _walletUsdc6 = int.tryParse(t.value.amount) ?? 0;
      } on Object {
        // no USDC ATA yet / read blip — leave the last value
      }
    } finally {
      // always release the flag — a stuck `_refreshing` would freeze every
      // future read (poll + manual + resume).
      _refreshing = false;
      notifyListeners();
    }
  }

  /// The owner's spendable USDC sitting in their wallet (the ATA balance) — what's
  /// available to DEPOSIT into Flash. Separate from [usdc6], which is the Flash
  /// fuel (deposit-ledger) balance. Raw 6dp units; 0 if no ATA or the read fails.
  Future<int> readWalletUsdc6() async {
    final o = _owner;
    if (o == null) return 0;
    try {
      final rpc = RpcClient(network.baseRpc);
      final ata = await findAssociatedTokenAddress(
        owner: Ed25519HDPublicKey.fromBase58(o),
        mint: Ed25519HDPublicKey.fromBase58(network.usdcMint),
      );
      final t = await rpc.getTokenAccountBalance(ata.toBase58());
      return int.tryParse(t.value.amount) ?? 0;
    } on Object {
      return 0;
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
      _backend.signAndSend(txs, cluster: network.mwaCluster);

  /// Owner-signs txs without broadcasting (app submits).
  Future<List<Uint8List>> signTransactions(List<Uint8List> txs) =>
      _backend.signTransactions(txs, cluster: network.mwaCluster);

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
    final signed = await _backend.signTransactions(txs, cluster: network.mwaCluster);
    final sigs = <String>[];
    for (final s in signed) {
      sigs.add(await _submitWithRetry(rpc, base64Encode(s), skipPreflight));
    }
    return sigs;
  }

  /// Submit an ALREADY-fully-signed tx via the same DNS-resilient retry path as
  /// [signAndSubmit]. Used when a tx needs a second in-memory signer beyond the
  /// wallet (e.g. the arming tx's Flash `session_signer`): MWA fills the owner slot
  /// via [signTransactions], the ephemeral key co-signs ([coSignSessionKey]), then
  /// the fully-signed bytes land here.
  Future<String> submitSigned(
    Uint8List signedTx,
    RpcClient rpc, {
    bool skipPreflight = false,
  }) => _submitWithRetry(rpc, base64Encode(signedTx), skipPreflight);

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
        final retriable =
            s.contains('Failed host lookup') ||
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
