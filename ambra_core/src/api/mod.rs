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
use lwk_wollet::bitcoin::hex::FromHex;
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

/// Set the `Authorization` header for a node behind HTTP auth (a bearer token or
/// basic-auth credentials). Pass an empty string to clear it. Applied to every
/// Esplora request; call whenever the node or its credentials change.
#[flutter_rust_bridge::frb(sync)]
pub fn set_auth_header(value: String) {
    crate::set_auth_header(value);
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

// --- Bitcoin parent-chain (testnet4) wallet -----------------------------------

/// Result of scanning the Bitcoin keychain: the balance (sats, as a string for
/// FFI precision-safety) plus the next-unused indices for cross-chain address
/// cycling (the shared receive address advances past use on EITHER chain).
pub struct BtcBalance {
    pub balance_sats: String,
    pub external_next: u32,
    pub change_next: u32,
}

/// A built + signed (not yet broadcast) Bitcoin transaction, for the review step.
pub struct BtcTx {
    pub hex: String,
    pub txid: String,
    pub fee_sats: String,
    pub vsize: u64,
    pub inputs: u32,
}

/// Scan the wallet's Bitcoin (testnet4) keychain; returns the balance and the
/// cycling indices. `t4_api` is the testnet4 esplora base (e.g. `<node>/testnet4/api`).
pub fn btc_sync(mnemonic: String, t4_api: String) -> Result<BtcBalance> {
    let s = crate::btc::scan(&mnemonic, &t4_api).map_err(err)?;
    Ok(BtcBalance {
        balance_sats: s.balance_sats.to_string(),
        external_next: s.external_next,
        change_next: s.change_next,
    })
}

/// Build + sign (but DON'T broadcast) a Bitcoin testnet4 payment of `amount_sats`
/// to `address`, at `fee_rate` sat/vB. Show the returned fee/vsize for review,
/// then [`btc_broadcast`] the hex to send.
pub fn btc_prepare(
    mnemonic: String,
    t4_api: String,
    address: String,
    amount_sats: u64,
    fee_rate: f64,
) -> Result<BtcTx> {
    let p = crate::btc::prepare(&mnemonic, &t4_api, &address, amount_sats, fee_rate).map_err(err)?;
    Ok(BtcTx { hex: p.hex, txid: p.txid, fee_sats: p.fee_sats.to_string(), vsize: p.vsize, inputs: p.inputs })
}

/// Broadcast a prepared Bitcoin testnet4 transaction hex; returns the txid.
pub fn btc_broadcast(t4_api: String, tx_hex: String) -> Result<String> {
    crate::btc::broadcast(&t4_api, &tx_hex).map_err(err)
}

// --- SeqDEX same-chain atomic swap --------------------------------------------

/// The taker half of a same-chain swap: the random swap id + the SwapRequest JSON
/// to POST to the daemon's /v1/trade/propose.
pub struct SeqdexSwapRequestOut {
    pub id: String,
    pub swap_request_json: String,
}

/// Build the taker (proposer) half of a SeqDEX same-chain swap. `asset_*` are
/// display hex; amounts are atoms. The fee folds into the funded `asset_p` leg
/// when `fee_asset == asset_p`. Returns the swap id + the SwapRequest JSON to
/// hand to the daemon's ProposeTrade.
#[allow(clippy::too_many_arguments)]
pub fn seqdex_build_swap_request(
    mnemonic: String,
    esplora_url: String,
    asset_p: String,
    amount_p: u64,
    asset_r: String,
    amount_r: u64,
    fee_asset: String,
    fee_amount: u64,
) -> Result<SeqdexSwapRequestOut> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let opts = lwk_wollet::SeqdexSwapRequestOpts {
            asset_p: AssetId::from_str(&asset_p).map_err(rerr)?,
            amount_p,
            asset_r: AssetId::from_str(&asset_r).map_err(rerr)?,
            amount_r,
            // seqdex_swap_request needs the CONFIDENTIAL address: the maker blinds
            // the receive + change outputs to its blinding key (else NotConfidentialAddress).
            receive_address: wollet.address(None).map_err(rerr)?.address().clone(),
            fee_asset: AssetId::from_str(&fee_asset).map_err(rerr)?,
            fee_amount,
        };
        let req = wollet.seqdex_swap_request(&opts).map_err(rerr)?;
        let swap_request_json = crate::seqdex::swap_request_json(&req).map_err(err)?;
        Ok(SeqdexSwapRequestOut { id: req.id, swap_request_json })
    })
}

/// Sign the maker's SwapAccept PSET (base64) and return the stripped, signed PSET
/// (base64) for /v1/trade/complete. Runs through the synced wallet so add_details
/// can recognise the taker's own input by its scriptPubKey (else it's skipped and
/// left unsigned). The maker's signatures on its inputs are preserved.
pub fn seqdex_sign_accept(mnemonic: String, esplora_url: String, accept_pset: String) -> Result<String> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let mut pset = PartiallySignedTransaction::from_str(&accept_pset).map_err(rerr)?;
        // The bare swap PSET carries no bip32 derivation; re-attach the taker
        // input's keypath from the wallet descriptor so the signer can sign it.
        wollet.add_details(&mut pset).map_err(rerr)?;
        let signer = SwSigner::new(&mnemonic, false).map_err(rerr)?;
        signer.sign(&mut pset).map_err(rerr)?;
        // The daemon's go-elements parser rejects the elements-rs bip32/xpub fields;
        // strip them (the partial signatures stay) before CompleteTrade.
        crate::seqdex::strip_bip32(&pset.to_string()).map_err(err)
    })
}

// --- SeqDEX cross-chain (BTC <-> SEQ asset) HTLC swap -------------------------
//
// The wallet is Alice (holds BTC, wants the SEQ asset). She funds the BTC HTLC
// (reusing btc_prepare/btc_broadcast to the P2SH address), proposes to the
// daemon, verifies the SEQ leg is anchor-safe, then claims it revealing the
// preimage. See crate::xchain for the reveal-gate rationale.

fn hexbytes(s: &str) -> Result<Vec<u8>> {
    Vec::<u8>::from_hex(s).map_err(rerr)
}

/// A fresh swap preimage + its SHA256 hashlock. `secret_hex` is NOT HD-derivable;
/// the caller MUST persist it before locking any BTC.
pub struct XchainSecret {
    pub secret_hex: String,
    pub hash_hex: String,
}

/// The BTC HTLC the wallet funds: the redeemScript + its bare-P2SH address/spk.
pub struct BtcHtlcInfo {
    pub redeem_script_hex: String,
    pub p2sh_address: String,
    pub p2sh_spk_hex: String,
}

/// A located BTC HTLC funding output (value as a string for FFI precision).
pub struct BtcFunding {
    pub vout: u32,
    pub value_sats: String,
    pub height: i64,
    pub confirmations: i64,
}

/// The reveal-gate verdict + the evidence behind it (all from the wallet's own
/// nodes). `ok` true means it is safe to reveal the preimage.
pub struct AnchorEvidence {
    pub seq_anchor_height: i64,
    pub btc_leg_height: i64,
    pub btc_tip: i64,
    pub anchor_status: String,
    pub depth: i64,
    pub ok: bool,
}

/// Generate the swap preimage + hashlock.
pub fn xchain_new_secret() -> XchainSecret {
    let (secret_hex, hash_hex) = crate::xchain::new_secret();
    XchainSecret { secret_hex, hash_hex }
}

/// Alice's SEQ-leg claim pubkey (the HTLC claim key; secret stays in the core).
pub fn xchain_seq_claim_pubkey(mnemonic: String) -> Result<String> {
    crate::xchain::seq_claim_keypair(&mnemonic).map(|(_, p)| p).map_err(err)
}

/// Alice's BTC-leg refund pubkey.
pub fn xchain_btc_refund_pubkey(mnemonic: String) -> Result<String> {
    crate::xchain::btc_refund_keypair(&mnemonic).map(|(_, p)| p).map_err(err)
}

/// Build the BTC HTLC the wallet will fund: redeemScript + P2SH address/spk.
pub fn xchain_btc_htlc(
    hash_hex: String,
    claim_pub_hex: String,
    refund_pub_hex: String,
    locktime: u32,
) -> Result<BtcHtlcInfo> {
    let redeem = crate::btc_htlc::build_htlc_redeem_script(
        &hexbytes(&hash_hex)?,
        &hexbytes(&claim_pub_hex)?,
        &hexbytes(&refund_pub_hex)?,
        locktime,
    )
    .map_err(err)?;
    let (address, spk) = crate::btc_htlc::htlc_p2sh(&redeem).map_err(err)?;
    Ok(BtcHtlcInfo {
        redeem_script_hex: redeem.to_hex_string(),
        p2sh_address: address.to_string(),
        p2sh_spk_hex: spk.to_hex_string(),
    })
}

/// The SEQ-leg redeemScript Alice rebuilds, as hex — compare it to the daemon's
/// reported `seqLeg.redeemScript` (value-binding) before trusting the leg.
pub fn xchain_seq_redeem_script(
    mnemonic: String,
    hash_hex: String,
    maker_seq_refund_pub_hex: String,
    seq_locktime: u32,
) -> Result<String> {
    crate::xchain::seq_redeem_script_hex(&mnemonic, &hash_hex, &maker_seq_refund_pub_hex, seq_locktime).map_err(err)
}

/// Locate the BTC HTLC funding output by its P2SH scriptPubKey on testnet4.
pub fn xchain_find_btc_funding(t4_api: String, txid: String, p2sh_spk_hex: String) -> Result<BtcFunding> {
    let f = crate::btc::find_htlc_funding(&t4_api, &txid, &p2sh_spk_hex).map_err(err)?;
    Ok(BtcFunding {
        vout: f.vout,
        value_sats: f.value_sats.to_string(),
        height: f.height,
        confirmations: f.confirmations,
    })
}

/// THE REVEAL GATE. ok == true means it is safe to broadcast the SEQ claim:
/// the SEQ leg's Bitcoin anchor >= the BTC funding height, anchorstatus "ok",
/// and the anchor is >= `min_depth` Bitcoin-confs deep (default D = 1).
pub fn xchain_verify_seq_leg_safe(
    seq_esplora: String,
    seq_block_hash: String,
    btc_leg_height: i64,
    t4_api: String,
    min_depth: i64,
) -> Result<AnchorEvidence> {
    let e = crate::xchain::verify_seq_leg_safe(&seq_esplora, &seq_block_hash, btc_leg_height, &t4_api, min_depth)
        .map_err(err)?;
    Ok(AnchorEvidence {
        seq_anchor_height: e.seq_anchor_height,
        btc_leg_height: e.btc_leg_height,
        btc_tip: e.btc_tip,
        anchor_status: e.anchor_status,
        depth: e.depth,
        ok: e.ok,
    })
}

/// Build the SEQ claim tx (reveals the preimage). Only call after the reveal gate
/// passes. Returns the raw Elements tx hex to [`xchain_seq_broadcast`].
#[allow(clippy::too_many_arguments)]
pub fn xchain_seq_claim(
    mnemonic: String,
    seq_txid: String,
    seq_vout: u32,
    seq_amount: u64,
    seq_asset_id: String,
    dest_address: String,
    hash_hex: String,
    maker_seq_refund_pub_hex: String,
    seq_locktime: u32,
    fee: u64,
    preimage_hex: String,
) -> Result<String> {
    crate::xchain::seq_claim(
        &mnemonic,
        &seq_txid,
        seq_vout,
        seq_amount,
        &seq_asset_id,
        &dest_address,
        &hash_hex,
        &maker_seq_refund_pub_hex,
        seq_locktime,
        fee,
        &preimage_hex,
    )
    .map_err(err)
}

/// Broadcast a raw SEQ (Elements) tx hex; returns the txid.
pub fn xchain_seq_broadcast(seq_esplora: String, tx_hex: String) -> Result<String> {
    crate::xchain::seq_broadcast(&seq_esplora, &tx_hex).map_err(err)
}

/// Build the BTC HTLC refund (CLTV/ELSE branch), valid once the chain tip reaches
/// `locktime`. Returns raw tx hex for [`btc_broadcast`].
#[allow(clippy::too_many_arguments)]
pub fn xchain_btc_refund(
    mnemonic: String,
    btc_txid: String,
    btc_vout: u32,
    btc_amount_sats: u64,
    dest_address: String,
    fee_sats: u64,
    redeem_script_hex: String,
    locktime: u32,
) -> Result<String> {
    let (sk, _) = crate::xchain::btc_refund_keypair(&mnemonic).map_err(err)?;
    let redeem = lwk_wollet::bitcoin::ScriptBuf::from_hex(&redeem_script_hex).map_err(rerr)?;
    let dest = lwk_wollet::bitcoin::Address::from_str(&dest_address)
        .map_err(|_| err("invalid Bitcoin address".to_string()))?
        .require_network(lwk_wollet::bitcoin::Network::Testnet)
        .map_err(|_| err("address is not a Bitcoin testnet (tb1) address".to_string()))?;
    let spend = crate::btc_htlc::BtcHtlcSpend {
        txid: btc_txid,
        vout: btc_vout,
        amount_sats: btc_amount_sats,
        dest_spk: dest.script_pubkey(),
        fee_sats,
    };
    crate::btc_htlc::build_refund_tx(&redeem, &spend, locktime, &sk).map_err(err)
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
    if recipients.is_empty() {
        return Err(err("add at least one recipient".to_string()));
    }
    if recipients.iter().any(|r| r.satoshi == 0) {
        return Err(err("amount must be greater than zero".to_string()));
    }
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
    clear_scan_marks(); // spent UTXOs changed; make the next sync actually rescan
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
            .map(|t| {
                // lwk's `type_` is policy-asset-centric, so an any-asset-fee send
                // (no tSEQ delta) comes back "unknown". Re-derive the direction
                // from the net change across ALL assets.
                let (mut neg, mut pos) = (false, false);
                for v in t.balance.values() {
                    if *v < 0 {
                        neg = true;
                    } else if *v > 0 {
                        pos = true;
                    }
                }
                let deltas = t
                    .balance
                    .iter()
                    .map(|(a, v)| AssetDelta {
                        asset_id: a.to_string(),
                        atoms: v.to_string(),
                    })
                    .collect();
                let kind = match (neg, pos) {
                    (true, false) => "outgoing".to_string(),
                    (false, true) => "incoming".to_string(),
                    _ => t.type_,
                };
                TxRow {
                    txid: t.txid.to_string(),
                    height: t.height,
                    timestamp: t.timestamp.map(|ts| ts as u64),
                    kind,
                    fee: t.fee,
                    deltas,
                }
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

/// When each cached wallet was last scanned, so back-to-back ops can share a scan.
fn last_scan() -> &'static std::sync::Mutex<std::collections::HashMap<String, std::time::Instant>> {
    static S: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, std::time::Instant>>> =
        std::sync::OnceLock::new();
    S.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

/// True if this wallet was scanned within the last few seconds (so a launch's
/// three tabs, or a send's review-then-broadcast, reuse one scan).
fn scanned_recently(descriptor: &str) -> bool {
    last_scan()
        .lock()
        .ok()
        .and_then(|m| m.get(descriptor).map(|t| t.elapsed() < std::time::Duration::from_secs(10)))
        .unwrap_or(false)
}

fn mark_scanned(descriptor: &str) {
    if let Ok(mut m) = last_scan().lock() {
        m.insert(descriptor.to_string(), std::time::Instant::now());
    }
}

/// Drop all scan timestamps so the next op rescans (e.g. after broadcasting a tx,
/// so the new balance shows promptly).
fn clear_scan_marks() {
    if let Ok(mut m) = last_scan().lock() {
        m.clear();
    }
}

/// A blocking Esplora client with a 30s request timeout, so a hung connection
/// errors out instead of holding the shared wallet lock indefinitely. Sends the
/// configured `Authorization` header (set via `set_auth_header`) so a node
/// behind HTTP auth is reachable.
fn esplora_client(url: &str) -> std::result::Result<EsploraClient, lwk_wollet::Error> {
    let mut builder = EsploraClientBuilder::new(url, crate::sequentia_testnet()).timeout(30);
    if let Some(value) = crate::auth_header() {
        let mut headers = std::collections::HashMap::new();
        headers.insert("Authorization".to_string(), value);
        builder = builder.headers(headers);
    }
    builder.build_blocking()
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
    // Recover a poisoned lock (from a prior panic) instead of bricking every wallet op.
    let mut guard = wollet_cache().lock().unwrap_or_else(|e| e.into_inner());
    if !guard.contains_key(&descriptor) {
        let w = crate::build_wollet(&descriptor).map_err(err)?;
        guard.insert(descriptor.clone(), w);
    }
    // Skip the network scan when this wallet was scanned moments ago: a launch
    // (three tabs) or a send flow (balance -> review -> broadcast) then shares one
    // scan instead of each paying a full esplora round-trip.
    if !scanned_recently(&descriptor) {
        let mut client = esplora_client(esplora_url).map_err(rerr)?;
        match scan_into(guard.get_mut(&descriptor).expect("just inserted"), &mut client) {
            Ok(()) => {}
            // The persisted cache is ahead of the backend: a testnet reorg/reindex
            // dropped blocks below our saved tip, so every update looks "too old".
            // Discard the stale memory + disk state and rebuild from the current
            // chain (the fresh wallet starts empty, so the next scan applies cleanly).
            Err(lwk_wollet::Error::UpdateHeightTooOld { .. }) => {
                guard.remove(&descriptor);
                crate::clear_data_dir();
                let w = crate::build_wollet(&descriptor).map_err(err)?;
                guard.insert(descriptor.clone(), w);
                scan_into(guard.get_mut(&descriptor).expect("just inserted"), &mut client).map_err(rerr)?;
            }
            Err(e) => return Err(rerr(e)),
        }
        mark_scanned(&descriptor);
    }
    let wollet = guard.get(&descriptor).expect("present after sync");
    f(wollet)
}

/// Incrementally scan `wollet` against `client`, applying any returned update.
fn scan_into(
    wollet: &mut lwk_wollet::Wollet,
    client: &mut EsploraClient,
) -> std::result::Result<(), lwk_wollet::Error> {
    if let Some(update) = client.full_scan(&*wollet)? {
        wollet.apply_update(update)?;
    }
    Ok(())
}

/// Forget any cached wallet state (called when the wallet is removed).
pub fn clear_wallet_cache() {
    let mut guard = wollet_cache().lock().unwrap_or_else(|e| e.into_inner());
    guard.clear();
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

/// The network fee of a built PSET: the fee output's asset and amount (atoms).
pub struct PsetFee {
    pub asset_id: String,
    pub atoms: String,
}

/// Read the network fee out of a built (unsigned) PSET so the review can show an
/// estimate. For an any-asset-fee tx this is the chosen fee asset, not tSEQ.
pub fn pset_fee(pset: String) -> Result<PsetFee> {
    let p = PartiallySignedTransaction::from_str(&pset).map_err(rerr)?;
    let tx = p.extract_tx().map_err(rerr)?;
    for o in &tx.output {
        if o.is_fee() {
            let atoms = o.value.explicit().ok_or_else(|| err("fee value not explicit".to_string()))?;
            let asset = o.asset.explicit().ok_or_else(|| err("fee asset not explicit".to_string()))?;
            return Ok(PsetFee {
                asset_id: asset.to_string(),
                atoms: atoms.to_string(),
            });
        }
    }
    Err(err("pset has no fee output".to_string()))
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
    fee_asset: Option<FeeAsset>,
) -> Result<String> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let b = TxBuilder::new(crate::sequentia_testnet())
            .issue_asset(asset_sats, None, token_sats, None, None)
            .map_err(rerr)?;
        apply_fee_and_finish(b, wollet, fee_rate_sat_kvb, fee_asset.as_ref())
    })
}

/// Reissue more of an existing asset (needs its reissuance token in this wallet).
pub fn build_reissue_tx(
    mnemonic: String,
    esplora_url: String,
    asset_id: String,
    satoshi: u64,
    fee_rate_sat_kvb: Option<f32>,
    fee_asset: Option<FeeAsset>,
) -> Result<String> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let asset = AssetId::from_str(&asset_id).map_err(rerr)?;
        let b = TxBuilder::new(crate::sequentia_testnet())
            .reissue_asset(asset, satoshi, None, None)
            .map_err(rerr)?;
        apply_fee_and_finish(b, wollet, fee_rate_sat_kvb, fee_asset.as_ref())
    })
}

/// Permanently destroy `satoshi` atoms of an asset.
pub fn build_burn_tx(
    mnemonic: String,
    esplora_url: String,
    asset_id: String,
    satoshi: u64,
    fee_rate_sat_kvb: Option<f32>,
    fee_asset: Option<FeeAsset>,
) -> Result<String> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let asset = AssetId::from_str(&asset_id).map_err(rerr)?;
        let b = TxBuilder::new(crate::sequentia_testnet())
            .add_burn(satoshi, asset)
            .map_err(rerr)?;
        apply_fee_and_finish(b, wollet, fee_rate_sat_kvb, fee_asset.as_ref())
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
    fee_asset: Option<FeeAsset>,
) -> Result<String> {
    if satoshi < MIN_STAKE_ATOMS {
        return Err(err("minimum stake is 40,000 tSEQ".to_string()));
    }
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let pubkey = PublicKey::from_str(&staker_pubkey).map_err(rerr)?.serialize();
        let b = TxBuilder::new(crate::sequentia_testnet()).add_stake_output(&pubkey, csv, satoshi);
        apply_fee_and_finish(b, wollet, fee_rate_sat_kvb, fee_asset.as_ref())
    })
}
