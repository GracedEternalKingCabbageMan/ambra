//! E2E courier crypter for the cross (BTC<->asset) swap co-sign. Byte-matches the Go relay's XcMsg
//! sealing and the web wallet's seqob.js `Crypter`: the session key is `sha256` of the RAW secp256k1
//! ECDH X-coordinate (matching `btcec.GenerateSharedSecret`, which returns the 32-byte X — NOT the
//! hashed shared secret), and a message is sealed with AES-256-GCM laid out as
//! `nonce(12) || ciphertext || tag(16)`. The relay only ever moves sealed bytes; the XcMsg JSON is the
//! plaintext. Ported to Rust (not Dart) so the crypto byte-matches the peers exactly.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use lwk_wollet::elements::hashes::{sha256, Hash};
use lwk_wollet::secp256k1::{PublicKey, Scalar, Secp256k1, SecretKey};

/// The 32-byte AES key for this session: `sha256(ECDH_X(my_priv, peer_pub))`.
fn session_key(my_priv: &[u8; 32], peer_pub: &[u8]) -> Result<[u8; 32], String> {
    let secp = Secp256k1::new();
    // Validate the key even though the scalar drives the multiply (a bad key must fail loudly).
    SecretKey::from_slice(my_priv).map_err(|e| format!("bad courier key: {e}"))?;
    let pk = PublicKey::from_slice(peer_pub).map_err(|e| format!("bad peer pubkey: {e}"))?;
    let scalar = Scalar::from_be_bytes(*my_priv).map_err(|_| "courier key out of range".to_string())?;
    let shared = pk.mul_tweak(&secp, &scalar).map_err(|e| format!("ecdh: {e}"))?;
    // Uncompressed = 0x04 || X(32) || Y(32); take the RAW X (matches btcec.GenerateSharedSecret).
    let unc = shared.serialize_uncompressed();
    Ok(sha256::Hash::hash(&unc[1..33]).to_byte_array())
}

/// Seal a plaintext XcMsg for the peer: `nonce(12) || AES-256-GCM(ciphertext || tag16)`.
pub fn seal(my_priv: &[u8; 32], peer_pub: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, String> {
    let key = session_key(my_priv, peer_pub)?;
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
    let mut nonce = [0u8; 12];
    getrandom::getrandom(&mut nonce).map_err(|e| format!("nonce: {e}"))?;
    let ct = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext)
        .map_err(|_| "seal failed".to_string())?;
    let mut out = Vec::with_capacity(12 + ct.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    Ok(out)
}

/// Open a sealed XcMsg from the peer. Errors on any tampering (GCM auth-tag mismatch).
pub fn open(my_priv: &[u8; 32], peer_pub: &[u8], sealed: &[u8]) -> Result<Vec<u8>, String> {
    if sealed.len() < 12 + 16 {
        return Err("ciphertext too short".to_string());
    }
    let key = session_key(my_priv, peer_pub)?;
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
    cipher
        .decrypt(Nonce::from_slice(&sealed[0..12]), &sealed[12..])
        .map_err(|_| "open failed (auth tag mismatch)".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_open_roundtrip_and_tamper() {
        let secp = Secp256k1::new();
        let a = SecretKey::from_slice(&[0x11u8; 32]).unwrap();
        let b = SecretKey::from_slice(&[0x22u8; 32]).unwrap();
        let a_pub = PublicKey::from_secret_key(&secp, &a).serialize();
        let b_pub = PublicKey::from_secret_key(&secp, &b).serialize();
        let msg = br#"{"type":"terms_request"}"#;

        // ECDH is symmetric: A seals to B, B opens from A.
        let sealed = seal(&a.secret_bytes(), &b_pub, msg).unwrap();
        assert_eq!(open(&b.secret_bytes(), &a_pub, &sealed).unwrap(), msg);

        // The session key is deterministic from both sides.
        assert_eq!(
            session_key(&a.secret_bytes(), &b_pub).unwrap(),
            session_key(&b.secret_bytes(), &a_pub).unwrap()
        );

        // Tampering the last byte (in the tag) fails the auth check.
        let mut bad = sealed.clone();
        *bad.last_mut().unwrap() ^= 0xff;
        assert!(open(&b.secret_bytes(), &a_pub, &bad).is_err());
    }
}
