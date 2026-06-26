//! Bitcoin parent-chain (testnet4) wallet for Ambra.
//!
//! Every Sequentia wallet is dual-chain: the same recovery phrase funds both the
//! Sequentia (Elements) side and the Bitcoin parent chain. The keychains are the
//! SAME — lwk's single-sig wpkh descriptor derives `m/84'/1'/0'/<0;1>/*` on
//! testnet (coin_type 1), and Sequentia testnet reuses Bitcoin testnet's `tb`
//! segwit HRP, so the wallet's unconfidential Sequentia address and its Bitcoin
//! address are the SAME string ("one address, both chains"). We therefore derive
//! the Bitcoin keys through the very same `SwSigner` lwk uses, guaranteeing
//! byte-identical addresses.
//!
//! This module is the Bitcoin analogue of the Sequentia send-flow: a small
//! esplora client (gap scan → balance, UTXO gather), and raw P2WPKH transaction
//! building + signing + broadcast. The `bitcoin` crate (via `lwk_wollet::bitcoin`)
//! supplies all the primitives the web wallet vendored from `@scure/btc-signer`.

use std::str::FromStr;
use std::time::Duration;

use lwk_signer::SwSigner;
use lwk_wollet::bitcoin::address::KnownHrp;
use lwk_wollet::bitcoin::bip32::DerivationPath;
use lwk_wollet::bitcoin::consensus::encode::serialize_hex;
use lwk_wollet::bitcoin::hashes::Hash;
use lwk_wollet::bitcoin::secp256k1::{All, Message, Secp256k1, SecretKey};
use lwk_wollet::bitcoin::sighash::SighashCache;
use lwk_wollet::bitcoin::{
    absolute::LockTime, transaction::Version, Address, Amount, CompressedPublicKey, EcdsaSighashType,
    Network, OutPoint, ScriptBuf, Sequence, Transaction, TxIn, TxOut, Txid, Witness,
};

use crate::AmbraResult;

/// BIP44 gap limit scanned per chain (external/internal) before stopping.
const GAP: u32 = 20;
/// P2WPKH dust threshold (sats); change at or below this is folded into the fee.
const DUST: u64 = 294;
/// Default fee rate (sat/vB) when the caller doesn't supply one.
pub const DEFAULT_FEERATE: f64 = 2.0;
/// Bound on gap-scan batches, so a pathological server can't loop forever.
const MAX_BATCHES: u32 = 64;
/// Concurrent esplora requests per batch (bounded so mobile doesn't spawn 40+ threads).
const CONCURRENCY: usize = 8;

fn map<E: std::fmt::Debug>(e: E) -> String {
    format!("{e:?}")
}

// --- esplora wire types (testnet4 /api) ---------------------------------------

#[derive(serde::Deserialize, Default)]
struct Stats {
    #[serde(default)]
    funded_txo_sum: i64,
    #[serde(default)]
    spent_txo_sum: i64,
    #[serde(default)]
    tx_count: i64,
}

#[derive(serde::Deserialize)]
struct AddrInfo {
    #[serde(default)]
    chain_stats: Stats,
    #[serde(default)]
    mempool_stats: Stats,
}

#[derive(serde::Deserialize)]
struct EsploraUtxo {
    txid: String,
    vout: u32,
    value: u64,
}

// --- key derivation (shared keychain with the Sequentia side) -----------------

/// One derived P2WPKH key: the spendable secret, the compressed pubkey, and the
/// `tb1` address / scriptPubKey it controls.
struct Key {
    sk: SecretKey,
    pk: CompressedPublicKey,
    address: Address,
    script: ScriptBuf,
}

fn signer(mnemonic: &str) -> AmbraResult<SwSigner> {
    // `is_mainnet = false` → testnet seed + the same `m/84'/1'/0'` keychain lwk uses.
    SwSigner::new(mnemonic, false).map_err(map)
}

fn derive(secp: &Secp256k1<All>, signer: &SwSigner, internal: bool, i: u32) -> AmbraResult<Key> {
    let path = DerivationPath::from_str(&format!("m/84h/1h/0h/{}/{}", internal as u8, i)).map_err(map)?;
    let xprv = signer.derive_xprv(&path).map_err(map)?;
    let sk = xprv.private_key;
    let pk = CompressedPublicKey(sk.public_key(secp));
    let address = Address::p2wpkh(&pk, KnownHrp::Testnets);
    let script = address.script_pubkey();
    Ok(Key { sk, pk, address, script })
}

/// The `tb1` address at a derivation slot — used by the alignment test and any
/// future BTC-specific receive flow. (Normal receive reuses the shared address.)
pub fn address(mnemonic: &str, internal: bool, i: u32) -> AmbraResult<String> {
    let secp = Secp256k1::new();
    Ok(derive(&secp, &signer(mnemonic)?, internal, i)?.address.to_string())
}

// --- esplora client + bounded-concurrency fetch -------------------------------

fn client() -> AmbraResult<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(map)
}

/// Map `f` over `items` with at most [`CONCURRENCY`] in-flight at once, preserving
/// order. Scoped threads borrow the client + base URL (no clones, no 'static bound).
fn par_fetch<I: Sync, R: Send>(
    client: &reqwest::blocking::Client,
    base: &str,
    items: &[I],
    f: impl Fn(&reqwest::blocking::Client, &str, &I) -> R + Sync,
) -> Vec<R> {
    let mut out = Vec::with_capacity(items.len());
    for chunk in items.chunks(CONCURRENCY) {
        let part = std::thread::scope(|s| {
            let handles: Vec<_> = chunk.iter().map(|it| s.spawn(|| f(client, base, it))).collect();
            handles.into_iter().map(|h| h.join().expect("esplora worker panicked")).collect::<Vec<_>>()
        });
        out.extend(part);
    }
    out
}

fn addr_info(client: &reqwest::blocking::Client, base: &str, addr: &String) -> Option<AddrInfo> {
    client.get(format!("{base}/address/{addr}")).send().ok()?.json::<AddrInfo>().ok()
}

fn addr_utxos(client: &reqwest::blocking::Client, base: &str, addr: &String) -> Vec<EsploraUtxo> {
    client
        .get(format!("{base}/address/{addr}/utxo"))
        .send()
        .ok()
        .and_then(|r| r.json::<Vec<EsploraUtxo>>().ok())
        .unwrap_or_default()
}

// --- scan → balance -----------------------------------------------------------

/// The result of a gap-limit scan of the Bitcoin keychain.
pub struct BtcScan {
    /// Confirmed + mempool balance, in sats.
    pub balance_sats: u64,
    /// Next unused external index (informational; receive reuses the shared addr).
    pub external_next: u32,
    /// Next change index to use for a new transaction.
    pub change_next: u32,
    /// How far (per chain) the scan reached — the window UTXO gathering covers.
    pub scan_limit: u32,
}

/// BIP44-style gap scan: keep scanning GAP-wide batches (external + internal) until
/// a whole batch shows no activity, so change that drifted past the first window is
/// still found. Balance = funded − spent across chain + mempool stats.
pub fn scan(mnemonic: &str, t4_api: &str) -> AmbraResult<BtcScan> {
    let secp = Secp256k1::new();
    let signer = signer(mnemonic)?;
    let client = client()?;
    let base = t4_api.trim_end_matches('/');

    let mut balance: i64 = 0;
    let (mut ext_max, mut chg_max): (i64, i64) = (-1, -1);
    let mut start: u32 = 0;
    let mut scanned: u32 = GAP;

    for _ in 0..MAX_BATCHES {
        // Derive this batch's external + internal addresses, then fetch concurrently.
        let mut slots: Vec<(bool, u32)> = Vec::with_capacity((GAP as usize) * 2);
        let mut addrs: Vec<String> = Vec::with_capacity((GAP as usize) * 2);
        for i in start..start + GAP {
            for internal in [false, true] {
                slots.push((internal, i));
                addrs.push(derive(&secp, &signer, internal, i)?.address.to_string());
            }
        }
        let infos = par_fetch(&client, base, &addrs, addr_info);

        let mut any = false;
        for ((internal, i), info) in slots.iter().zip(infos.into_iter()) {
            let Some(info) = info else { continue };
            let cs = info.chain_stats;
            let ms = info.mempool_stats;
            balance += (cs.funded_txo_sum - cs.spent_txo_sum) + (ms.funded_txo_sum - ms.spent_txo_sum);
            if cs.tx_count + ms.tx_count > 0 {
                any = true;
                if *internal {
                    chg_max = chg_max.max(*i as i64);
                } else {
                    ext_max = ext_max.max(*i as i64);
                }
            }
        }
        start += GAP;
        scanned = start;
        if !any {
            break;
        }
    }

    Ok(BtcScan {
        balance_sats: balance.max(0) as u64,
        external_next: (ext_max + 1) as u32,
        change_next: (chg_max + 1) as u32,
        scan_limit: scanned,
    })
}

// --- transaction building -----------------------------------------------------

struct Utxo {
    outpoint: OutPoint,
    value: u64,
    script: ScriptBuf,
    sk: SecretKey,
    pk: CompressedPublicKey,
}

/// Spendable UTXOs across the scanned window (both chains), each carrying its key.
fn gather_utxos(
    secp: &Secp256k1<All>,
    signer: &SwSigner,
    client: &reqwest::blocking::Client,
    base: &str,
    scan_limit: u32,
    change_next: u32,
) -> AmbraResult<Vec<Utxo>> {
    let lim = scan_limit.max(change_next + 1);
    let mut keys: Vec<Key> = Vec::with_capacity((lim as usize) * 2);
    for internal in [false, true] {
        for i in 0..lim {
            keys.push(derive(secp, signer, internal, i)?);
        }
    }
    let addrs: Vec<String> = keys.iter().map(|k| k.address.to_string()).collect();
    let lists = par_fetch(client, base, &addrs, addr_utxos);

    let mut utxos = Vec::new();
    for (k, list) in keys.iter().zip(lists.into_iter()) {
        for u in list {
            let txid = Txid::from_str(&u.txid).map_err(map)?;
            utxos.push(Utxo {
                outpoint: OutPoint { txid, vout: u.vout },
                value: u.value,
                script: k.script.clone(),
                sk: k.sk,
                pk: k.pk,
            });
        }
    }
    Ok(utxos)
}

/// Deterministic vbytes for a P2WPKH-only transaction.
fn vbytes(nin: usize, nout: usize) -> u64 {
    (10.75 + 68.0 * nin as f64 + 31.0 * nout as f64).ceil() as u64
}

/// A built, signed (but not yet broadcast) Bitcoin transaction.
pub struct BtcPrepared {
    pub hex: String,
    pub txid: String,
    pub fee_sats: u64,
    pub vsize: u64,
    pub inputs: u32,
}

/// Build + sign a P2WPKH transaction paying `amount_sats` to `dest_addr`, with
/// largest-first coin selection and change back to the next change address. Does
/// a fresh scan so the UTXO set and change index are current. Not broadcast.
pub fn prepare(
    mnemonic: &str,
    t4_api: &str,
    dest_addr: &str,
    amount_sats: u64,
    fee_rate: f64,
) -> AmbraResult<BtcPrepared> {
    if amount_sats == 0 {
        return Err("enter an amount greater than zero".into());
    }
    let fee_rate = if fee_rate > 0.0 { fee_rate } else { DEFAULT_FEERATE };
    let secp = Secp256k1::new();
    let signer = signer(mnemonic)?;
    let client = client()?;
    let base = t4_api.trim_end_matches('/');

    let dest = Address::from_str(dest_addr)
        .map_err(|_| "invalid Bitcoin address".to_string())?
        .require_network(Network::Testnet)
        .map_err(|_| "address is not a Bitcoin testnet (tb1) address".to_string())?;

    let scan = scan(mnemonic, base)?;
    let mut utxos = gather_utxos(&secp, &signer, &client, base, scan.scan_limit, scan.change_next)?;
    if utxos.is_empty() {
        return Err("no spendable BTC; the testnet4 balance is empty".into());
    }
    utxos.sort_by(|a, b| b.value.cmp(&a.value)); // largest first

    let fee_for = |nin: usize, nout: usize| (vbytes(nin, nout) as f64 * fee_rate).ceil() as u64;

    // Select until inputs cover amount + fee (assuming a change output).
    let mut sel: Vec<&Utxo> = Vec::new();
    let mut in_sum: u64 = 0;
    for u in &utxos {
        sel.push(u);
        in_sum += u.value;
        if in_sum >= amount_sats.saturating_add(fee_for(sel.len(), 2)) {
            break;
        }
    }

    let mut fee = fee_for(sel.len(), 2);
    let mut with_change = true;
    if in_sum < amount_sats.saturating_add(fee) {
        return Err("insufficient BTC for amount + fee".into());
    }
    let mut change = in_sum - amount_sats - fee;
    if change <= DUST {
        // Dust change isn't worth an output — fold it into the fee.
        with_change = false;
        let no_change_fee = fee_for(sel.len(), 1);
        if in_sum < amount_sats.saturating_add(no_change_fee) {
            return Err("insufficient BTC for amount + fee".into());
        }
        fee = in_sum - amount_sats;
        change = 0;
    }

    // Assemble inputs/outputs.
    let input: Vec<TxIn> = sel
        .iter()
        .map(|u| TxIn {
            previous_output: u.outpoint,
            script_sig: ScriptBuf::new(),
            sequence: Sequence::MAX,
            witness: Witness::new(),
        })
        .collect();

    let mut output = vec![TxOut { value: Amount::from_sat(amount_sats), script_pubkey: dest.script_pubkey() }];
    if with_change {
        let change_spk = derive(&secp, &signer, true, scan.change_next)?.script;
        output.push(TxOut { value: Amount::from_sat(change), script_pubkey: change_spk });
    }

    let mut tx = Transaction { version: Version::TWO, lock_time: LockTime::ZERO, input, output };

    // Sign each P2WPKH input (BIP143). Compute every sighash first (the cache holds
    // an immutable borrow of the tx), then drop it and attach the witnesses.
    let mut witnesses: Vec<Witness> = Vec::with_capacity(sel.len());
    {
        let mut cache = SighashCache::new(&tx);
        for (idx, u) in sel.iter().enumerate() {
            let sighash = cache
                .p2wpkh_signature_hash(idx, &u.script, Amount::from_sat(u.value), EcdsaSighashType::All)
                .map_err(map)?;
            let msg = Message::from_digest(sighash.to_byte_array());
            let sig = secp.sign_ecdsa(&msg, &u.sk);
            let es = lwk_wollet::bitcoin::ecdsa::Signature { signature: sig, sighash_type: EcdsaSighashType::All };
            witnesses.push(Witness::p2wpkh(&es, &u.pk.0));
        }
    }
    for (txin, w) in tx.input.iter_mut().zip(witnesses.into_iter()) {
        txin.witness = w;
    }

    Ok(BtcPrepared {
        hex: serialize_hex(&tx),
        txid: tx.compute_txid().to_string(),
        fee_sats: fee,
        vsize: tx.vsize() as u64,
        inputs: sel.len() as u32,
    })
}

/// Broadcast a raw transaction hex to testnet4; returns the txid on success.
pub fn broadcast(t4_api: &str, tx_hex: &str) -> AmbraResult<String> {
    let base = t4_api.trim_end_matches('/');
    let resp = client()?.post(format!("{base}/tx")).body(tx_hex.to_string()).send().map_err(map)?;
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

/// A located HTLC funding output on testnet4.
pub struct HtlcFunding {
    pub vout: u32,
    pub value_sats: u64,
    pub height: i64,        // -1 if unconfirmed
    pub confirmations: i64, // 0 if unconfirmed
}

/// Find the HTLC funding output in `txid` by matching `p2sh_spk_hex`. HARD-FAILS
/// if no output matches (never defaults to vout 0 — that could strand the lock).
/// Reports its value + the confirmation height/depth on Alice's own testnet4 view.
pub fn find_htlc_funding(t4_api: &str, txid: &str, p2sh_spk_hex: &str) -> AmbraResult<HtlcFunding> {
    let base = t4_api.trim_end_matches('/');
    let client = client()?;
    let tx: serde_json::Value =
        client.get(format!("{base}/tx/{txid}")).send().map_err(map)?.json().map_err(map)?;
    let vouts = tx.get("vout").and_then(|v| v.as_array()).ok_or_else(|| "funding tx has no vout".to_string())?;
    let mut found: Option<(u32, u64)> = None;
    for (i, o) in vouts.iter().enumerate() {
        let spk = o.get("scriptpubkey").and_then(|s| s.as_str()).unwrap_or("");
        if spk.eq_ignore_ascii_case(p2sh_spk_hex) {
            found = Some((i as u32, o.get("value").and_then(|v| v.as_u64()).unwrap_or(0)));
            break;
        }
    }
    let (vout, value_sats) = found.ok_or_else(|| "HTLC P2SH output not found in the funding tx".to_string())?;
    let status = tx.get("status");
    let confirmed = status.and_then(|s| s.get("confirmed")).and_then(|b| b.as_bool()).unwrap_or(false);
    let height = if confirmed {
        status.and_then(|s| s.get("block_height")).and_then(|h| h.as_i64()).unwrap_or(-1)
    } else {
        -1
    };
    let confirmations = if confirmed && height >= 0 {
        let tip = client
            .get(format!("{base}/blocks/tip/height"))
            .send()
            .map_err(map)?
            .text()
            .map_err(map)?
            .trim()
            .parse::<i64>()
            .unwrap_or(-1);
        if tip >= height {
            tip - height + 1
        } else {
            0
        }
    } else {
        0
    };
    Ok(HtlcFunding { vout, value_sats, height, confirmations })
}

#[cfg(test)]
mod tests {
    // The whole point of the dual-chain design: the Bitcoin address derived here
    // must be byte-identical to the lwk Sequentia wallet's unconfidential address
    // at the same index. If this ever fails, "one address, both chains" is broken.
    const MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn tb1_matches_lwk_unconfidential() {
        let btc0 = super::address(MNEMONIC, false, 0).unwrap();
        assert!(btc0.starts_with("tb1"), "expected a tb1 address, got {btc0}");

        let desc = crate::descriptor_from_mnemonic(MNEMONIC).unwrap();
        let wollet = crate::build_wollet(&desc).unwrap();
        let lwk0 = wollet.address(Some(0)).unwrap().address().to_unconfidential().to_string();

        assert_eq!(btc0, lwk0, "Bitcoin and Sequentia-unconfidential addresses must match");
    }
}
