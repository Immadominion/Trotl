# throtl

The Throtl cockpit — a Flutter racing game that trades the SOL-perp market on Flash
Trade via MagicBlock ephemeral rollups. Android-first (Mobile Wallet Adapter); also
runs on web for keyboard/D-pad play (no wallet).

## Configuration — RPC endpoints & private keys

Every chain endpoint is read from a **compile-time env var with a public default**, so
the app runs out of the box. A private/paid RPC (e.g. a Helius key) is injected via env
and is **never committed** — `env.json` is gitignored; `env.example.json` is the template.

| Key | Default | Notes |
|-----|---------|-------|
| `THROTL_RPC` | _(empty)_ | Your private/paid L1 RPC — tried first. Empty ⇒ use the publics. |
| `THROTL_RPC2` / `THROTL_RPC3` | publicnode / drpc | Public L1 fallbacks. |
| `FLASH_ER_RPC` | flash.magicblock.xyz | Flash ephemeral-rollup RPC (trades). |
| `FLASH_API_BASE` | flashapi.trade/v2 | Flash hosted REST API. |

### Run locally (VS Code)

`env.json` already exists (public defaults). To use a private RPC, edit `THROTL_RPC` in
it — or start fresh from the template:

```bash
cp env.example.json env.json   # then set THROTL_RPC to your Helius/Triton URL
```

Hit **Run ▶** — the bundled `.vscode/launch.json` passes `--dart-define-from-file=env.json`.
Use **“Throtl (profile — smooth)”** for a release-speed run (debug mode is much heavier).

CLI equivalent:

```bash
flutter run --dart-define-from-file=env.json
```

### Mobile / CI build

Same mechanism — provide `env.json` at build time (generated from a CI secret), then:

```bash
flutter build apk --release --dart-define-from-file=env.json
```

Nothing private lives in the repo: the public defaults make a missing/empty `env.json`
harmless, and the real keys only ever exist in the build-time file.
