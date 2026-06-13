/// Real MagicBlock Ephemeral Rollup client: Magic Router custom RPCs, ER endpoint models, and the
/// in-ER Pyth Lazer oracle parser. Standard ER RPC + WS use `package:solana` directly against the
/// node fqdn (it implements the full Solana RPC + subscription surface).
library;

export 'src/models.dart';
export 'src/oracle.dart';
export 'src/router_client.dart';
