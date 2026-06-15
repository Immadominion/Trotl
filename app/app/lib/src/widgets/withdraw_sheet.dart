import 'dart:async';

import 'package:flash_client/flash_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:solana/solana.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/wallet/flash_funding.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// Open the "cash out" sheet — withdraw USDC from the Flash basket back to the
/// wallet, ALL of it or a partial amount. Pairs with the fund sheet.
Future<void> showWithdrawSheet(BuildContext context) {
  final wallet = context.read<WalletController>();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0x00000000),
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 540),
    builder: (_) => _WithdrawSheet(wallet: wallet),
  );
}

class _WithdrawSheet extends StatefulWidget {
  const _WithdrawSheet({required this.wallet});

  final WalletController wallet;

  @override
  State<_WithdrawSheet> createState() => _WithdrawSheetState();
}

class _WithdrawSheetState extends State<_WithdrawSheet> {
  final TextEditingController _custom = TextEditingController();
  int _amount6 = 0;
  bool _busy = false;
  bool _done = false;
  String? _progress;

  int get _fuel6 => widget.wallet.usdc6;

  @override
  void initState() {
    super.initState();
    _amount6 = _fuel6; // default: cash out everything
    _custom.text = (_amount6 / 1e6).toStringAsFixed(2);
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _pick(int amt6) {
    sfx.click();
    setState(() {
      _amount6 = amt6;
      _custom.text = (amt6 / 1e6).toStringAsFixed(2);
    });
  }

  void _onCustom(String s) {
    final v = double.tryParse(s.replaceAll(',', '').trim());
    if (v == null) return;
    setState(() => _amount6 = (v * 1e6).round());
  }

  Future<void> _withdraw() async {
    final api = FlashApi();
    final base = RpcClient(widget.wallet.network.baseRpc);
    setState(() {
      _busy = true;
      _progress = 'starting…';
    });
    try {
      await flashWithdraw(
        widget.wallet,
        api,
        base,
        amount6: _amount6,
        onStep: (s) {
          if (mounted) setState(() => _progress = s);
        },
      );
      unawaited(widget.wallet.refreshBalances());
      if (mounted) {
        setState(() {
          _done = true;
          _progress = 'Cashed out — funds are in your wallet.';
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _progress = 'Cash out failed: $e');
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  String _amountLabel() {
    final ui = _amount6 / 1e6;
    return ui == ui.roundToDouble() ? ui.toStringAsFixed(0) : ui.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fuel = _fuel6;
    final valid = _amount6 > 0 && _amount6 <= fuel;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        margin: const EdgeInsets.all(14),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: p.paper,
          border: Border.all(color: p.ink, width: 3),
          borderRadius: BorderRadius.circular(20),
          boxShadow: hardShadow(p.ink, dy: 6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BannerPlate(kicker: 'BACK TO YOUR WALLET', title: 'CASH OUT', color: p.cyan),
            const SizedBox(height: 12),
            Text(
              'Flash fuel: ${(fuel / 1e6).toStringAsFixed(2)} USDC',
              style: bodyStyle(size: 12.5, color: shade(p.ink, 0.2), weight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            if (fuel <= 0)
              Text(
                'No Flash fuel to cash out yet.',
                style: bodyStyle(size: 12.5, color: shade(p.ink, 0.4)),
              )
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip(p, 'HALF', (fuel / 2).round()),
                  _chip(p, 'MAX', fuel),
                ],
              ),
              const SizedBox(height: 12),
              _customField(p),
              const SizedBox(height: 6),
              Text(
                'Up to \$${(fuel / 1e6).toStringAsFixed(2)} · 1–2 wallet confirmations',
                style: bodyStyle(size: 10.5, color: shade(p.ink, 0.45)),
              ),
              const SizedBox(height: 14),
              if (_progress != null) ...[
                Text(_progress!, style: bodyStyle(size: 11.5, color: shade(p.ink, 0.4))),
                const SizedBox(height: 10),
              ],
              ChunkyButton(
                label: _done
                    ? 'DONE ✓'
                    : (_busy
                          ? '…'
                          : r'CASH OUT $'
                                '${_amountLabel()}'),
                color: (valid || _done) ? p.cyan : p.inkSoft,
                big: true,
                sfxName: 'confirm',
                onTap: () {
                  if (_done) {
                    Navigator.of(context).pop();
                    return;
                  }
                  if (!_busy && valid) unawaited(_withdraw());
                },
              ),
              const SizedBox(height: 8),
              ChunkyButton(
                label: 'CLOSE',
                color: p.purple,
                sfxName: 'back',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(ThrotlPalette p, String label, int amt6) {
    final selected = _amount6 == amt6;
    return GestureDetector(
      onTap: () => _pick(amt6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          gradient: selected ? candy(p.cyan) : null,
          color: selected ? null : p.white,
          border: Border.all(color: p.ink, width: 2.5),
          borderRadius: BorderRadius.circular(12),
          boxShadow: hardShadow(p.ink, dy: 2),
        ),
        child: Text(
          label,
          style: displayStyle(
            size: 14,
            color: selected ? p.white : p.ink,
          ).copyWith(shadows: const []),
        ),
      ),
    );
  }

  Widget _customField(ThrotlPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(
        color: p.white,
        border: Border.all(color: p.ink, width: 2.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            r'Amount  $',
            style: bodyStyle(size: 13, color: p.inkSoft, weight: FontWeight.w800),
          ),
          Expanded(
            child: TextField(
              controller: _custom,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9.]'))],
              style: bodyStyle(size: 15, color: p.ink, weight: FontWeight.w800),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: '0.00',
              ),
              onChanged: _onCustom,
            ),
          ),
        ],
      ),
    );
  }
}
