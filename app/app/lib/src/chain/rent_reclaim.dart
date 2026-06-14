import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/dto.dart' hide Commitment;
import 'package:solana/solana.dart';
import 'package:throtl/src/chain/tx_builder.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl_chain/throtl_chain.dart';

/// Remembers ride PDAs whose money SETTLED on-chain but whose final,
/// rent-reclaiming `close_ride` didn't confirm (the owner declined it, or the
/// RPC timed out). Without this the ~0.002 SOL of rent per ride would be
/// silently stranded; the Settings "reclaim rent" action retries them.
class RentReclaimStore {
  static const _key = 'throtl.unsettled_rides';

  static Future<List<String>> list() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? const [];
  }

  static Future<void> add(String ridePubkey) async {
    final prefs = await SharedPreferences.getInstance();
    final set = <String>{...(prefs.getStringList(_key) ?? const []), ridePubkey};
    await prefs.setStringList(_key, set.toList());
  }

  static Future<void> remove(String ridePubkey) async {
    final prefs = await SharedPreferences.getInstance();
    final cur = prefs.getStringList(_key) ?? const [];
    await prefs.setStringList(_key, cur.where((r) => r != ridePubkey).toList());
  }
}

/// Result of a reclaim sweep.
class ReclaimResult {
  const ReclaimResult({required this.reclaimed, required this.remaining});
  final int reclaimed;
  final int remaining;
}

/// Retry `close_ride` for every stranded ride PDA, owner-signed via MWA. A close
/// that fails (e.g. the PDA never made it back to L1) is left in the store to try
/// again later. Returns how many were reclaimed + how many remain.
Future<ReclaimResult> reclaimRideRent(
  WalletController wallet, {
  void Function(String step)? onStep,
}) async {
  final ownerStr = wallet.owner;
  final pending = await RentReclaimStore.list();
  if (ownerStr == null || pending.isEmpty) {
    return ReclaimResult(reclaimed: 0, remaining: pending.length);
  }
  final owner = Ed25519HDPublicKey.fromBase58(ownerStr);
  final program = ThrotlProgram();
  final base = RpcClient(wallet.network.baseRpc);
  var reclaimed = 0;

  for (final ridePk in pending) {
    try {
      onStep?.call('Closing ${_short(ridePk)}…');
      final ride = Ed25519HDPublicKey.fromBase58(ridePk);
      final bh = (await base.getLatestBlockhash()).value;
      final unsigned = buildUnsignedLegacyTx(
        instructions: [program.closeRide(ride: ride, owner: owner)],
        recentBlockhash: bh.blockhash,
        feePayer: owner,
      );
      final sigs = await wallet.signAndSend([unsigned]);
      await _confirm(base, sigs.first);
      await RentReclaimStore.remove(ridePk);
      reclaimed++;
    } on Object catch (e) {
      onStep?.call("Couldn't close ${_short(ridePk)} — keeping it for next time. ($e)");
    }
  }
  final remaining = (await RentReclaimStore.list()).length;
  return ReclaimResult(reclaimed: reclaimed, remaining: remaining);
}

Future<void> _confirm(RpcClient rpc, String sig) async {
  final stop = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(stop)) {
    final st = await rpc.getSignatureStatuses([sig], searchTransactionHistory: true);
    final s = st.value.isEmpty ? null : st.value.first;
    if (s != null) {
      if (s.err != null) throw StateError('close failed: ${s.err}');
      if (s.confirmationStatus == ConfirmationStatus.confirmed ||
          s.confirmationStatus == ConfirmationStatus.finalized) {
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  throw StateError('close not confirmed within 45s');
}

String _short(String s) => s.length <= 8 ? s : '${s.substring(0, 4)}…${s.substring(s.length - 4)}';
