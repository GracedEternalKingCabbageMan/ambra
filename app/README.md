# app/: the Ambra Flutter application

The Flutter UI of Ambra, the non-custodial dual-chain (Bitcoin testnet4 + Sequentia)
mobile wallet. Build prerequisites, the Android cross-compile of the Rust core, and the
full feature list live in the [repo README](../README.md); the product/design spec is
[docs/SPEC.md](../docs/SPEC.md). This file is a map of the Dart code.

The app talks to the `ambra_core` Rust crate over flutter_rust_bridge (generated
bindings in `lib/src/rust/`, codegen config in `flutter_rust_bridge.yaml`, both pinned
to FRB 2.12.0). All key handling, derivation, signing, transaction building, and chain
scanning happen in the core; the Dart layer owns UI state, secure storage of the
mnemonic, and the plain-HTTP sidecar services.

## Layout (`lib/`)

| Path | What |
|---|---|
| `main.dart` | Startup (core init, data dir, node/prices/registry load) + root routing: boot, onboarding, lock, shell. |
| `src/screens/shell.dart` | The tab shell: Balance, Send, Receive, Swap, History, More (plus the Balance/Receive/More tab bodies). |
| `src/screens/` | The remaining screens: onboarding, lock, send, scan (QR), history, rescue (RBF/CPFP), swap, xchain_swap, lightning_swap, assets, stake, faucet, node. |
| `src/data/` | Services and state: `wallet_repository.dart` (mnemonic in secure storage + opt-in app lock), `config.dart` (backend endpoints + asset labels), `wallet_cache.dart` (instant-launch cache), price/registry/faucet clients, SeqDEX + cross-chain swap clients, OpenAMP service, LSP client + `seqln_signer.dart` (on-device Lightning signer transport). |
| `src/rust/` | Generated flutter_rust_bridge bindings (do not edit; regenerate with `flutter_rust_bridge_codegen generate`). |
| `src/theme/`, `src/widgets/` | Design tokens and the shared component set from the spec. |

## Run and test

```sh
flutter pub get
flutter run                    # needs the Android .so built first (see repo README)
flutter test test/lsp_client_test.dart   # pure-Dart test, runs anywhere
```

The other two tests (`widget_test.dart`, `seqln_device_key_test.dart`) load the
host-built `ambra_core` cdylib via a hardcoded absolute path; build it with `cargo build`
in `../ambra_core` and adjust `_hostLib` to your checkout before running them.
