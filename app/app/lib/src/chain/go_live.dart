import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Flash Trade v2 endpoints (mainnet-only). Trades execute on Flash's own ER;
/// setup (deposit/basket) + withdrawal go to the base mainnet RPC.
const String flashErRpc = 'https://flash.magicblock.xyz';
const String flashApiBase = 'https://flashapi.trade/v2';

/// The **go-live gate** — the deliberate switch between practice (simulated Flash,
/// no funds) and real-money mode (the RealFlashGateway trades your own USDC on
/// Flash Trade). OFF by default and persisted; turning it ON requires an explicit
/// risk acknowledgement (see the settings sheet). This is the only thing that lets
/// real money move, so nothing flips it implicitly.
class GoLiveController extends ChangeNotifier {
  GoLiveController({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage() {
    unawaited(_restore());
  }

  static const _key = 'throtl.goLive.armed';
  final FlutterSecureStorage _storage;

  bool _armed = false;
  bool _loaded = false;

  /// Whether real-money Flash trading is armed. Practice (sim) when false.
  bool get armed => _armed;
  bool get loaded => _loaded;

  Future<void> _restore() async {
    try {
      _armed = (await _storage.read(key: _key)) == '1';
    } on Object {
      _armed = false;
    }
    _loaded = true;
    notifyListeners();
  }

  /// Arm real-money mode. Caller MUST have shown + captured the risk disclosure.
  Future<void> arm() async {
    _armed = true;
    notifyListeners();
    try {
      await _storage.write(key: _key, value: '1');
    } on Object {
      /* best-effort persistence */
    }
  }

  /// Return to practice (simulated Flash). Always available.
  Future<void> disarm() async {
    _armed = false;
    notifyListeners();
    try {
      await _storage.delete(key: _key);
    } on Object {
      /* best-effort */
    }
  }
}
