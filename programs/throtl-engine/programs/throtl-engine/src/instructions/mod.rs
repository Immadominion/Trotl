pub mod close_ride;
pub mod delegate_ride;
pub mod freeze;
pub mod init_ride;
pub mod request_settle;
pub mod tick;

// Glob re-export so Anchor's generated `__client_accounts_*` / `__cpi_client_accounts_*` modules
// (which `#[program]` resolves via `crate::...`) are reachable at the crate root. The per-module
// `handler` fns are `pub(crate)`, so they are NOT pulled in by these globs — no name collision.
pub use close_ride::*;
pub use delegate_ride::*;
pub use freeze::*;
pub use init_ride::*;
pub use request_settle::*;
pub use tick::*;
