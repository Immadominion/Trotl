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

/// Min deposit to ride for real — Flash needs > $10 collateral after fees, so $11
/// is the practical floor (research/flash.md §6).
const int _minFund6 = 11000000;

/// Open the "add fuel" sheet — deposit USDC from the wallet into the Flash basket,
/// ANY amount from $11 up to the wallet's USDC balance. Replaces the old fixed-$11
/// flow that was buried in Settings.
Future<void> showFundSheet(BuildContext context) {
  final wallet = context.read<WalletController>();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0x00000000),
    isScrollControlled: true,
    builder: (_) => _FundSheet(wallet: wallet),
  );
}

class _FundSheet extends StatefulWidget {
  const _FundSheet({required this.wallet});

  final WalletController wallet;

  @override
  State<_FundSheet> createState() => _FundSheetState();
}

class _FundSheetState extends State<_FundSheet> {
  final TextEditingController _custom = TextEditingController();
  int? _available; // wallet USDC raw, null while loading
  int _amount6 = _minFund6;
  bool _busy = false;
  bool _done = false;
  String? _progress;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final a = await widget.wallet.readWalletUsdc6();
    if (!mounted) return;
    setState(() {
      _available = a;
      _amount6 = a >= _minFund6 ? _minFund6 : a;
    });
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

  Future<void> _fund() async {
    final api = FlashApi();
    final base = RpcClient(widget.wallet.network.baseRpc);
    setState(() {
      _busy = true;
      _progress = 'starting…';
    });
    try {
      await flashDeposit(
        widget.wallet,
        api,
        base,
        _amount6,
        onStep: (s) {
          if (mounted) setState(() => _progress = s);
        },
      );
      // The deposit just confirmed on-chain, but the ledger read can lag the RPC
      // by a few seconds — nudge the balance a few times and tell the player.
      _nudgeBalance();
      if (mounted) {
        setState(() {
          _done = true;
          _progress = 'Funded ✓ — your fuel updates in a few seconds.';
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _progress = 'Fund failed: $e');
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The ledger read can trail the deposit confirmation — re-read a few times.
  void _nudgeBalance() {
    unawaited(widget.wallet.refreshBalances());
    Future<void>.delayed(const Duration(seconds: 3), () {
      unawaited(widget.wallet.refreshBalances());
    });
    Future<void>.delayed(const Duration(seconds: 8), () {
      unawaited(widget.wallet.refreshBalances());
    });
  }

  String _amountLabel() {
    final ui = _amount6 / 1e6;
    return ui == ui.roundToDouble() ? ui.toStringAsFixed(0) : ui.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final avail = _available;
    final canFund = avail != null && avail >= _minFund6;
    final valid = avail != null && _amount6 >= _minFund6 && _amount6 <= avail;
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
            BannerPlate(kicker: 'FUEL UP · REAL MONEY', title: 'ADD USDC', color: p.green),
            const SizedBox(height: 12),
            Text(
              avail == null
                  ? 'Reading your wallet…'
                  : 'Wallet: ${(avail / 1e6).toStringAsFixed(2)} USDC available to deposit',
              style: bodyStyle(size: 12.5, color: shade(p.ink, 0.2), weight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            if (avail != null && !canFund)
              _topUp(p)
            else ...[
              _presets(p, avail ?? 0),
              const SizedBox(height: 12),
              _customField(p),
              const SizedBox(height: 6),
              Text(
                'Min \$11 · Max \$${((avail ?? 0) / 1e6).toStringAsFixed(2)}',
                style: bodyStyle(size: 10.5, color: shade(p.ink, 0.45)),
              ),
              const SizedBox(height: 14),
              if (_progress != null) ...[
                Text(
                  _progress!,
                  style: bodyStyle(size: 11.5, color: shade(p.ink, 0.4)),
                ),
                const SizedBox(height: 10),
              ],
              ChunkyButton(
                label: _done
                    ? 'DONE ✓'
                    : (_busy
                          ? '…'
                          : r'FUND $'
                                '${_amountLabel()}'),
                color: (valid || _done) ? p.green : p.inkSoft,
                big: true,
                sfxName: 'confirm',
                onTap: () {
                  if (_done) {
                    Navigator.of(context).pop();
                    return;
                  }
                  if (!_busy && valid) unawaited(_fund());
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

  Widget _presets(ThrotlPalette p, int max) {
    const opts = <(String, int)>[(r'$11', 11000000), (r'$25', 25000000), (r'$50', 50000000)];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (label, amt) in opts)
          if (amt <= max) _chip(p, label, amt, selected: _amount6 == amt),
        if (max >= _minFund6) _chip(p, 'MAX', max, selected: _amount6 == max),
      ],
    );
  }

  Widget _chip(ThrotlPalette p, String label, int amt6, {required bool selected}) {
    return GestureDetector(
      onTap: () => _pick(amt6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          gradient: selected ? candy(p.green) : null,
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
            r'Custom  $',
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

  Widget _topUp(ThrotlPalette p) {
    final owner = widget.wallet.owner ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          r'You need at least $11 USDC in your wallet to fuel up. Send USDC (the SPL '
          'token) on Solana mainnet to your address below — plus a little SOL for gas '
          '(~0.02) — then tap REFRESH.',
          style: bodyStyle(size: 12.5, color: shade(p.ink, 0.2), height: 1.5),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () {
            sfx.confirm();
            unawaited(Clipboard.setData(ClipboardData(text: owner)));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Address copied'), duration: Duration(seconds: 1)),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: p.white,
              border: Border.all(color: p.ink, width: 3),
              borderRadius: BorderRadius.circular(14),
              boxShadow: hardShadow(p.ink, dy: 3),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    owner.isEmpty ? '—' : owner,
                    style: bodyStyle(size: 12, color: p.ink, weight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 10),
                Icon(Icons.copy, size: 18, color: p.inkSoft),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        ChunkyButton(
          label: _busy ? '…' : 'REFRESH',
          color: p.green,
          big: true,
          sfxName: 'confirm',
          onTap: () {
            setState(() => _busy = true);
            unawaited(
              _load().whenComplete(() {
                if (mounted) setState(() => _busy = false);
              }),
            );
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
    );
  }
}
