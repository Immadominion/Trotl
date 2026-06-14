// M0.3 spike — the REAL Flash Trade v2 lifecycle on mainnet with a tiny burner position.
// Flash has no devnet, so this live round-trip is the only way to validate the integration and
// capture fixtures. Staged and phase-gated; run `read` first (zero funds), inspect, then proceed.
//
//   dart run flash_client:flash_lifecycle read       # health/tokens/price/preview + sign (no submit)
//   dart run flash_client:flash_lifecycle setup      # ledger → basket → delegate → deposit 11 USDC
//   dart run flash_client:flash_lifecycle trade      # open 11 USDC @2x LONG SOL (owner-signed, ER)
//   dart run flash_client:flash_lifecycle close       # full close
//   dart run flash_client:flash_lifecycle withdraw    # request → execute withdrawal
//
// Every request/response is written to fixtures/flash/<step>.json for offline tests (no funds).
import 'dart:convert';
import 'dart:io';

import 'package:flash_client/flash_client.dart';

const _usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

String _env(String k, String dflt) => Platform.environment[k] ?? dflt;

final String _keypairPath = _env(
  'FLASH_SPIKE_KEYPAIR',
  '/Users/mac/Documents/codes/bounties/mageekbloc/tools/spikes/.keys/flash-spike-keypair.json',
);
final String _fixturesDir = _env(
  'FLASH_FIXTURES',
  '/Users/mac/Documents/codes/bounties/mageekbloc/fixtures/flash',
);
final String _baseRpc = _env('BASE_RPC', 'https://betsey-5efi0d-fast-devnet.helius-rpc.com');
final String _erRpc = _env('ER_RPC', 'https://flash.magicblock.xyz');

void _save(String name, Object data) {
  Directory(_fixturesDir).createSync(recursive: true);
  File(
    '$_fixturesDir/$name.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  stdout.writeln('  ↳ fixtures/flash/$name.json');
}

void _log(String s) => stdout.writeln(s);

Future<void> main(List<String> args) async {
  final phase = args.isEmpty ? 'read' : args.first;
  final api = FlashApi();
  final signer = await WalletSigner.fromCliKeypairFile(_keypairPath);
  final base = RpcSubmitter(_baseRpc);
  final er = RpcSubmitter(_erRpc);
  final owner = signer.address;
  _log('owner (burner): $owner');
  _log('phase: $phase  (base=$_baseRpc  er=$_erRpc)\n');

  try {
    switch (phase) {
      case 'read':
        await _read(api, signer);
      case 'setup':
        await _setup(api, signer, base);
      case 'trade':
        await _trade(api, signer, er, owner);
      case 'close':
        await _close(api, signer, er, owner);
      case 'withdraw':
        await _withdraw(api, signer, base, owner);
      case 'execute':
        await _executeOnly(api, signer, base, owner);
      default:
        _log('unknown phase "$phase"');
        exitCode = 2;
    }
  } on FlashError catch (e) {
    _log('\nFLASH ERROR: $e');
    exitCode = 1;
  } finally {
    api.close();
  }
}

Future<void> _read(FlashApi api, WalletSigner signer) async {
  _log('1) health');
  final health = await api.health();
  _log('   program=${health['program']} markets=${(health['accounts'] as Map?)?['markets']}');
  _save('health', health);

  _log('2) SOL price (Pyth Lazer)');
  final price = await api.price('SOL');
  _log('   ${price['priceUi'] ?? price['price']}  session=${price['marketSession']}');
  _save('price_sol', price);

  _log('3) open-position PREVIEW (11 USDC @2x LONG SOL, no owner ⇒ quote)');
  final pv = await api.previewOpen(
    inputTokenSymbol: 'USDC',
    outputTokenSymbol: 'SOL',
    inputAmountUi: '11',
    leverage: 2,
    tradeType: 'LONG',
  );
  _log(
    '   entry=${pv.newEntryPrice} liq=${pv.newLiquidationPrice} '
    'fee=${pv.entryFee} pay=${pv.youPayUsdUi} recv=${pv.youRecieveUsdUi}',
  );
  _save('preview_open', pv.raw);

  _log('4) build init-deposit-ledger + SIGN (NOT submitted — validates the signer end-to-end)');
  final built = await api.initDepositLedger(signer.address);
  final signed = await signer.signBase64(built.transactionBase64);
  _log(
    '   unsigned len=${built.transactionBase64.length}  signed len=${signed.length}  ✓ signer OK',
  );
  _save('init_ledger_built', {'unsigned': built.transactionBase64, 'signed': signed});

  _log('\nREAD phase OK — client + signer validated against the live API with zero funds.');
}

Future<String> _step(
  String name,
  Future<BuiltTx> Function() build,
  WalletSigner signer,
  RpcSubmitter rpc, {
  bool skipPreflight = false,
}) async {
  _log('• $name: build');
  final built = await build();
  _save('${name}_unsigned', {'transactionBase64': built.transactionBase64});
  final signed = await signer.signBase64(built.transactionBase64);
  _log('• $name: submit (skipPreflight=$skipPreflight)');
  final sig = await rpc.submit(signed, skipPreflight: skipPreflight);
  _log('  sig=$sig — confirming…');
  await rpc.confirm(sig);
  _log('  ✓ confirmed');
  _save('${name}_result', {'signature': sig});
  return sig;
}

Future<void> _setup(FlashApi api, WalletSigner signer, RpcSubmitter base) async {
  // Strict lifecycle order (the API does NOT enforce it; the program does).
  await _step('init_deposit_ledger', () => api.initDepositLedger(signer.address), signer, base);
  await _step('init_basket', () => api.initBasket(signer.address), signer, base);
  await _step(
    'delegate_basket',
    () => api.delegateBasket(owner: signer.address, payer: signer.address),
    signer,
    base,
  );
  await _step(
    'deposit_direct',
    () => api.depositDirect(owner: signer.address, tokenMint: _usdcMint, amountUi: '11'),
    signer,
    base,
  );
  _log('\nSETUP OK — 11 USDC deposited into the delegated basket.');
}

Future<void> _trade(FlashApi api, WalletSigner signer, RpcSubmitter er, String owner) async {
  await _step(
    'open_position',
    () => api.openPosition(
      inputTokenSymbol: 'USDC',
      outputTokenSymbol: 'SOL',
      inputAmountUi: '11',
      leverage:
          1.1, // low leverage ⇒ minimal notional ⇒ minimal dev-env spread burn on the round-trip
      tradeType: 'LONG',
      owner: owner,
    ),
    signer,
    er,
    skipPreflight: true, // ER has no simulateTransaction
  );
  final state = await api.ownerState(owner);
  _save('owner_state_after_open', state);
  _log('\nTRADE OK — owner state captured.');
}

Future<void> _close(FlashApi api, WalletSigner signer, RpcSubmitter er, String owner) async {
  await _step(
    'close_position',
    () => api.closePosition(
      owner: owner,
      marketSymbol: 'SOL',
      side: 'LONG',
      inputUsdUi: '0', // full close
      withdrawTokenSymbol: 'USDC',
    ),
    signer,
    er,
    skipPreflight: true,
  );
  final state = await api.ownerState(owner);
  _save('owner_state_after_close', state);
  _log('\nCLOSE OK.');
}

Future<void> _withdraw(FlashApi api, WalletSigner signer, RpcSubmitter base, String owner) async {
  // Balance-aware: read the real withdrawable USDC from the decoded basket (never guess).
  final state = await api.ownerState(owner);
  final basketPubkey = state['basketPubkey'] as String;
  final raw = await api.withdrawableRaw(basketPubkey, _usdcMint);
  final amountUi = (raw / 1000000).toStringAsFixed(6); // USDC = 6 decimals
  _log('• withdrawable USDC: $amountUi (raw $raw)');
  if (raw <= 0) {
    _log('  nothing to withdraw.');
    return;
  }

  await _step(
    'request_withdrawal',
    () => api.requestWithdrawal(owner: owner, tokenMint: _usdcMint, amountUi: amountUi),
    signer,
    base,
  );
  _log('• waiting ~30–90s for the settlement receipt to cross to base…');
  await Future<void>.delayed(const Duration(seconds: 45));
  await _step(
    'execute_withdrawal',
    () => api.executeWithdrawal(owner: owner, tokenMint: _usdcMint),
    signer,
    base,
  );
  _log('\nWITHDRAW OK — funds returned to the owner ATA (unwrap WSOL if any).');
}

/// Retry-only: after a confirmed request_withdrawal, the validator crosses a settlement receipt to
/// base in ~30–90s; execute fails 0xbc4 (3012 AccountNotInitialized) at PREFLIGHT (no fee) until it
/// lands. Poll until it succeeds.
Future<void> _executeOnly(
  FlashApi api,
  WalletSigner signer,
  RpcSubmitter base,
  String owner,
) async {
  for (var attempt = 1; attempt <= 20; attempt++) {
    try {
      final built = await api.executeWithdrawal(owner: owner, tokenMint: _usdcMint);
      final signed = await signer.signBase64(built.transactionBase64);
      final sig = await base.submit(signed);
      await base.confirm(sig);
      _log('  ✓ execute_withdrawal confirmed: $sig');
      _save('execute_withdrawal_result', {'signature': sig});
      return;
    } on Object catch (e) {
      final s = e.toString();
      final notReady =
          s.contains('0xbc4') || s.contains('AccountNotInitialized') || s.contains('3012');
      if (notReady) {
        // AccountNotInitialized means EITHER the receipt hasn't crossed yet OR it was already
        // consumed by a finalized withdrawal (the validator keeper auto-executes). Distinguish by
        // checking whether anything is still withdrawable.
        final state = await api.ownerState(owner);
        final basketPubkey = state['basketPubkey'] as String?;
        final pending = basketPubkey == null
            ? 0
            : await api.withdrawableRaw(basketPubkey, _usdcMint);
        if (pending <= 0) {
          _log('  ✓ withdrawal already finalized (receipt consumed; funds in wallet).');
          return;
        }
        if (attempt < 20) {
          _log('  attempt $attempt: settlement receipt not on base yet — waiting 15s…');
          await Future<void>.delayed(const Duration(seconds: 15));
          continue;
        }
      }
      rethrow;
    }
  }
}
