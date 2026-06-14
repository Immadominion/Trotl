import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:throtl/src/theme/tokens.dart';

/// Holds the active brand [ThrotlPalette], the selected car, and the sound
/// flag — persisted across launches. Slow app state (not the 60fps loop), so
/// a plain [ChangeNotifier] is the right tool.
class ThemeController extends ChangeNotifier {
  ThemeController(this._prefs) {
    _load();
  }

  static const _kTheme = 'throtl.theme';
  static const _kSfx = 'throtl.sfx';
  static const _kMusic = 'throtl.music';
  static const _kCar = 'throtl.car';

  final SharedPreferences _prefs;

  ThrotlPalette _palette = kArcade;
  bool _sfxOn = true;
  bool _musicOn = true;
  int _carIndex = 0;

  ThrotlPalette get palette => _palette;

  /// Interface sound effects (clicks, coins, skids) — own toggle.
  bool get sfxOn => _sfxOn;

  /// Melodic music (race loop + result stings) — own toggle, separate from SFX.
  bool get musicOn => _musicOn;

  int get carIndex => _carIndex;
  GameCar get car => kCars[_carIndex];

  /// Livery tint follows the active theme.
  Color get tint => _palette.tint;

  void _load() {
    _palette = kThemes[_prefs.getString(_kTheme)] ?? kArcade;
    _sfxOn = _prefs.getBool(_kSfx) ?? true;
    _musicOn = _prefs.getBool(_kMusic) ?? true;
    _carIndex = _carIndexForAsset(_palette.carAsset);
    final savedCar = _prefs.getInt(_kCar);
    if (savedCar != null) {
      _carIndex = savedCar.clamp(0, kCars.length - 1);
    }
  }

  Future<void> setTheme(String key) async {
    final next = kThemes[key];
    if (next == null) return;
    _palette = next;
    // A theme arrives with its signature car (matches the design).
    _carIndex = _carIndexForAsset(next.carAsset);
    notifyListeners();
    await _prefs.setString(_kTheme, next.key);
    await _prefs.setInt(_kCar, _carIndex);
  }

  Future<void> setSfx({required bool on}) async {
    _sfxOn = on;
    notifyListeners();
    await _prefs.setBool(_kSfx, on);
  }

  Future<void> setMusic({required bool on}) async {
    _musicOn = on;
    notifyListeners();
    await _prefs.setBool(_kMusic, on);
  }

  void cycleCar(int dir) {
    _carIndex = (_carIndex + dir + kCars.length) % kCars.length;
    notifyListeners();
    unawaited(_prefs.setInt(_kCar, _carIndex));
  }

  void setCar(int index) {
    _carIndex = index.clamp(0, kCars.length - 1);
    notifyListeners();
    unawaited(_prefs.setInt(_kCar, _carIndex));
  }

  int _carIndexForAsset(String carKey) {
    final i = kCars.indexWhere((c) => c.key == carKey);
    return i < 0 ? 0 : i;
  }
}
