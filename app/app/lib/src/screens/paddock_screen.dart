import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/util/session_history.dart';
import 'package:throtl/src/widgets/balance_pill.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// The "Paddock" screen — the player's REAL race history (every pit-in, newest
/// first, from [SessionHistoryStore]) plus the live onchain proof stream.
class PaddockScreen extends StatefulWidget {
  const PaddockScreen({required this.onBack, required this.onRace, super.key});

  final VoidCallback onBack;
  final VoidCallback onRace;

  @override
  State<PaddockScreen> createState() => _PaddockScreenState();
}

class _PaddockScreenState extends State<PaddockScreen> {
  List<RaceSession> _sessions = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final s = await SessionHistoryStore.list();
    if (mounted) {
      setState(() {
        _sessions = s;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GameScaffold(
      bottomBar: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: ChunkyButton(
              label: 'BACK',
              color: p.purple,
              onTap: widget.onBack,
              sfxName: 'back',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: ChunkyButton(
              label: 'NEW SESSION',
              color: p.orange,
              big: true,
              onTap: widget.onRace,
            ),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: BannerPlate(
                    kicker: 'PADDOCK',
                    title: 'RACE HISTORY',
                    color: p.cyan,
                  ),
                ),
                const Spacer(),
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: BalancePill(),
                ),
              ],
            ),
            const SizedBox(height: 11),
            const _LiveExplorer(),
            const SizedBox(height: 11),
            if (_loaded && _sessions.isEmpty)
              _emptyState(p)
            else
              for (final session in _sessions) ...[
                _SessionRow(session: session),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }

  Widget _emptyState(ThrotlPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      decoration: BoxDecoration(
        color: p.cream,
        border: Border.all(color: p.ink, width: 3),
        borderRadius: BorderRadius.circular(14),
        boxShadow: hardShadow(p.ink, dy: 4),
      ),
      child: Column(
        children: [
          Text(
            'No rides yet',
            style: displayStyle(size: 18, color: p.ink, shadowDy: 0).copyWith(shadows: const []),
          ),
          const SizedBox(height: 6),
          Text(
            'Your race history shows up here after your first pit-in. Hit NEW SESSION to ride.',
            textAlign: TextAlign.center,
            style: bodyStyle(size: 12, color: shade(p.ink, 0.35)),
          ),
        ],
      ),
    );
  }
}

/// The live tick / COMMIT stream card (the design's `GLiveExplorer`).
///
/// With no data-feed prop, it synthesises rows on a [Timer.periodic], keeping
/// the latest five. tick rows render in [ThrotlPalette.inkSoft]; the occasional
/// COMMIT row renders in [ThrotlPalette.purple].
class _LiveExplorer extends StatefulWidget {
  const _LiveExplorer();

  @override
  State<_LiveExplorer> createState() => _LiveExplorerState();
}

class _LiveExplorerState extends State<_LiveExplorer> {
  static const _b58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  final Random _rng = Random(42);
  final List<_Tick> _feed = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _emit());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _emit() {
    if (!mounted) return;
    setState(() {
      final commit = _rng.nextDouble() < 0.12;
      final price = 158 + _rng.nextDouble() * 9; // ~ $158–167
      final latency = 28 + _rng.nextInt(22); // 28–49 ms
      _feed.insert(
        0,
        _Tick(
          commit: commit,
          sig: '${_b58sig()}…${_b58sig()}',
          price: '\$${price.toStringAsFixed(2)}',
          latency: '${latency}ms',
        ),
      );
      if (_feed.length > 5) _feed.removeLast();
    });
  }

  String _b58sig() {
    final buffer = StringBuffer();
    for (var i = 0; i < 4; i++) {
      buffer.write(_b58[_rng.nextInt(_b58.length)]);
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ChunkyCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'LIVE · EPHEMERAL ROLLUP',
                style: displayStyle(
                  size: 10,
                  color: p.inkSoft,
                  letterSpacing: 1,
                  shadowDy: 0,
                ).copyWith(shadows: const []),
              ),
              Text(
                '● STREAMING',
                style: displayStyle(
                  size: 10,
                  color: p.greenDeep,
                  letterSpacing: 1,
                  shadowDy: 0,
                ).copyWith(shadows: const []),
              ),
            ],
          ),
          const SizedBox(height: 7),
          if (_feed.isEmpty)
            Text(
              'connecting to the rollup…',
              style: bodyStyle(
                size: 11,
                color: shade(p.ink, 0.4),
                height: 1.2,
              ),
            )
          else
            for (final entry in _feed.asMap().entries)
              Padding(
                padding: EdgeInsets.only(top: entry.key == 0 ? 0 : 4),
                child: Opacity(
                  opacity: 1 - entry.key * 0.17,
                  child: _TickRow(tick: entry.value),
                ),
              ),
        ],
      ),
    );
  }
}

class _TickRow extends StatelessWidget {
  const _TickRow({required this.tick});

  final _Tick tick;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final base = bodyStyle(size: 11, color: p.ink, weight: FontWeight.w800);
    return Row(
      children: [
        Text(
          tick.commit ? 'COMMIT' : 'tick',
          style: base.copyWith(color: tick.commit ? p.purple : p.inkSoft),
        ),
        const SizedBox(width: 9),
        Opacity(opacity: 0.6, child: Text(tick.sig, style: base)),
        const SizedBox(width: 9),
        Text(tick.price, style: base),
        const Spacer(),
        Opacity(opacity: 0.55, child: Text(tick.latency, style: base)),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session});

  final RaceSession session;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final positive = session.win;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: p.cream,
        border: Border.all(color: p.ink, width: 3),
        borderRadius: BorderRadius.circular(14),
        boxShadow: hardShadow(p.ink, dy: 4),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 8,
              decoration: BoxDecoration(
                color: positive ? p.green : p.red,
                border: Border.all(color: p.ink, width: 2),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        _fmtMoney6(session.pnl6),
                        style: displayStyle(
                          size: 15,
                          color: positive ? p.greenDeep : p.redDeep,
                          shadowDy: 0,
                        ).copyWith(shadows: const []),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _fmtWhen(session.tsMs),
                        style: bodyStyle(
                          size: 10,
                          color: p.inkSoft,
                          weight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_fmtThousands(session.ticks)} ticks · peak ${session.peakLev.toStringAsFixed(1)}x',
                    style: bodyStyle(
                      size: 10,
                      color: shade(p.ink, 0.35),
                      weight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: session.live ? const Color(0xFFDCF5E4) : const Color(0xFFE9F0FF),
                  border: Border.all(color: p.ink, width: 2.5),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  session.live ? 'LIVE' : 'PRACTICE',
                  style: bodyStyle(
                    size: 9.5,
                    color: session.live ? p.greenDeep : p.inkSoft,
                    weight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Formats PnL the design way: `+$38.42` / `−$12.07` (U+2212 minus sign).
String _fmtMoney6(int v6) {
  final value = v6 / 1e6;
  final sign = value >= 0 ? '+' : '−';
  return '$sign\$${value.abs().toStringAsFixed(2)}';
}

/// `TODAY 14:08` / `YESTERDAY 09:31` / `JUN 11` from an epoch-millis timestamp.
String _fmtWhen(int tsMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(tsMs);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  final diff = today.difference(day).inDays;
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  if (diff <= 0) return 'TODAY $hh:$mm';
  if (diff == 1) return 'YESTERDAY $hh:$mm';
  const months = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ];
  return '${months[dt.month - 1]} ${dt.day}';
}

/// Inserts thousands separators, e.g. `2031` → `2,031` (no `intl` dependency).
String _fmtThousands(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// One synthesised explorer row.
@immutable
class _Tick {
  const _Tick({
    required this.commit,
    required this.sig,
    required this.price,
    required this.latency,
  });

  final bool commit;
  final String sig;
  final String price;
  final String latency;
}
