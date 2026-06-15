import 'package:flutter/foundation.dart';
import 'package:magicblock_client/magicblock_client.dart';
import 'package:solana/solana.dart';

/// L1 **mainnet** base RPC. A custom first-choice can be passed at build time:
///   flutter run --dart-define=THROTL_RPC=https://your-mainnet-rpc
///
/// Hard-won lesson (Starlink + a Seeker): some DEVICES fail to resolve specific
/// RPC *domains* — `helius-rpc.com` returns "Failed host lookup (errno=7)" while
/// `flashapi.trade` and `solana-rpc.publicnode.com` (both Cloudflare too) resolve
/// fine. It's the DOMAIN, not the network. And Dart's HttpClient can't be pointed
/// at a pre-resolved IP for a Cloudflare host (TLS needs SNI, which the
/// connection-factory API can't set by-IP) — so DoH-in-app is out. The robust fix
/// is to default to domains that resolve broadly and let the user inject their own
/// fast endpoint (e.g. a Helius key) via --dart-define when their network resolves
/// it. The app PROBES the list at startup ([resolveRpc]) and pins the first that
/// actually responds, so a dead/blocked endpoint self-heals across the whole app.
///
/// To get a *fast* endpoint when your device won't resolve Helius: set Android
/// Private DNS (Settings → Network → Private DNS) to `one.one.one.one`, then pass
/// `--dart-define=THROTL_RPC=https://mainnet.helius-rpc.com/?api-key=YOUR_KEY`.
const String _rpcOverride = String.fromEnvironment('THROTL_RPC');

/// Public L1 fallbacks. Like every endpoint here they're read from compile-time
/// env vars with a public default, so a private/paid RPC can be injected at build
/// time (`--dart-define-from-file=env.json`, gitignored) and NEVER committed.
const String _rpcPublic1 = String.fromEnvironment(
  'THROTL_RPC2',
  defaultValue: 'https://solana-rpc.publicnode.com',
);
const String _rpcPublic2 = String.fromEnvironment(
  'THROTL_RPC3',
  defaultValue: 'https://solana.drpc.org',
);

/// Tried in order: the private override (if any) first, then broadly-resolvable
/// public mainnet endpoints. NOT Helius by default — its domain is the one that
/// fails to resolve on the target device; inject your own key via THROTL_RPC (env).
///
/// `api.mainnet-beta.solana.com` was deliberately DROPPED: Solana Labs rate-limits
/// it hard (429), and every transient blip re-probes this whole list ([resolveRpc]),
/// so a rate-limited endpoint turns one 429 into a probe storm.
const List<String> kRpcCandidates = [
  if (_rpcOverride != '') _rpcOverride,
  _rpcPublic1,
  _rpcPublic2,
];

/// The RPC the whole app uses (set by [resolveRpc]; starts as the first candidate).
String _activeRpc = kRpcCandidates.first;

/// The active base RPC URL (for diagnostics / display).
String get activeRpc => _activeRpc;

/// The last time [resolveRpc] actually re-probed. The wallet retry loops call
/// resolveRpc() on EVERY transient blip (DNS flap / 429 / timeout); without a
/// cooldown each call would re-ping every candidate, turning one failure into a
/// burst of N requests against already-struggling free RPCs. We probe at most
/// once per [_probeCooldown] and otherwise reuse the current active endpoint.
DateTime? _lastProbeAt;
const Duration _probeCooldown = Duration(seconds: 3);

/// Probe each candidate once; switch the active RPC to the first that resolves +
/// responds. Cheap (`getLatestBlockhash`); a non-resolving host fails fast so the
/// whole probe is ~1s worst case. Debounced by [_probeCooldown] so retry loops
/// can call it freely. Pass `force: true` to bypass the cooldown (startup).
Future<void> resolveRpc({bool force = false}) async {
  final now = DateTime.now();
  if (!force && _lastProbeAt != null && now.difference(_lastProbeAt!) < _probeCooldown) {
    return; // probed moments ago — reuse the active endpoint instead of hammering
  }
  _lastProbeAt = now;
  for (final url in kRpcCandidates) {
    try {
      await RpcClient(url).getLatestBlockhash();
      _activeRpc = url;
      debugPrint('[rpc] active endpoint: $url');
      return;
    } on Object catch (e) {
      debugPrint('[rpc] candidate unusable ($url): $e');
    }
  }
  debugPrint('[rpc] WARNING: no candidate responded — using ${kRpcCandidates.first}');
}

/// Which Solana cluster the app is pointed at. Mainnet is the only network now —
/// the `throtl-engine` program (same ID) is deployed there, and Flash Trade (the
/// real-money settlement venue) is mainnet-only.
enum AppCluster { devnet, mainnet }

/// All per-cluster endpoints + addresses behind one object, so every chain call
/// (balances, init/delegate, ER router, oracle, USDC) reads from a single
/// source of truth that flips with the network toggle.
class NetworkConfig {
  const NetworkConfig({
    required this.cluster,
    required this.label,
    required this.routerUrl,
    required this.oracleFeedPda,
    required this.usdcMint,
    required this.usdcDecimals,
    required this.mwaCluster,
    required this.flashEnabled,
  });

  final AppCluster cluster;

  /// Short display label for the network chip.
  final String label;

  /// L1 base RPC — balances, `init_ride`/`delegate_ride` submit, `close_ride`,
  /// Flash setup/withdraw. Dynamic: the first reachable candidate (see [resolveRpc]).
  String get baseRpc => _activeRpc;

  /// MagicBlock Magic Router — region/ER discovery + delegation status.
  final String routerUrl;

  /// In-ER Pyth Lazer SOL feed PDA (the program's mark source).
  final String oracleFeedPda;

  /// USDC SPL mint for fuel balance reads.
  final String usdcMint;
  final int usdcDecimals;

  /// Cluster string the MWA `authorize` call expects.
  final String mwaCluster;

  /// Whether real-money Flash settlement is reachable on this cluster.
  /// Flash Trade is mainnet-only, so devnet rides always simulate the venue.
  final bool flashEnabled;

  /// Mainnet — the only network. Flash Trade (the settlement venue) is
  /// mainnet-only, so there is no devnet ride target; practice rides simulate
  /// the venue against this same live mainnet market.
  /// NOTE: [oracleFeedPda] reuses the devnet PDA as a placeholder; the real
  /// mainnet Lazer SOL feed PDA must be confirmed before mainnet on-chain rides
  /// (balances + connect work regardless).
  static const mainnet = NetworkConfig(
    cluster: AppCluster.mainnet,
    label: 'MAINNET',
    routerUrl: RouterClient.mainnet,
    oracleFeedPda: devnetSolPriceFeedPda, // TODO(throtl): confirm mainnet Lazer SOL feed PDA
    usdcMint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', // mainnet USDC
    usdcDecimals: 6,
    mwaCluster: 'mainnet-beta',
    flashEnabled: true,
  );

  /// Mainnet is the only network now (devnet removed).
  static NetworkConfig of(AppCluster cluster) => mainnet;
}
