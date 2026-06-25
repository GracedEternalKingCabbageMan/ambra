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
use lwk_wollet::clients::EsploraClientBuilder;
use lwk_wollet::elements::pset::PartiallySignedTransaction;
use lwk_wollet::bitcoin::bip32::{ChildNumber, DerivationPath};
use lwk_wollet::elements::{Address, AssetId, Txid};
use lwk_wollet::secp256k1::PublicKey;
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

/// Point wallet persistence at the app's writable directory. Call once at
/// startup, before any sync, so cold starts resume scanned state from disk
/// instead of re-scanning the whole wallet.
#[flutter_rust_bridge::frb(sync)]
pub fn set_data_dir(path: String) {
    crate::set_data_dir(path);
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
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let tip = wollet.tip();
        let balances = wollet
            .balance()
            .map_err(rerr)?
            .iter()
            .map(|(asset, atoms)| AssetBalance {
                asset_id: asset.to_string(),
                atoms: atoms.to_string(),
            })
            .collect();
        let next_index = wollet.address(None).map_err(rerr)?.index();
        Ok(WalletSync {
            tip_height: tip.height(),
            tip_hash: tip.hash().to_string(),
            balances,
            next_index,
        })
    })
}

/// A send recipient: who, which asset, how many atoms.
pub struct Recipient {
    pub address: String,
    pub asset_id: String,
    pub satoshi: u64,
}

/// Pay the fee in any accepted asset at the node's published rate.
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
/// `fee_asset` pays the fee in any accepted asset at the EXACT published rate
/// (never fabricated); `fee_rate_sat_kvb` None = builder default. RBF is on by
/// default (so a stuck tx can be bump/CPFP-rescued later).
pub fn build_send_tx(
    mnemonic: String,
    esplora_url: String,
    recipients: Vec<Recipient>,
    fee_rate_sat_kvb: Option<f32>,
    fee_asset: Option<FeeAsset>,
) -> Result<String> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        // Parse recipients with the SEQUENTIA address params so foreign-network
        // addresses (Liquid ex1/lq1, Elements ert1, …) are REJECTED; `from_str`
        // would happily accept them and we'd broadcast funds to an unrecoverable
        // foreign script.
        let params = crate::sequentia_testnet().address_params();
        let mut b = TxBuilder::new(crate::sequentia_testnet());
        for r in &recipients {
            let address = Address::parse_with_params(&r.address, params).map_err(rerr)?;
            let asset = AssetId::from_str(&r.asset_id).map_err(rerr)?;
            // Sequentia defaults to explicit (tb1) recipients; confidential
            // (tsqb1) go through the blinded path.
            b = if address.blinding_pubkey.is_some() {
                b.add_recipient(&address, r.satoshi, asset).map_err(rerr)?
            } else {
                b.add_explicit_recipient(&address, r.satoshi, asset).map_err(rerr)?
            };
        }
        apply_fee_and_finish(b, wollet, fee_rate_sat_kvb, fee_asset.as_ref())
    })
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
    let client = esplora_client(&esplora_url).map_err(rerr)?;
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
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
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
    })
}

// --- M6: RBF / CPFP rescue (cross-asset, RBF on by default) -----------------

/// Process-lifetime wallet cache, keyed by descriptor. Keeping the scanned
/// `Wollet` between calls is the whole performance story: lwk's `full_scan` is
/// INCREMENTAL when the wallet already holds state, so a cached wallet syncs only
/// new data instead of re-scanning every address from scratch on every balance
/// refresh, tab switch, history view, and build. `Wollet` is not `Clone`, so
/// operations run against the cached wallet under the lock via
/// [`with_synced_wollet`].
fn wollet_cache() -> &'static std::sync::Mutex<std::collections::HashMap<String, lwk_wollet::Wollet>> {
    static CACHE: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, lwk_wollet::Wollet>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

/// A blocking Esplora client with a 30s request timeout, so a hung connection
/// errors out instead of holding the shared wallet lock indefinitely.
fn esplora_client(url: &str) -> std::result::Result<EsploraClient, lwk_wollet::Error> {
    EsploraClientBuilder::new(url, crate::sequentia_testnet())
        .timeout(30)
        .build_blocking()
}

/// Sync the cached wallet (incrementally) and run `f` against it. All blockchain
/// reads/builds go through here so they share one persistent, incrementally
/// scanned wallet per descriptor.
fn with_synced_wollet<T>(
    mnemonic: &str,
    esplora_url: &str,
    f: impl FnOnce(&lwk_wollet::Wollet) -> Result<T>,
) -> Result<T> {
    let descriptor = crate::descriptor_from_mnemonic(mnemonic).map_err(err)?;
    let mut guard = wollet_cache()
        .lock()
        .map_err(|e| err(format!("wallet cache lock: {e}")))?;
    if !guard.contains_key(&descriptor) {
        let w = crate::build_wollet(&descriptor).map_err(err)?;
        guard.insert(descriptor.clone(), w);
    }
    let wollet = guard.get_mut(&descriptor).expect("just inserted");
    let mut client = esplora_client(esplora_url).map_err(rerr)?;
    if let Some(update) = client.full_scan(&*wollet).map_err(rerr)? {
        wollet.apply_update(update).map_err(rerr)?;
    }
    f(&*wollet)
}

/// Forget any cached wallet state (called when the wallet is removed).
pub fn clear_wallet_cache() {
    if let Ok(mut guard) = wollet_cache().lock() {
        guard.clear();
    }
}

/// Default fee rate (2 sat/vB) for any tx that does not set its own. The lwk
/// builder default is 0.1 sat/vB, which is below the network min-relay, so every
/// build path here applies at least this.
const DEFAULT_FEERATE_SAT_KVB: f32 = 2000.0;

/// Chain a fee rate (defaulted when absent) + optional any-asset fee onto a
/// builder, finish.
fn apply_fee_and_finish(
    mut b: TxBuilder,
    wollet: &lwk_wollet::Wollet,
    fee_rate_sat_kvb: Option<f32>,
    fee_asset: Option<&FeeAsset>,
) -> Result<String> {
    b = b.fee_rate(Some(fee_rate_sat_kvb.unwrap_or(DEFAULT_FEERATE_SAT_KVB)));
    if let Some(fa) = fee_asset {
        b = b.fee_asset(AssetId::from_str(&fa.asset_id).map_err(rerr)?, fa.rate);
    }
    Ok(b.finish(wollet).map_err(rerr)?.to_string())
}

/// RBF fee-bump: re-send the SAME payment at a higher fee (optionally in another
/// asset). The replacement's reference (rfa) fee must exceed the original's.
pub fn build_rbf_bump_tx(
    mnemonic: String,
    esplora_url: String,
    txid: String,
    fee_rate_sat_kvb: f32,
    fee_asset: Option<FeeAsset>,
) -> Result<String> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let b = wollet.bump_fee_of(Txid::from_str(&txid).map_err(rerr)?).map_err(rerr)?;
        apply_fee_and_finish(b, wollet, Some(fee_rate_sat_kvb), fee_asset.as_ref())
    })
}

/// RBF replace: same inputs, brand-new recipients — to correct a still-pending
/// payment's address/asset/amount.
pub fn build_rbf_replace_tx(
    mnemonic: String,
    esplora_url: String,
    txid: String,
    new_recipients: Vec<Recipient>,
    fee_rate_sat_kvb: f32,
    fee_asset: Option<FeeAsset>,
) -> Result<String> {
    if new_recipients.is_empty() {
        return Err(err("a replacement needs at least one recipient".to_string()));
    }
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let mut b = wollet.replace_tx_of(Txid::from_str(&txid).map_err(rerr)?).map_err(rerr)?;
        let params = crate::sequentia_testnet().address_params();
        for r in &new_recipients {
            let address = Address::parse_with_params(&r.address, params).map_err(rerr)?;
            let asset = AssetId::from_str(&r.asset_id).map_err(rerr)?;
            b = if address.blinding_pubkey.is_some() {
                b.add_recipient(&address, r.satoshi, asset).map_err(rerr)?
            } else {
                b.add_explicit_recipient(&address, r.satoshi, asset).map_err(rerr)?
            };
        }
        apply_fee_and_finish(b, wollet, Some(fee_rate_sat_kvb), fee_asset.as_ref())
    })
}

/// CPFP: a child that spends the parent's unconfirmed wallet output and pays a
/// high fee (in any accepted asset) to lift the {parent, child} package.
pub fn build_cpfp_tx(
    mnemonic: String,
    esplora_url: String,
    parent_txid: String,
    fee_rate_sat_kvb: f32,
    fee_asset: Option<FeeAsset>,
) -> Result<String> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let b = wollet.cpfp_of(Txid::from_str(&parent_txid).map_err(rerr)?).map_err(rerr)?;
        apply_fee_and_finish(b, wollet, Some(fee_rate_sat_kvb), fee_asset.as_ref())
    })
}

/// A conservative child fee rate (sat/kvb) that lifts the {parent, child}
/// package to `target_feerate`.
pub fn cpfp_suggested_feerate(
    mnemonic: String,
    esplora_url: String,
    parent_txid: String,
    target_feerate: f32,
) -> Result<f32> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        wollet
            .cpfp_suggested_feerate(Txid::from_str(&parent_txid).map_err(rerr)?, target_feerate)
            .map_err(rerr)
    })
}

// --- M7: asset issuance / reissue / burn + staking --------------------------

/// Issue a brand-new asset: mint `asset_sats` of it plus `token_sats` reissuance
/// tokens, both to this wallet. The new asset's id appears after the tx
/// confirms and the wallet re-syncs.
pub fn build_issue_tx(
    mnemonic: String,
    esplora_url: String,
    asset_sats: u64,
    token_sats: u64,
    fee_rate_sat_kvb: Option<f32>,
) -> Result<String> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let b = TxBuilder::new(crate::sequentia_testnet())
            .issue_asset(asset_sats, None, token_sats, None, None)
            .map_err(rerr)?;
        apply_fee_and_finish(b, wollet, fee_rate_sat_kvb, None)
    })
}

/// Reissue more of an existing asset (needs its reissuance token in this wallet).
pub fn build_reissue_tx(
    mnemonic: String,
    esplora_url: String,
    asset_id: String,
    satoshi: u64,
    fee_rate_sat_kvb: Option<f32>,
) -> Result<String> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let asset = AssetId::from_str(&asset_id).map_err(rerr)?;
        let b = TxBuilder::new(crate::sequentia_testnet())
            .reissue_asset(asset, satoshi, None, None)
            .map_err(rerr)?;
        apply_fee_and_finish(b, wollet, fee_rate_sat_kvb, None)
    })
}

/// Permanently destroy `satoshi` atoms of an asset.
pub fn build_burn_tx(
    mnemonic: String,
    esplora_url: String,
    asset_id: String,
    satoshi: u64,
    fee_rate_sat_kvb: Option<f32>,
) -> Result<String> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let asset = AssetId::from_str(&asset_id).map_err(rerr)?;
        let b = TxBuilder::new(crate::sequentia_testnet())
            .add_burn(satoshi, asset)
            .map_err(rerr)?;
        apply_fee_and_finish(b, wollet, fee_rate_sat_kvb, None)
    })
}

/// The 33-byte staker public key (compressed hex) at m/2/0 — the key a stake is
/// bonded to (the wallet controls the matching private key to later unbond).
pub fn staker_public_key(mnemonic: String) -> Result<String> {
    let signer = SwSigner::new(&mnemonic, false).map_err(rerr)?;
    let path = DerivationPath::from(vec![
        ChildNumber::Normal { index: 2 },
        ChildNumber::Normal { index: 0 },
    ]);
    let xpub = signer.derive_xpub(&path).map_err(rerr)?;
    Ok(xpub.public_key.to_string())
}

/// Minimum blocksigner stake: 40,000 tSEQ (0.01% of supply), 8 decimals.
const MIN_STAKE_ATOMS: u64 = 4_000_000_000_000;

/// Bond `satoshi` atoms of tSEQ into the canonical CSV-locked staking script for
/// `staker_pubkey` (33-byte hex). Enforces the 40,000-tSEQ minimum. The output
/// is non-confidential (only explicit stake confers weight).
pub fn build_stake_tx(
    mnemonic: String,
    esplora_url: String,
    staker_pubkey: String,
    csv: u32,
    satoshi: u64,
    fee_rate_sat_kvb: Option<f32>,
) -> Result<String> {
    if satoshi < MIN_STAKE_ATOMS {
        return Err(err("minimum stake is 40,000 tSEQ".to_string()));
    }
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let pubkey = PublicKey::from_str(&staker_pubkey).map_err(rerr)?.serialize();
        let b = TxBuilder::new(crate::sequentia_testnet()).add_stake_output(&pubkey, csv, satoshi);
        apply_fee_and_finish(b, wollet, fee_rate_sat_kvb, None)
    })
}
