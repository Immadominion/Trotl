import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/theme/tokens.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl/src/widgets/chunky.dart';
import 'package:throtl/src/widgets/throtl_logo.dart';

/// Show the connect-wallet sheet. Returns `true` if the user is ready to enter
/// the garage — either connected via MWA, or chose to continue in practice.
Future<bool> showConnectSheet(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0xCC05060F),
    builder: (_) => const _ConnectSheet(),
  );
  return ok ?? false;
}

class _ConnectSheet extends StatefulWidget {
  const _ConnectSheet();

  @override
  State<_ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<_ConnectSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _connect() async {
    final wallet = context.read<WalletController>();
    sfx.confirm();
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await wallet.connect();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = wallet.error ?? 'Connection failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wallet = context.watch<WalletController>();
    final available = wallet.mwaAvailable;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(10),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [p.blueBot, p.blueDeep],
          ),
          border: Border.all(color: p.ink, width: 3),
          borderRadius: BorderRadius.circular(22),
          boxShadow: hardShadow(p.ink, dy: 6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ThrotlLogo(size: 34, color: p.white),
                const SizedBox(width: 10),
                StrokeText(
                  'CONNECT WALLET',
                  strokeColor: p.ink,
                  style: displayStyle(size: 20, color: p.white, letterSpacing: 1),
                ),
                const Spacer(),
                _mainnetBadge(p),
              ],
            ),
            const SizedBox(height: 14),
            // The honest can / can't-do table (PRODUCT §9.2) — bounded-to-fuel truth.
            ChunkyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row(p, true, 'Build transactions for you to sign'),
                  _row(
                    p,
                    true,
                    'Open / resize / close positions with the fuel you commit to a ride',
                  ),
                  _row(p, false, 'Move funds to anyone else — ever'),
                  _row(p, false, "Touch wallet funds you haven't committed as fuel"),
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (!available)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  kIsWeb
                      ? 'No browser wallet detected. Install Phantom, Solflare, or '
                            'Backpack and reload to connect — or ride in practice now.'
                      : 'Wallet connect needs an Android device with a Solana wallet '
                            '(Seed Vault / Phantom / Solflare). You can still ride in practice.',
                  textAlign: TextAlign.center,
                  style: bodyStyle(size: 12, color: const Color(0xCCFFFFFF)),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: bodyStyle(size: 12, color: p.red, weight: FontWeight.w800),
                ),
              ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 3, color: p.yellow),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'CHECK YOUR WALLET…',
                      style: displayStyle(size: 13, color: p.white).copyWith(shadows: const []),
                    ),
                  ],
                ),
              )
            else if (available)
              ChunkyButton(
                label: 'CONNECT WALLET',
                color: p.orange,
                big: true,
                sfxName: 'confirm',
                onTap: _connect,
              ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () {
                sfx.back();
                Navigator.of(context).pop(true);
              },
              child: Center(
                child: Text(
                  available ? 'Skip — ride in practice' : 'Continue in practice',
                  style: bodyStyle(
                    size: 12.5,
                    color: const Color(0xCCFFFFFF),
                    weight: FontWeight.w800,
                  ).copyWith(decoration: TextDecoration.underline),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Static network badge — mainnet is the only network (Flash is mainnet-only).
  Widget _mainnetBadge(ThrotlPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: p.green,
        border: Border.all(color: p.ink, width: 2.5),
        borderRadius: BorderRadius.circular(100),
        boxShadow: hardShadow(p.ink, dy: 2.5),
      ),
      child: Text(
        'MAINNET',
        style: displayStyle(
          size: 10,
          color: p.white,
          letterSpacing: 0.8,
        ).copyWith(shadows: const []),
      ),
    );
  }

  Widget _row(ThrotlPalette p, bool can, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            can ? Icons.check_circle : Icons.cancel,
            size: 16,
            color: can ? p.greenDeep : p.redDeep,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: bodyStyle(size: 12, color: p.ink, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
