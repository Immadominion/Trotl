import 'package:magicblock_client/magicblock_client.dart';

/// L1 **mainnet** base RPC. The public `api.mainnet-beta.solana.com` is heavily
/// rate-limited — drop in a dedicated **MAINNET** endpoint (Helius / Triton …)
/// without touching code (use your mainnet URL, NOT devnet):
///
///   flutter run --dart-define=THROTL_RPC=https://your-id-fast-mainnet.helius-rpc.com
///
/// Empty (the default) falls back to the public mainnet endpoint. This is the only
/// network — there is no devnet path; not-connected = practice, connected = real.
const String _rpcOverride = String.fromEnvironment('THROTL_RPC');
const String kBaseRpc = _rpcOverride == ''
    ? 'https://karine-caqxkl-fast-mainnet.helius-rpc.com'
    : _rpcOverride;

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
    required this.baseRpc,
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

  /// L1 base RPC — balances, `init_ride`/`delegate_ride` submit, `close_ride`.
  final String baseRpc;

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
    baseRpc: kBaseRpc,
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
