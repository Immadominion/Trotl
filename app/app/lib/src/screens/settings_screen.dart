import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/chain/rent_reclaim.dart';
import 'package:throtl/src/screens/connect_sheet.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/util/responsive.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl/src/widgets/chunky.dart';
import 'package:throtl/src/widgets/fund_sheet.dart';
import 'package:throtl/src/widgets/withdraw_sheet.dart';

/// Settings ("garage") — sound toggle + brand theme picker (the design's
/// `GSettingsScreen`). Restyles the whole app live via [ThemeController].
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({required this.onBack, super.key});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final tc = context.watch<ThemeController>();
    final wallet = context.watch<WalletController>();
    final p = tc.palette;
    final banner = Align(
      alignment: Alignment.centerLeft,
      child: BannerPlate(kicker: 'GARAGE', title: 'SETTINGS', color: p.purple),
    );
    final musicCard = _ToggleCard(
      title: 'MUSIC',
      subtitle: 'Race loop + win / loss jingles.',
      on: tc.musicOn,
      onToggle: () {
        final next = !tc.musicOn;
        unawaited(tc.setMusic(on: next));
        unawaited(music.setEnabled(on: next));
        if (next) {
          unawaited(music.startMenuLoop());
        } else {
          sfx.toggle();
        }
      },
    );
    final soundFx = _ToggleCard(
      title: 'SOUND FX',
      subtitle: 'Clicks, coin pops, spin-out skid.',
      on: tc.sfxOn,
      onToggle: () {
        final next = !tc.sfxOn;
        unawaited(tc.setSfx(on: next));
        unawaited(sfx.setEnabled(on: next));
        sfx.toggle();
      },
    );
    final rideToggle = _ToggleCard(
      title: wallet.isConnected ? 'LIVE · MAINNET' : 'PRACTICE',
      subtitle: wallet.isConnected
          ? 'Real funds on mainnet · ${wallet.ownerShort}'
          : 'Fake funds vs the real mainnet market.',
      on: wallet.isConnected,
      onToggle: () {
        sfx.toggle();
        if (wallet.isConnected) {
          unawaited(wallet.disconnect());
        } else {
          unawaited(showConnectSheet(context));
        }
      },
    );
    final themeDropdown = _ThemeDropdown(
      activeKey: tc.palette.key,
      activeLabel: tc.palette.label,
    );
    final credits = ChunkyCard(
      color: const Color(0xFFFFF1D6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(
        'Themes restyle the whole app to a Solana-ecosystem brand. SFX are '
        'CC0 Kenney; music by SoundSurfer & Viacheslav Starostin (Pixabay).',
        style: bodyStyle(
          size: 10.5,
          color: shade(p.ink, 0.2),
          weight: FontWeight.w800,
          height: 1.5,
        ),
      ),
    );

    // Sections: audio + theme = "preferences"; ride mode + funds = "money".
    final audio = <Widget>[musicCard, const SizedBox(height: 10), soundFx];
    final theme = <Widget>[
      _label(p, 'BRAND THEME'),
      themeDropdown,
      const SizedBox(height: 12),
      credits,
    ];
    final money = <Widget>[
      _label(p, 'RIDE MODE'),
      rideToggle,
      const SizedBox(height: 10),
      const _FundsCard(),
      const _ReclaimCard(),
    ];

    return GameScaffold(
      padding: const EdgeInsets.only(bottom: 18),
      bodyScrolls: !context.isWide,
      bottomBar: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ChunkyButton(
              label: 'DONE',
              color: p.orange,
              big: true,
              sfxName: 'back',
              onTap: onBack,
            ),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: context.isWide
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 10),
                  banner,
                  const SizedBox(height: 14),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [...audio, const SizedBox(height: 14), ...theme],
                            ),
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: money,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 10),
                  banner,
                  const SizedBox(height: 12),
                  ...audio,
                  const SizedBox(height: 14),
                  ...money,
                  const SizedBox(height: 14),
                  ...theme,
                ],
              ),
      ),
    );
  }

  Widget _label(ThrotlPalette p, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 10),
      child: Text(
        text,
        style: displayStyle(
          size: 13,
          color: p.white,
          letterSpacing: 1.3,
          shadow: p.ink,
          shadowDy: 1.5,
        ),
      ),
    );
  }
}

/// Real-money funds: your live wallet balance + deposit / cash-out to the Flash
/// basket. Shown when connected — **connected IS real money** (there's no separate
/// toggle; disconnect for practice).
class _FundsCard extends StatefulWidget {
  const _FundsCard();

  @override
  State<_FundsCard> createState() => _FundsCardState();
}

class _FundsCardState extends State<_FundsCard> {
  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wallet = context.watch<WalletController>();
    if (!wallet.isConnected) return const SizedBox.shrink();
    return ChunkyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'FLASH FUNDS · REAL MONEY',
                style: displayStyle(
                  size: 11,
                  color: p.greenDeep,
                  letterSpacing: 1.1,
                ).copyWith(shadows: const []),
              ),
              GestureDetector(
                onTap: () => unawaited(wallet.refreshBalances()),
                child: Icon(Icons.refresh, size: 16, color: p.inkSoft),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Flash fuel · ${wallet.usdcUi.toStringAsFixed(2)} USDC',
            style: bodyStyle(size: 13, color: p.ink, weight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            'Wallet · ${wallet.walletUsdcUi.toStringAsFixed(2)} USDC · ${wallet.solUi.toStringAsFixed(3)} SOL gas',
            style: bodyStyle(size: 11.5, color: shade(p.ink, 0.3), weight: FontWeight.w800),
          ),
          if (wallet.networkError != null) ...[
            const SizedBox(height: 6),
            Text(
              '⚠ ${wallet.networkError}',
              style: bodyStyle(size: 11, color: p.redDeep, weight: FontWeight.w800, height: 1.3),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ChunkyButton(
                  label: 'FUND',
                  color: p.green,
                  sfxName: 'confirm',
                  onTap: () => unawaited(showFundSheet(context)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ChunkyButton(
                  label: 'CASH OUT',
                  color: p.cyan,
                  sfxName: 'back',
                  onTap: () => unawaited(showWithdrawSheet(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            r'Deposit USDC to your self-custodial Flash basket to ride for real (min $11). '
            'Cash out anytime — Throtl never holds your funds.',
            style: bodyStyle(size: 10.5, color: shade(p.ink, 0.4)),
          ),
          const SizedBox(height: 12),
          ChunkyButton(
            label: 'LOG OUT',
            color: p.red,
            sfxName: 'back',
            onTap: () {
              sfx.toggle();
              unawaited(wallet.disconnect());
            },
          ),
        ],
      ),
    );
  }
}

/// Reclaim the rent of rides whose money settled but whose final `close_ride`
/// didn't confirm. Only appears when there's something to reclaim — so the
/// "reclaim later from Settings" promise on the results screen is real.
class _ReclaimCard extends StatefulWidget {
  const _ReclaimCard();

  @override
  State<_ReclaimCard> createState() => _ReclaimCardState();
}

class _ReclaimCardState extends State<_ReclaimCard> {
  List<String> _pending = const [];
  bool _busy = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final list = await RentReclaimStore.list();
    if (mounted) setState(() => _pending = list);
  }

  Future<void> _reclaim(WalletController wallet) async {
    if (!wallet.isConnected) {
      await showConnectSheet(context);
      return;
    }
    setState(() {
      _busy = true;
      _msg = 'Reclaiming…';
    });
    final res = await reclaimRideRent(
      wallet,
      onStep: (s) {
        if (mounted) setState(() => _msg = s);
      },
    );
    if (!mounted) return;
    await _load();
    setState(() {
      _busy = false;
      _msg = res.reclaimed > 0
          ? 'Reclaimed ${res.reclaimed} ride${res.reclaimed == 1 ? '' : 's'}.'
                '${res.remaining > 0 ? ' ${res.remaining} still pending — try again shortly.' : ''}'
          : res.remaining > 0
          ? "Couldn't reclaim yet — the rollup may still be returning the ride. Try again shortly."
          : 'Nothing to reclaim.';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_pending.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    final wallet = context.watch<WalletController>();
    final n = _pending.length;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: ChunkyCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'UNSETTLED · RECLAIM RENT',
              style: displayStyle(
                size: 13,
                color: p.orangeDeep,
                letterSpacing: 0.6,
                shadowDy: 0,
                shadow: const Color(0x00000000),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$n ride${n == 1 ? '' : 's'} settled but the rent-reclaiming close '
              "didn't confirm. Reclaim it back to your wallet.",
              style: bodyStyle(size: 11, color: shade(p.ink, 0.32)),
            ),
            const SizedBox(height: 10),
            ChunkyButton(
              label: _busy ? '…' : 'RECLAIM RENT',
              color: p.orange,
              sfxName: 'confirm',
              onTap: () {
                if (!_busy) unawaited(_reclaim(wallet));
              },
            ),
            if (_msg != null) ...[
              const SizedBox(height: 8),
              Text(_msg!, style: bodyStyle(size: 11, color: shade(p.ink, 0.4))),
            ],
          ],
        ),
      ),
    );
  }
}

/// An audio toggle card (title + subtitle + sliding pill). Used for both the
/// MUSIC and SOUND FX channels, each with its own independent toggle.
class _ToggleCard extends StatelessWidget {
  const _ToggleCard({
    required this.title,
    required this.subtitle,
    required this.on,
    required this.onToggle,
  });

  final String title;
  final String subtitle;
  final bool on;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ChunkyCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: displayStyle(
                    size: 15,
                    color: p.ink,
                    letterSpacing: 0.6,
                    shadowDy: 0,
                    shadow: const Color(0x00000000),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: bodyStyle(size: 11, color: shade(p.ink, 0.32)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _TogglePill(on: on, onTap: onToggle),
        ],
      ),
    );
  }
}

/// The rounded toggle pill (66×34) with a sliding white knob.
class _TogglePill extends StatelessWidget {
  const _TogglePill({required this.on, required this.onTap});

  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 66,
        height: 34,
        decoration: BoxDecoration(
          gradient: on ? candy(p.green, lighten: 0.3, mid: 1) : null,
          color: on ? null : const Color(0xFFC9BEA8),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: p.ink, width: 3),
          boxShadow: hardShadow(p.ink, dy: 3),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 150),
              top: 2,
              left: on ? 32 : 2,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: p.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: p.ink, width: 2.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2-column grid of theme cards, one per [kThemeOrder] key.
/// Collapsible brand-theme picker — shows the active theme; tap to drop open the
/// full grid and pick another. Default collapsed so Settings stays compact.
class _ThemeDropdown extends StatefulWidget {
  const _ThemeDropdown({required this.activeKey, required this.activeLabel});

  final String activeKey;
  final String activeLabel;

  @override
  State<_ThemeDropdown> createState() => _ThemeDropdownState();
}

class _ThemeDropdownState extends State<_ThemeDropdown> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final swatches = [p.orange, p.yellow, p.purple, p.green];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: () {
            sfx.open();
            setState(() => _open = !_open);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: p.cream,
              border: Border.all(color: p.ink, width: 3),
              borderRadius: BorderRadius.circular(16),
              boxShadow: hardShadow(p.ink, dy: 4),
            ),
            child: Row(
              children: [
                for (final c in swatches) ...[
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: p.ink, width: 1.5),
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    widget.activeLabel,
                    style: displayStyle(
                      size: 14,
                      color: p.ink,
                      shadowDy: 0,
                      shadow: const Color(0x00000000),
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.keyboard_arrow_down, color: p.inkSoft),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: _ThemeGrid(activeKey: widget.activeKey),
          ),
          crossFadeState: _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 220),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
    );
  }
}

class _ThemeGrid extends StatelessWidget {
  const _ThemeGrid({required this.activeKey});

  final String activeKey;

  @override
  Widget build(BuildContext context) {
    const cols = 2;
    const gap = 10.0;
    final rows = <Widget>[];
    for (var i = 0; i < kThemeOrder.length; i += cols) {
      final cells = <Widget>[];
      for (var c = 0; c < cols; c++) {
        final idx = i + c;
        if (c > 0) cells.add(const SizedBox(width: gap));
        if (idx < kThemeOrder.length) {
          final key = kThemeOrder[idx];
          cells.add(
            Expanded(
              child: _ThemeCard(themeKey: key, active: key == activeKey),
            ),
          );
        } else {
          cells.add(const Expanded(child: SizedBox.shrink()));
        }
      }
      if (rows.isNotEmpty) rows.add(const SizedBox(height: gap));
      rows.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells));
    }
    return Column(children: rows);
  }
}

/// A single theme swatch card: sky-gradient band + cream footer.
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({required this.themeKey, required this.active});

  final String themeKey;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = kThemes[themeKey]!;
    final swatches = [theme.orange, theme.yellow, theme.purple, theme.green];
    return GestureDetector(
      onTap: () {
        unawaited(context.read<ThemeController>().setTheme(themeKey));
        sfx.select();
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: p.ink, width: 3),
          boxShadow: [
            if (active) BoxShadow(color: p.yellow, spreadRadius: 3),
            BoxShadow(color: p.ink, offset: const Offset(0, 4)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [theme.skyTop, theme.skyBot],
                  ),
                ),
                child: Row(
                  children: [
                    for (final c in swatches) ...[
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: c,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: p.ink, width: 1.5),
                        ),
                      ),
                      if (c != swatches.last) const SizedBox(width: 5),
                    ],
                  ],
                ),
              ),
              Container(
                color: p.cream,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Row(
                  children: [
                    Text(
                      theme.label,
                      style: displayStyle(
                        size: 12,
                        color: p.ink,
                        shadowDy: 0,
                        shadow: const Color(0x00000000),
                      ),
                    ),
                    if (active) ...[
                      const Spacer(),
                      Text(
                        '● ON',
                        style: displayStyle(
                          size: 10,
                          color: p.greenDeep,
                          shadowDy: 0,
                          shadow: const Color(0x00000000),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
