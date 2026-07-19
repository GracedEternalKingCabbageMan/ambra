//! `flutter_rust_bridge` API surface for Ambra — the functions the Flutter
//! (Dart) UI calls. Keep signatures FFI-friendly (String / primitives /
//! `anyhow::Result`) and delegate the real work to the crate-root wallet logic.
//!
//! Generated Dart bindings land in `app/lib/src/rust/` via
//! `flutter_rust_bridge_codegen generate`.

/// Phone-side SeqLN Tier-2 device signer (the WASM signer's native twin): holds
/// the wallet's keys on-device and co-signs a hosted SeqLN node over Noise_XK.
pub mod signer;

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
use lwk_wollet::{
    build_covenant_fill_tx, build_covenant_refund_tx, covenant_secret_from_hex, maker_payout_program,
    Chain, CovenantFillPlan, CovenantInput, CovenantRefundInput, CovenantRefundPlan, FillCredit,
    FillRemainder, TakerFundingInput,
};

use crate::seqob_covenant_derive as covd;
use crate::seqob_wire as wire;

fn err(s: String) -> anyhow::Error {
    anyhow::Error::msg(s)
}

fn rerr<E: std::fmt::Debug>(e: E) -> anyhow::Error {
    anyhow::Error::msg(format!("{e:?}"))
}

/// The kit's address parameters for the Bitcoin parent chain (testnet4): shared
/// coin_type 1 / `tb` HRP with the Sequentia side.
fn btc_params() -> lwk_wollet::btc::addr::ChainAddressParams {
    lwk_wollet::btc::addr::ChainAddressParams::testnet()
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

/// A confidential (blech32 `tsqb…`) receive address together with its 33-byte
/// blinding pubkey (hex). Both are published in a confidential-book offer's
/// `same_chain{maker_recv_address, maker_blinding_pub}` so the counterparty can
/// add a blinded output crediting this leg — both legs blind on-chain. Index 0.
pub struct ConfidentialReceive {
    pub address: String,
    pub blinding_pub_hex: String,
}

/// The blinded (blech32) receive address + its 33-byte blinding pubkey (hex) for a
/// confidential same-chain DEX credit/refund. `blinding_pub_hex` is empty only if
/// the address somehow carries no blinding key (never for the CT descriptor).
pub fn confidential_receive_with_blinding_pub(mnemonic: String) -> Result<ConfidentialReceive> {
    let descriptor = crate::descriptor_from_mnemonic(&mnemonic).map_err(err)?;
    let wollet = crate::build_wollet(&descriptor).map_err(err)?;
    let res = wollet.address(Some(0)).map_err(rerr)?;
    let addr = res.address();
    let blinding_pub_hex = addr
        .blinding_pubkey
        .as_ref()
        .map(|pk| tohex(&pk.serialize()))
        .unwrap_or_default();
    Ok(ConfidentialReceive { address: addr.to_string(), blinding_pub_hex })
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
    let s = lwk_wollet::btc::wallet::scan(&btc_params(), &mnemonic, &t4_api).map_err(rerr)?;
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
    let p = lwk_wollet::btc::wallet::prepare(&btc_params(), &mnemonic, &t4_api, &address, amount_sats, fee_rate)
        .map_err(rerr)?;
    Ok(BtcTx { hex: p.hex, txid: p.txid, fee_sats: p.fee_sats.to_string(), vsize: p.vsize, inputs: p.inputs })
}

/// Broadcast a prepared Bitcoin testnet4 transaction hex; returns the txid.
pub fn btc_broadcast(t4_api: String, tx_hex: String) -> Result<String> {
    lwk_wollet::btc::wallet::broadcast(&t4_api, &tx_hex).map_err(rerr)
}

// --- SeqDEX same-chain atomic swap --------------------------------------------

/// The taker half of a same-chain swap: the random swap id + the SwapRequest JSON
/// to POST to the daemon's /v1/trade/propose.
pub struct SeqdexSwapRequestOut {
    pub id: String,
    pub swap_request_json: String,
}

/// Build the taker (proposer) half of a SeqDEX same-chain swap. `asset_*` are
/// display hex; amounts are atoms. Open fee market: `fee_amount == 0` ⇒ the maker
/// funds the network fee in `asset_r` (default); `fee_amount > 0` ⇒ the taker
/// funds it in `fee_asset` (any held, fee-eligible asset except `asset_r`),
/// adding a fee input + explicit fee output. `fee_rate` is `fee_asset`'s
/// published rate (atoms per 1e8 native), used only for the dust threshold.
/// Returns the swap id + the SwapRequest JSON to hand to the daemon's ProposeTrade.
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
    fee_rate: u64,
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
            fee_rate,
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

// --- SeqOB passive-CLOB covenant order book (same-chain, transparent) --------
//
// The web wallet replaced the RFQ daemon with the P2P SeqOB relay: a maker RESTS
// a self-enforcing covenant limit order ("the order is the coin") and a taker
// LIFTS it by broadcasting a permissionless FILL. These FFIs reuse the SWK raw-tx
// assemblers (build_covenant_fill_tx) + the ported byte-exact derivation
// (seqob_covenant_derive) + the ported relay wire (seqob_wire). The plain-HTTP
// relay transport itself lives in Dart (seqob_client.dart); every signature is
// produced here so the bytes match the Go relay.

/// The BIP84 coin type: 1 on testnet/regtest, 1776 on mainnet (matches
/// `lwk_common::singlesig_desc`). Ambra is testnet-only for now.
const SEQ_COIN_TYPE: u32 = 1;

/// Derive the maker's stable SeqOB identity private key (NOT a fund key) from the
/// wallet seed: `sha256("seqob-maker-identity-v1" || bip39_seed)`.
fn maker_identity_priv(mnemonic: &str) -> Result<[u8; 32]> {
    let signer = SwSigner::new(mnemonic, false).map_err(rerr)?;
    let seed = signer
        .seed()
        .ok_or_else(|| err("wallet seed unavailable for maker identity".into()))?;
    wire::maker_key_from_seed(&seed).map_err(err)
}

/// A BIP86 taproot maker-payout address + its 32-byte covenant `maker_prog`.
pub struct CovenantMakerAddress {
    /// The 32-byte v1-taproot payout program hex (the offer's `maker_prog`).
    pub program_hex: String,
    /// The `OP_1 <program>` scriptPubKey the FILL credit pays.
    pub spk_hex: String,
    /// The unblinded (transparent) BIP86 taproot receive address.
    pub address: String,
    /// The x-only internal key hex (the offer's `maker_x`, REFUND authoriser).
    pub internal_key_hex: String,
    /// The derivation path `m/86'/coin'/0'/0/index`.
    pub path: String,
}

/// Derive the maker payout at `m/86'/coin'/0'/0/index` — the taproot output the
/// covenant FILL credits, and the x-only key the REFUND leaf commits to.
pub fn covenant_maker_address(mnemonic: String, index: u32) -> Result<CovenantMakerAddress> {
    let (program, spk, internal_hex) = derive_maker_payout(&mnemonic, index)?;
    let script = lwk_wollet::elements::Script::from(hexbytes(&spk)?);
    let address =
        lwk_wollet::elements::Address::from_script(&script, None, seq_addr_params())
            .ok_or_else(|| err("cannot form taproot address from program".into()))?;
    Ok(CovenantMakerAddress {
        program_hex: program,
        spk_hex: spk,
        address: address.to_string(),
        internal_key_hex: internal_hex,
        path: format!("m/86'/{SEQ_COIN_TYPE}'/0'/0/{index}"),
    })
}

/// The Sequentia transparent-address params (Elements bech32 HRP on testnet).
fn seq_addr_params() -> &'static lwk_wollet::elements::AddressParams {
    &lwk_wollet::elements::AddressParams::ELEMENTS
}

/// Derive `(maker_prog_hex, spk_hex, internal_x_only_hex)` for a maker index.
fn derive_maker_payout(mnemonic: &str, index: u32) -> Result<(String, String, String)> {
    use lwk_wollet::bitcoin::secp256k1::Secp256k1;
    let signer = SwSigner::new(mnemonic, false).map_err(rerr)?;
    let path = DerivationPath::from(vec![
        ChildNumber::Hardened { index: 86 },
        ChildNumber::Hardened { index: SEQ_COIN_TYPE },
        ChildNumber::Hardened { index: 0 },
        ChildNumber::Normal { index: 0 },
        ChildNumber::Normal { index },
    ]);
    let xprv = signer.derive_xprv(&path).map_err(rerr)?;
    let secp = Secp256k1::signing_only();
    let (internal, _parity) = xprv.private_key.public_key(&secp).x_only_public_key();
    let (program, spk) = maker_payout_program(internal).map_err(rerr)?;
    Ok((tohex(&program), tohex(&spk), tohex(&internal.serialize())))
}

/// The prepared (pre-funding) parameters for a covenant resting LIMIT order.
pub struct CovenantPrepared {
    /// Opaque JSON round-tripped back into `covenant_finalize_offer` after funding.
    pub prepared_json: String,
    /// The address the maker must FUND with `sell_atoms` of the sold asset.
    pub covenant_address: String,
    /// The covenant scriptPubKey (used to locate the funded vout after funding).
    pub covenant_spk_hex: String,
    /// Atoms of the wanted asset a FULL fill pays the maker (ceil price).
    pub required_b: String,
    /// The min-lot floor (atoms of the sold asset) a taker may fill.
    pub min_lot: String,
    /// The absolute REFUND expiry height.
    pub expiry_locktime: u32,
    /// The fresh maker payout index used (persist to avoid credit collisions).
    pub maker_index: u32,
    /// The maker's SeqOB identity pubkey hex (offer namespace + cancel auth).
    pub maker_pubkey: String,
}

/// Derive everything a covenant resting LIMIT order needs, WITHOUT wallet I/O:
/// the covenant scriptPubKey/address to fund, the reduced rate, the min-lot, and
/// the maker payout. The caller then funds `covenant_address` with `sell_atoms`
/// of `sell_asset` (via the ordinary send path) and calls
/// `covenant_finalize_offer` with the funded txid/vout.
#[allow(clippy::too_many_arguments)]
pub fn covenant_prepare_offer(
    mnemonic: String,
    sell_asset: String,
    sell_atoms: u64,
    buy_asset: String,
    buy_atoms: u64,
    tip_height: u32,
    expiry_blocks: u32,
    maker_index: u32,
) -> Result<CovenantPrepared> {
    if sell_atoms == 0 || buy_atoms == 0 {
        return Err(err("amounts must be greater than zero".into()));
    }
    let (rate_num, rate_den) = covd::compute_rate(sell_atoms, buy_atoms).map_err(err)?;
    let min_lot = {
        let f = sell_atoms / 1000; // covenantMinLot: 0.1%, min 1 (partial-fillable)
        if f > 0 {
            f
        } else {
            1
        }
    };
    let expiry = covd::order_expiry(tip_height, expiry_blocks);
    let (maker_prog, _maker_spk, maker_x) = derive_maker_payout(&mnemonic, maker_index)?;

    let payout = covenant_maker_address(mnemonic.clone(), maker_index)?;
    let order = covd::DeriveOrder {
        asset_a: sell_asset.clone(),
        asset_b: buy_asset.clone(),
        rate_num,
        rate_den,
        min_lot,
        maker_prog: maker_prog.clone(),
        maker_ver: 1,
        expiry_locktime: expiry,
        maker_x: maker_x.clone(),
        internal_key: None, // NUMS: no maker key-path spend
    };
    let tap = covd::derive_taptree(&order).map_err(err)?;
    let spk_hex = tohex(&tap.script_pubkey);
    let script = lwk_wollet::elements::Script::from(tap.script_pubkey.clone());
    let cov_address = lwk_wollet::elements::Address::from_script(&script, None, seq_addr_params())
        .ok_or_else(|| err("cannot form covenant address".into()))?
        .to_string();

    let maker_pubkey = wire::maker_pubkey_hex(&maker_identity_priv(&mnemonic)?).map_err(err)?;
    let required_b = covd::ceil_price(sell_atoms, rate_num, rate_den);
    let internal_key_hex = tohex(&tap.internal_key);
    let merkle_path: Vec<String> = tap.merkle_path.iter().map(|p| tohex(p)).collect();

    let prepared = serde_json::json!({
        "sell_asset": sell_asset,
        "buy_asset": buy_asset,
        "sell_atoms": sell_atoms.to_string(),
        "buy_atoms": buy_atoms.to_string(),
        "rate_num": rate_num.to_string(),
        "rate_den": rate_den.to_string(),
        "min_lot": min_lot.to_string(),
        "expiry_locktime": expiry,
        "maker_prog": maker_prog,
        "maker_prog_ver": 1,
        "maker_x": maker_x,
        "internal_key": internal_key_hex,
        "merkle_path": merkle_path,
        "maker_recv_address": payout.address,
        "maker_pubkey": maker_pubkey,
        "spk_hex": spk_hex,
    });

    Ok(CovenantPrepared {
        prepared_json: prepared.to_string(),
        covenant_address: cov_address,
        covenant_spk_hex: spk_hex,
        required_b: required_b.to_string(),
        min_lot: min_lot.to_string(),
        expiry_locktime: expiry,
        maker_index,
        maker_pubkey,
    })
}

/// After funding the covenant, assemble the `seqob.v1.Offer` (covenant resting
/// SELL) from the prepared params + the funded `covenant_txid`:`covenant_vout`,
/// sign it with the maker identity key, and return the signed offer JSON (hex
/// `bytes` fields). The caller converts the covenant hex fields to base64 for the
/// grpc-gateway POST (`seqob_client.dart`).
pub fn covenant_finalize_offer(
    mnemonic: String,
    prepared_json: String,
    covenant_txid: String,
    covenant_vout: u32,
) -> Result<String> {
    let p: serde_json::Value =
        serde_json::from_str(&prepared_json).map_err(|e| err(format!("bad prepared json: {e}")))?;
    let s = |k: &str| p.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();

    let sell_asset = s("sell_asset");
    let buy_asset = s("buy_asset");
    let sell_atoms = s("sell_atoms");
    let buy_atoms = s("buy_atoms");

    let covenant = serde_json::json!({
        "covenant_txid": covenant_txid,
        "covenant_vout": covenant_vout,
        "asset_a": sell_asset,
        "asset_b": buy_asset,
        "rate_num": s("rate_num"),
        "rate_den": s("rate_den"),
        "maker_prog": s("maker_prog"),
        "maker_prog_ver": p.get("maker_prog_ver").and_then(|v| v.as_u64()).unwrap_or(1),
        "min_lot": s("min_lot"),
        "expiry_locktime": p.get("expiry_locktime").and_then(|v| v.as_u64()).unwrap_or(0),
        "maker_x": s("maker_x"),
        "internal_key": s("internal_key"),
        "merkle_path": p.get("merkle_path").cloned().unwrap_or(serde_json::json!([])),
    });

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let ttl = 3600u64;
    // A unique offer id derived from the funding outpoint + time (16 bytes hex).
    let offer_id = {
        use lwk_wollet::elements::hashes::{sha256, Hash};
        let seed = format!("{covenant_txid}:{covenant_vout}:{now}");
        let h = sha256::Hash::hash(seed.as_bytes()).to_byte_array();
        tohex(&h[..8])
    };

    let mut offer = serde_json::json!({
        "offer_id": offer_id,
        "schema_version": 1,
        "pair": { "base_asset": sell_asset, "quote_asset": buy_asset },
        "trade_dir": 1, // SELL: maker gives base (asset A)
        "base_amount": sell_atoms,
        "offer_amount": sell_atoms, "offer_asset": sell_asset,
        "want_amount": buy_atoms, "want_asset": buy_asset,
        "allow_partial": true,
        "min_fill": s("min_lot"),
        "created_at_unix": now.to_string(),
        "expires_at_unix": (now + ttl).to_string(),
        "fee_asset_hint": buy_asset,
        // ONLY `covenant` in the settlement oneof. Emitting `same_chain` here too made every covenant
        // POST fail to decode at the relay ("oneof seqob.v1.Offer.settlement is already set"); the
        // covenant self-describes its payout via maker_prog, so a separate maker_recv_address is redundant.
        "covenant": covenant,
    });

    let priv_key = maker_identity_priv(&mnemonic)?;
    wire::sign_offer(&mut offer, &priv_key).map_err(err)?;
    Ok(offer.to_string())
}

/// Sign an already-assembled offer JSON with the maker identity key (used when the
/// caller builds the offer object itself). Returns the signed offer JSON.
pub fn seqob_sign_offer(mnemonic: String, offer_json: String) -> Result<String> {
    let mut offer: serde_json::Value =
        serde_json::from_str(&offer_json).map_err(|e| err(format!("bad offer json: {e}")))?;
    let priv_key = maker_identity_priv(&mnemonic)?;
    wire::sign_offer(&mut offer, &priv_key).map_err(err)?;
    Ok(offer.to_string())
}

/// Verify a relay-served offer's maker signature locally (the relay is untrusted).
pub fn seqob_verify_offer(offer_json: String) -> Result<bool> {
    let offer: serde_json::Value =
        serde_json::from_str(&offer_json).map_err(|e| err(format!("bad offer json: {e}")))?;
    Ok(wire::verify_offer(&offer))
}

/// The maker's SeqOB identity pubkey hex (offer namespace + `myOffers` lookup).
pub fn seqob_maker_pubkey(mnemonic: String) -> Result<String> {
    wire::maker_pubkey_hex(&maker_identity_priv(&mnemonic)?).map_err(err)
}

/// Sign an `OfferCancel` for an offer this wallet made. Returns the cancel JSON
/// to POST to `/v1/offers/cancel`.
pub fn seqob_sign_cancel(mnemonic: String, offer_id: String, nonce: u64) -> Result<String> {
    let priv_key = maker_identity_priv(&mnemonic)?;
    let cancel = wire::sign_cancel(&offer_id, &priv_key, nonce).map_err(err)?;
    Ok(cancel.to_string())
}

/// A fresh ephemeral secp256k1 keypair for a cross-lift courier session (forward secrecy — one per lift).
/// The taker seals its XcMsgs with [priv_hex]; [pub_hex] (compressed) goes in the StartLift as the
/// taker_session_pubkey so the maker can derive the same ECDH key.
pub struct SeqobKeypair {
    pub priv_hex: String,
    pub pub_hex: String,
}

pub fn seqob_ephemeral_key() -> Result<SeqobKeypair> {
    use lwk_wollet::secp256k1::{PublicKey, Secp256k1, SecretKey};
    let secp = Secp256k1::new();
    for _ in 0..64 {
        let mut b = [0u8; 32];
        getrandom::getrandom(&mut b).map_err(|e| anyhow::anyhow!("rng: {e}"))?;
        if let Ok(sk) = SecretKey::from_slice(&b) {
            let pk = PublicKey::from_secret_key(&secp, &sk);
            return Ok(SeqobKeypair { priv_hex: tohex(&b), pub_hex: tohex(&pk.serialize()) });
        }
    }
    anyhow::bail!("could not sample a session key")
}

fn priv32(hex: &str) -> Result<[u8; 32]> {
    let pb = hexbytes(hex)?;
    if pb.len() != 32 {
        anyhow::bail!("private key must be 32 bytes");
    }
    let mut k = [0u8; 32];
    k.copy_from_slice(&pb);
    Ok(k)
}

/// Seal a plaintext XcMsg for the maker over the cross courier: nonce(12) || AES-256-GCM. [my_priv_hex]
/// is the taker's ephemeral session key, [peer_pub_hex] the maker's identity pubkey. Byte-matches the Go
/// relay + web wallet Crypter (key = sha256(secp256k1 ECDH raw-X)).
pub fn seqob_e2e_seal(my_priv_hex: String, peer_pub_hex: String, plaintext: Vec<u8>) -> Result<Vec<u8>> {
    let key = priv32(&my_priv_hex)?;
    let peer = hexbytes(&peer_pub_hex)?;
    crate::seqob_courier::seal(&key, &peer, &plaintext).map_err(|e| anyhow::anyhow!(e))
}

/// Open a sealed XcMsg from the maker over the cross courier. Errors on tampering (GCM tag mismatch).
pub fn seqob_e2e_open(my_priv_hex: String, peer_pub_hex: String, sealed: Vec<u8>) -> Result<Vec<u8>> {
    let key = priv32(&my_priv_hex)?;
    let peer = hexbytes(&peer_pub_hex)?;
    crate::seqob_courier::open(&key, &peer, &sealed).map_err(|e| anyhow::anyhow!(e))
}

/// The built raw FILL/lift transaction: Elements hex + its txid.
pub struct BuiltRawTx {
    pub raw_hex: String,
    pub txid: String,
}

/// Assemble + sign the permissionless covenant FILL (TAKE/lift) that fills a
/// chosen resting offer. `covenant_terms_json` is the offer's `CovenantTerms`
/// (from the relay book). The covenant is trustlessly re-derived and checked
/// against the funded UTXO's on-chain scriptPubKey (anti-relay-lie); the taker's
/// own asset-B + fee UTXOs fund the maker credit + network fee. `take_atoms` is
/// clamped to the covenant's locked amount. The fee is paid in `fee_asset`
/// (open fee market; must NOT be the sold asset A). Returns the raw Elements tx
/// hex to broadcast via `xchain_seq_broadcast`.
pub fn covenant_build_fill_tx(
    mnemonic: String,
    esplora_url: String,
    covenant_terms_json: String,
    take_atoms: u64,
    fee_asset: String,
    fee_atoms: u64,
) -> Result<BuiltRawTx> {
    let ct: serde_json::Value = serde_json::from_str(&covenant_terms_json)
        .map_err(|e| err(format!("bad covenant terms json: {e}")))?;
    let order = order_from_terms(&ct)?;
    let cov_txid = ct_str(&ct, &["covenant_txid", "covenantTxid"]);
    let cov_vout = ct_u64(&ct, &["covenant_vout", "covenantVout"]) as u32;
    if cov_txid.is_empty() {
        return Err(err("covenant terms missing covenant_txid".into()));
    }

    // Fetch the funded UTXO on-chain: its real spk (for the anti-relay-lie check),
    // locked value, and asset.
    let (onchain_spk, locked, onchain_asset) = fetch_utxo(&esplora_url, &cov_txid, cov_vout)?;
    let onchain_spk_bytes = hexbytes(&onchain_spk)?;
    let tap = covd::verify_against_spk(&order, &onchain_spk_bytes, false).map_err(err)?;
    if onchain_asset != order.asset_a {
        return Err(err(format!(
            "funded covenant asset {onchain_asset} != terms asset_a {}",
            order.asset_a
        )));
    }

    let filled = take_atoms.min(locked);
    let plan = covd::plan_fill(&order, locked, filled).map_err(err)?;

    let a_asset = AssetId::from_str(&order.asset_a).map_err(rerr)?;
    let b_asset = AssetId::from_str(&order.asset_b).map_err(rerr)?;
    let fee_asset_id = AssetId::from_str(&fee_asset).map_err(rerr)?;
    if fee_asset_id == a_asset {
        return Err(err(
            "fee asset must not be the covenant's sold asset A (fund the fee from asset B or another asset)".into(),
        ));
    }

    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let signer = SwSigner::new(&mnemonic, false).map_err(rerr)?;

        // Fund the maker credit (asset B) + the network fee (fee asset) from the
        // taker's own coins. Asset A comes entirely from the covenant.
        let mut need: std::collections::BTreeMap<AssetId, u64> = std::collections::BTreeMap::new();
        *need.entry(b_asset).or_insert(0) += plan.required_b;
        *need.entry(fee_asset_id).or_insert(0) += fee_atoms;

        let taker_inputs = select_taker_inputs(wollet, &signer, &need, a_asset)?;

        let receipt_addr = wollet
            .address(None)
            .map_err(rerr)?
            .address()
            .to_unconfidential();
        let change_addr = receipt_addr.clone();

        let remainder = if plan.partial {
            Some(FillRemainder {
                asset: a_asset,
                value: plan.remainder,
                spk: tap.script_pubkey.clone(),
            })
        } else {
            None
        };

        let fill_plan = CovenantFillPlan {
            covenant: CovenantInput {
                txid: cov_txid.clone(),
                vout: cov_vout,
                asset: a_asset,
                locked,
                fill_leaf: tap.fill_leaf.clone(),
                control_block: tap.control_block.clone(),
            },
            credit: FillCredit {
                asset: b_asset,
                program: hexbytes(&order.maker_prog)?,
                version: order.maker_ver,
                value: plan.required_b,
            },
            remainder,
            taker_inputs,
            receipt_addr,
            change_addr,
            fee_atoms,
            fee_asset: fee_asset_id,
        };

        let (raw_hex, txid) = build_covenant_fill_tx(&fill_plan).map_err(rerr)?;
        Ok(BuiltRawTx {
            raw_hex,
            txid: txid.to_string(),
        })
    })
}

/// Derive the maker payout SECRET key for a maker index — the key the covenant
/// REFUND leaf commits to via `maker_x`. Same BIP86 path as [`derive_maker_payout`]'s
/// public key (`m/86'/coin'/0'/0/index`); the refund builder re-checks the signature
/// verifies against the leaf's committed key.
fn derive_maker_secret(
    mnemonic: &str,
    index: u32,
) -> Result<lwk_wollet::bitcoin::secp256k1::SecretKey> {
    let signer = SwSigner::new(mnemonic, false).map_err(rerr)?;
    let path = DerivationPath::from(vec![
        ChildNumber::Hardened { index: 86 },
        ChildNumber::Hardened { index: SEQ_COIN_TYPE },
        ChildNumber::Hardened { index: 0 },
        ChildNumber::Normal { index: 0 },
        ChildNumber::Normal { index },
    ]);
    let xprv = signer.derive_xprv(&path).map_err(rerr)?;
    Ok(xprv.private_key)
}

/// Assemble + sign the covenant REFUND (cancel/reclaim) transaction: spend a resting
/// covenant order back to the maker via the CLTV REFUND leaf, once it has matured
/// (chain tip >= expiry_locktime). `prepared_json` is the recipe the wallet stored
/// when it posted the order (`PlacedCovenant.preparedJson`), carrying the params the
/// taptree derives from. The funded covenant UTXO is fetched on-chain for its REAL
/// locked value + scriptPubKey (so a partially-filled remainder reclaims its ACTUAL
/// value, and an already-spent covenant errors cleanly), the taptree is re-derived
/// (REFUND leaf + control block) and checked against that spk, and the maker key at
/// `maker_index` signs the tapscript-path Schnorr signature. The fee is paid in
/// `fee_asset`: if it equals the covenant asset it is taken from the reclaimed value
/// (no wallet inputs); otherwise it is funded from the wallet's own coins with change
/// returned. The reclaimed asset A is sent to the wallet's own address. Returns the
/// raw Elements tx to broadcast via [`xchain_seq_broadcast`]. NOTE: the tx sets
/// nLockTime = expiry, so a node accepts it only once the tip reaches that height —
/// call after the order has matured.
#[allow(clippy::too_many_arguments)]
pub fn covenant_build_refund_tx(
    mnemonic: String,
    esplora_url: String,
    prepared_json: String,
    covenant_txid: String,
    covenant_vout: u32,
    maker_index: u32,
    fee_asset: String,
    fee_atoms: u64,
) -> Result<BuiltRawTx> {
    let pj: serde_json::Value = serde_json::from_str(&prepared_json)
        .map_err(|e| err(format!("bad prepared json: {e}")))?;
    let order = order_from_terms(&pj)?;
    if order.asset_a.is_empty() {
        return Err(err("prepared json missing the covenant sold asset".into()));
    }
    if covenant_txid.is_empty() {
        return Err(err("covenant txid required".into()));
    }

    // The funded covenant UTXO on-chain: its REAL locked value + spk (a partial-fill
    // remainder differs from the original), which also proves it is still unspent.
    let (onchain_spk, locked, onchain_asset) =
        fetch_utxo(&esplora_url, &covenant_txid, covenant_vout)
            .map_err(|e| err(format!("covenant output not found or already spent: {e}")))?;
    let onchain_spk_bytes = hexbytes(&onchain_spk)?;
    let tap = covd::verify_against_spk(&order, &onchain_spk_bytes, false).map_err(err)?;
    if onchain_asset != order.asset_a {
        return Err(err(format!(
            "funded covenant asset {onchain_asset} != prepared asset_a {}",
            order.asset_a
        )));
    }

    let a_asset = AssetId::from_str(&order.asset_a).map_err(rerr)?;
    let fee_asset_id = AssetId::from_str(&fee_asset).map_err(rerr)?;
    let genesis_hash = crate::sequentia_testnet().genesis_hash();
    let maker_secret = derive_maker_secret(&mnemonic, maker_index)?;

    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let signer = SwSigner::new(&mnemonic, false).map_err(rerr)?;
        let reclaim_addr = wollet
            .address(None)
            .map_err(rerr)?
            .address()
            .to_unconfidential();

        // Fee funding: in the covenant asset it comes out of the reclaimed value (no
        // inputs); otherwise from the wallet's own coins (asset A is never funded here).
        let fee_inputs = if fee_asset_id == a_asset {
            Vec::new()
        } else {
            let mut need: std::collections::BTreeMap<AssetId, u64> =
                std::collections::BTreeMap::new();
            *need.entry(fee_asset_id).or_insert(0) += fee_atoms;
            select_taker_inputs(wollet, &signer, &need, a_asset)?
        };

        let plan = CovenantRefundPlan {
            covenant: CovenantRefundInput {
                txid: covenant_txid.clone(),
                vout: covenant_vout,
                asset: a_asset,
                locked,
                spk: tap.script_pubkey.clone(),
                refund_leaf: tap.refund_leaf.clone(),
                control_block: tap.refund_control_block.clone(),
                maker_secret,
            },
            expiry_locktime: order.expiry_locktime,
            reclaim_addr: reclaim_addr.clone(),
            fee_atoms,
            fee_asset: fee_asset_id,
            fee_inputs,
            change_addr: reclaim_addr,
            genesis_hash,
        };

        let (raw_hex, txid) = build_covenant_refund_tx(&plan).map_err(rerr)?;
        Ok(BuiltRawTx {
            raw_hex,
            txid: txid.to_string(),
        })
    })
}

/// Parse a relay `CovenantTerms` object into the pure derive order.
fn order_from_terms(ct: &serde_json::Value) -> Result<covd::DeriveOrder> {
    let internal_key = {
        let ik = ct_str(ct, &["internal_key", "internalKey"]);
        if ik.is_empty() {
            None
        } else {
            Some(ik)
        }
    };
    Ok(covd::DeriveOrder {
        // Accept both the relay CovenantTerms names (asset_a/asset_b) and the wallet's
        // stored prepared_json names (sell_asset/buy_asset) so the covenant REFUND path
        // can rebuild the order from the recipe it persisted when posting the offer.
        asset_a: ct_str(ct, &["asset_a", "assetA", "sell_asset", "sellAsset"]),
        asset_b: ct_str(ct, &["asset_b", "assetB", "buy_asset", "buyAsset"]),
        rate_num: ct_u64(ct, &["rate_num", "rateNum"]),
        rate_den: ct_u64(ct, &["rate_den", "rateDen"]),
        min_lot: ct_u64(ct, &["min_lot", "minLot"]),
        maker_prog: ct_str(ct, &["maker_prog", "makerProg"]),
        maker_ver: ct_u64(ct, &["maker_prog_ver", "makerProgVer"]).max(1) as u8,
        expiry_locktime: ct_u64(ct, &["expiry_locktime", "expiryLocktime"]) as u32,
        maker_x: ct_str(ct, &["maker_x", "makerX"]),
        internal_key,
    })
}

fn ct_str(o: &serde_json::Value, names: &[&str]) -> String {
    for n in names {
        if let Some(v) = o.get(*n) {
            if let Some(s) = v.as_str() {
                return s.to_string();
            }
        }
    }
    String::new()
}

fn ct_u64(o: &serde_json::Value, names: &[&str]) -> u64 {
    for n in names {
        if let Some(v) = o.get(*n) {
            if let Some(u) = v.as_u64() {
                return u;
            }
            if let Some(s) = v.as_str() {
                if let Ok(u) = s.parse::<u64>() {
                    return u;
                }
            }
        }
    }
    0
}

/// Fetch a funded output's `(scriptpubkey_hex, value_atoms, asset_display_hex)`
/// from the wallet's own esplora `/tx/{txid}`.
fn fetch_utxo(esplora_url: &str, txid: &str, vout: u32) -> Result<(String, u64, String)> {
    let url = format!("{}/tx/{}", esplora_url.trim_end_matches('/'), txid);
    let mut req = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(rerr)?
        .get(&url);
    if let Some(auth) = crate::auth_header() {
        req = req.header("Authorization", auth);
    }
    let resp = req.send().map_err(rerr)?;
    if !resp.status().is_success() {
        return Err(err(format!("esplora /tx/{txid} returned {}", resp.status())));
    }
    let tx: serde_json::Value = resp.json().map_err(rerr)?;
    let outs = tx
        .get("vout")
        .and_then(|v| v.as_array())
        .ok_or_else(|| err("esplora tx has no vout array".into()))?;
    let o = outs
        .get(vout as usize)
        .ok_or_else(|| err(format!("tx {txid} has no vout {vout}")))?;
    let spk = o
        .get("scriptpubkey")
        .and_then(|v| v.as_str())
        .ok_or_else(|| err("vout missing scriptpubkey".into()))?
        .to_string();
    let value = o
        .get("value")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| err("vout has no explicit value (confidential?)".into()))?;
    let asset = o
        .get("asset")
        .and_then(|v| v.as_str())
        .ok_or_else(|| err("vout has no explicit asset".into()))?
        .to_string();
    Ok((spk, value, asset))
}

/// Greedy largest-first coin selection of the taker's OWN p2wpkh UTXOs covering
/// `need` (per asset), re-deriving each signing key at `m/84'/coin'/0'/chain/index`.
/// Rejects funding the covenant's sold asset `a_asset`.
fn select_taker_inputs(
    wollet: &lwk_wollet::Wollet,
    signer: &SwSigner,
    need: &std::collections::BTreeMap<AssetId, u64>,
    a_asset: AssetId,
) -> Result<Vec<TakerFundingInput>> {
    let utxos = wollet.utxos().map_err(rerr)?;
    let mut out: Vec<TakerFundingInput> = Vec::new();
    for (asset, target) in need {
        if *asset == a_asset {
            return Err(err("cannot fund the covenant's sold asset A".into()));
        }
        let mut cands: Vec<&lwk_wollet::WalletTxOut> = utxos
            .iter()
            .filter(|u| u.unblinded.asset == *asset && !u.is_spent)
            .collect();
        cands.sort_by(|a, b| b.unblinded.value.cmp(&a.unblinded.value));
        let mut sum: u64 = 0;
        for u in cands {
            if sum >= *target {
                break;
            }
            let spk = u.script_pubkey.as_bytes().to_vec();
            if spk.len() != 22 || spk[0] != 0x00 || spk[1] != 0x14 {
                continue; // only key-path p2wpkh coins are spendable by this builder
            }
            let chain = match u.ext_int {
                Chain::Internal => 1u32,
                Chain::External => 0u32,
            };
            let path = DerivationPath::from(vec![
                ChildNumber::Hardened { index: 84 },
                ChildNumber::Hardened { index: SEQ_COIN_TYPE },
                ChildNumber::Hardened { index: 0 },
                ChildNumber::Normal { index: chain },
                ChildNumber::Normal { index: u.wildcard_index },
            ]);
            let xprv = signer.derive_xprv(&path).map_err(rerr)?;
            let secret_key =
                covenant_secret_from_hex(&tohex(&xprv.private_key.secret_bytes())).map_err(rerr)?;
            out.push(TakerFundingInput {
                txid: u.outpoint.txid.to_string(),
                vout: u.outpoint.vout,
                value: u.unblinded.value,
                asset: *asset,
                spk,
                secret_key,
            });
            sum += u.unblinded.value;
        }
        if sum < *target {
            return Err(err(format!(
                "insufficient {asset}: need {target}, have {sum}"
            )));
        }
    }
    Ok(out)
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
    let (secret_hex, hash_hex) = lwk_wollet::btc::xchain::new_secret();
    XchainSecret { secret_hex, hash_hex }
}

/// Alice's SEQ-leg claim pubkey (the HTLC claim key; secret stays in the core).
pub fn xchain_seq_claim_pubkey(mnemonic: String) -> Result<String> {
    lwk_wollet::btc::xchain::seq_claim_keypair(&btc_params(), &mnemonic, lwk_wollet::btc::xchain::PathMode::Canonical)
        .map(|(_, p)| p)
        .map_err(rerr)
}

/// Alice's BTC-leg refund pubkey.
pub fn xchain_btc_refund_pubkey(mnemonic: String) -> Result<String> {
    lwk_wollet::btc::xchain::btc_refund_keypair(&btc_params(), &mnemonic, lwk_wollet::btc::xchain::PathMode::Canonical)
        .map(|(_, p)| p)
        .map_err(rerr)
}

/// Build the BTC HTLC the wallet will fund: redeemScript + P2SH address/spk.
pub fn xchain_btc_htlc(
    hash_hex: String,
    claim_pub_hex: String,
    refund_pub_hex: String,
    locktime: u32,
) -> Result<BtcHtlcInfo> {
    let redeem = lwk_wollet::btc::htlc::build_htlc_redeem_script(
        &hexbytes(&hash_hex)?,
        &hexbytes(&claim_pub_hex)?,
        &hexbytes(&refund_pub_hex)?,
        locktime,
    )
    .map_err(rerr)?;
    let (address, spk) = lwk_wollet::btc::htlc::htlc_p2sh(&redeem).map_err(rerr)?;
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
    lwk_wollet::btc::xchain::seq_redeem_script_hex(
        &btc_params(),
        &mnemonic,
        lwk_wollet::btc::xchain::PathMode::Canonical,
        &hash_hex,
        &maker_seq_refund_pub_hex,
        seq_locktime,
    )
    .map_err(rerr)
}

/// Locate the BTC HTLC funding output by its P2SH scriptPubKey on testnet4.
pub fn xchain_find_btc_funding(t4_api: String, txid: String, p2sh_spk_hex: String) -> Result<BtcFunding> {
    let f = lwk_wollet::btc::wallet::find_htlc_funding(&t4_api, &txid, &p2sh_spk_hex).map_err(rerr)?;
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
    let e = lwk_wollet::btc::xchain::blocking::verify_seq_leg_safe(
        &seq_esplora,
        &seq_block_hash,
        btc_leg_height,
        &t4_api,
        min_depth,
    )
    .map_err(rerr)?;
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
    lwk_wollet::btc::xchain::seq_claim(
        &btc_params(),
        &mnemonic,
        lwk_wollet::btc::xchain::PathMode::Canonical,
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
    .map_err(rerr)
}

/// Broadcast a raw SEQ (Elements) tx hex; returns the txid.
pub fn xchain_seq_broadcast(seq_esplora: String, tx_hex: String) -> Result<String> {
    lwk_wollet::btc::xchain::blocking::seq_broadcast(&seq_esplora, &tx_hex).map_err(rerr)
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
    let (sk, _) = lwk_wollet::btc::xchain::btc_refund_keypair(
        &btc_params(),
        &mnemonic,
        lwk_wollet::btc::xchain::PathMode::Canonical,
    )
    .map_err(rerr)?;
    let redeem = lwk_wollet::bitcoin::ScriptBuf::from_hex(&redeem_script_hex).map_err(rerr)?;
    let dest = lwk_wollet::bitcoin::Address::from_str(&dest_address)
        .map_err(|_| err("invalid Bitcoin address".to_string()))?
        .require_network(lwk_wollet::bitcoin::Network::Testnet)
        .map_err(|_| err("address is not a Bitcoin testnet (tb1) address".to_string()))?;
    let spend = lwk_wollet::btc::htlc::BtcHtlcSpend {
        txid: btc_txid,
        vout: btc_vout,
        amount_sats: btc_amount_sats,
        dest_spk: dest.script_pubkey(),
        fee_sats,
    };
    lwk_wollet::btc::htlc::build_refund_tx(&redeem, &spend, locktime, &sk).map_err(rerr)
}

// --- REVERSE cross-chain (Sequentia asset -> BTC on-chain HTLC) ----------------
//
// The MIRROR of the forward buy. Here the wallet is the TAKER SELLING an asset:
// the remote MAKER holds the secret and locks the BTC leg FIRST, the taker funds
// the SEQ asset leg SECOND, the maker claims the asset (revealing the secret), and
// the taker claims the BTC with that secret. The taker NEVER holds or reveals a
// preimage in this direction, so the "never reveal before the paying leg is
// anchor-safe" discipline is upheld BY CONSTRUCTION; the taker's own discipline is
// verify-the-maker's-BTC-leg-before-funding + wait-for-its-confirmation (so the
// SEQ leg anchors at/above it) + T_btc > T_seq + a CLTV asset refund off-ramp.
// The BTC claim itself is on the anchor-supreme parent chain and needs no gate.

/// A reverse-swap SEQ HTLC the taker FUNDS: its redeemScript + Sequentia P2SH
/// address/spk. Fund the address with an EXPLICIT (unblinded) asset output via
/// [`build_send_tx`] so the maker can read the asset + amount before it claims.
pub struct SeqHtlcInfo {
    pub redeem_script_hex: String,
    pub p2sh_address: String,
    pub p2sh_spk_hex: String,
}

/// The taker's BTC-leg CLAIM pubkey for a REVERSE swap: the pubkey the maker must
/// embed as the IF/claim key in its BTC HTLC, and whose secret (kept in-core)
/// signs the on-chain claim once the maker reveals the preimage. Distinct HD path
/// from the BTC-refund key, so one leaked key never unlocks both HTLC branches.
pub fn xchain_btc_claim_pubkey(mnemonic: String) -> Result<String> {
    lwk_wollet::btc::xchain::btc_claim_keypair(&btc_params(), &mnemonic, lwk_wollet::btc::xchain::PathMode::Canonical)
        .map(|(_, p)| p)
        .map_err(rerr)
}

/// Build the SEQ-leg HTLC the taker FUNDS in a reverse (asset -> BTC) swap. The
/// maker CLAIMS it (revealing the preimage) via the IF branch, and the taker
/// REFUNDS it via the CLTV/ELSE branch after `seq_locktime`. So claim = the
/// maker's SEQ-claim pubkey and refund = the taker's OWN canonical SEQ key (the
/// same key [`xchain_seq_claim_pubkey`] returns — reused, so refund recovery is
/// HD-derivable). Returns the redeemScript plus the Sequentia P2SH address/spk to
/// fund via [`build_send_tx`] as an explicit recipient.
pub fn xchain_seq_htlc_reverse(
    mnemonic: String,
    hash_hex: String,
    maker_seq_claim_pub_hex: String,
    seq_locktime: u32,
) -> Result<SeqHtlcInfo> {
    let (_sk, taker_seq_refund_pub) =
        lwk_wollet::btc::xchain::seq_claim_keypair(&btc_params(), &mnemonic, lwk_wollet::btc::xchain::PathMode::Canonical)
            .map_err(rerr)?;
    let redeem = lwk_wollet::build_htlc_redeem_script(
        &hexbytes(&hash_hex)?,
        &hexbytes(&maker_seq_claim_pub_hex)?,
        &hexbytes(&taker_seq_refund_pub)?,
        seq_locktime,
    )
    .map_err(rerr)?;
    // Sequentia P2SH (p2sh_prefix 196, byte-identical to Bitcoin testnet), encoded
    // under the SEQUENTIA address params so `build_send_tx` round-trips the address.
    let address = lwk_wollet::elements::Address::p2sh(&redeem, None, crate::sequentia_testnet().address_params());
    Ok(SeqHtlcInfo {
        redeem_script_hex: tohex(redeem.as_bytes()),
        p2sh_spk_hex: tohex(address.script_pubkey().as_bytes()),
        p2sh_address: address.to_string(),
    })
}

/// The SEQ-leg HTLC info for a FORWARD (BTC -> asset) swap: the redeemScript PLUS its Sequentia P2SH
/// address/spk. Here the MAKER funds this leg and the TAKER claims it with the preimage (IF branch,
/// claim = the taker's own canonical SEQ key), the maker refunding after `seq_locktime` (refund =
/// `maker_seq_refund_pub_hex`) — the exact script [`xchain_seq_redeem_script`] rebuilds. Exposing the
/// P2SH spk lets the forward taker BIND the maker's reported leg to a REAL on-chain output (existence +
/// script + asset + value) before it reveals the secret, closing the "maker reports a fabricated or
/// wrong-script leg" reveal-into-nothing attack. Pure derivation from the same inputs — no network.
pub fn xchain_seq_htlc_forward(
    mnemonic: String,
    hash_hex: String,
    maker_seq_refund_pub_hex: String,
    seq_locktime: u32,
) -> Result<SeqHtlcInfo> {
    let redeem_hex = lwk_wollet::btc::xchain::seq_redeem_script_hex(
        &btc_params(),
        &mnemonic,
        lwk_wollet::btc::xchain::PathMode::Canonical,
        &hash_hex,
        &maker_seq_refund_pub_hex,
        seq_locktime,
    )
    .map_err(rerr)?;
    let redeem = lwk_wollet::elements::Script::from(hexbytes(&redeem_hex)?);
    // Sequentia P2SH (p2sh_prefix 196, byte-identical to Bitcoin testnet), under the SEQUENTIA params.
    let address = lwk_wollet::elements::Address::p2sh(&redeem, None, crate::sequentia_testnet().address_params());
    Ok(SeqHtlcInfo {
        redeem_script_hex: redeem_hex,
        p2sh_spk_hex: tohex(address.script_pubkey().as_bytes()),
        p2sh_address: address.to_string(),
    })
}

/// Build the taker's BTC CLAIM (reverse swap): spend the maker's funded BTC HTLC
/// via the IF/preimage branch to `dest_address`, paying `amount - fee`. Only call
/// once the maker has revealed the preimage on the SEQ leg (read it with
/// [`xchain_read_seq_preimage`]). Returns raw tx hex for [`btc_broadcast`].
#[allow(clippy::too_many_arguments)]
pub fn xchain_btc_claim(
    mnemonic: String,
    btc_txid: String,
    btc_vout: u32,
    btc_amount_sats: u64,
    dest_address: String,
    fee_sats: u64,
    redeem_script_hex: String,
    preimage_hex: String,
) -> Result<String> {
    let (sk, _) = lwk_wollet::btc::xchain::btc_claim_keypair(
        &btc_params(),
        &mnemonic,
        lwk_wollet::btc::xchain::PathMode::Canonical,
    )
    .map_err(rerr)?;
    let redeem = lwk_wollet::bitcoin::ScriptBuf::from_hex(&redeem_script_hex).map_err(rerr)?;
    let dest = lwk_wollet::bitcoin::Address::from_str(&dest_address)
        .map_err(|_| err("invalid Bitcoin address".to_string()))?
        .require_network(lwk_wollet::bitcoin::Network::Testnet)
        .map_err(|_| err("address is not a Bitcoin testnet (tb1) address".to_string()))?;
    let spend = lwk_wollet::btc::htlc::BtcHtlcSpend {
        txid: btc_txid,
        vout: btc_vout,
        amount_sats: btc_amount_sats,
        dest_spk: dest.script_pubkey(),
        fee_sats,
    };
    lwk_wollet::btc::htlc::build_claim_tx(&redeem, &spend, &hexbytes(&preimage_hex)?, &sk).map_err(rerr)
}

/// Build the taker's SEQ asset-leg REFUND (reverse swap): spend the funded SEQ
/// HTLC back to `dest_address` via the CLTV/ELSE branch, valid once the SEQ tip
/// reaches `seq_locktime`. The refund key is the taker's OWN canonical SEQ key
/// (the one [`xchain_seq_htlc_reverse`] embedded as the refund pubkey). `fee_atoms`
/// is paid in the CLAIMED asset (the HTLC holds no native tSEQ): the caller MUST
/// derive it from the asset's published rate and cap it at half the output — the
/// flat forward-direction claim fee would be rejected as "Fee exceeds maximum" for
/// a valuable asset (memory principle 4). Returns raw Elements tx hex for
/// [`xchain_seq_broadcast`].
#[allow(clippy::too_many_arguments)]
pub fn xchain_seq_refund(
    mnemonic: String,
    seq_txid: String,
    seq_vout: u32,
    seq_amount: u64,
    seq_asset_id: String,
    dest_address: String,
    fee_atoms: u64,
    redeem_script_hex: String,
    seq_locktime: u32,
) -> Result<String> {
    let (sk, _) = lwk_wollet::btc::xchain::seq_claim_keypair(
        &btc_params(),
        &mnemonic,
        lwk_wollet::btc::xchain::PathMode::Canonical,
    )
    .map_err(rerr)?;
    let redeem = lwk_wollet::elements::Script::from(hexbytes(&redeem_script_hex)?);
    let dest = lwk_wollet::elements::Address::parse_with_params(&dest_address, crate::sequentia_testnet().address_params())
        .map_err(rerr)?;
    let spend = lwk_wollet::SeqHtlcSpend {
        txid: seq_txid,
        vout: seq_vout,
        amount: seq_amount,
        asset_id: seq_asset_id,
        dest_spk: dest.script_pubkey().as_bytes().to_vec(),
        fee: fee_atoms,
    };
    lwk_wollet::build_refund_tx(&spend, &redeem, &sk, seq_locktime).map_err(rerr)
}

/// Read the maker's revealed preimage from its on-chain spend of the taker's
/// funded SEQ asset leg (the reverse-swap reveal). Returns the preimage hex once
/// the leg is spent and a push hashing to `hash_hex` (H) is visible, else `None`.
/// The `sha256(push) == H` validation runs in trusted core — the taker learns the
/// secret from the chain, never on the counterparty's word.
pub fn xchain_read_seq_preimage(
    seq_esplora: String,
    seq_leg_txid: String,
    seq_vout: u32,
    hash_hex: String,
) -> Result<Option<String>> {
    lwk_wollet::btc::xchain::blocking::read_seq_preimage(&seq_esplora, &seq_leg_txid, seq_vout, &hash_hex).map_err(rerr)
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
    /// The asset id (hex) the network fee was paid in. Sequentia's open fee market
    /// lets the fee be ANY accepted asset, not just the policy asset, so the UI
    /// must label the fee with its real asset instead of assuming tSEQ. Falls back
    /// to the policy asset when the tx has no explicit fee output (fee == 0).
    pub fee_asset: String,
    pub deltas: Vec<AssetDelta>,
}

/// Sync and return the wallet's transaction history (net signed per-asset deltas
/// per tx). Ordering is left to the UI.
pub fn wallet_transactions(mnemonic: String, esplora_url: String) -> Result<Vec<TxRow>> {
    with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        // The policy asset is the fee-asset fallback for txs with no explicit fee
        // output (e.g. incoming, fee == 0).
        let policy = wollet.policy_asset();
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
                // The fee output's asset (any-asset fee market): the fee need not
                // be tSEQ. Read it straight off the tx's explicit fee output.
                let fee_asset = t
                    .tx
                    .output
                    .iter()
                    .find(|o| o.is_fee())
                    .and_then(|o| o.asset.explicit())
                    .unwrap_or(policy)
                    .to_string();
                TxRow {
                    txid: t.txid.to_string(),
                    height: t.height,
                    timestamp: t.timestamp.map(|ts| ts as u64),
                    kind,
                    fee: t.fee,
                    fee_asset,
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

// --- OpenAMP restricted-asset enclave signing --------------------------------
//
// OpenAMP holds a user's restricted (clawback-capable) assets in an enclave
// keyed by a DEDICATED taproot x-only key the wallet derives from its own
// mnemonic. The enclave never sees the private key: it hands the wallet the
// sighashes to sign for a transfer, the wallet Schnorr-signs each under the
// dedicated key, and the enclave completes the tx. This is the ONLY native
// crypto OpenAMP needs; everything else is plain HTTP in the Dart layer.

/// Lowercase hex-encode bytes (dependency-free; mirrors the signer module).
fn tohex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{x:02x}"));
    }
    s
}

/// Derive the dedicated OpenAMP keypair from the wallet mnemonic.
///
/// Uses the standard BIP39 seed (empty passphrase) — the same seed source as
/// the SeqLN device key — through a DEDICATED, otherwise-unused BIP32 path
/// **m/5/0**. That index is distinct from every other role Ambra derives: the
/// staker key at m/2/0, and the SeqLN device transport key at m/1017'/0'/0'.
/// A single key is used both to register the enclave user (its x-only pubkey)
/// and to Schnorr-sign transfer sighashes, so the two must agree bit-for-bit.
fn openamp_keypair(mnemonic: &str) -> Result<lwk_wollet::bitcoin::secp256k1::Keypair> {
    use lwk_wollet::bitcoin::secp256k1::{Keypair, Secp256k1};
    // Standard 64-byte BIP39 seed via the "32 zero bytes || mnemonic" on-disk
    // form (same path as seqln_device_transport_privkey); yields secret.seed.
    let mut bytes = vec![0u8; 32];
    bytes.extend_from_slice(mnemonic.trim().as_bytes());
    let secret = seqln_signer::hsm_secret::parse(&bytes).map_err(|e| err(format!("{e:?}")))?;
    let secp = Secp256k1::new();
    // The BIP32 network version affects only the (unused) xprv serialization, not
    // the derived private-key bytes, so testnet here is fine and cross-consistent.
    let master = lwk_wollet::bitcoin::bip32::Xpriv::new_master(
        lwk_wollet::bitcoin::Network::Testnet,
        &secret.seed,
    )
    .map_err(rerr)?;
    let path = DerivationPath::from(vec![
        ChildNumber::Normal { index: 5 },
        ChildNumber::Normal { index: 0 },
    ]);
    let child = master.derive_priv(&secp, &path).map_err(rerr)?;
    Ok(Keypair::from_secret_key(&secp, &child.private_key))
}

/// The 32-byte x-only public key (BIP340) at m/5/0, as 64-char hex — the key an
/// OpenAMP enclave user registers under (`POST /v1/users {pubkeys:[..]}`).
#[flutter_rust_bridge::frb(sync)]
pub fn openamp_xonly_pubkey(mnemonic: String) -> Result<String> {
    let kp = openamp_keypair(&mnemonic)?;
    let (xonly, _parity) = kp.x_only_public_key();
    Ok(xonly.to_string())
}

/// Schnorr-sign a 32-byte enclave transfer sighash (64-char hex) under the same
/// dedicated m/5/0 key, returning the 64-byte (128-char hex) BIP340 signature.
/// Verifies under the key from [`openamp_xonly_pubkey`].
#[flutter_rust_bridge::frb(sync)]
pub fn openamp_sign_sighash(mnemonic: String, sighash_hex: String) -> Result<String> {
    use lwk_wollet::bitcoin::secp256k1::{Message, Secp256k1};
    let kp = openamp_keypair(&mnemonic)?;
    let bytes = hexbytes(&sighash_hex)?;
    let arr: [u8; 32] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| err("sighash must be 32 bytes".to_string()))?;
    let msg = Message::from_digest(arr);
    let secp = Secp256k1::new();
    let sig = secp.sign_schnorr_no_aux_rand(&msg, &kp);
    Ok(tohex(&sig.serialize()))
}

// --- OpenAMP client-side safety mechanism (SWK-6, spec 0.4(3)) ---------------
//
// The enclave is hosted, so it MUST NOT be trusted to tell the wallet what it is
// signing. These are the three primitives the Dart layer uses to (1) verify the
// account id it registered under, (2) recompute every enclave-spend sighash
// itself and refuse to sign anything whose digest it cannot reproduce, and (3)
// decode a candidate spend into human-readable effects to show before signing.
//
// Ported from the SWK reference (`SWK/lwk_wollet/src/openamp.rs`); ambra_core
// does not compile lwk_wollet's `openamp` feature, and flutter_rust_bridge can
// only mirror structs declared in `crate::api`, so the pure functions + result
// structs live here directly. The elements crate is the SAME vendored fork SWK
// uses (`../../SWK/rust-elements`), so the taproot sighash is byte-identical
// (locked by `enclave_sighash_parity_vector` below).

use lwk_wollet::elements::hashes::{sha256, Hash, HashEngine};
use lwk_wollet::elements::sighash::{Prevouts, SchnorrSighashType, ScriptPath, SighashCache};
use lwk_wollet::elements::{confidential, BlockHash, Script, Transaction, TxOut};

/// Tag prepended to the sorted pubkey set before hashing to the AID (spec 0.2).
const OPENAMP_AID_TAG: &str = "openamp-aid-v1";

/// A transaction prevout as the wallet knows it: explicit asset id, explicit
/// value (atoms), and the scriptPubKey (hex). Restricted-asset transactions are
/// transparent (spec 0.6), so these are always explicit. Aligned 1:1 with the
/// transaction inputs when passed to [`enclave_sighash`] / [`decode_enclave_spend`].
pub struct EnclavePrevout {
    /// The prevout's asset id, display hex.
    pub asset: String,
    /// The prevout's explicit value, atoms.
    pub value: u64,
    /// The prevout's scriptPubKey, hex.
    pub script: String,
}

/// One decoded input of a candidate enclave spend.
pub struct EnclaveDecodedInput {
    /// Input index in the transaction.
    pub index: u32,
    /// Prevout txid, display hex.
    pub txid: String,
    /// Prevout vout.
    pub vout: u32,
    /// Prevout asset id (display hex) if the prevout was supplied.
    pub asset: Option<String>,
    /// Prevout value (atoms) if the prevout was supplied.
    pub value: Option<u64>,
    /// True when the prevout scriptPubKey is one of MY enclave scripts.
    pub mine: bool,
}

/// One decoded output of a candidate enclave spend.
pub struct EnclaveDecodedOutput {
    /// Output index in the transaction.
    pub index: u32,
    /// Explicit asset id (display hex), or `None` if the output is confidential.
    pub asset: Option<String>,
    /// Explicit value (atoms), or `None` if the output is confidential.
    pub value: Option<u64>,
    /// The output scriptPubKey, hex (empty for the Elements fee output).
    pub script: String,
    /// True for the explicit Elements fee output (empty scriptPubKey).
    pub is_fee: bool,
    /// True when this output pays one of MY enclave scripts (a receipt to me).
    pub mine: bool,
}

/// The human-readable effects of a candidate enclave spend, shown to the user
/// BEFORE signing (spec 0.4(3)): which of my UTXOs are spent, what each output
/// pays and to whom, and whether anything is confidential (a red flag).
pub struct EnclaveSpendEffects {
    /// The transaction id.
    pub txid: String,
    /// Every input, with `mine` set for my enclave prevouts.
    pub inputs: Vec<EnclaveDecodedInput>,
    /// Every output, with `mine` set for receipts to my enclave scripts.
    pub outputs: Vec<EnclaveDecodedOutput>,
    /// Indices of the inputs that spend MY enclave UTXOs.
    pub my_inputs_spent: Vec<u32>,
    /// True if ANY output is confidential (restricted-asset spends must be fully
    /// transparent, spec 2.4/0.6, so this is an integrity warning).
    pub any_confidential: bool,
}

fn enclave_prevout_to_txout(p: &EnclavePrevout) -> Result<TxOut> {
    let asset = AssetId::from_str(&p.asset)
        .map_err(|e| err(format!("invalid asset id {}: {e}", p.asset)))?;
    let spk = Script::from(hexbytes(&p.script)?);
    Ok(TxOut {
        asset: confidential::Asset::Explicit(asset),
        value: confidential::Value::Explicit(p.value),
        nonce: confidential::Nonce::Null,
        script_pubkey: spk,
        witness: Default::default(),
    })
}

fn enclave_prevouts_to_txouts(prevouts: &[EnclavePrevout]) -> Result<Vec<TxOut>> {
    prevouts.iter().map(enclave_prevout_to_txout).collect()
}

fn parse_openamp_tx(tx_hex: &str) -> Result<Transaction> {
    let bytes = hexbytes(tx_hex)?;
    lwk_wollet::elements::encode::deserialize(&bytes)
        .map_err(|e| err(format!("invalid tx hex: {e}")))
}

/// Recompute the Elements taproot script-path sighash (SIGHASH_DEFAULT,
/// genesis-committed) for a foreign NUMS enclave input, exactly as openampd does.
/// The leaf version is recovered from the control block's first byte with the
/// parity bit cleared (`0xc4` for an enclave leaf).
fn enclave_sighash_inner(
    tx: &Transaction,
    input_index: usize,
    prevouts: &[TxOut],
    leaf_script: &Script,
    control_block: &[u8],
    genesis_hash: BlockHash,
) -> Result<[u8; 32]> {
    if control_block.is_empty() {
        return Err(err("enclave control block is empty".to_string()));
    }
    if input_index >= tx.input.len() {
        return Err(err(format!(
            "input index {input_index} out of range ({} inputs)",
            tx.input.len()
        )));
    }
    if prevouts.len() != tx.input.len() {
        return Err(err(format!(
            "prevouts ({}) must align with inputs ({})",
            prevouts.len(),
            tx.input.len()
        )));
    }
    let leaf_version = control_block[0] & 0xfe;
    let script_path = ScriptPath::new(leaf_script, 0xFFFF_FFFF, leaf_version);
    let mut cache = SighashCache::new(tx);
    let sighash = cache
        .taproot_script_spend_signature_hash(
            input_index,
            &Prevouts::All(prevouts),
            script_path,
            SchnorrSighashType::Default,
            genesis_hash,
        )
        .map_err(|e| err(format!("enclave tapscript sighash: {e}")))?;
    Ok(sighash.to_byte_array())
}

/// Compute an OpenAMP AID locally from a set of 64-hex x-only pubkeys, exactly
/// matching Go `store.AID`: `hex(first 20 bytes of sha256("openamp-aid-v1" ||
/// pubkeys lowercased, sorted lexicographically, concatenated as UTF-8))`. The
/// wallet MUST call this and assert equality with the server's AID (spec 1.3);
/// a mismatch means the server registered a different or additional key.
#[flutter_rust_bridge::frb(sync)]
pub fn openamp_compute_aid(pubkeys: Vec<String>) -> String {
    let mut sorted: Vec<String> = pubkeys.iter().map(|p| p.trim().to_lowercase()).collect();
    sorted.sort();
    let mut engine = sha256::Hash::engine();
    engine.input(OPENAMP_AID_TAG.as_bytes());
    for p in &sorted {
        engine.input(p.as_bytes());
    }
    let digest = sha256::Hash::from_engine(engine).to_byte_array();
    tohex(&digest[..20])
}

/// The Sequentia network genesis block hash (hex), the taproot sighash domain
/// separator the wallet must pass to [`enclave_sighash`]. Resolved from the
/// active network so Dart never hardcodes it.
#[flutter_rust_bridge::frb(sync)]
pub fn sequentia_genesis_hash() -> String {
    crate::sequentia_testnet().genesis_hash().to_string()
}

/// Recompute the enclave-spend sighash the wallet must sign (SWK-6, spec 0.4(3)).
///
/// - `tx_hex`: the FULL unsigned transaction the enclave asked the wallet to sign.
/// - `input_index`: which input this enclave spend is.
/// - `prevouts`: `{asset, value, script}` for EVERY input, aligned by index
///   (taproot SIGHASH_DEFAULT commits to all prevout amounts + scripts).
/// - `leaf_script_hex`: the enclave transfer leaf.
/// - `control_block_hex`: the transfer-leaf control block (first byte = leaf
///   version `0xc4` with the parity bit).
/// - `genesis_hex`: the network genesis block hash (from [`sequentia_genesis_hash`]).
///
/// Returns the 32-byte sighash as hex. The wallet MUST sign THIS value and refuse
/// if it differs from the server's `to_sign` digest.
#[flutter_rust_bridge::frb(sync)]
pub fn enclave_sighash(
    tx_hex: String,
    input_index: u32,
    prevouts: Vec<EnclavePrevout>,
    leaf_script_hex: String,
    control_block_hex: String,
    genesis_hex: String,
) -> Result<String> {
    let tx = parse_openamp_tx(&tx_hex)?;
    let txouts = enclave_prevouts_to_txouts(&prevouts)?;
    let leaf = Script::from(hexbytes(&leaf_script_hex)?);
    let cb = hexbytes(&control_block_hex)?;
    let genesis =
        BlockHash::from_str(&genesis_hex).map_err(|e| err(format!("invalid genesis hash: {e}")))?;
    let digest = enclave_sighash_inner(&tx, input_index as usize, &txouts, &leaf, &cb, genesis)?;
    Ok(tohex(&digest))
}

/// Decode a candidate enclave-spend transaction into the effects a wallet must
/// display before signing (SWK-6, spec 0.4(3)). `my_scripts` is the set of MY
/// enclave scriptPubKeys (hex); a prevout or output matching one is flagged
/// `mine`. `prevouts` aligns with the transaction inputs; pass an empty list to
/// only enumerate each input's outpoint (txid/vout/index).
#[flutter_rust_bridge::frb(sync)]
pub fn decode_enclave_spend(
    tx_hex: String,
    prevouts: Vec<EnclavePrevout>,
    my_scripts: Vec<String>,
) -> Result<EnclaveSpendEffects> {
    let tx = parse_openamp_tx(&tx_hex)?;
    let txouts = enclave_prevouts_to_txouts(&prevouts)?;
    let mine: std::collections::BTreeSet<String> =
        my_scripts.iter().map(|s| s.trim().to_lowercase()).collect();

    let mut inputs = Vec::with_capacity(tx.input.len());
    let mut my_inputs_spent = Vec::new();
    for (i, txin) in tx.input.iter().enumerate() {
        let (asset, value, is_mine) = match txouts.get(i) {
            Some(o) => {
                let asset = match o.asset {
                    confidential::Asset::Explicit(a) => Some(a.to_string()),
                    _ => None,
                };
                let value = match o.value {
                    confidential::Value::Explicit(v) => Some(v),
                    _ => None,
                };
                let spk = tohex(o.script_pubkey.as_bytes());
                (asset, value, mine.contains(&spk))
            }
            None => (None, None, false),
        };
        if is_mine {
            my_inputs_spent.push(i as u32);
        }
        inputs.push(EnclaveDecodedInput {
            index: i as u32,
            txid: txin.previous_output.txid.to_string(),
            vout: txin.previous_output.vout,
            asset,
            value,
            mine: is_mine,
        });
    }

    let mut outputs = Vec::with_capacity(tx.output.len());
    let mut any_confidential = false;
    for (i, o) in tx.output.iter().enumerate() {
        let asset = match o.asset {
            confidential::Asset::Explicit(a) => Some(a.to_string()),
            _ => {
                any_confidential = true;
                None
            }
        };
        let value = match o.value {
            confidential::Value::Explicit(v) => Some(v),
            _ => {
                any_confidential = true;
                None
            }
        };
        let spk = tohex(o.script_pubkey.as_bytes());
        outputs.push(EnclaveDecodedOutput {
            index: i as u32,
            asset,
            value,
            script: spk.clone(),
            is_fee: o.is_fee(),
            mine: mine.contains(&spk),
        });
    }

    Ok(EnclaveSpendEffects {
        txid: tx.txid().to_string(),
        inputs,
        outputs,
        my_inputs_spent,
        any_confidential,
    })
}

#[cfg(test)]
mod openamp_tests {
    use super::*;
    use lwk_wollet::bitcoin::secp256k1::{schnorr, Message, Secp256k1, XOnlyPublicKey};

    // Standard BIP39 test vector mnemonic.
    const MNEMONIC: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn openamp_sign_verifies_under_pubkey() {
        let xonly_hex = openamp_xonly_pubkey(MNEMONIC.to_string()).unwrap();
        assert_eq!(xonly_hex.len(), 64, "x-only pubkey is 32 bytes");

        let sighash = "3333333333333333333333333333333333333333333333333333333333333344";
        let sig_hex = openamp_sign_sighash(MNEMONIC.to_string(), sighash.to_string()).unwrap();
        assert_eq!(sig_hex.len(), 128, "schnorr sig is 64 bytes");

        let secp = Secp256k1::new();
        let xonly = XOnlyPublicKey::from_str(&xonly_hex).unwrap();
        let sig = schnorr::Signature::from_slice(&hexbytes(&sig_hex).unwrap()).unwrap();
        let msg_arr: [u8; 32] = hexbytes(sighash).unwrap().try_into().unwrap();
        let msg = Message::from_digest(msg_arr);
        assert!(secp.verify_schnorr(&sig, &msg, &xonly).is_ok());
    }

    // AID parity: sorted, lowercased, tag-prefixed sha256 first-20 (== Go store.AID).
    #[test]
    fn openamp_aid_is_sorted_and_case_insensitive() {
        let pk = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let aid = openamp_compute_aid(vec![pk.to_string()]);
        assert_eq!(aid.len(), 40, "AID is 20 bytes as hex");
        let a = "aa".repeat(32);
        let b = "bb".repeat(32);
        assert_eq!(
            openamp_compute_aid(vec![a.clone(), b.clone()]),
            openamp_compute_aid(vec![b.clone(), a.to_uppercase()]),
            "AID must be order- and case-independent"
        );
        assert_ne!(openamp_compute_aid(vec![a.clone(), b]), openamp_compute_aid(vec![a]));
    }

    // Byte-parity with the SWK reference vector (openamp.rs:829): the SAME fixed
    // tx + prevout + 0xc4 NUMS transfer leaf must recompute to the SAME digest.
    // This proves the shared rust-elements taproot sighash is identical across the
    // two crates (the `sequentia` feature affects issuance parsing, not this path).
    #[test]
    fn enclave_sighash_parity_vector() {
        use lwk_wollet::elements::{
            confidential, AssetId, BlockHash, LockTime, OutPoint, Script, Sequence, Transaction,
            TxIn, TxInWitness, TxOut, Txid,
        };
        const ENCLAVE_NUMS_HEX: &str =
            "50929b74c1a04954b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac0";
        const ENCLAVE_LEAF_VERSION: u8 = 0xc4;
        let asset = AssetId::from_slice(&[0x01u8; 32]).unwrap();
        let value = 100_000u64;
        let spk = Script::from(
            hexbytes("5120aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                .unwrap(),
        );
        // transfer leaf: <32B K_user> CHECKSIGVERIFY <32B K_policy> CHECKSIG
        let mut leaf_bytes = vec![0x20u8];
        leaf_bytes.extend_from_slice(&[0xbbu8; 32]);
        leaf_bytes.push(0xad);
        leaf_bytes.push(0x20);
        leaf_bytes.extend_from_slice(&[0xccu8; 32]);
        leaf_bytes.push(0xac);
        let leaf = Script::from(leaf_bytes);
        let mut cb = vec![ENCLAVE_LEAF_VERSION];
        cb.extend_from_slice(&hexbytes(ENCLAVE_NUMS_HEX).unwrap());
        let genesis = BlockHash::from_str(
            "0000000000000000000000000000000000000000000000000000000000000042",
        )
        .unwrap();
        let tx = Transaction {
            version: 2,
            lock_time: LockTime::ZERO,
            input: vec![TxIn {
                previous_output: OutPoint::new(Txid::from_str(&"11".repeat(32)).unwrap(), 0),
                is_pegin: false,
                script_sig: Script::new(),
                sequence: Sequence::MAX,
                asset_issuance: Default::default(),
                witness: TxInWitness::default(),
            }],
            output: vec![
                TxOut {
                    asset: confidential::Asset::Explicit(asset),
                    value: confidential::Value::Explicit(value - 1000),
                    nonce: confidential::Nonce::Null,
                    script_pubkey: spk.clone(),
                    witness: Default::default(),
                },
                TxOut::new_fee(1000, asset),
            ],
        };
        let prevout = TxOut {
            asset: confidential::Asset::Explicit(asset),
            value: confidential::Value::Explicit(value),
            nonce: confidential::Nonce::Null,
            script_pubkey: spk,
            witness: Default::default(),
        };
        let sighash = enclave_sighash_inner(&tx, 0, &[prevout], &leaf, &cb, genesis).unwrap();
        assert_eq!(
            tohex(&sighash),
            "1bff568af1b88b0518ea7b82374b047e5d8383b9bd230bb20df68452001db43c",
            "enclave sighash drifted from the SWK reference vector"
        );
    }
}
