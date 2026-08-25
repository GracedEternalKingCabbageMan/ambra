# Ambra

Ambra is a non-custodial **dual-chain mobile wallet for Bitcoin (testnet4) and Sequentia**:
a Flutter UI over a shared Rust core (`ambra_core`) built on
[SWK](https://github.com/ConcatenaLabs/SWK), the Sequentia Wallet Kit.
One 12-word recovery phrase controls both chains, and the same `tb1...` address
receives Bitcoin and Sequentia assets alike: Sequentia is transparent by default and its
default addresses use Bitcoin's own bech32 format, so BTC is a first-class asset in the
wallet, not an add-on.

Everything here is **testnet software** (Bitcoin testnet4 + the public Sequentia testnet).
There is no mainnet. Coins and assets have no value.

Sequentia itself is a Bitcoin sidechain for asset tokenization and disintermediated exchanges.
Protocol documentation lives in the node repo:
[Sequentia `doc/sequentia/`](https://github.com/ConcatenaLabs/Sequentia/tree/HEAD/doc/sequentia).

## Get the app

- Download the Android APK from https://sequentiatestnet.com/download/. That page always
  names the current release; this file deliberately does not, because a version pinned in
  prose goes stale the next time the publisher runs. Allow "install unknown apps", then
  open the `.apk`.
- Ambra also ships as a Chromium browser extension, the same dual-chain wallet built from
  [sequentia-extension](https://github.com/ConcatenaLabs/sequentia-extension),
  offered on the same download page.
- iOS is not released. The `app/ios/` scaffold exists but iOS bring-up has not happened
  (it needs a macOS + Xcode machine).
- Free testnet funds: the in-app faucet (More tab) dispenses tSEQ and the demo assets;
  for BTC use any public Bitcoin testnet4 faucet with the wallet's receive address.

## What the wallet does

Each item below is implemented in this repo; the file pointers name the screen or
module that implements it.

**Wallet and custody**
- Create a wallet (12-word BIP39 phrase, word grid + verification quiz) or import an
  existing phrase (`app/lib/src/screens/onboarding.dart`). The phrase is stored only in
  platform secure storage (Android Keystore-backed encrypted preferences / iOS Keychain)
  and is read out transiently for signing, never cached
  (`app/lib/src/data/wallet_repository.dart`).
- Opt-in app lock (biometrics or device PIN) that engages on cold start and whenever the
  app is backgrounded; revealing the recovery phrase always requires authentication.
- Reveal recovery phrase and remove wallet (deletes the phrase from the device), both
  from the More tab.
- Keylogger-immune phrase import: the import path uses an on-screen keyboard with BIP39
  autocomplete, so no system IME ever sees the words; free-text paste remains as a
  fallback (`app/lib/src/screens/recover_screen.dart`).
- OpenAMP tagged signing: sign a wallet-link/login challenge or a document hash for an
  OpenAMP-integrated site, opened from an `oamp-sign` deep link
  (`app/lib/src/screens/sign_screen.dart`).

**Balance (dual-chain, no privileged asset)**
- The headline is one **total balance across all held assets, valued in a user-chosen
  reference currency** (USD default; picker in the top bar, fed by the public price
  server). Below it, every held asset is one equal row: BTC (Bitcoin testnet4), tSEQ,
  issued assets, and OpenAMP restricted assets side by side
  (`app/lib/src/screens/shell.dart`).
- Both chains sync against Esplora-style REST APIs; last-known balances are cached on
  disk and shown instantly on launch, with an explicit offline/stale indicator when a
  scan fails.

**Receive**
- One shared `tb1...` address for both chains, with QR code and cross-chain index
  cycling ("New address" advances both chains together, discouraging reuse).
- Opt-in confidential Sequentia address (blech32, `tsqb1...`) that hides amount and
  asset on-chain; the screen then also shows the matching transparent `tb1` form, which
  is the one that can receive Bitcoin.
- OpenAMP account id + enclave deposit address for receiving restricted assets, shown
  when the OpenAMP service is reachable.

**Send**
- Sequentia send of any held asset, with the signature Sequentia feature: an **any-asset
  fee picker**. The fee defaults to the asset being sent and can be paid in any asset the
  network accepts, at the node's published exchange rates. Optional fee-rate override,
  always denominated in **the chosen fee asset's own units per vByte** (never sat/vB;
  sats are Bitcoin-only) (`app/lib/src/screens/send_screen.dart`).
- Bitcoin (testnet4) send: BTC appears in the same asset picker and pays its own fee in
  sat/vB (correct there, it is the Bitcoin chain).
- QR scanning of recipient addresses using the first-party CameraX preview plus a
  **pure-Dart ZXing decoder (`zxing2`)**, so the app needs no Google ML Kit and no Play
  Services (`app/lib/src/screens/scan_screen.dart`).
- OpenAMP restricted assets are sent by account id through the enclave's
  transfer-approval flow (`app/lib/src/data/openamp_service.dart`).

**History and stuck-transaction rescue**
- Transaction history with kind badges, per-asset deltas, and explorer deep links.
- Rescue actions on unconfirmed transactions (`app/lib/src/screens/rescue_screen.dart`):
  - **RBF bump**: re-send the same payment at a higher fee,
  - **RBF replace**: same inputs, brand-new recipient/asset/amount,
  - **CPFP**: pay a child fee, in any asset, to pull the parent in
    (with a suggested child fee rate from the core).

**Swap (SeqDEX)**
- **Same-chain atomic swap**: pay one Sequentia asset, receive another, settled in a
  single atomic transaction against the SeqDEX daemon's order book
  (`app/lib/src/screens/swap_screen.dart`). The review sheet states finality honestly:
  settles in ~1 block, anchor-bound to Bitcoin (reverts only if Bitcoin reverts).
- **Cross-chain buy**: buy a Sequentia asset by locking BTC in a testnet4 HTLC
  (`app/lib/src/screens/xchain_swap_screen.dart`). The preimage reveal is hard-gated on
  verifying the Sequentia leg's Bitcoin anchor; in-flight swaps persist across restarts
  and a BTC refund path opens after the timeout.
- **Instant (Lightning)**: a pure-Lightning BTC<->asset rail through the public hosted
  SeqLN LSP, non-custodial via an on-device signer
  (`app/lib/src/screens/lightning_swap_screen.dart`). It is on by default: the released
  APK points at `wss://sequentiatestnet.com/lsp-ws-asset` and `/lsp-ws-btc` with pinned
  host keys (`Backend` in `app/lib/src/data/config.dart`). Pointing the wallet at a
  custom node clears these, because a custom node has no hosted LSP, and the rail goes
  dark until you return to the default.
- **Peer-to-peer submarine swap**: a rail crossing on the BTC leg settled directly with
  an interactive maker, no LSP in the value path. A buy pays Bitcoin over Lightning and
  receives the asset in one on-chain HTLC bound to the same secret; a sell funds the
  asset HTLC (`app/lib/src/screens/submarine_swap_screen.dart`).
- **Sub-asset rails**: buy or sell a Sequentia asset over Lightning against Bitcoin on
  the testnet4 chain, served by the LSP (`app/lib/src/screens/subasset_buy_screen.dart`,
  `subasset_sell_screen.dart`).
- **Cross-market lift and walk**: buy an asset with Bitcoin against one resting cross
  offer at a live maker quote fetched over the relay courier
  (`app/lib/src/screens/cross_lift_screen.dart`), or sweep several resting offers best
  price first, one leg at a time through the same path
  (`app/lib/src/screens/cross_walk_screen.dart`). The BTC is refundable after the
  timeout and the secret reveals only on an anchor-safe asset leg.
- **My orders**: the maker's own resting covenant orders (funded on-chain, posted to the
  relay) with a reclaim path (`app/lib/src/screens/my_orders_screen.dart`).

**Assets, staking, faucet, node**
- Issue a new asset, reissue (mint more of) an asset you hold the reissuance token for,
  and burn (`app/lib/src/screens/assets_screen.dart`).
- Stake the Sequence token (tSEQ) for block production: 40,000 tSEQ minimum, time-based
  CSV lock of roughly 15 days (`app/lib/src/screens/stake_screen.dart`). Staked tSEQ is
  excluded from the spendable balance. Unbonding is not available in the app, so
  only stake what you can lock. Staking is the one thing the Sequence token is for; it
  is not privileged anywhere else in the wallet.
- Faucet screen requesting tSEQ, USDX, EURX, GOLD, SILVR, or OILX from the public
  testnet faucet.
- Custom node: point the wallet at your own Sequentia node/backend (with optional HTTP
  auth) instead of the public testnet default (`app/lib/src/screens/node_screen.dart`).

## Consensus rules the UX must respect

Bitcoin **anchoring is supreme**: every Sequentia block references a Bitcoin block
header, and Sequentia reorganizes whenever Bitcoin reorganizes away an anchor, in real
time, overriding checkpoints and immediate finality. A transaction's real safety depth
is the **Bitcoin** confirmation depth of its block's anchor, not its Sequentia block
depth. Ambra never presents Sequentia finality as stronger than a Bitcoin reorg: swap
review sheets say "anchor-bound to Bitcoin (reverts only if Bitcoin reverts)", the
cross-chain swap gates its preimage reveal on an anchor check, and only the pure
Lightning rail (where nothing settles on-chain) is ever labeled final.

## Backend endpoints

The wallet defaults to the public Sequentia testnet node and derives every endpoint from
one origin (`app/lib/src/data/config.dart`), so switching to a custom node is one
change:

| Endpoint | Purpose |
|---|---|
| `<origin>/api` | Sequentia Esplora REST (sync, broadcast) |
| `<origin>/testnet4/api` | Bitcoin testnet4 Esplora REST |
| `<origin>/dex` | SeqDEX daemon (REST via grpc-gateway) |
| `<origin>/feerates` | Per-asset fee exchange rates |
| `<origin>/prices` | Reference-currency price server |
| `<origin>/registry/index.minimal.json` | Asset registry labels |
| `<origin>/faucet` | Testnet faucet |
| `<origin>/openamp` | OpenAMP restricted-asset API |
| `<origin>/lsp` | Hosted SeqLN LSP HTTP API |

The default origin is `https://sequentiatestnet.com`. The Lightning rail's websocket
endpoints and pinned host keys are separate constants in the same file and are enabled
only while the default origin is in use.

## Architecture

```
Flutter UI (app/)  --flutter_rust_bridge-->  ambra_core (Rust)  -->  SWK (lwk_wollet,
   Dart                                          |                    `sequentia` feature)
                                                 +-->  seqln-signer (Lightning device signer)
```

- **`app/`** is the Flutter application: screens, theme, and thin Dart service classes
  for the HTTP sidecars (faucet, prices, registry, SeqDEX, OpenAMP, LSP). See
  [`app/README.md`](app/README.md).
- **`ambra_core/`** is the shared Rust crate exposed to Dart via flutter_rust_bridge
  (pinned to 2.12.0). It consumes SWK's `lwk_wollet` with the `sequentia` cargo feature
  ON, which is where the whole Sequentia send-flow lives: any-asset fees, RBF/CPFP,
  transparent-by-default addresses, staking, the Bitcoin testnet4 wallet
  (`lwk_wollet::btc`), and the cross-chain HTLC glue (`lwk_wollet::btc::xchain`).
  SWK's own UniFFI bindings (`lwk_bindings`) build with that feature OFF and cannot
  reach these code paths, which is why Ambra has a dedicated core crate.
  It also embeds `seqln-signer` (from the
  [seqln](https://github.com/ConcatenaLabs/seqln) repo): the phone-side
  Lightning signing kernel + Noise_XK transport that keeps the LSP rail non-custodial.
- **`docs/SPEC.md`** is the product/design spec (custody contract, navigation, design
  tokens, core API surface).

Key implementation detail: the core API is intentionally stateless per call. Dart passes
the mnemonic into each operation; the core derives what it needs, signs, and returns.
Scanned wallet state persists to the app's data dir (set once at startup) so cold starts
resume instead of re-scanning.

## Building from source

Verified toolchain: Linux host, Rust (stable), Flutter with Dart SDK >= 3.12,
Android SDK with **NDK 29.0.14206865** (pinned in `app/android/app/build.gradle.kts`),
`cargo-ndk`, and flutter_rust_bridge_codegen 2.12.0 (only needed if you change the core
API).

`ambra_core` consumes SWK and seqln **by relative path**: both checkouts must sit as
siblings of the `ambra` repo (see `[patch.crates-io]` in `ambra_core/Cargo.toml`).

```sh
# 1. Sibling checkouts
git clone https://github.com/ConcatenaLabs/ambra.git
git clone -b sequentia https://github.com/ConcatenaLabs/SWK.git
git clone -b sequentia-stable https://github.com/ConcatenaLabs/seqln.git

# 2. Rust core (host build; also produces the cdylib the Flutter host tests load)
cd ambra/ambra_core
cargo build

# 3. Cross-compile the core for Android
rustup target add aarch64-linux-android
cargo install cargo-ndk
cargo ndk -t arm64-v8a -o ../app/android/app/src/main/jniLibs build --release

# 4. Build the app
cd ../app
flutter pub get
flutter build apk --release        # or: flutter run (device attached)
```

`app/android/app/src/main/jniLibs/` is gitignored; the `.so` is rebuilt on demand by
step 3. Release builds are signed with the Ambra release key when
`app/android/key.properties` (gitignored) is present; without it Gradle silently falls
back to the debug key, producing an APK that will not install over the published one
(`app/android/app/build.gradle.kts`).

If you change the `ambra_core::api` surface, regenerate the bridge from `app/`
(config in `app/flutter_rust_bridge.yaml`):

```sh
flutter_rust_bridge_codegen generate
```

## Tests

Rust core (from `ambra_core/`):

```sh
# Offline tests: architecture smoke test + Lightning signer conformance
# (a 99-frame corpus byte-compared against libhsmd's replies)
cargo test --test smoke --test signer_conformance

# Network tests (hit the live public testnet; run explicitly)
cargo test --test sync -- --nocapture
```

A bare `cargo test` runs the network tests too, so prefer the explicit forms offline.

Flutter (from `app/`):

```sh
flutter test test/lsp_client_test.dart        # pure-Dart, mocked HTTP, runs anywhere
flutter test                                  # all tests; see the caveat below
```

Caveat: `test/widget_test.dart` and `test/seqln_device_key_test.dart` drive the real
Rust core through flutter_rust_bridge on the host. They resolve the cdylib from
`$AMBRA_CORE_LIB`, defaulting to `../ambra_core/target/debug/libambra_core.so`
(relative to `app/`), so run `cargo build` in `ambra_core/` first or set the variable.

## Sequentia ecosystem

| Repo | One-liner |
|---|---|
| [Sequentia](https://github.com/ConcatenaLabs/Sequentia) | The Sequentia node (`sequentiad`, a fork of Elements 23.3.3): consensus, anchoring, proof of stake, open fee market, plus the canonical protocol documentation in `doc/sequentia/`. |
| [SWK](https://github.com/ConcatenaLabs/SWK) | Sequentia Wallet Kit: a fork of Blockstream LWK, providing the Rust wallet library, CLI, and WASM bindings for building Sequentia (and Bitcoin testnet4) wallets. |
| [sequentia-web-wallet](https://github.com/ConcatenaLabs/sequentia-web-wallet) | Proof-of-concept browser wallet built on SWK, live at https://sequentiatestnet.com/wallet. |
| [seqdex](https://github.com/ConcatenaLabs/seqdex) | SeqDEX: non-custodial atomic-swap DEX with an on-chain covenant order book (SeqOB) served over a relay, same-chain swaps, and cross-chain BTC↔asset swaps made safe by Bitcoin anchoring. |
| [seqln](https://github.com/ConcatenaLabs/seqln) | SeqLN: a Core Lightning fork that runs on Sequentia and Bitcoin from the same binary, with asset channels, any-asset payments, and pure-Lightning swaps. |
| [openamp](https://github.com/ConcatenaLabs/openamp) | OpenAMP: open-source restricted-asset issuance/transfer-approval service (an AMP2 equivalent) with opt-in confidentiality; zero consensus changes. |
| [fulmen](https://github.com/ConcatenaLabs/fulmen) | Fulmen: desktop (Electron) wallet for SeqLN with a bundled Lightning node. |
| [sequentia-extension](https://github.com/ConcatenaLabs/sequentia-extension) | Ambra for Chromium: the same dual-chain wallet as a browser extension, plus the `window.sequentia` API websites use to reach it. |

## Contributing

Development happens on `main`; open PRs against it. The Sequentia-specific logic worth
knowing before you start: `ambra_core/src/api/mod.rs` (the whole FFI surface),
`app/lib/src/data/config.dart` (endpoints + asset labels), and
`app/lib/src/screens/shell.dart` (the tab shell and balance model). Never commit
secrets: no real seeds, keys, or credentials belong in this public repo (test fixtures
use only the well-known all-zero BIP39 vector).

## License

MIT, in [LICENSE](LICENSE) and declared in `ambra_core/Cargo.toml`.
