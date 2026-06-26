//! Cross-chain (BTC <-> Sequentia-asset) HTLC swap — the wallet's (Alice's) side.
//!
//! Alice holds BTC and wants the SEQ asset: she funds the BTC HTLC, the maker
//! funds the SEQ HTLC, Alice verifies the SEQ leg is anchor-safe (the reveal
//! gate), then claims it, revealing the preimage. SEQ-leg crypto reuses lwk's
//! `seqdex_htlc` primitives; the BTC leg lives in [`crate::btc_htlc`]. This module
//! is the glue: HTLC spend-key derivation, the swap secret, the reveal gate, and
//! the SEQ claim + broadcast.
//!
//! THE REVEAL GATE (anchoring's whole point — no cross-chain buffer): Alice may
//! reveal the preimage only when, read from her OWN nodes (never the maker), the
//! SEQ funding's Bitcoin anchor height A satisfies A >= H_btc, `getanchorstatus`
//! is "ok", and A is at least D Bitcoin-confirmations deep (D default 1 — the
//! same security as accepting that much BTC at 1 conf). See
//! doc/sequentia/03-bitcoin-anchoring.md + the theoretical paper, Principle 5.

use std::str::FromStr;
use std::time::Duration;

use lwk_signer::SwSigner;
use lwk_wollet::bitcoin::bip32::DerivationPath;
use lwk_wollet::bitcoin::hex::{DisplayHex, FromHex};
use lwk_wollet::bitcoin::secp256k1::{Secp256k1, SecretKey};

use crate::AmbraResult;

// HD paths for the HTLC spend keys: outside the receive(0)/change(1) branches so
// they're never swept as ordinary funds. The daemon doesn't enforce the path (it
// rebuilds scripts from the pubkeys Alice sends); they're deterministic from the
// seed, so only the swap secret (below) needs out-of-band persistence.
const SEQ_CLAIM_PATH: &str = "m/84h/1h/0h/3/0";
const BTC_REFUND_PATH: &str = "m/84h/1h/0h/2/0";

fn map<E: std::fmt::Debug>(e: E) -> String {
    format!("{e:?}")
}

fn hexdec(s: &str) -> AmbraResult<Vec<u8>> {
    Vec::<u8>::from_hex(s).map_err(map)
}

fn http() -> AmbraResult<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder().timeout(Duration::from_secs(30)).build().map_err(map)
}

/// Derive the secp256k1 keypair at `path`; returns (secret, 33-byte compressed pubkey hex).
pub fn derive_keypair(mnemonic: &str, path: &str) -> AmbraResult<(SecretKey, String)> {
    let signer = SwSigner::new(mnemonic, false).map_err(map)?;
    let xprv = signer.derive_xprv(&DerivationPath::from_str(path).map_err(map)?).map_err(map)?;
    let sk = xprv.private_key;
    let pubkey = sk.public_key(&Secp256k1::new()).serialize().to_lower_hex_string();
    Ok((sk, pubkey))
}

pub fn seq_claim_keypair(mnemonic: &str) -> AmbraResult<(SecretKey, String)> {
    derive_keypair(mnemonic, SEQ_CLAIM_PATH)
}
pub fn btc_refund_keypair(mnemonic: &str) -> AmbraResult<(SecretKey, String)> {
    derive_keypair(mnemonic, BTC_REFUND_PATH)
}

/// A fresh swap preimage + its SHA256 hashlock, as (secret_hex, hash_hex). The
/// secret is NOT HD-derivable; the caller MUST persist it before any money moves.
pub fn new_secret() -> (String, String) {
    let s = lwk_wollet::generate_swap_secret();
    (s.secret_hex, s.hash_hex)
}

/// Evidence + verdict of the reveal gate.
pub struct AnchorEvidence {
    pub seq_anchor_height: i64, // -1 if the SEQ block carries no anchor
    pub btc_leg_height: i64,    // H_btc (BTC funding confirmation height)
    pub btc_tip: i64,           // Alice's own testnet4 tip
    pub anchor_status: String,
    pub depth: i64, // btc_tip - seq_anchor_height + 1, or -1
    pub ok: bool,
}

/// Evaluate the reveal gate from Alice's own nodes. `min_depth` = D (default 1).
pub fn verify_seq_leg_safe(
    seq_esplora: &str,
    seq_block_hash: &str,
    btc_leg_height: i64,
    t4_api: &str,
    min_depth: i64,
) -> AmbraResult<AnchorEvidence> {
    let client = http()?;
    let seq = seq_esplora.trim_end_matches('/');
    let t4 = t4_api.trim_end_matches('/');

    // (b) the SEQ funding block's Bitcoin anchor height (already in esplora).
    let block: serde_json::Value =
        client.get(format!("{seq}/block/{seq_block_hash}")).send().map_err(map)?.json().map_err(map)?;
    let seq_anchor_height = block
        .get("bitcoin_anchor")
        .and_then(|a| a.get("height"))
        .and_then(|h| h.as_i64())
        .unwrap_or(-1); // omitted on a non-anchored chain -> not safe

    // (a) the tip's live anchor status.
    let status_v: serde_json::Value =
        client.get(format!("{seq}/sequentia/anchorstatus")).send().map_err(map)?.json().map_err(map)?;
    let anchor_status =
        status_v.get("anchorstatus").and_then(|s| s.as_str()).unwrap_or("unknown").to_string();

    // The Bitcoin tip from Alice's OWN testnet4 view (for the depth term).
    let btc_tip = client
        .get(format!("{t4}/blocks/tip/height"))
        .send()
        .map_err(map)?
        .text()
        .map_err(map)?
        .trim()
        .parse::<i64>()
        .map_err(map)?;

    let depth = if seq_anchor_height >= 0 { btc_tip - seq_anchor_height + 1 } else { -1 };
    let ok = seq_anchor_height >= 0
        && seq_anchor_height >= btc_leg_height
        && anchor_status == "ok"
        && depth >= min_depth;
    Ok(AnchorEvidence { seq_anchor_height, btc_leg_height, btc_tip, anchor_status, depth, ok })
}

/// The SEQ-leg redeemScript Alice rebuilds (claim = her SEQ-claim key, refund =
/// the maker's SEQ-refund pubkey). Returned as hex so the caller can byte-compare
/// it against the daemon-reported `seqLeg.redeemScript` (value-binding).
pub fn seq_redeem_script_hex(
    mnemonic: &str,
    hash_hex: &str,
    maker_seq_refund_pub_hex: &str,
    seq_locktime: u32,
) -> AmbraResult<String> {
    let (_sk, claim_pub_hex) = seq_claim_keypair(mnemonic)?;
    let script = lwk_wollet::build_htlc_redeem_script(
        &hexdec(hash_hex)?,
        &hexdec(&claim_pub_hex)?,
        &hexdec(maker_seq_refund_pub_hex)?,
        seq_locktime,
    )
    .map_err(map)?;
    Ok(script.as_bytes().to_lower_hex_string())
}

/// Build the SEQ claim tx (reveals the preimage). Rebuilds the redeemScript from
/// its components (so it's exactly the verified script), pays to Alice's own SEQ
/// `dest_address`. Returns the raw Elements tx hex.
#[allow(clippy::too_many_arguments)]
pub fn seq_claim(
    mnemonic: &str,
    seq_txid: &str,
    seq_vout: u32,
    seq_amount: u64,
    seq_asset_id: &str,
    dest_address: &str,
    hash_hex: &str,
    maker_seq_refund_pub_hex: &str,
    seq_locktime: u32,
    fee: u64,
    preimage_hex: &str,
) -> AmbraResult<String> {
    let (sk, claim_pub_hex) = seq_claim_keypair(mnemonic)?;
    let redeem = lwk_wollet::build_htlc_redeem_script(
        &hexdec(hash_hex)?,
        &hexdec(&claim_pub_hex)?,
        &hexdec(maker_seq_refund_pub_hex)?,
        seq_locktime,
    )
    .map_err(map)?;
    let dest = lwk_wollet::elements::Address::parse_with_params(
        dest_address,
        crate::sequentia_testnet().address_params(),
    )
    .map_err(map)?;
    // The claim pays `amount - fee` to dest + an explicit Elements fee output (in
    // the claimed asset). Fee must be < amount.
    if fee >= seq_amount {
        return Err("SEQ claim fee exceeds the leg amount".to_string());
    }
    let spend = lwk_wollet::SeqHtlcSpend {
        txid: seq_txid.to_string(),
        vout: seq_vout,
        amount: seq_amount,
        asset_id: seq_asset_id.to_string(),
        dest_spk: dest.script_pubkey().as_bytes().to_vec(),
        fee,
    };
    lwk_wollet::build_claim_tx(&spend, &redeem, &sk, &hexdec(preimage_hex)?).map_err(map)
}

/// Broadcast a raw Elements (SEQ) tx hex to the SEQ esplora; returns the txid.
pub fn seq_broadcast(seq_esplora: &str, tx_hex: &str) -> AmbraResult<String> {
    let base = seq_esplora.trim_end_matches('/');
    let resp = http()?.post(format!("{base}/tx")).body(tx_hex.to_string()).send().map_err(map)?;
    let ok = resp.status().is_success();
    let body = resp.text().map_err(map)?;
    let body = body.trim();
    if !ok {
        return Err(body.to_string());
    }
    if body.len() != 64 || !body.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(format!("unexpected broadcast response: {}", &body[..body.len().min(80)]));
    }
    Ok(body.to_string())
}
