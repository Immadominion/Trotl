import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/chain/markets.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl/src/widgets/balance_pill.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// Min SOL (lamports) a connected wallet needs for a ride's gas (init+delegate
/// L1 tx fees + RideSession rent + ER/Flash session fees — comfortably < 0.05).
const int _gasFloorLamports = 30000000; // 0.03 SOL

/// 02 · Starting Grid — pick the market, fuel + downforce, then slide to arm.
/// When a wallet is connected the fuel ladder is REAL (round numbers scaled to
/// your USDC), each market enforces Flash's minimum (sub-min stakes go inactive),
/// and arming is gated on having a valid stake + enough SOL for gas.
class GridScreen extends StatefulWidget {
  const GridScreen({
    required this.maxLevBps,
    required this.onArm,
    required this.onBack,
    super.key,
  });

  final int maxLevBps;

  /// Called with the chosen collateral (usd6) + marketId when the user arms.
  final void Function(int fuel6, int marketId) onArm;

  /// Back to the garage (Home).
  final VoidCallback onBack;

  @override
  State<GridScreen> createState() => _GridScreenState();
}

class _GridScreenState extends State<GridScreen> {
  // Practice stakes (no wallet) — fixed demo ladder.
  static const _demoFuels = <(String, int)>[
    (r'$100', 100 * 1000000),
    (r'$250', 250 * 1000000),
    (r'$500', 500 * 1000000),
    ('MAX', 1204200000),
  ];

  final int _marketId = 0; // SOL — the only live market
  int _fuelIdx = 1;
  bool _customOn = false;
  int? _customFuel6;
  final TextEditingController _customCtrl = TextEditingController();

  Market get _market => Market.byId(_marketId);

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  List<(String, int)> _fuels(WalletController w) {
    if (!w.isConnected || w.usdc6 <= 0) return _demoFuels;
    final ladder = fuelLadder(w.usdc6);
    return ladder.isEmpty ? _demoFuels : ladder;
  }

  int? _parseUsd6(String s) {
    final v = double.tryParse(s.trim());
    if (v == null || v <= 0) return null;
    return (v * 1e6).round();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wallet = context.watch<WalletController>();
    final connected = wallet.isConnected && wallet.usdc6 > 0;
    final min6 = _market.minCollateralUsd6;
    final fuels = _fuels(wallet);

    bool enabled(int v6) => !connected || (v6 >= min6 && v6 <= wallet.usdc6);

    // Effective ladder index: keep the user's pick if valid, else the first valid one.
    var effIdx = _fuelIdx.clamp(0, fuels.length - 1);
    if (connected && !_customOn && !enabled(fuels[effIdx].$2)) {
      final firstOk = fuels.indexWhere((f) => enabled(f.$2));
      if (firstOk >= 0) effIdx = firstOk;
    }

    final selFuel = (_customOn && _customFuel6 != null) ? _customFuel6! : fuels[effIdx].$2;
    final lowGas = wallet.isConnected && wallet.solLamports < _gasFloorLamports;
    final overBalance = connected && selFuel > wallet.usdc6;
    final belowMin = connected && selFuel < min6;
    final canArm = _market.live && selFuel > 0 && !belowMin && !overBalance && !lowGas;

    return GameScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _backButton(p),
                  const SizedBox(width: 10),
                  const BannerPlate(
                    kicker: 'STARTING GRID',
                    title: 'ARM SESSION',
                    color: Color(0xFFA06CF8),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: BalancePill(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _fuelCard(p, wallet, fuels, effIdx, selFuel, connected, min6, belowMin, overBalance),
          if (lowGas) ...[const SizedBox(height: 11), ChunkyCard(child: _gasWarning(p, wallet))],
          const SizedBox(height: 11),
          _downforceCard(p),
          const SizedBox(height: 11),
          _sessionKeyCard(p),
          const Spacer(),
          _SlideToArm(
            enabled: canArm,
            onArm: () => widget.onArm(selFuel, _marketId),
          ),
        ],
      ),
    );
  }

  // Back to the garage (Home).
  Widget _backButton(ThrotlPalette p) {
    return GestureDetector(
      onTap: () {
        sfx.back();
        widget.onBack();
      },
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: const Color(0x800D163A),
          border: Border.all(color: p.ink, width: 3),
          borderRadius: BorderRadius.circular(12),
          boxShadow: hardShadow(p.ink, dy: 3),
        ),
        child: Icon(Icons.arrow_back, color: p.white, size: 22),
      ),
    );
  }

  // ── fuel: round ladder scaled to balance + per-market min + custom ──────────
  Widget _fuelCard(
    ThrotlPalette p,
    WalletController wallet,
    List<(String, int)> fuels,
    int effIdx,
    int selFuel,
    bool connected,
    int min6,
    bool belowMin,
    bool overBalance,
  ) {
    bool enabled(int v6) => !connected || (v6 >= min6 && v6 <= wallet.usdc6);
    final (hint, hintColor) = overBalance
        ? ("That's more than your USDC balance.", p.redDeep)
        : belowMin
        ? (
            "Below ${_market.symbol}'s ${_market.minLabel} minimum — pick a larger stake or add USDC.",
            p.redDeep,
          )
        : connected
        ? (
            'Deposited to a per-ride Flash basket — bounds your risk. It never leaves your '
                'custody. Min ${_market.minLabel}.',
            shade(p.ink, 0.35),
          )
        : ('Your stake for this session. It never leaves your custody.', shade(p.ink, 0.35));

    return ChunkyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardHead(
            p,
            'FUEL · COLLATERAL',
            connected ? 'USDC ${wallet.usdcUi.toStringAsFixed(2)}' : 'PRACTICE · 1,204.20',
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < fuels.length; i++) ...[
                Expanded(
                  child: _fuelChip(p, fuels[i].$1, i, effIdx, enabled(fuels[i].$2) && !_customOn),
                ),
                if (i < fuels.length - 1) const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 8),
          _customRow(p),
          const SizedBox(height: 9),
          Text(hint, style: bodyStyle(size: 11, color: hintColor)),
        ],
      ),
    );
  }

  Widget _fuelChip(ThrotlPalette p, String label, int index, int effIdx, bool enabled) {
    final on = effIdx == index && !_customOn;
    return GestureDetector(
      onTap: enabled
          ? () {
              sfx.select();
              setState(() {
                _fuelIdx = index;
                _customOn = false;
              });
            }
          : null,
      child: Opacity(
        opacity: enabled || on ? 1 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: on ? candy(p.green) : null,
            color: on ? null : p.white,
            border: Border.all(color: p.ink, width: 3),
            borderRadius: BorderRadius.circular(10),
            boxShadow: hardShadow(p.ink, dy: on ? 4 : 3),
          ),
          child: Text(
            label,
            style: displayStyle(
              size: 14,
              color: on ? p.white : p.inkSoft,
            ).copyWith(shadows: const []),
          ),
        ),
      ),
    );
  }

  Widget _customRow(ThrotlPalette p) {
    if (!_customOn) {
      return GestureDetector(
        onTap: () {
          sfx.select();
          setState(() => _customOn = true);
        },
        child: Row(
          children: [
            Icon(Icons.edit, size: 14, color: p.inkSoft),
            const SizedBox(width: 6),
            Text(
              'Custom amount',
              style: displayStyle(size: 11, color: p.inkSoft).copyWith(shadows: const []),
            ),
          ],
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              gradient: candy(p.green),
              border: Border.all(color: p.ink, width: 3),
              borderRadius: BorderRadius.circular(10),
              boxShadow: hardShadow(p.ink, dy: 4),
            ),
            child: Row(
              children: [
                Text(
                  r'$',
                  style: displayStyle(size: 16, color: p.white).copyWith(shadows: const []),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: _customCtrl,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9.]'))],
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      hintText: '0.00',
                      hintStyle: bodyStyle(size: 16, color: const Color(0x80FFFFFF)),
                    ),
                    style: displayStyle(size: 16, color: p.white).copyWith(shadows: const []),
                    onChanged: (s) => setState(() => _customFuel6 = _parseUsd6(s)),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () {
            sfx.back();
            setState(() {
              _customOn = false;
              _customFuel6 = null;
              _customCtrl.clear();
            });
          },
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: p.white,
              border: Border.all(color: p.ink, width: 3),
              borderRadius: BorderRadius.circular(10),
              boxShadow: hardShadow(p.ink, dy: 3),
            ),
            child: Icon(Icons.close, size: 16, color: p.inkSoft),
          ),
        ),
      ],
    );
  }

  // ── downforce (unchanged content) ───────────────────────────────────────────
  Widget _downforceCard(ThrotlPalette p) {
    final maxLev = (widget.maxLevBps / 10000).toStringAsFixed(0);
    return ChunkyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                'DOWNFORCE · MAX LEVERAGE',
                style: displayStyle(
                  size: 11,
                  color: p.inkSoft,
                  letterSpacing: 1.1,
                ).copyWith(shadows: const []),
              ),
              Text(
                '$maxLev×',
                style: displayStyle(size: 22, color: p.orangeDeep).copyWith(shadows: const []),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < 20; i++) ...[
                Expanded(
                  child: Container(
                    height: 16,
                    decoration: BoxDecoration(
                      color: i < (widget.maxLevBps / 100000) * 20
                          ? p.orange
                          : const Color(0xFFEFE3CB),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(
                        color: i < (widget.maxLevBps / 100000) * 20
                            ? p.ink
                            : const Color(0xFFD9CCB2),
                        width: 2,
                      ),
                    ),
                  ),
                ),
                if (i < 19) const SizedBox(width: 3),
              ],
            ],
          ),
          const SizedBox(height: 9),
          Text(
            'Full throttle deflection = $maxLev×. Center detent = flat.',
            style: bodyStyle(size: 11, color: shade(p.ink, 0.35)),
          ),
        ],
      ),
    );
  }

  // ── session key (unchanged content) ─────────────────────────────────────────
  Widget _sessionKeyCard(ThrotlPalette p) {
    return ChunkyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'SESSION KEY · GASLESS 30 MIN',
                style: displayStyle(
                  size: 11,
                  color: p.greenDeep,
                  letterSpacing: 1.1,
                ).copyWith(shadows: const []),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                decoration: BoxDecoration(
                  color: p.green,
                  border: Border.all(color: p.ink, width: 2),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  'READY',
                  style: displayStyle(size: 9, color: p.white).copyWith(shadows: const []),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            'A scoped key streams your ticks to the ephemeral rollup — your '
            'thumb never signs a prompt. Settlement on Flash stays '
            'self-custodial.',
            style: bodyStyle(size: 11.5, color: shade(p.ink, 0.3)),
          ),
          const SizedBox(height: 9),
          Container(
            padding: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: p.creamDim, width: 2)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final s in ['GRIP ±250 BPS', 'TICK 30–50 MS', '${_market.symbol} SPEEDWAY'])
                  Text(
                    s,
                    style: displayStyle(
                      size: 10.5,
                      color: p.inkSoft,
                    ).copyWith(shadows: const []),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _gasWarning(ThrotlPalette p, WalletController wallet) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: p.red.withValues(alpha: 0.14),
        border: Border.all(color: p.redDeep, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.local_gas_station, size: 16, color: p.redDeep),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Low SOL (${wallet.solUi.toStringAsFixed(3)}). A ride needs ~0.05 SOL '
              'for gas — top up to arm.',
              style: bodyStyle(size: 11, color: p.redDeep, weight: FontWeight.w800, height: 1.25),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardHead(ThrotlPalette p, String left, String right) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          left,
          style: displayStyle(
            size: 11,
            color: p.inkSoft,
            letterSpacing: 1.1,
          ).copyWith(shadows: const []),
        ),
        Text(
          right,
          style: displayStyle(
            size: 11,
            color: p.inkSoft,
            letterSpacing: 1.1,
          ).copyWith(shadows: const []),
        ),
      ],
    );
  }
}

/// The one deliberate friction point: drag the knob past 75% to arm.
class _SlideToArm extends StatefulWidget {
  const _SlideToArm({required this.onArm, this.enabled = true});
  final VoidCallback onArm;
  final bool enabled;

  @override
  State<_SlideToArm> createState() => _SlideToArmState();
}

class _SlideToArmState extends State<_SlideToArm> {
  double _f = 0;
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final locked = _armed || !widget.enabled;
    return Opacity(
      opacity: widget.enabled ? 1 : 0.5,
      child: LayoutBuilder(
        builder: (context, c) {
          const knob = 52.0;
          final maxX = (c.maxWidth - knob - 10).clamp(40.0, double.infinity);
          return GestureDetector(
            onHorizontalDragUpdate: locked
                ? null
                : (d) => setState(
                    () => _f = (_f + d.delta.dx / maxX).clamp(0.0, 1.0),
                  ),
            onHorizontalDragEnd: locked
                ? null
                : (_) {
                    if (_f > 0.75) {
                      setState(() {
                        _f = 1;
                        _armed = true;
                      });
                      sfx.confirm();
                      Timer(const Duration(milliseconds: 180), widget.onArm);
                    } else {
                      setState(() => _f = 0);
                    }
                  },
            child: Container(
              height: 60,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    p.orange.withValues(alpha: _f > 0.7 ? 0.6 : 0.27),
                    const Color(0x660D163A),
                  ],
                  stops: [0, (0.65 + _f * 0.35).clamp(0.0, 1.0)],
                ),
                borderRadius: BorderRadius.circular(100),
                border: Border.all(color: p.ink, width: 3),
                boxShadow: hardShadow(p.ink, dy: 4),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 34),
                    child: Opacity(
                      opacity: 1 - _f * 0.8,
                      child: Text(
                        widget.enabled ? 'SLIDE TO ARM' : 'CANT ARM YET',
                        style:
                            displayStyle(
                              size: 15,
                              color: p.white,
                              letterSpacing: 2.7,
                            ).copyWith(
                              shadows: [
                                Shadow(color: p.ink, offset: const Offset(0, 2)),
                              ],
                            ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 5 + _f * maxX,
                    top: 4,
                    bottom: 4,
                    child: Container(
                      width: knob,
                      decoration: BoxDecoration(
                        gradient: candy(p.orange),
                        border: Border.all(color: p.ink, width: 3),
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: Center(
                        child: Text(
                          '→',
                          style: displayStyle(size: 20, color: p.white).copyWith(shadows: const []),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
