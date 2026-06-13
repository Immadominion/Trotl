# Throtl — Flutter Web Target Strategy (verified June 2026)

## 1. Flutter web runtime status

Current stable is **Flutter 3.44.0 (May 18, 2026)** ([release notes](https://docs.flutter.dev/release/release-notes)). The HTML renderer is **gone** — deprecated March 2024, removed from the SDK ([flutter-announce](https://groups.google.com/g/flutter-announce/c/JqkMe7cPkQo)). Two renderers remain ([docs](https://docs.flutter.dev/platform-integration/web/renderers)):

- **canvaskit** (default `flutter build web`): Skia-to-wasm, ~1.5 MB engine download, runs everywhere, Dart compiled by dart2js.
- **skwasm** (`flutter build web --wasm`): ~1.1 MB, Dart compiled by dart2wasm, "noticeably better start-up time and frame performance"; requires **WasmGC** (runtime falls back to canvaskit on unsupported browsers). Multithreaded rendering requires **SharedArrayBuffer → COOP/COEP cross-origin-isolation headers** on your hosting ([wasm docs](https://docs.flutter.dev/platform-integration/web/wasm)) — note cross-origin isolation forces CORP/CORS on every subresource you load.
- `--wasm` builds **hard-require `dart:js_interop` + `package:web`**; any transitive dep using legacy `package:js`/`dart:html` kills the wasm build.

**Concurrency — the big one**: "Dart web platforms, including Flutter web, don't support isolates. `compute()` runs the computation on the main thread on the web" ([docs.flutter.dev/perf/isolates](https://docs.flutter.dev/perf/isolates)). Wasm shared-memory threads are still experimental ([flutter#145132](https://github.com/flutter/flutter/issues/145132)). Everything — tick engine, signing, WS decode, rendering — shares one thread on web.

**Runtime viability for a 20–33 Hz data app**: skwasm at 60fps with a single animated canvas is realistic on desktop browsers; the threat is main-thread contention, not raster speed. Budget total payload realistically at ~2.5–4 MB compressed (engine wasm + app code + font subsets); use deferred imports for non-critical routes.

**PWA**: `manifest.json` is still generated and Chrome installability needs only manifest+HTTPS, but Flutter **stopped shipping its default service worker** (`flutter_service_worker.js` deprecated/removed, [flutter#156910](https://github.com/flutter/flutter/issues/156910), [announcement](https://groups.google.com/g/flutter-announce/c/0Vv-j_TyrdI)). Offline/caching is now DIY (Workbox or hand-written SW injected in `flutter_bootstrap.js`). For a trading app, do NOT cache aggressively — a stale build talking to a live ER is a hazard; use a network-first SW only for install/offline-shell.

## 2. Wallet connectivity from Flutter web — the honest enumeration

**(a) Hand-rolled `dart:js_interop` → Wallet Standard / injected providers — the only viable path.** No maintained package does this (verified via pub.dev API, June 13 2026). You bind to the [Wallet Standard](https://github.com/wallet-standard/wallet-standard) registry (dispatch `wallet-standard:app-ready`, collect registered wallets) or directly to `window.phantom.solana` / `window.solflare` / `window.backpack`. Phantom, Solflare and Backpack extensions all expose `standard:connect`, `solana:signTransaction` (accepts serialized **versioned** tx bytes), `solana:signMessage`, and `solana:signIn` (SIWS). `dart:js_interop` is wasm-compatible. Cost: ~300–600 LOC of bindings plus a thin TS shim if you want `@wallet-standard/app` semantics verbatim. This path delivers all three requirements: extension connect, versioned-tx signing, SIWS.

**(b) `solana_wallet_adapter` 0.1.5 (merigo-labs)** — last published **2023-12-04** ([pub.dev API](https://pub.dev/api/packages/solana_wallet_adapter)), 2.5 years stale. Its web implementation `solana_wallet_adapter_web` 0.0.9 (I unpacked the archive) depends on **legacy `package:js ^0.6.5`** → **breaks `--wasm` builds outright**, supports only hardcoded Phantom/Solflare injected providers (no Backpack, no Wallet Standard, no `signIn`, no versioned-tx surface), and sits on `solana_web3` 0.1.3 (also Dec 2023, no `platform:web` tag). Companion `solana_wallet_provider` is android/ios-only. **Reject.**

**(c) `reown_appkit` 1.8.3 (Feb 19, 2026)** — actively maintained and supports Solana **on mobile** via the WalletConnect relay ([reown blog](https://reown.com/blog/how-to-get-started-with-reown-appkit-on-solana)), but **has no Flutter web platform**: pub.dev tags are android+ios only, `webview_flutter_web` is commented out in [pubspec](https://github.com/reown-com/reown_flutter/blob/master/packages/reown_appkit/pubspec.yaml), and GitHub [issue #62 "Web support"](https://github.com/reown-com/reown_flutter/issues/62) was **closed `not_planned` (Dec 2025)**; the community `wagmi_web` substitute is EVM-only. **Reject for web** (optionally useful on mobile as a WalletConnect fallback alongside MWA).

**(d) espresso-cash `package:solana` 0.32.0+1 (Apr 10, 2026)** — actively maintained, tagged `platform:web` **and `is:wasm-ready`** ([score API](https://pub.dev/api/packages/solana/score)). Pure-Dart deps only: `cryptography ^2.5.0`, `bip39`, `borsh_annotation`, `http`, `web_socket_channel` — no ffi ([pubspec](https://raw.githubusercontent.com/espresso-cash/espresso-cash-public/master/packages/solana/pubspec.yaml)). But it is an **RPC client + local-keypair signer, not a wallet connector** — it has no extension/Wallet Standard component. It is exactly right for the session-key hot path (signing ER ticks with the delegated key) and L1 RPC on every platform; pair it with (a) for L1 wallet UX.

**Honorable mention**: `solana_kit` ([github.com/openbudgetfun/solana_kit](https://github.com/openbudgetfun/solana_kit)) — a 57-package Dart port of `@solana/kit`, created Feb 2026, pushed June 7 2026, v0.5.0. Codecs/codama renderers could replace hand-written Borsh for throtl-engine accounts. But: 2 stars, bus-factor 1, MWA package Android-only, **no web wallet package**. Watch, don't depend.

## 3. CORS reality check (live `curl -I` with `Origin:` headers, June 13 2026)

- **Flash Trade** `https://api.prod.flash.trade` (confirmed as the exact base URL embedded in `flash-sdk` 15.16.16 from npm, alongside `https://hermes.pyth.network`): OPTIONS → 204, `access-control-allow-origin: *`, methods `GET,HEAD,PUT,PATCH,POST,DELETE`. Browser-callable.
- **MagicBlock** `https://devnet-router.magicblock.app`: OPTIONS → 200, `access-control-allow-origin: *`, `access-control-allow-methods: *`, `access-control-allow-headers: *`; POST JSON-RPC with Origin echoes `*`. Browser-callable; WS subscriptions to the ER are exempt from CORS entirely.
- **Helius** `https://mainnet.helius-rpc.com/?api-key=…`: OPTIONS → 200, `access-control-allow-origin: *`, `access-control-allow-headers: *`. Browser-callable — Helius expects browser use; lock the API key to your domains in the dashboard. (`api.mainnet-beta.solana.com` also reflects the origin.)
- **Pyth Hermes** `https://hermes.pyth.network`: `access-control-allow-origin: *`.

**Conclusion: no CORS proxy is required.** A thin proxy is still justified for two non-CORS reasons: hiding the Helius key from bundle inspection if domain-allowlisting is deemed insufficient, and any **Pyth Lazer access token** (Lazer is token-authed WSS; WS has no CORS but the token ships in the client on web *and* mobile — same problem, server-side relay is the clean fix).

## 4. Architecture validation (melos monorepo, pure-Dart core)

The proposed layering is idiomatic — it is literally Flutter's **federated plugin / platform-interface pattern** applied at app scale. **Melos 7.8.2 (published June 10, 2026, Invertase)** is current and built on **Dart pub workspaces** (Dart ≥3.6) ([melos.invertase.dev](https://melos.invertase.dev)). Concrete layout:

- `packages/throtl_core` — tick engine client, hysteresis reconciler FSMs, VWAP/PnL math. **Pure Dart, zero Flutter imports** → `dart test` deterministic tests, runs in CI in seconds.
- `packages/throtl_chain` — espresso `solana` + tx building + throtl-engine codecs.
- `packages/wallet_api` — abstract `WalletSession` interface (connect / signTx(bytes) / signIn).
- `packages/wallet_mwa` (Android, MWA 2.0) and `packages/wallet_web` (`dart:js_interop` Wallet Standard), selected via conditional imports (`if (dart.library.js_interop)`).

**Web-breakers to gate in CI**: anything `dart:ffi` (no ffi on web), legacy `package:js`/`dart:html` deps (break `--wasm` specifically — the merigo stack is the example in your own domain), `reown_appkit` (no web), `Isolate.spawn` anywhere in shared code. Add a CI job that runs `flutter build web --wasm` on every PR — it is your canary for both categories. The espresso stack is clean: `cryptography` 2.x is wasm-ready pure Dart/WebCrypto.

**Web-specific security note**: there is no Keystore/StrongBox on web — the delegated session key lives in IndexedDB/memory. Mitigations: short session TTL + the on-chain loss-floor (already in your design) as the real bound; optionally hold the key as a **non-extractable WebCrypto Ed25519 `CryptoKey`** (supported in Chrome, Firefox, Safari as of 2025-26) so XSS can use but not exfiltrate it.

## 5. Riskiest assumption + mitigation

**Riskiest assumption: "the 30–50 ms tick hot path (ed25519-sign → send → decode → reconcile → render) ships unchanged to web."** On Android you would put it in an isolate; **on web there are no isolates and `compute()` runs on the main UI thread** ([docs](https://docs.flutter.dev/perf/isolates)), and `cryptography`'s Ed25519 on web is pure Dart (dart2js) — unbenchmarked for your cadence. One slow frame = visible thumb-control jank; sustained overrun = the reconciler falls behind real exposure.

**Mitigation, in order**: (1) make `throtl_core` single-threaded-by-design — no isolate API in the hot path, allocation-light, frame-budgeted; isolates become a mobile-only *optimization* injected at the edge, not an architectural dependency. (2) Week-1 spike: benchmark `Ed25519().sign()` of a ~200-byte tick payload under dart2js **and** dart2wasm in Chrome/Safari; pass bar <2 ms p99. (3) Ship `--wasm` as the primary web build (lower GC jitter, faster numerics) with dart2js fallback. (4) If signing misses budget, swap the web signer to native **WebCrypto Ed25519** behind the same `wallet_api` interface. (5) Let the web client degrade tick rate adaptively (50→100 ms) — the hysteresis reconciler and ER commit boundaries already tolerate variable cadence, so this is a UX nicety, not a correctness change.

---

## Verified claims

- **[CONFIRMED]** No maintained pub.dev package provides Solana extension-wallet (Wallet Standard) connectivity for Flutter web as of June 2026: merigo solana_wallet_adapter/solana_wallet_adapter_web last published 2023-12-04 and use legacy package:js 0.6.5 (incompatible with --wasm builds, Phantom/Solflare only, no SIWS), and reown_appkit 1.8.3 supports only android/ios with web support closed as 'not_planned'. A hand-rolled dart:js_interop Wallet Standard bridge is the only path to Phantom/Solflare/Backpack connect + versioned-tx signing + SIWS.
  - evidence: Every load-bearing element of the claim checks out against primary sources as of June 2026; an adversarial sweep of pub.dev found no maintained refuting package.

1) merigo packages are dead and legacy-interop:
- https://pub.dev/api/packages/solana_wallet_adapter: latest 0.1.5, published 2023-12-04T23:12:36Z.
- https://pub.dev/api/packages/solana_wallet_adapter_web: latest 0.0.9, published 2023-12-04T23:10:45Z, dependency "js": "^0.6.5" (claim says "0.6.5"; actual constraint is ^0.6.5 — substantively identical).
- Downloaded the published archive (pub.dev/api/archives/solana_wallet_adapter_web
- **[CONFIRMED]** All three required HTTP endpoints are directly browser-callable with access-control-allow-origin: * (verified by curl with Origin headers on 2026-06-13): https://api.prod.flash.trade (the exact base URL embedded in flash-sdk 15.16.16 npm dist), https://devnet-router.magicblock.app, and https://mainnet.helius-rpc.com — so the web build needs no CORS proxy; a proxy is only justified to hide the Helius key or a Pyth Lazer access token.
  - evidence: Verified 2026-06-13 via curl with Origin headers against all three endpoints, plus inspection of the flash-sdk 15.16.16 tarball from the npm registry.

1) flash-sdk version + embedded URL: https://registry.npmjs.org/flash-sdk shows dist-tags {latest: '15.16.16'}. Downloaded https://registry.npmjs.org/flash-sdk/-/flash-sdk-15.16.16.tgz and grepped the dist: package/dist/backupOracle.js line 70 contains `var API_ENDPOINT = process.env.NEXT_PUBLIC_API_ENDPOINT ?? 'https://api.prod.flash.trade'` (used at line 161 as `${API_ENDPOINT}/backup-oracle/prices?poolAddress=...`). It is the only api.prod.f
- **[CONFIRMED]** Dart web platforms (including Flutter web, both dart2js and dart2wasm) do not support isolates; compute() executes on the main thread on web, so the 30-50ms tick loop (signing, WS decode, reconciler) shares one thread with rendering.
  - evidence: All primary sources, fetched live (June 2026), confirm the claim:

1. Stated source, Flutter official docs (https://docs.flutter.dev/perf/isolates): "Dart web platforms, including Flutter web, don't support isolates." and "The compute() method runs the computation on the main thread on the web, but spawns a new thread on mobile devices."

2. Dart official docs (https://dart.dev/language/concurrency): "The Dart web platform, however, does not support isolates." It offers web workers as the only alternative and notes they have no equivalent of Isolate.spawn() and copy data on message passing.

3
- **[CONFIRMED]** espresso-cash package:solana 0.32.0+1 (published 2026-04-10) is actively maintained, tagged platform:web and is:wasm-ready on pub.dev, and depends only on pure-Dart packages (cryptography ^2.5.0, bip39, borsh_annotation, http, web_socket_channel — no ffi), making it a viable shared core for RPC + session-key signing across Android and web; it provides no wallet-connection functionality.
  - evidence: Verified against pub.dev API, the package archive itself, and GitHub (June 2026):

1. VERSION & DATE — CONFIRMED. https://pub.dev/api/packages/solana shows latest = 0.32.0+1, published 2026-04-10T09:27:35Z, publisher cryptoplease.com (Espresso Cash), repository https://github.com/espresso-cash/espresso-cash-public.

2. TAGS — CONFIRMED. https://pub.dev/api/packages/solana/score returns tags including "platform:web", "is:wasm-ready", plus platform:android/ios/windows/linux/macos, runtime:web. Score: 130/160 pub points, 97 likes, ~1,066 downloads/30 days.

3. DEPENDENCIES — CONFIRMED IN SUBSTANC
- **[CONFIRMED]** As of Flutter 3.44 (May 2026) the HTML renderer is removed; default web builds are CanvasKit (~1.5MB engine, dart2js) and --wasm builds use skwasm (~1.1MB, dart2wasm, requires WasmGC, falls back to canvaskit) with better startup/frame performance; --wasm requires every dependency to use dart:js_interop/package:web (legacy package:js breaks the build), and multithreaded rendering requires COOP/COEP headers; the default service worker has been removed so PWA offline caching is DIY.
  - evidence: All sub-claims verified against primary sources on 2026-06-13; one phrasing nuance on the service worker noted below.

(1) VERSION/DATE: Official Flutter release feed (https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json) shows stable 3.44.0 released 2026-05-18; current stable is 3.44.2 (2026-06-11). "Flutter 3.44 (May 2026)" is accurate.

(2) HTML RENDERER REMOVED: https://docs.flutter.dev/platform-integration/web/renderers (footer: "reflects Flutter 3.44.0", updated 2026-05-05) lists exactly two renderers: canvaskit and skwasm; no HTML renderer exists. The remova
  - CORRECTED: Accurate as stated, with one refinement: in Flutter 3.44 the default service worker has not been fully deleted — `flutter build web` still emits and registers a flutter_service_worker.js, but since Flutter 3.41 it is a no-op cleanup worker that performs no caching and unregisters itself on activation (the offline-first caching worker last shipped in 3.38). Full removal is still pending under open issue flutter/flutter#156910. Practically, PWA offline caching is DIY, exactly as the claim concludes.
