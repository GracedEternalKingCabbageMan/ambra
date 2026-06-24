//! `ambra_core` — the shared Rust core for **Ambra**, a non-custodial Sequentia
//! wallet for Android + iOS.
//!
//! It is built on **SWK** (a Sequentia fork of Blockstream LWK) with the
//! `sequentia` feature enabled, so the full Sequentia send-flow — any-asset
//! fees, RBF/CPFP rescue, non-confidential-as-first-class funds, staking — is
//! reachable. The Flutter UI talks to this crate via `flutter_rust_bridge`
//! (wired in a later milestone); for now the functions below are the seed of
//! that API surface and are exercised directly by the smoke test.
//!
//! CONSENSUS LAW (must never be contradicted by the UX layered on top): Bitcoin
//! anchoring is supreme — Sequentia reorgs whenever Bitcoin reorgs away a
//! block's anchor, overriding immediate finality and checkpoints. A tx's real
//! safety depth is the *Bitcoin* confirmation depth of its block's anchor, not
//! its Sequentia block depth.

/// flutter_rust_bridge API surface consumed by the Flutter (Dart) app.
pub mod api;
mod frb_generated;

use std::str::FromStr;

use lwk_common::{singlesig_desc, DescriptorBlindingKey, Singlesig};
use lwk_signer::SwSigner;
use lwk_wollet::{Network, Wollet, WolletBuilder, WolletDescriptor};

/// Errors surfaced across the core API (kept as strings for an easy FFI mapping
/// until the FRB layer introduces a typed error enum).
pub type AmbraResult<T> = Result<T, String>;

/// The Sequentia testnet network handle (policy asset, genesis, address params).
pub fn sequentia_testnet() -> Network {
    Network::sequentia_testnet()
}

/// Generate a fresh 12-word BIP39 recovery phrase (testnet).
pub fn generate_mnemonic() -> AmbraResult<String> {
    let (_signer, mnemonic) = SwSigner::random(false).map_err(|e| format!("{e:?}"))?;
    Ok(mnemonic.to_string())
}

/// Derive Ambra's standard Sequentia receive descriptor from a BIP39 mnemonic:
/// a single-sig native-segwit (wpkh) CT descriptor with a SLIP-77 blinding key.
/// On Sequentia testnet this yields non-confidential, Bitcoin-format `tb1…`
/// receive addresses (confidentiality is opt-in).
pub fn descriptor_from_mnemonic(mnemonic: &str) -> AmbraResult<String> {
    let signer = SwSigner::new(mnemonic, /* is_mainnet */ false).map_err(|e| format!("{e:?}"))?;
    singlesig_desc(&signer, Singlesig::Wpkh, DescriptorBlindingKey::Slip77)
}

/// Build a watch-only wallet for `descriptor` on Sequentia testnet. Holds no
/// keys; blockchain data enters later via `apply_update`.
pub fn build_wollet(descriptor: &str) -> AmbraResult<Wollet> {
    let desc = WolletDescriptor::from_str(descriptor).map_err(|e| format!("{e:?}"))?;
    WolletBuilder::new(sequentia_testnet(), desc)
        .build()
        .map_err(|e| format!("{e:?}"))
}

/// Derive the **default (non-confidential)** receive address at `index` — a
/// Bitcoin-format `tb1…` address. Sequentia defaults to transparent addresses
/// (confidentiality is opt-in), so even though the wallet uses a confidential
/// (`ct`) descriptor we hand back the *unblinded* form for the default receive
/// flow. The same key/script also receives on Bitcoin testnet4 — one address,
/// both chains.
pub fn receive_address(wollet: &Wollet, index: u32) -> AmbraResult<String> {
    let res = wollet.address(Some(index)).map_err(|e| format!("{e:?}"))?;
    Ok(res.address().to_unconfidential().to_string())
}

/// Derive the **confidential** ("private") receive address at `index` — a
/// blech32 `tsqb…` address that hides amount and asset. This is the opt-in
/// privacy path and is NOT Bitcoin-compatible (it embeds a blinding key).
pub fn confidential_receive_address(wollet: &Wollet, index: u32) -> AmbraResult<String> {
    let res = wollet.address(Some(index)).map_err(|e| format!("{e:?}"))?;
    Ok(res.address().to_string())
}
