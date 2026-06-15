import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

/// The shared low-latency audio backend (one `flutter_soloud` engine drives both
/// the [SfxController] and the [MusicController]). Init is idempotent and
/// guarded so a device without a working audio backend degrades to silence.
class _AudioBackend {
  final SoLoud soloud = SoLoud.instance;
  bool ready = false;
  Object? lastError;

  Future<bool> ensure() async {
    if (ready) return true;
    try {
      if (!soloud.isInitialized) {
        await soloud.init();
      }
      ready = true;
      lastError = null;
      return true;
    } on Object catch (e) {
      lastError = e;
      debugPrint('AudioBackend: init failed ($e)');
      ready = false;
      return false;
    }
  }
}

final _AudioBackend _backend = _AudioBackend();

/// SFX bus — matches the design's `sfx.js` + `ThrottleAudio`: short interface
/// one-shots (CC0 OGGs), a **synthesised engine drone** that rises with the
/// throttle, and synthesised game beats (coin / loss / skid / eject / count)
/// rather than re-purposed UI jingles. Gated on its own [enabled] flag.
class SfxController {
  final Map<String, AudioSource> _sources = {};
  bool _ready = false;
  bool _enabled = false;

  bool get enabled => _enabled;
  Object? get lastError => _backend.lastError;

  // ── synthesised voices (WebAudio in the design; SoLoud waveforms here) ──
  AudioSource? _engine; // looping saw — the analog engine hum
  SoundHandle? _engineHandle;
  AudioSource? _square; // coin / count blips
  AudioSource? _triangle; // loss / bank
  AudioSource? _sawFx; // skid / eject sweeps (separate from the engine saw)

  // OGG one-shots (without the assets/audio/ prefix or .ogg suffix): the short
  // interface clicks + the win/loss pit stings.
  static const _oneShots = <String>[
    'ui-click',
    'ui-select',
    'ui-switch',
    'ui-toggle',
    'ui-back',
    'ui-confirm',
    'ui-open',
    'ui-notify',
    'win',
    'lose',
  ];

  /// Warms the backend + decodes the one-shots and builds the synth voices once
  /// at boot, independent of [enabled] (so the first tap is never silent).
  Future<void> init({required bool enabled}) async {
    _enabled = enabled;
    if (_ready) return;
    if (!await _backend.ensure()) return;
    try {
      for (final name in _oneShots) {
        _sources[name] = await _backend.soloud.loadAsset('assets/audio/$name.ogg');
      }
      _engine = await _backend.soloud.loadWaveform(WaveForm.saw, false, 1, 1);
      _square = await _backend.soloud.loadWaveform(WaveForm.square, false, 1, 1);
      _triangle = await _backend.soloud.loadWaveform(WaveForm.triangle, false, 1, 1);
      _sawFx = await _backend.soloud.loadWaveform(WaveForm.saw, false, 1, 1);
      _ready = true;
    } on Object catch (e) {
      debugPrint('SfxController: load failed ($e)');
      _ready = false;
    }
  }

  Future<void> setEnabled({required bool on}) async {
    _enabled = on;
    if (!on) {
      engineStop();
    } else if (!_ready) {
      await init(enabled: true);
    }
  }

  void _play(String name, {required double volume}) {
    if (!_enabled || !_ready) return;
    final src = _sources[name];
    if (src == null) return;
    unawaited(_safePlay(src, volume));
  }

  Future<void> _safePlay(AudioSource src, double volume) async {
    try {
      await _backend.soloud.play(src, volume: volume);
    } on Object catch (_) {
      // Drop a single missed sound rather than surface an error.
    }
  }

  // ── the engine drone (design's ThrottleAudio) ───────────────────────────
  // A looping saw whose pitch + loudness track the throttle deflection. Started
  // when the race scene mounts, fed each frame, silenced on leave.
  Future<void> engineStart() async {
    if (!_enabled || !_ready || _engine == null || _engineHandle != null) return;
    try {
      _engineHandle = await _backend.soloud.play(_engine!, volume: 0, looping: true);
    } on Object catch (_) {
      _engineHandle = null;
    }
  }

  /// Feed the drone: [level] is |throttle| (0..1), [on] gates it to silence
  /// while coasting. Mirrors `ThrottleAudio.set` (freq 46→196 Hz, soft gain).
  void engineSet(double level, {required bool on}) {
    final h = _engineHandle;
    if (h == null || _engine == null) return;
    try {
      _backend.soloud
        ..setWaveformFreq(_engine!, 46 + level * 150)
        ..setVolume(h, on && level > 0.01 ? 0.03 + level * 0.12 : 0);
    } on Object catch (_) {}
  }

  void engineStop() {
    final h = _engineHandle;
    _engineHandle = null;
    if (h == null) return;
    try {
      unawaited(_backend.soloud.stop(h));
    } on Object catch (_) {}
  }

  /// Pause the engine drone without losing the voice (app backgrounded). The
  /// handle survives so [resumeEngine] can pick it back up on foreground.
  void pauseEngine() {
    final h = _engineHandle;
    if (h == null) return;
    try {
      _backend.soloud.setPause(h, true);
    } on Object catch (_) {}
  }

  void resumeEngine() {
    final h = _engineHandle;
    if (h == null || !_enabled) return;
    try {
      _backend.soloud.setPause(h, false);
    } on Object catch (_) {}
  }

  // ── synth helpers ────────────────────────────────────────────────────────
  void _blip(
    AudioSource? src, {
    required double freq,
    required double vol,
    required Duration dur,
    double? slideTo,
  }) {
    if (!_enabled || !_ready || src == null) return;
    final sl = _backend.soloud;
    unawaited(() async {
      try {
        sl.setWaveformFreq(src, freq);
        final h = await sl.play(src, volume: vol);
        if (slideTo != null) {
          // ramp the pitch over the note (WebAudio exponentialRamp stand-in)
          const steps = 8;
          for (var i = 1; i <= steps; i++) {
            unawaited(
              Future<void>.delayed(dur * (i / steps), () {
                try {
                  sl.setWaveformFreq(src, freq + (slideTo - freq) * (i / steps));
                } on Object catch (_) {}
              }),
            );
          }
        }
        sl.fadeVolume(h, 0, dur);
        unawaited(
          Future<void>.delayed(dur + const Duration(milliseconds: 20), () {
            try {
              unawaited(sl.stop(h));
            } on Object catch (_) {}
          }),
        );
      } on Object catch (_) {}
    }());
  }

  // ── interface sounds (OGG) ──
  void click() => _play('ui-click', volume: 0.5);
  void select() => _play('ui-select', volume: 0.5);
  void swap() => _play('ui-switch', volume: 0.5);
  void toggle() => _play('ui-toggle', volume: 0.5);
  void back() => _play('ui-back', volume: 0.5);
  void confirm() => _play('ui-confirm', volume: 0.6);
  void open() => _play('ui-open', volume: 0.5);
  void notify() => _play('ui-notify', volume: 0.6);

  // ── pit-in result stings (OGG win/lose, like the design's pitWin/pitLoss) ──
  void pitWin() => _play('win', volume: 0.62);
  void pitLoss() => _play('lose', volume: 0.62);

  // ── synthesised game beats (mirroring sfx.js) ──
  /// Profitable tick — a bright two-note square pop (880 → 1320).
  void coin() {
    _blip(_square, freq: 880, vol: 0.32, dur: const Duration(milliseconds: 70));
    Timer(const Duration(milliseconds: 45), () {
      _blip(_square, freq: 1320, vol: 0.32, dur: const Duration(milliseconds: 90));
    });
  }

  /// Losing tick — a soft descending triangle.
  void loss() => _blip(
    _triangle,
    freq: 220,
    slideTo: 140,
    vol: 0.3,
    dur: const Duration(milliseconds: 110),
  );

  /// Tyre skid — a quick descending saw screech.
  void skid() => _blip(
    _sawFx,
    freq: 320,
    slideTo: 90,
    vol: 0.34,
    dur: const Duration(milliseconds: 420),
  );

  /// Spin-out / eject — a harsh descending three-tone alarm.
  void eject() {
    _blip(_sawFx, freq: 440, slideTo: 130, vol: 0.4, dur: const Duration(milliseconds: 140));
    Timer(const Duration(milliseconds: 120), () {
      _blip(_sawFx, freq: 330, slideTo: 110, vol: 0.36, dur: const Duration(milliseconds: 180));
    });
    Timer(const Duration(milliseconds: 260), () {
      _blip(_square, freq: 220, slideTo: 120, vol: 0.32, dur: const Duration(milliseconds: 240));
    });
  }

  /// Countdown tick — a clean square beep.
  void countBeep() => _blip(_square, freq: 620, vol: 0.34, dur: const Duration(milliseconds: 120));

  /// Launch — a rising square chirp.
  void countGo() {
    _blip(_square, freq: 880, vol: 0.4, dur: const Duration(milliseconds: 100));
    Timer(const Duration(milliseconds: 60), () {
      _blip(_square, freq: 1320, slideTo: 1480, vol: 0.4, dur: const Duration(milliseconds: 220));
    });
  }

  /// Play by a named sfx key used by widgets (e.g. ChunkyButton's `sfxName`).
  void byName(String name) {
    switch (name) {
      case 'click':
        click();
      case 'select':
        select();
      case 'swap':
        swap();
      case 'toggle':
        toggle();
      case 'back':
        back();
      case 'confirm':
        confirm();
      case 'open':
        open();
      case 'notify':
        notify();
      default:
        click();
    }
  }
}

/// Music bus — the melodic Kenney jingles: a soft looping race ambience that
/// sits *under* the engine drone, plus the result stings. Gated on its own
/// [enabled] flag (separate toggle from SFX). Accessed via [music].
class MusicController {
  final Map<String, AudioSource> _sources = {};
  bool _ready = false;
  bool _enabled = false;
  SoundHandle? _loop;
  String? _loopTrack;

  bool get enabled => _enabled;

  // Looping background music (Pixabay, mp3), STREAMED from disk (LoadMode.disk)
  // so the multi-minute tracks don't decode into ~100 MB of PCM each:
  //   • menu — "Street Racing" by Viktor Sklemin (SoundSurfer) · Pixabay 262363
  //   • race — "Racing Speed Gaming Music" by Viacheslav Starostin · Pixabay 361427
  static const _menuTrack = 'soundsurfer-street-racing-262363';
  static const _raceTrack = 'viacheslavstarostin-racing-speed-gaming-music-361427';
  static const _menuVol = 0.4; // app-open ambience (40%, per spec)
  static const _raceVol = 0.35; // in-race music — sits under the engine drone + SFX

  // Short melodic stings (OGG) for the settings-toggle preview.
  static const _stings = <String>['mus-win', 'mus-lose', 'mus-menu'];

  Future<void> init({required bool enabled}) async {
    _enabled = enabled;
    if (_ready) return;
    if (!await _backend.ensure()) return;
    try {
      for (final name in _stings) {
        _sources[name] = await _backend.soloud.loadAsset('assets/audio/$name.ogg');
      }
      _ready = true;
    } on Object catch (e) {
      debugPrint('MusicController: stings load failed ($e)');
      _ready = false;
    }
    // Stream the long mp3 beds from disk. Best-effort + separate from the stings:
    // if this fails it just means no background music, never total silence.
    try {
      _sources[_menuTrack] = await _backend.soloud.loadAsset(
        'assets/audio/$_menuTrack.mp3',
        mode: LoadMode.disk,
      );
      _sources[_raceTrack] = await _backend.soloud.loadAsset(
        'assets/audio/$_raceTrack.mp3',
        mode: LoadMode.disk,
      );
    } on Object catch (e) {
      debugPrint('MusicController: bg tracks load failed ($e)');
    }
  }

  Future<void> setEnabled({required bool on}) async {
    _enabled = on;
    if (!on) {
      stopLoopNow();
    } else if (!_ready) {
      await init(enabled: true);
    }
  }

  /// Switch the looping background music to [track] at [volume] (no-op if it's
  /// already the active loop, or music is off). Stops whatever was playing first,
  /// so the menu and race beds never stack.
  Future<void> _startLoop(String track, double volume) async {
    if (!_enabled || !_ready) return;
    if (_loopTrack == track && _loop != null) return;
    await stopLoop();
    final src = _sources[track];
    if (src == null) return;
    try {
      _loop = await _backend.soloud.play(src, volume: volume, looping: true);
      _loopTrack = track;
    } on Object catch (_) {
      _loop = null;
      _loopTrack = null;
    }
  }

  /// App-open ambience — plays on every menu screen at 40%.
  Future<void> startMenuLoop() => _startLoop(_menuTrack, _menuVol);

  /// In-race music — swapped in when the ride starts, after the 3·2·1.
  Future<void> startRaceLoop() => _startLoop(_raceTrack, _raceVol);

  Future<void> stopLoop() async {
    final h = _loop;
    _loop = null;
    _loopTrack = null;
    if (h == null) return;
    try {
      await _backend.soloud.stop(h);
    } on Object catch (_) {}
  }

  void stopLoopNow() {
    final h = _loop;
    _loop = null;
    _loopTrack = null;
    if (h == null) return;
    try {
      unawaited(_backend.soloud.stop(h));
    } on Object catch (_) {}
  }

  /// Pause the race loop without dropping it (app backgrounded) so [resumeLoop]
  /// can continue it on foreground — instead of YouTube-style background music.
  void pauseLoop() {
    final h = _loop;
    if (h == null) return;
    try {
      _backend.soloud.setPause(h, true);
    } on Object catch (_) {}
  }

  void resumeLoop() {
    final h = _loop;
    if (h == null || !_enabled) return;
    try {
      _backend.soloud.setPause(h, false);
    } on Object catch (_) {}
  }

  void _sting(String name, {required double volume}) {
    if (!_enabled || !_ready) return;
    final src = _sources[name];
    if (src == null) return;
    unawaited(() async {
      try {
        await _backend.soloud.play(src, volume: volume);
      } on Object catch (_) {}
    }());
  }

  /// Optional melodic stings (used for the settings-toggle preview).
  void win() => _sting('mus-win', volume: 0.6);
  void lose() => _sting('mus-lose', volume: 0.55);
  void menu() => _sting('mus-menu', volume: 0.4);
}

/// App-wide SFX bus. Initialized in `main`; safe to call before init (silent).
final SfxController sfx = SfxController();

/// App-wide music bus. Initialized in `main`; safe to call before init (silent).
final MusicController music = MusicController();
