/// Throtl's ride executor: drives the pure reconciler FSM against a real (or simulated) Flash
/// position. The executor itself holds no keys and authorizes nothing on its own — every action is
/// the bounded output of `throtl_core`'s reconciler, executed through a FlashGateway.
library;

export 'src/executor.dart';
export 'src/flash_planner.dart';
export 'src/ports.dart';
export 'src/sim_gateway.dart';
