//! `flutter_rust_bridge` API surface for Ambra — the functions the Flutter
//! (Dart) UI calls. Keep signatures FFI-friendly (String / primitives /
//! `anyhow::Result`) and delegate the real work to the crate-root wallet logic.
//!
//! Generated Dart bindings land in `app/lib/src/rust/` via
//! `flutter_rust_bridge_codegen generate`.

use std::str::FromStr;

use anyhow::Result;
use lwk_common::Signer;
use lwk_signer::SwSigner;
use lwk_wollet::clients::blocking::{BlockchainBackend, EsploraClient};
use lwk_wollet::elements::pset::PartiallySignedTransaction;
use lwk_wollet::elements::{Address, AssetId};
use lwk_wollet::TxBuilder;

fn err(s: String) -> anyhow::Error {
    anyhow::Error::msg(s)
}

fn rerr<E: std::fmt::Debug>(e: E) -> anyhow::Error {
    anyhow::Error::msg(format!("{e:?}"))
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

/// A per-asset balance: the asset id (hex) and the amount in atoms (a string to
/// avoid any integer-precision loss across the FFI boundary).
pub struct AssetBalance {
    pub asset_id: String,
    pub atoms: String,
}

/// A snapshot of the wallet after a full scan against an esplora backend.
pub struct WalletSync {
    pub tip_height: u32,
    pub tip_hash: String,
    pub balances: Vec<AssetBalance>,
    pub next_index: u32,
}

/// Full-scan the wallet against `esplora_url`, apply the update, and return the
/// chain tip, per-asset balances, and the next unused receive index. Runs on an
/// FRB worker thread (off the UI thread).
pub fn sync_wallet(mnemonic: String, esplora_url: String) -> Result<WalletSync> {
    let descriptor = crate::descriptor_from_mnemonic(&mnemonic).map_err(err)?;
    let mut wollet = crate::build_wollet(&descriptor).map_err(err)?;
    let mut client = EsploraClient::new(&esplora_url, crate::sequentia_testnet())
        .map_err(|e| err(format!("{e:?}")))?;
    if let Some(update) = client.full_scan(&wollet).map_err(|e| err(format!("{e:?}")))? {
        wollet.apply_update(update).map_err(|e| err(format!("{e:?}")))?;
    }
    let tip = wollet.tip();
    let balances = wollet
        .balance()
        .map_err(|e| err(format!("{e:?}")))?
        .iter()
        .map(|(asset, atoms)| AssetBalance {
            asset_id: asset.to_string(),
            atoms: atoms.to_string(),
        })
        .collect();
    let next_index = wollet.address(None).map_err(|e| err(format!("{e:?}")))?.index();
    Ok(WalletSync {
        tip_height: tip.height(),
        tip_hash: tip.hash().to_string(),
        balances,
        next_index,
    })
}

/// A send recipient: who, which asset, how many atoms.
pub struct Recipient {
    pub address: String,
    pub asset_id: String,
    pub satoshi: u64,
}

/// Pay the fee in a non-native asset at the node's published rate.
pub struct FeeAsset {
    pub asset_id: String,
    pub rate: u64,
}

/// Validate a recipient address is a well-formed **Sequentia** address (rejects
/// foreign-network addresses).
pub fn validate_address(address: String) -> Result<()> {
    Address::parse_with_params(&address, crate::sequentia_testnet().address_params())
        .map(|_| ())
        .map_err(rerr)
}

/// Build an UNSIGNED send PSET (base64). Syncs first so the wallet has utxos.
/// `fee_asset` pays the fee in a non-native asset at the EXACT published rate
/// (never fabricated); `fee_rate_sat_kvb` None = builder default. RBF is on by
/// default (so a stuck tx can be bump/CPFP-rescued later).
pub fn build_send_tx(
    mnemonic: String,
    esplora_url: String,
    recipients: Vec<Recipient>,
    fee_rate_sat_kvb: Option<f32>,
    fee_asset: Option<FeeAsset>,
) -> Result<String> {
    let descriptor = crate::descriptor_from_mnemonic(&mnemonic).map_err(err)?;
    let mut wollet = crate::build_wollet(&descriptor).map_err(err)?;
    let mut client = EsploraClient::new(&esplora_url, crate::sequentia_testnet()).map_err(rerr)?;
    if let Some(update) = client.full_scan(&wollet).map_err(rerr)? {
        wollet.apply_update(update).map_err(rerr)?;
    }
    // Parse recipients with the SEQUENTIA address params so foreign-network
    // addresses (Liquid ex1/lq1, Elements ert1, …) are REJECTED — `from_str`
    // would happily accept them and we'd broadcast funds to an unrecoverable
    // foreign script.
    let params = crate::sequentia_testnet().address_params();
    let mut b = TxBuilder::new(crate::sequentia_testnet());
    for r in &recipients {
        let address = Address::parse_with_params(&r.address, params).map_err(rerr)?;
        let asset = AssetId::from_str(&r.asset_id).map_err(rerr)?;
        // Sequentia defaults to explicit (tb1) recipients; confidential (tsqb1)
        // go through the blinded path.
        b = if address.blinding_pubkey.is_some() {
            b.add_recipient(&address, r.satoshi, asset).map_err(rerr)?
        } else {
            b.add_explicit_recipient(&address, r.satoshi, asset).map_err(rerr)?
        };
    }
    if let Some(fr) = fee_rate_sat_kvb {
        b = b.fee_rate(Some(fr));
    }
    if let Some(fa) = &fee_asset {
        b = b.fee_asset(AssetId::from_str(&fa.asset_id).map_err(rerr)?, fa.rate);
    }
    let pset = b.finish(&wollet).map_err(rerr)?;
    Ok(pset.to_string())
}

/// Sign a PSET with the software signer (mnemonic read transiently, never
/// cached). Returns the signed PSET as base64.
pub fn sign_pset(mnemonic: String, pset: String) -> Result<String> {
    let signer = SwSigner::new(&mnemonic, false).map_err(rerr)?;
    let mut p = PartiallySignedTransaction::from_str(&pset).map_err(rerr)?;
    signer.sign(&mut p).map_err(rerr)?;
    Ok(p.to_string())
}

/// Finalize a signed PSET into a transaction and broadcast it. Returns the txid.
pub fn finalize_and_broadcast(mnemonic: String, esplora_url: String, pset: String) -> Result<String> {
    let descriptor = crate::descriptor_from_mnemonic(&mnemonic).map_err(err)?;
    let wollet = crate::build_wollet(&descriptor).map_err(err)?;
    let mut p = PartiallySignedTransaction::from_str(&pset).map_err(rerr)?;
    let tx = wollet.finalize(&mut p).map_err(rerr)?;
    let client = EsploraClient::new(&esplora_url, crate::sequentia_testnet()).map_err(rerr)?;
    let txid = client.broadcast(&tx).map_err(rerr)?;
    Ok(txid.to_string())
}

/// A signed per-asset delta on a transaction (atoms as a string; may be negative).
pub struct AssetDelta {
    pub asset_id: String,
    pub atoms: String,
}

/// A wallet transaction history row.
pub struct TxRow {
    pub txid: String,
    pub height: Option<u32>,
    pub timestamp: Option<u64>,
    /// "incoming" | "outgoing" | "issuance" | "reissuance" | "burn" | "redeposit" | "unknown".
    pub kind: String,
    pub fee: u64,
    pub deltas: Vec<AssetDelta>,
}

/// Sync and return the wallet's transaction history (net signed per-asset deltas
/// per tx). Ordering is left to the UI.
pub fn wallet_transactions(mnemonic: String, esplora_url: String) -> Result<Vec<TxRow>> {
    let descriptor = crate::descriptor_from_mnemonic(&mnemonic).map_err(err)?;
    let mut wollet = crate::build_wollet(&descriptor).map_err(err)?;
    let mut client = EsploraClient::new(&esplora_url, crate::sequentia_testnet()).map_err(rerr)?;
    if let Some(update) = client.full_scan(&wollet).map_err(rerr)? {
        wollet.apply_update(update).map_err(rerr)?;
    }
    let rows = wollet
        .transactions()
        .map_err(rerr)?
        .into_iter()
        .map(|t| TxRow {
            txid: t.txid.to_string(),
            height: t.height,
            timestamp: t.timestamp.map(|ts| ts as u64),
            kind: t.type_,
            fee: t.fee,
            deltas: t
                .balance
                .iter()
                .map(|(a, v)| AssetDelta {
                    asset_id: a.to_string(),
                    atoms: v.to_string(),
                })
                .collect(),
        })
        .collect();
    Ok(rows)
}
