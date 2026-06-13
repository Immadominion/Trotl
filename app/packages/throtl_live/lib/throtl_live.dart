/// Live I/O adapters wiring the pure `throtl_runtime` executor to real infrastructure — the ER
/// RideSession feed and the Flash settlement gateway. Import this only from non-pure consumers (the
/// app controller, live binaries); the executor/reconciler themselves stay in pure packages.
library;

export 'src/er_ride_feed.dart';
export 'src/er_subscription.dart';
export 'src/real_flash_gateway.dart';
