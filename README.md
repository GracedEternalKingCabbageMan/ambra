# Ambra

A non-custodial mobile wallet for **Bitcoin and Sequentia** (Android + iOS), built in
**Flutter** over a shared **Rust core** (`ambra_core`) that wraps the
[SWK](https://github.com/aejkcs50/SWK) kit — a Sequentia fork of Blockstream's
Liquid Wallet Kit (LWK).

## Why a Rust core

The whole Sequentia send-flow — any-asset fees, RBF/CPFP rescue,
non-confidential-as-first-class funds, and staking — already exists in
`lwk_wollet` as pure, target-agnostic Rust, behind its `sequentia` cargo
feature. `ambra_core` turns that feature **on** and exposes exactly the API
Ambra needs to Dart via `flutter_rust_bridge`. (The kit's existing UniFFI
bindings, `lwk_bindings`, compile with the feature **off**, so they can't reach
those code paths — hence a dedicated core instead.)

## Consensus law (non-negotiable in the UX)

Bitcoin **anchoring is supreme**: Sequentia reorgs whenever Bitcoin reorgs away
a block's anchor — overriding immediate finality *and* checkpoints, with no
exception. A transaction's real safety depth is the **Bitcoin** confirmation
depth of its block's anchor, not its Sequentia block depth. The wallet must
never present Sequentia "finality" as stronger than a Bitcoin reorg.

## Layout

| Path         | What                                                            |
|--------------|----------------------------------------------------------------|
| `ambra_core` | Rust core: Sequentia wallet logic via SWK (`flutter_rust_bridge` surface). |
| `app`        | Flutter UI (added in a later milestone).                        |

## Status

Early scaffolding. Milestone 1: prove `ambra_core` drives the SWK fork with the
`sequentia` feature on (`cargo test -p ambra_core`).

### Build notes (local dev)

`ambra_core` currently consumes SWK by relative path (expects the `SWK` checkout
as a sibling of this repo's parent, i.e. `../SWK`) and replicates SWK's
`elements` → vendored `rust-elements` patch. This switches to a pinned git
dependency before CI. iOS builds require a macOS + Xcode machine; Android and
the core build on Linux.
