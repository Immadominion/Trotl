import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One completed ride, recorded when the player pits in. This is the real
/// Paddock history — newest first, capped — replacing the old mock list.
class RaceSession {
  const RaceSession({
    required this.tsMs,
    required this.pnl6,
    required this.ticks,
    required this.peakLev,
    required this.live,
  });

  factory RaceSession.fromJson(Map<String, dynamic> j) => RaceSession(
    tsMs: (j['ts'] as num?)?.toInt() ?? 0,
    pnl6: (j['pnl6'] as num?)?.toInt() ?? 0,
    ticks: (j['ticks'] as num?)?.toInt() ?? 0,
    peakLev: (j['peak'] as num?)?.toDouble() ?? 0,
    live: j['live'] as bool? ?? false,
  );

  /// Epoch millis the ride ended.
  final int tsMs;

  /// Realized PnL in USDC base units (6dp). Negative for a losing ride.
  final int pnl6;

  /// Ticks streamed during the ride.
  final int ticks;

  /// Peak leverage reached, as a multiplier (e.g. 18.2).
  final double peakLev;

  /// Real-money ride (true) vs practice (false).
  final bool live;

  bool get win => pnl6 >= 0;

  Map<String, dynamic> toJson() => {
    'ts': tsMs,
    'pnl6': pnl6,
    'ticks': ticks,
    'peak': peakLev,
    'live': live,
  };
}

/// SharedPreferences-backed ride history — same pattern as RentReclaimStore.
class SessionHistoryStore {
  static const _key = 'throtl.race_history_v1';
  static const _cap = 50;

  static Future<List<RaceSession>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    final out = <RaceSession>[];
    for (final s in raw) {
      try {
        out.add(RaceSession.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } on Object {
        // skip a corrupt row rather than lose the whole history
      }
    }
    return out;
  }

  /// Prepend [session] (newest first) and trim to [_cap].
  static Future<void> record(RaceSession session) async {
    final prefs = await SharedPreferences.getInstance();
    final cur = prefs.getStringList(_key) ?? const [];
    final next = <String>[jsonEncode(session.toJson()), ...cur];
    if (next.length > _cap) next.removeRange(_cap, next.length);
    await prefs.setStringList(_key, next);
  }
}
