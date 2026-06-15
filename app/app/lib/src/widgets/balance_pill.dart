import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/screens/connect_sheet.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl/src/widgets/chunky.dart';

/// The USDC coin pill, made reactive: it rebuilds on every balance change, shows
/// a spinner while a read is in flight, and a TAP re-reads the balance (the
/// "reload" the cockpit was missing) — opening the funding sheet when you're
/// connected but empty. Disconnected, it opens the connect sheet.
class BalancePill extends StatelessWidget {
  const BalancePill({this.onHistory, super.key});

  /// Tapping the pill (when connected) opens the player's race history.
  final VoidCallback? onHistory;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wallet = context.watch<WalletController>();
    return GestureDetector(
      onTap: () {
        if (!wallet.isConnected) {
          unawaited(showConnectSheet(context));
          return;
        }
        sfx.click();
        onHistory?.call();
      },
      onLongPress: wallet.isConnected
          ? () {
              sfx.click();
              unawaited(wallet.refreshBalances());
            }
          : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          StatPill(
            icon: const CoinIcon(size: 18),
            value: wallet.isConnected ? wallet.usdcUi.toStringAsFixed(2) : '—',
            color: p.yellow,
          ),
          if (wallet.refreshing)
            Positioned(
              right: -2,
              top: -2,
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: p.white),
              ),
            ),
        ],
      ),
    );
  }
}

/// "How do I fund?" — the cockpit never explained it. This sheet shows the
/// connected address (copyable) and tells you to send USDC (SPL) on Solana
/// mainnet, then re-reads the balance.
Future<void> showFundingSheet(BuildContext context) {
  final wallet = context.read<WalletController>();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0x00000000),
    isScrollControlled: true,
    builder: (_) => _FundingSheet(wallet: wallet),
  );
}

class _FundingSheet extends StatelessWidget {
  const _FundingSheet({required this.wallet});

  final WalletController wallet;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final owner = wallet.owner ?? '';
    return Container(
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
          BannerPlate(kicker: 'FUEL UP', title: 'ADD USDC', color: p.green),
          const SizedBox(height: 14),
          Text(
            'Send USDC (the SPL token) on Solana mainnet to your wallet address '
            'below — from an exchange or another wallet. SOL too (you need ~0.05 '
            'for gas). It shows up here within a few seconds of confirming.',
            style: bodyStyle(size: 12.5, color: shade(p.ink, 0.2), height: 1.5),
          ),
          const SizedBox(height: 14),
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
            label: 'REFRESH BALANCE',
            color: p.green,
            big: true,
            sfxName: 'confirm',
            onTap: () {
              unawaited(wallet.refreshBalances());
              Navigator.of(context).pop();
            },
          ),
          const SizedBox(height: 8),
          ChunkyButton(
            label: 'DONE',
            color: p.purple,
            sfxName: 'back',
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
