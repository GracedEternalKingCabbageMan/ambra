//! SeqOB relay WIRE — the byte-exact port of the web wallet's `seqob.js`
//! deterministic Offer codec + signing, so a maker offer Ambra signs verifies at
//! the Go relay (validated against `internal/seqob/offer` ground truth).
//!
//! Ported to Rust (not Dart) because the maker signature must byte-match the Go
//! relay and reuse a real secp256k1 + sha256 (Ambra has both via
//! `lwk_wollet::secp256k1` / `lwk_wollet::elements::hashes`); Dart has no bundled
//! secp256k1. The plain-HTTP relay transport itself is the ONLY piece that stays
//! in Dart (`seqob_client.dart`), calling these signing FFIs.
//!
//! Only the same-chain + covenant settlement variants are produced (the wallet
//! posts same-chain covenant resting orders). The E2E WS-courier `lift` path is
//! NOT needed for the passive-covenant TAKE (it settles by broadcasting a
//! permissionless FILL) and is out of scope for Stage 1a.

use lwk_wollet::elements::hashes::{sha256, Hash};
use lwk_wollet::secp256k1::ecdsa::Signature;
use lwk_wollet::secp256k1::{Message, PublicKey, Secp256k1, SecretKey};
use serde_json::Value;

// --- base64 (standard, padded — matches JS btoa/atob) ----------------------

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(B64[((n >> 18) & 0x3f) as usize] as char);
        out.push(B64[((n >> 12) & 0x3f) as usize] as char);
        if chunk.len() > 1 {
            out.push(B64[((n >> 6) & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(B64[(n & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

fn b64_decode(s: &str) -> Result<Vec<u8>, String> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a' + 26) as u32),
            b'0'..=b'9' => Some((c - b'0' + 52) as u32),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let clean: Vec<u8> = s.bytes().filter(|&c| c != b'=' && !c.is_ascii_whitespace()).collect();
    let mut out = Vec::with_capacity(clean.len() / 4 * 3);
    for chunk in clean.chunks(4) {
        let mut n = 0u32;
        let mut bits = 0;
        for &c in chunk {
            let v = val(c).ok_or_else(|| "invalid base64".to_string())?;
            n = (n << 6) | v;
            bits += 6;
        }
        // Emit the high bytes for however many 6-bit groups we accumulated.
        let bytes = match chunk.len() {
            4 => 3,
            3 => 2,
            2 => 1,
            _ => 0,
        };
        n <<= 24 - bits;
        for i in 0..bytes {
            out.push(((n >> (16 - 8 * i)) & 0xff) as u8);
        }
    }
    Ok(out)
}

// --- minimal deterministic protobuf writer (mirrors seqob.js `PW`) ---------

struct Pw {
    b: Vec<u8>,
}

impl Pw {
    fn new() -> Self {
        Pw { b: Vec::new() }
    }
    fn varint(&mut self, mut n: u64) {
        while n > 0x7f {
            self.b.push(((n & 0x7f) as u8) | 0x80);
            n >>= 7;
        }
        self.b.push(n as u8);
    }
    fn tag(&mut self, field: u64, wtype: u64) {
        self.varint((field << 3) | wtype);
    }
    /// string (wiretype 2): omit empty (proto3 default).
    fn str(&mut self, field: u64, s: &str) {
        if s.is_empty() {
            return;
        }
        self.tag(field, 2);
        self.varint(s.len() as u64);
        self.b.extend_from_slice(s.as_bytes());
    }
    /// uint32/uint64 (wiretype 0): omit zero.
    fn uint(&mut self, field: u64, v: u64) {
        if v == 0 {
            return;
        }
        self.tag(field, 0);
        self.varint(v);
    }
    /// bool (wiretype 0): omit false.
    fn boolean(&mut self, field: u64, v: bool) {
        if !v {
            return;
        }
        self.tag(field, 0);
        self.varint(1);
    }
    /// length-delimited raw bytes (wiretype 2); always emitted.
    fn lenbytes(&mut self, field: u64, bytes: &[u8]) {
        self.tag(field, 2);
        self.varint(bytes.len() as u64);
        self.b.extend_from_slice(bytes);
    }
    /// embedded message (wiretype 2): emitted only when `sub` is present.
    fn msg(&mut self, field: u64, sub: Option<Vec<u8>>) {
        if let Some(bytes) = sub {
            self.lenbytes(field, &bytes);
        }
    }
    fn bytes(self) -> Vec<u8> {
        self.b
    }
}

// --- field readers (snake/camel tolerant, number-or-string) ----------------

fn get<'a>(o: &'a Value, names: &[&str]) -> Option<&'a Value> {
    let obj = o.as_object()?;
    for n in names {
        if let Some(v) = obj.get(*n) {
            if !v.is_null() {
                return Some(v);
            }
        }
    }
    None
}

fn as_u64(v: Option<&Value>) -> u64 {
    match v {
        Some(Value::Number(n)) => n.as_u64().unwrap_or(0),
        Some(Value::String(s)) => s.parse::<u64>().unwrap_or(0),
        _ => 0,
    }
}

fn as_str<'a>(v: Option<&'a Value>) -> &'a str {
    match v {
        Some(Value::String(s)) => s.as_str(),
        _ => "",
    }
}

fn as_bool(v: Option<&Value>) -> bool {
    matches!(v, Some(Value::Bool(true)))
        || matches!(v, Some(Value::String(s)) if s == "true")
        || matches!(v, Some(Value::Number(n)) if n.as_u64() == Some(1))
}

fn hex_to_bytes(h: &str) -> Vec<u8> {
    let clean: Vec<u8> = h.bytes().filter(u8::is_ascii_hexdigit).collect();
    let mut out = Vec::with_capacity(clean.len() / 2);
    let mut i = 0;
    while i + 1 < clean.len() {
        let hi = (clean[i] as char).to_digit(16).unwrap_or(0);
        let lo = (clean[i + 1] as char).to_digit(16).unwrap_or(0);
        out.push(((hi << 4) | lo) as u8);
        i += 2;
    }
    out
}

fn bytes_to_hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{x:02x}"));
    }
    s
}

fn trade_dir_num(v: Option<&Value>) -> u64 {
    match v {
        Some(Value::Number(n)) => n.as_u64().unwrap_or(0),
        Some(Value::String(s)) => match s.as_str() {
            "TRADE_DIR_SELL" | "1" => 1,
            "TRADE_DIR_BUY" | "2" => 2,
            _ => s.parse::<u64>().unwrap_or(0),
        },
        _ => 0,
    }
}

// --- sub-message encoders --------------------------------------------------

fn encode_asset_pair(p: Option<&Value>) -> Option<Vec<u8>> {
    let p = p?;
    let mut w = Pw::new();
    w.str(1, as_str(get(p, &["base_asset", "baseAsset"])));
    w.str(2, as_str(get(p, &["quote_asset", "quoteAsset"])));
    Some(w.bytes())
}

fn encode_same_chain(s: Option<&Value>) -> Option<Vec<u8>> {
    let s = s?;
    let mut w = Pw::new();
    w.str(1, as_str(get(s, &["maker_recv_address", "makerRecvAddress"])));
    w.str(2, as_str(get(s, &["maker_blinding_pub", "makerBlindingPub"])));
    Some(w.bytes())
}

fn encode_cross_chain(c: Option<&Value>) -> Option<Vec<u8>> {
    let c = c?;
    let mut w = Pw::new();
    w.str(1, as_str(get(c, &["btc_sentinel", "btcSentinel"])));
    w.str(2, as_str(get(c, &["maker_claim_pub", "makerClaimPub"])));
    w.str(3, as_str(get(c, &["maker_refund_pub", "makerRefundPub"])));
    w.uint(4, as_u64(get(c, &["maker_leg_locktime", "makerLegLocktime"])));
    w.str(5, as_str(get(c, &["maker_recv_address", "makerRecvAddress"])));
    w.uint(6, as_u64(get(c, &["direction"])));
    Some(w.bytes())
}

fn encode_covenant_terms(c: Option<&Value>) -> Option<Vec<u8>> {
    let c = c?;
    let mut w = Pw::new();
    w.str(1, as_str(get(c, &["covenant_txid", "covenantTxid"])));
    w.uint(2, as_u64(get(c, &["covenant_vout", "covenantVout"])));
    w.str(3, as_str(get(c, &["asset_a", "assetA"])));
    w.str(4, as_str(get(c, &["asset_b", "assetB"])));
    w.uint(5, as_u64(get(c, &["rate_num", "rateNum"])));
    w.uint(6, as_u64(get(c, &["rate_den", "rateDen"])));
    w.lenbytes(7, &hex_to_bytes(as_str(get(c, &["maker_prog", "makerProg"]))));
    w.uint(8, as_u64(get(c, &["maker_prog_ver", "makerProgVer"])));
    w.uint(9, as_u64(get(c, &["min_lot", "minLot"])));
    w.uint(10, as_u64(get(c, &["expiry_locktime", "expiryLocktime"])));
    w.lenbytes(11, &hex_to_bytes(as_str(get(c, &["maker_x", "makerX"]))));
    w.lenbytes(12, &hex_to_bytes(as_str(get(c, &["internal_key", "internalKey"]))));
    if let Some(Value::Array(arr)) = get(c, &["merkle_path", "merklePath"]) {
        for p in arr {
            if let Value::String(s) = p {
                w.lenbytes(13, &hex_to_bytes(s));
            }
        }
    }
    Some(w.bytes())
}

/// Deterministic proto encoding of `seqob.v1.Offer` with `maker_sig` cleared,
/// fields in ascending number order — the exact bytes the Go relay signs/verifies.
pub fn canonical_offer_bytes(o: &Value) -> Vec<u8> {
    let mut w = Pw::new();
    w.str(1, as_str(get(o, &["offer_id", "offerId"])));
    w.uint(2, as_u64(get(o, &["schema_version", "schemaVersion"])));
    w.msg(3, encode_asset_pair(get(o, &["pair"])));
    w.tag_enum(4, trade_dir_num(get(o, &["trade_dir", "tradeDir"])));
    w.uint(5, as_u64(get(o, &["base_amount", "baseAmount"])));
    w.uint(6, as_u64(get(o, &["offer_amount", "offerAmount"])));
    w.str(7, as_str(get(o, &["offer_asset", "offerAsset"])));
    w.uint(8, as_u64(get(o, &["want_amount", "wantAmount"])));
    w.str(9, as_str(get(o, &["want_asset", "wantAsset"])));
    w.boolean(10, as_bool(get(o, &["allow_partial", "allowPartial"])));
    w.uint(11, as_u64(get(o, &["min_fill", "minFill"])));
    w.uint(12, as_u64(get(o, &["created_at_unix", "createdAtUnix"])));
    w.uint(13, as_u64(get(o, &["expires_at_unix", "expiresAtUnix"])));
    w.str(14, as_str(get(o, &["maker_pubkey", "makerPubkey"])));
    w.str(15, as_str(get(o, &["fee_asset_hint", "feeAssetHint"])));
    w.uint(16, as_u64(get(o, &["min_anchor_depth", "minAnchorDepth"])));
    w.str(17, as_str(get(o, &["maker_ln_node_pubkey", "makerLnNodePubkey"])));
    if let Some(Value::Array(arr)) = get(o, &["ln_connect_hints", "lnConnectHints"]) {
        for h in arr {
            if let Value::String(s) = h {
                w.str(18, s);
            }
        }
    }
    w.boolean(19, as_bool(get(o, &["confidential"])));
    w.msg(20, encode_same_chain(get(o, &["same_chain", "sameChain"])));
    w.msg(21, encode_cross_chain(get(o, &["cross_chain", "crossChain"])));
    w.msg(23, encode_covenant_terms(get(o, &["covenant"])));
    // maker_sig (31) is deliberately omitted.
    w.bytes()
}

impl Pw {
    /// enum (wiretype 0): omit zero (proto3 default), same as `uint`.
    fn tag_enum(&mut self, field: u64, v: u64) {
        self.uint(field, v);
    }
}

// --- ECDSA sign / verify over sha256(canonical) ----------------------------

fn sha256d(bytes: &[u8]) -> [u8; 32] {
    sha256::Hash::hash(bytes).to_byte_array()
}

/// Sign an offer object in place: set `maker_pubkey` from `priv`, then
/// `maker_sig` = base64(DER ECDSA over sha256(canonical)). `priv` is 32 bytes.
pub fn sign_offer(offer: &mut Value, priv_key: &[u8; 32]) -> Result<(), String> {
    let sk = SecretKey::from_slice(priv_key).map_err(|e| format!("bad maker key: {e}"))?;
    let secp = Secp256k1::new();
    let pk = PublicKey::from_secret_key(&secp, &sk);
    let map = offer
        .as_object_mut()
        .ok_or_else(|| "offer must be a JSON object".to_string())?;
    map.insert("maker_pubkey".into(), Value::String(bytes_to_hex(&pk.serialize())));
    map.remove("maker_sig");
    let h = sha256d(&canonical_offer_bytes(offer));
    let msg = Message::from_digest(h);
    let sig = secp.sign_ecdsa(&msg, &sk); // RFC6979, low-S normalized
    let der = sig.serialize_der();
    offer
        .as_object_mut()
        .unwrap()
        .insert("maker_sig".into(), Value::String(b64_encode(der.as_ref())));
    Ok(())
}

/// Verify a relay-served offer's maker signature. Never panics; returns false on
/// any malformed field.
pub fn verify_offer(offer: &Value) -> bool {
    let sig_b64 = as_str(get(offer, &["maker_sig", "makerSig"]));
    let pub_hex = as_str(get(offer, &["maker_pubkey", "makerPubkey"]));
    if sig_b64.is_empty() || pub_hex.is_empty() {
        return false;
    }
    let der = match b64_decode(sig_b64) {
        Ok(d) => d,
        Err(_) => return false,
    };
    let mut sig = match Signature::from_der(&der) {
        Ok(s) => s,
        Err(_) => return false,
    };
    sig.normalize_s();
    let pk = match PublicKey::from_slice(&hex_to_bytes(pub_hex)) {
        Ok(p) => p,
        Err(_) => return false,
    };
    let h = sha256d(&canonical_offer_bytes(offer));
    let msg = Message::from_digest(h);
    Secp256k1::verification_only().verify_ecdsa(&msg, &sig, &pk).is_ok()
}

/// The maker's compressed identity pubkey hex for a 32-byte maker private key.
pub fn maker_pubkey_hex(priv_key: &[u8; 32]) -> Result<String, String> {
    let sk = SecretKey::from_slice(priv_key).map_err(|e| format!("bad maker key: {e}"))?;
    let pk = PublicKey::from_secret_key(&Secp256k1::new(), &sk);
    Ok(bytes_to_hex(&pk.serialize()))
}

/// Build a signed `OfferCancel` JSON for an offer the wallet made. Deterministic
/// canonical cancel bytes = `{offer_id=1, maker_pubkey=2, nonce=3}` with the sig
/// cleared, signed like an offer.
pub fn sign_cancel(offer_id: &str, priv_key: &[u8; 32], nonce: u64) -> Result<Value, String> {
    let sk = SecretKey::from_slice(priv_key).map_err(|e| format!("bad maker key: {e}"))?;
    let secp = Secp256k1::new();
    let pk = PublicKey::from_secret_key(&secp, &sk);
    let maker_pub = bytes_to_hex(&pk.serialize());
    let nonce_str = nonce.to_string();

    let mut w = Pw::new();
    w.str(1, offer_id);
    w.str(2, &maker_pub);
    w.uint(3, nonce);
    let h = sha256d(&w.bytes());
    let msg = Message::from_digest(h);
    let sig = secp.sign_ecdsa(&msg, &sk);
    let sig_b64 = b64_encode(sig.serialize_der().as_ref());

    Ok(serde_json::json!({
        "offer_id": offer_id,
        "maker_pubkey": maker_pub,
        "nonce": nonce_str,
        "sig": sig_b64,
    }))
}

/// `makerKeyFromSeed` — a stable, domain-separated maker identity key derived from
/// wallet-private entropy (`sha256("seqob-maker-identity-v1" || seed)`), so a
/// posted offer survives a reload and can be cancelled. NOT a fund key.
pub fn maker_key_from_seed(seed: &[u8]) -> Result<[u8; 32], String> {
    let mut buf = Vec::with_capacity(23 + seed.len());
    buf.extend_from_slice(b"seqob-maker-identity-v1");
    buf.extend_from_slice(seed);
    let k = sha256d(&buf);
    // A sha256 output is a valid secp256k1 scalar w.h.p.; reject the astronomically
    // rare out-of-range case rather than silently producing a bad key.
    SecretKey::from_slice(&k).map_err(|e| format!("derived maker key invalid: {e}"))?;
    Ok(k)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_roundtrip() {
        for v in [vec![], vec![0u8], vec![1, 2, 3], vec![255, 254, 0, 17, 42, 200]] {
            assert_eq!(b64_decode(&b64_encode(&v)).unwrap(), v);
        }
        // Known vector.
        assert_eq!(b64_encode(b"Man"), "TWFu");
        assert_eq!(b64_encode(b"Ma"), "TWE=");
        assert_eq!(b64_decode("TWFu").unwrap(), b"Man");
    }

    #[test]
    fn proto_omits_zero_and_empty() {
        let mut w = Pw::new();
        w.str(1, "");
        w.uint(2, 0);
        w.boolean(3, false);
        assert!(w.bytes().is_empty());
    }

    #[test]
    fn sign_then_verify_roundtrips() {
        let priv_key = [7u8; 32];
        let mut offer = serde_json::json!({
            "offer_id": "abc123",
            "schema_version": 1,
            "pair": { "base_asset": "aa", "quote_asset": "bb" },
            "trade_dir": 1,
            "base_amount": "1000000000",
            "offer_amount": "1000000000", "offer_asset": "aa",
            "want_amount": "300000000", "want_asset": "bb",
            "allow_partial": true,
            "created_at_unix": "1700000000",
            "expires_at_unix": "1700003600",
            "fee_asset_hint": "bb",
            "same_chain": { "maker_recv_address": "tex1qexample" },
            "covenant": {
                "covenant_txid": "11",
                "covenant_vout": 0,
                "asset_a": "aa", "asset_b": "bb",
                "rate_num": "3", "rate_den": "7",
                "maker_prog": "11".repeat(32),
                "maker_prog_ver": 1,
                "min_lot": "500000000",
                "expiry_locktime": 400,
                "maker_x": "22".repeat(32),
                "internal_key": crate::seqob_covenant_derive::NUMS_HEX,
                "merkle_path": ["33".repeat(32)],
            },
        });
        sign_offer(&mut offer, &priv_key).unwrap();
        assert!(verify_offer(&offer), "self-signed offer must verify");
        // Tampering the amount breaks verification.
        offer["base_amount"] = Value::String("999".into());
        assert!(!verify_offer(&offer), "tampered offer must not verify");
    }

    #[test]
    fn canonical_is_stable_and_excludes_sig() {
        let base = serde_json::json!({
            "offer_id": "x", "schema_version": 1, "trade_dir": 1,
            "base_amount": "5", "maker_pubkey": "02aa",
        });
        let mut with_sig = base.clone();
        with_sig["maker_sig"] = Value::String("ZZZZ".into());
        assert_eq!(canonical_offer_bytes(&base), canonical_offer_bytes(&with_sig));
    }

    #[test]
    fn maker_key_is_deterministic() {
        let a = maker_key_from_seed(b"seed-bytes-abc").unwrap();
        let b = maker_key_from_seed(b"seed-bytes-abc").unwrap();
        assert_eq!(a, b);
        assert_ne!(a, maker_key_from_seed(b"seed-bytes-xyz").unwrap());
    }
}
