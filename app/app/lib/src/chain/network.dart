import 'package:magicblock_client/magicblock_client.dart';
import 'package:solana/solana.dart';

/// L1 **mainnet** base RPC. A custom first-choice can be passed at build time:
///   flutter run --dart-define=THROTL_RPC=https://your-mainnet-rpc
/// BUT some endpoints (e.g. Helius *dedicated* subdomains like `…-fast-mainnet`)
/// don't resolve on every network — they fail DNS on Starlink/some carriers while
/// the browser + `flashapi.trade` resolve fine. So the app PROBES the candidates
/// below at startup ([resolveRpc]) and uses the first that actually resolves +
/// responds — a dead endpoint self-heals across the whole app (balances, funding,
/// ride), instead of every call dying with "Failed host lookup".
const String _rpcOverride = String.fromEnvironment('THROTL_RPC');

/// Tried in order; the override (if any) first, then well-propagated endpoints that
/// resolve everywhere.
const List<String> kRpcCandidates = [
  if (_rpcOverride != '') _rpcOverride,
  'https://mainnet.helius-rpc.com/?api-key=65e62146-bb34-47a1-8567-60b2fbb70953',
  'https://solana-rpc.publicnode.com',
  'https://api.mainnet-beta.solana.com',
];

/// The RPC the whole app uses (set by [resolveRpc]; starts as the first candidate).
String _activeRpc = kRpcCandidates.first;

/// Probe each candidate once at startup; switch the active RPC to the first that
/// resolves + responds. Cheap (`getLatestBlockhash`); a non-resolving host fails
/// fast (~200ms) so the whole probe is ~1s worst case.
Future<void> resolveRpc() async {
  for (final url in kRpcCandidates) {
    try {
      await RpcClient(url).getLatestBlockhash();
      _activeRpc = url;
      return;
    } on Object {
      // unresolvable / unreachable / rate-limited — try the next
    }
  }
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
