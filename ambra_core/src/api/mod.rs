//! `flutter_rust_bridge` API surface for Ambra — the functions the Flutter
//! (Dart) UI calls. Keep signatures FFI-friendly (String / primitives /
//! `anyhow::Result`) and delegate the real work to the crate-root wallet logic.
//!
//! Generated Dart bindings land in `app/lib/src/rust/` via
//! `flutter_rust_bridge_codegen generate`.

use anyhow::Result;

fn err(s: String) -> anyhow::Error {
    anyhow::Error::msg(s)
}

/// The active Sequentia network's identifier, e.g. `"sequentia-testnet"`.
#[flutter_rust_bridge::frb(sync)]
pub fn network_name() -> String {
    crate::sequentia_testnet().as_str().to_string()
}

/// Generate a fresh 12-word BIP39 recovery phrase.
pub fn generate_mnemonic() -> Result<String> {
    crate::generate_mnemonic().map_err(err)
}

/// The default (non-confidential, Bitcoin-format `tb1…`) receive address for a
/// recovery phrase, at index 0. The same address also receives on Bitcoin
/// testnet4 — one address, both chains.
pub fn receive_address(mnemonic: String) -> Result<String> {
    let descriptor = crate::descriptor_from_mnemonic(&mnemonic).map_err(err)?;
    let wollet = crate::build_wollet(&descriptor).map_err(err)?;
    crate::receive_address(&wollet, 0).map_err(err)
}

/// The opt-in confidential ("private", blech32 `tsqb…`) receive address at
/// index 0. NOT Bitcoin-compatible (it embeds a blinding key).
pub fn confidential_receive_address(mnemonic: String) -> Result<String> {
    let descriptor = crate::descriptor_from_mnemonic(&mnemonic).map_err(err)?;
    let wollet = crate::build_wollet(&descriptor).map_err(err)?;
    crate::confidential_receive_address(&wollet, 0).map_err(err)
}

/// The wallet's CT output descriptor for a recovery phrase.
pub fn descriptor_from_mnemonic(mnemonic: String) -> Result<String> {
    crate::descriptor_from_mnemonic(&mnemonic).map_err(err)
}

/// A receive address together with the derivation index it came from.
pub struct AddressInfo {
    pub address: String,
    pub index: u32,
}

/// Validate a BIP39 recovery phrase (import flow). Throws on an invalid phrase.
pub fn validate_mnemonic(mnemonic: String) -> Result<()> {
    crate::validate_mnemonic(&mnemonic).map_err(err)
}

/// Receive address at `index`: non-confidential `tb1…` (default) or the opt-in
/// confidential `tsqb…` form. Returns the address + the index it used.
pub fn receive_address_at(mnemonic: String, index: u32, confidential: bool) -> Result<AddressInfo> {
    let address = crate::receive_address_at(&mnemonic, index, confidential).map_err(err)?;
    Ok(AddressInfo { address, index })
}
