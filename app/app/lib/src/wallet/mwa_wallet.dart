import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana_mobile_client/solana_mobile_client.dart';
import 'package:throtl/src/wallet/wallet_backend.dart';

/// The Mobile Wallet Adapter edge — a thin, byte-level wrapper over
/// `solana_mobile_client` (Android only; the Seeker target). Ported from the
/// proven `aura` MwaWalletService: one `LocalAssociationScenario` per call,
/// `reauthorize` when the cluster is unchanged, full `authorize` otherwise; the
/// wallet returns raw bytes, we base58 the pubkey/signatures ourselves. No
/// `package:solana` dependency here — keeps this layer free of the chain SDK.
class MwaWallet implements WalletBackend {
  MwaWallet({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static final Uri _identityUri = Uri.parse('https://throtl.fun');
  static const _identityName = 'Throtl';

  final FlutterSecureStorage _storage;

  String? _publicKey;
  String? _authToken;
  String? _walletName;
  String _authCluster = 'mainnet-beta';

  /// Connected wallet address (base58), or null.
  @override
  String? get publicKey => _publicKey;

  /// The connected wallet's account label, if it gave one.
  @override
  String? get walletName => _walletName;

  /// MWA is Android-only.
  @override
  bool get isAvailable => !kIsWeb && Platform.isAndroid;

  /// Restore a persisted session at boot. The pubkey / cluster / name live in
  /// SharedPreferences (reliable across hot-restart, unlike the Android keystore
  /// path that flutter_secure_storage uses); only the sensitive auth token stays
  /// in secure storage. We just need the pubkey to show "connected" and read
  /// balances — the next signature transparently re-auths if the token is gone.
  @override
  Future<void> loadPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _publicKey = prefs.getString('mwa_public_key');
      _authCluster = prefs.getString('mwa_auth_cluster') ?? 'mainnet-beta';
      _walletName = prefs.getString('mwa_wallet_name');
      _authToken = await _storage.read(key: 'mwa_auth_token');
    } on Object catch (e) {
      debugPrint('[MWA] loadPersisted failed ($e)');
    }
  }

  /// Persist the session. AWAITED (not fire-and-forget) so a hot-restart right
  /// after connecting still finds the pubkey.
  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pk = _publicKey;
      final name = _walletName;
      if (pk != null) await prefs.setString('mwa_public_key', pk);
      await prefs.setString('mwa_auth_cluster', _authCluster);
      if (name != null) await prefs.setString('mwa_wallet_name', name);
      if (_authToken != null) await _storage.write(key: 'mwa_auth_token', value: _authToken);
    } on Object catch (e) {
      debugPrint('[MWA] persist failed ($e)');
    }
  }

  /// On mobile the OS shows its own wallet chooser, so there's a single logical
  /// entry — selection happens in that system sheet, not ours.
  @override
  Future<List<WalletOption>> listWallets() async =>
      isAvailable ? const [WalletOption(id: 'mwa', name: 'Wallet app')] : const [];

  /// Connect: launch the system wallet chooser and authorize on [cluster]
  /// (`'devnet'` / `'mainnet-beta'`). Returns the base58 owner pubkey. [walletId]
  /// is ignored — the Android wallet chooser does the picking.
  @override
  Future<WalletConnectResult> connect({required String cluster, String? walletId}) async {
    if (!isAvailable) {
      return WalletConnectResult.fail('Wallet connect needs an Android device + wallet app');
    }
    final session = await LocalAssociationScenario.create();
    try {
      session.startActivityForResult(null).ignore();
      final client = await session.start();
      final auth = await client.authorize(
        identityUri: _identityUri,
        identityName: _identityName,
        iconUri: Uri.parse('icon.png'),
        cluster: cluster,
      );
      if (auth == null) return WalletConnectResult.fail('Authorization cancelled');
      _publicKey = base58Encode(Uint8List.fromList(auth.publicKey));
      _authToken = auth.authToken;
      _authCluster = cluster;
      _walletName = auth.accountLabel;
      await _persist();
      return WalletConnectResult.ok(
        publicKey: _publicKey!,
        walletName: auth.accountLabel,
      );
    } on PlatformException catch (e) {
      return WalletConnectResult.fail(e.message ?? e.code);
    } on Object catch (e) {
      return WalletConnectResult.fail(e.toString());
    } finally {
      await session.close();
    }
  }

  /// Sign + send serialized transactions; returns base58 signatures. The OWNER
  /// signs (the wallet app broadcasts). Used for `init_ride`/`delegate_ride`
  /// and `close_ride` — the only owner-signed, wallet-popup moments per ride.
  @override
  Future<List<String>> signAndSend(
    List<Uint8List> transactions, {
    required String cluster,
  }) async {
    if (!isAvailable) throw const MwaException('Wallet unavailable');
    final session = await LocalAssociationScenario.create();
    try {
      session.startActivityForResult(null).ignore();
      final client = await session.start();
      await _ensureAuthorized(client, cluster);
      final result = await client.signAndSendTransactions(transactions: transactions);
      final sigs = result.signatures.map((s) => base58Encode(Uint8List.fromList(s))).toList();
      if (sigs.isEmpty) {
        throw const MwaException('Wallet returned no signatures');
      }
      return sigs;
    } on PlatformException catch (e) {
      throw MwaException('Wallet rejected transaction: ${e.message ?? e.code}');
    } finally {
      await session.close();
    }
  }

  /// Sign (don't send) — for txs the app submits itself (bypasses the wallet's
  /// simulation, which can reject devnet / sponsored txs).
  @override
  Future<List<Uint8List>> signTransactions(
    List<Uint8List> transactions, {
    required String cluster,
  }) async {
    if (!isAvailable) throw const MwaException('Wallet unavailable');
    final session = await LocalAssociationScenario.create();
    try {
      session.startActivityForResult(null).ignore();
      final client = await session.start();
      await _ensureAuthorized(client, cluster);
      final result = await client.signTransactions(transactions: transactions);
      if (result.signedPayloads.isEmpty) {
        throw const MwaException('Wallet returned no signed payloads');
      }
      return result.signedPayloads.map(Uint8List.fromList).toList();
    } on PlatformException catch (e) {
      throw MwaException('Wallet rejected signing: ${e.message ?? e.code}');
    } finally {
      await session.close();
    }
  }

  /// Reauthorize when the cluster matches the stored session; otherwise a fresh
  /// authorize (reauthorize inherits the original cluster — a mismatch would
  /// send the tx to the wrong network).
  Future<void> _ensureAuthorized(MobileWalletAdapterClient client, String cluster) async {
    if (_authToken != null && cluster == _authCluster) {
      try {
        final reauth = await client.reauthorize(
          identityUri: _identityUri,
          identityName: _identityName,
          iconUri: Uri.parse('icon.png'),
          authToken: _authToken!,
        );
        if (reauth != null) {
          _authToken = reauth.authToken;
          await _persist();
          return;
        }
      } on Object catch (e) {
        debugPrint('[MWA] reauthorize failed ($e) — full authorize');
      }
    }
    final auth = await client.authorize(
      identityUri: _identityUri,
      identityName: _identityName,
      iconUri: Uri.parse('icon.png'),
      cluster: cluster,
    );
    if (auth == null) throw const MwaException('Authorization cancelled');
    _authToken = auth.authToken;
    _publicKey = base58Encode(Uint8List.fromList(auth.publicKey));
    _authCluster = cluster;
    await _persist();
  }

  @override
  Future<void> disconnect() async {
    _publicKey = null;
    _authToken = null;
    _walletName = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('mwa_public_key');
      await prefs.remove('mwa_auth_cluster');
      await prefs.remove('mwa_wallet_name');
    } on Object {
      // best-effort clear
    }
    await _storage.delete(key: 'mwa_auth_token');
  }
}

class MwaException implements Exception {
  const MwaException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ── base58 (Bitcoin alphabet) — the wallet returns raw bytes ──
const _b58Alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

/// Base58-encode raw bytes (e.g. a 32-byte pubkey or 64-byte signature).
String base58Encode(Uint8List input) {
  if (input.isEmpty) return '';
  final bytes = Uint8List.fromList(input); // copy — the algorithm mutates
  var zeros = 0;
  while (zeros < bytes.length && bytes[zeros] == 0) {
    zeros++;
  }
  final encoded = <int>[];
  var start = zeros;
  while (start < bytes.length) {
    var carry = 0;
    for (var i = start; i < bytes.length; i++) {
      carry = carry * 256 + bytes[i];
      bytes[i] = carry ~/ 58;
      carry %= 58;
    }
    encoded.add(carry);
    while (start < bytes.length && bytes[start] == 0) {
      start++;
    }
  }
  final buf = StringBuffer();
  for (var i = 0; i < zeros; i++) {
    buf.write('1');
  }
  for (var i = encoded.length - 1; i >= 0; i--) {
    buf.write(_b58Alphabet[encoded[i]]);
  }
  return buf.toString();
}
