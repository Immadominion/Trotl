import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:throtl/src/wallet/wallet_backend.dart';

/// Web wallet backend — talks to the browser's injected Solana wallet (Phantom /
/// Solflare / Backpack) through a tiny JS shim (`web/wallet.js`, exposed as
/// `window.throtlWallet`). The shim owns the `@solana/web3.js` + provider plumbing;
/// Dart just passes base64 transactions across. It honors the SAME sign-only
/// contract as the mobile MWA backend — [signTransactions] returns the wallet-signed
/// payload (partial signing allowed) and the app submits — so the arming/funding
/// flows and the Flash-session co-sign work identically on web.
class WebWallet implements WalletBackend {
  String? _publicKey;
  String? _walletName;

  @override
  bool get isAvailable {
    final s = _shim;
    return s != null && s.available();
  }

  @override
  String? get publicKey => _publicKey;

  @override
  String? get walletName => _walletName;

  @override
  Future<void> loadPersisted() async {
    final s = _shim;
    if (s == null) return;
    try {
      // Silent reconnect if the wallet already trusts this origin (no popup).
      final pk = (await s.eagerConnect().toDart)?.toDart;
      if (pk != null && pk.isNotEmpty) {
        _publicKey = pk;
        _walletName = s.walletName();
      }
    } on Object {
      // not previously connected — that's fine, the user can connect manually
    }
  }

  @override
  Future<WalletConnectResult> connect({required String cluster}) async {
    final s = _shim;
    if (s == null || !s.available()) {
      return WalletConnectResult.fail(
        'No Solana wallet found. Install Phantom, Solflare, or Backpack and reload.',
      );
    }
    try {
      final pk = (await s.connect().toDart).toDart;
      _publicKey = pk;
      _walletName = s.walletName();
      return WalletConnectResult.ok(publicKey: pk, walletName: _walletName);
    } on Object catch (e) {
      return WalletConnectResult.fail(_clean(e));
    }
  }

  @override
  Future<List<Uint8List>> signTransactions(
    List<Uint8List> txs, {
    required String cluster,
  }) async {
    final s = _shim;
    if (s == null) throw StateError('No browser wallet available');
    final b64 = txs.map((t) => base64Encode(t).toJS).toList().toJS;
    final signed = await s.signTransactions(b64).toDart;
    return signed.toDart.map((j) => Uint8List.fromList(base64Decode(j.toDart))).toList();
  }

  @override
  Future<List<String>> signAndSend(
    List<Uint8List> txs, {
    required String cluster,
  }) async {
    final s = _shim;
    if (s == null) throw StateError('No browser wallet available');
    final b64 = txs.map((t) => base64Encode(t).toJS).toList().toJS;
    final sigs = await s.signAndSend(b64).toDart;
    return sigs.toDart.map((j) => j.toDart).toList();
  }

  @override
  Future<void> disconnect() async {
    _publicKey = null;
    _walletName = null;
    final s = _shim;
    if (s == null) return;
    try {
      await s.disconnect().toDart;
    } on Object {
      // best-effort
    }
  }
}

/// Native impl factory resolved by the conditional import in `wallet_backend.dart`.
WalletBackend makeWalletBackend() => WebWallet();

String _clean(Object e) {
  final s = '$e';
  final l = s.toLowerCase();
  if (l.contains('user rejected') || l.contains('4001') || l.contains('cancel')) {
    return 'Connection cancelled';
  }
  return s.replaceFirst('Error: ', '').replaceFirst('JSError: ', '');
}

// ── JS shim binding (window.throtlWallet from web/wallet.js) ──────────────────
@JS('throtlWallet')
external JSObject? get _shimRaw;

_ThrotlWalletJs? get _shim => _shimRaw == null ? null : _ThrotlWalletJs._(_shimRaw!);

extension type _ThrotlWalletJs._(JSObject _) implements JSObject {
  external bool available();
  external String? walletName();
  external JSPromise<JSString> connect();
  external JSPromise<JSString?> eagerConnect();
  external JSPromise<JSArray<JSString>> signTransactions(JSArray<JSString> b64Txs);
  external JSPromise<JSArray<JSString>> signAndSend(JSArray<JSString> b64Txs);
  external JSPromise<JSAny?> disconnect();
}
