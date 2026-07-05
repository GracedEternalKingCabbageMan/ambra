//! Byte-for-byte conformance of the phone-side FFI device signer, plus a
//! Noise_XK initiator<->responder handshake round-trip.
//!
//! The proof: the SAME real-channel request corpus the browser WASM signer and
//! the native `seqln-signer` replay (99 frames captured from a live channel) is
//! driven through the Ambra FFI `process_frame` and byte-compared against
//! libhsmd's OWN replies (`oracle_replies.bin`, dumped from the reference
//! `lightning_signerd` binary — see
//! `seqln/contrib/seqln-signer/src/bin/conformance.rs`). Byte-identical means
//! the phone signs a hosted node's operations exactly as libhsmd would — across
//! ECDH, key derivation, BIP32/BIP86 checks, commitment/HTLC/penalty tx
//! signatures, gossip signatures, invoice signing, and the validation subset.
//!
//! The corpus node's `hsm_secret` is the canonical PUBLIC BIP-39 all-zero test
//! vector ("abandon ... about"), so the fixtures carry no secret; the signer is
//! reconstructed from that public mnemonic.

use ambra_core::api::signer::{device_pubkey, NoiseSession, SeqlnSigner};

/// The corpus node's mnemonic — the public all-zero BIP-39 test vector (also
/// hardcoded in `seqln-signer`'s own conformance harness). NOT a secret.
const MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

/// Split a byte stream of length-prefixed records (`u32-LE len || len bytes`)
/// into whole records INCLUDING the 4-byte length prefix — exactly the framing
/// of both a request frame and a framed reply.
fn split_records(buf: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let mut off = 0usize;
    while off + 4 <= buf.len() {
        let len = u32::from_le_bytes(buf[off..off + 4].try_into().unwrap()) as usize;
        let end = off + 4 + len;
        assert!(end <= buf.len(), "truncated record at {off}");
        out.push(buf[off..end].to_vec());
        off = end;
    }
    out
}

/// The hsmd message type of a framed reply (first big-endian u16 of the body
/// after the 4-byte frame length); 0 for the zero-length sentinel.
fn reply_type(record: &[u8]) -> u16 {
    let len = u32::from_le_bytes(record[0..4].try_into().unwrap()) as usize;
    if len < 2 {
        return 0;
    }
    u16::from_be_bytes(record[4..6].try_into().unwrap())
}

/// Parse the compressed node id out of a `WIRE_HSMD_INIT_REPLY_V4` framed reply:
/// `[u32 len] u16 type(114) u32 hsm_version u16 num_caps caps(4*n) node_id(33)`.
fn node_id_from_init_reply(framed: &[u8]) -> Option<String> {
    let body = &framed[4..];
    if body.len() < 8 || u16::from_be_bytes(body[0..2].try_into().unwrap()) != 114 {
        return None;
    }
    let num_caps = u16::from_be_bytes(body[6..8].try_into().unwrap()) as usize;
    let off = 2 + 4 + 2 + 4 * num_caps;
    if body.len() < off + 33 {
        return None;
    }
    Some(hex(&body[off..off + 33]))
}

fn hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{x:02x}"));
    }
    s
}

const CORPUS: &[u8] = include_bytes!("fixtures/t2m2b-corpus.bin");
const ORACLE: &[u8] = include_bytes!("fixtures/oracle_replies.bin");

/// The whole point: replay the real corpus through the FFI `process_frame` and
/// byte-compare every reply to libhsmd's. SUCCESS = 99/99 byte-identical.
#[test]
fn corpus_byte_exact_vs_libhsmd() {
    let requests = split_records(CORPUS);
    let oracle = split_records(ORACLE);
    assert_eq!(
        requests.len(),
        oracle.len(),
        "corpus/oracle record count mismatch"
    );

    let signer = SeqlnSigner::from_mnemonic(MNEMONIC.to_string()).expect("construct signer");

    // Reply types that carry a real cryptographic signature: SIGN_TX_REPLY (112,
    // commitment/HTLC/penalty compact ECDSA + sighash), CUPDATE (103),
    // CANNOUNCEMENT (104, node+bitcoin sigs), NODE_ANNOUNCEMENT (106), and
    // SIGN_INVOICE (108, recoverable ECDSA).
    let sig_types = [103u16, 104, 106, 108, 112];

    let mut passed = 0usize;
    let mut sig_ops = 0usize;
    let mut tx_sigs = 0usize;
    for (i, (req, want)) in requests.iter().zip(oracle.iter()).enumerate() {
        let got = signer
            .process_frame(req.clone())
            .unwrap_or_else(|e| panic!("entry {i}: process_frame errored: {e}"));
        assert_eq!(
            hex(&got),
            hex(want),
            "entry {i} (reply type {}) byte mismatch",
            reply_type(want)
        );
        let t = reply_type(want);
        if sig_types.contains(&t) {
            sig_ops += 1;
        }
        if t == 112 {
            tx_sigs += 1;
        }
        passed += 1;
    }
    assert_eq!(passed, 99, "expected the full 99-frame corpus");
    assert!(tx_sigs > 0, "corpus should exercise tx-signature replies");
    println!(
        "conformance: {passed}/{passed} byte-exact vs libhsmd \
         ({sig_ops} signing ops, {tx_sigs} commitment/HTLC/penalty tx signatures)"
    );
}

/// Enforce mode must not regress legitimate signing: the M4 validating policy
/// witnesses SETUP_CHANNEL and permits every honest sign, so the SAME corpus
/// replays byte-identically with the policy turned ON.
#[test]
fn corpus_byte_exact_in_enforce_mode() {
    let requests = split_records(CORPUS);
    let oracle = split_records(ORACLE);
    let signer = SeqlnSigner::from_mnemonic(MNEMONIC.to_string()).expect("construct signer");
    signer.set_enforce(true);
    for (i, (req, want)) in requests.iter().zip(oracle.iter()).enumerate() {
        let got = signer
            .process_frame(req.clone())
            .unwrap_or_else(|e| panic!("entry {i}: process_frame errored: {e}"));
        assert_eq!(hex(&got), hex(want), "entry {i} differs in enforce mode");
    }
}

/// `node_id()` (derived from the mnemonic) matches the node id libhsmd embeds in
/// the INIT reply for the same secret.
#[test]
fn node_id_matches_init_reply() {
    let oracle = split_records(ORACLE);
    let want = oracle
        .iter()
        .find_map(|r| node_id_from_init_reply(r))
        .expect("corpus has an INIT reply carrying a node id");
    let signer = SeqlnSigner::from_mnemonic(MNEMONIC.to_string()).expect("construct signer");
    assert_eq!(signer.node_id(), want, "device node_id != libhsmd node_id");
}

/// The FFI Noise_XK **initiator** interoperates with the exact `Responder` the
/// hosted proxy runs (same `seqln_signer::noise` code): full handshake, mutual
/// static-key auth, then encrypted transport records both directions. This is
/// the device<->host secure link, proven without booting a node.
#[test]
fn noise_initiator_handshake_and_transport() {
    use seqln_signer::noise::{static_pubkey, Responder, BODY_OVERHEAD, HDR_SIZE};

    let device_priv = [0x11u8; 32];
    let host_priv = [0x22u8; 32];
    let device_pub = static_pubkey(&device_priv).unwrap();
    let host_pub = static_pubkey(&host_priv).unwrap();

    // Sanity: the FFI device_pubkey matches the crate's derivation (hex).
    assert_eq!(
        device_pubkey(device_priv.to_vec()).unwrap(),
        hex(&device_pub),
        "device_pubkey FFI disagrees with static_pubkey"
    );

    // FFI initiator (the phone) toward a responder that pins the device key.
    let sess = NoiseSession::new_initiator(
        host_pub.to_vec(),
        device_priv.to_vec(),
        [0x33u8; 32].to_vec(),
    )
    .unwrap();
    let mut responder = Responder::new(&host_priv, &[0x44u8; 32], device_pub).unwrap();

    let act1 = sess.write_act_one().unwrap();
    responder.read_act_one(&act1).unwrap();
    let act2 = responder.write_act_two().unwrap();
    let act3 = sess.read_act_two(act2.to_vec()).unwrap();
    let mut rt = responder.read_act_three(&act3).unwrap();
    assert!(sess.is_ready(), "transport should be live after act three");

    // Initiator (device) -> responder (host): encrypt then decrypt a frame.
    let msg = b"a signer-split frame".to_vec();
    let rec = sess.encrypt(msg.clone()).unwrap();
    let body_len = rt
        .decrypt_header(rec[..HDR_SIZE].try_into().unwrap())
        .unwrap() as usize;
    let got = rt
        .decrypt_body(&rec[HDR_SIZE..HDR_SIZE + body_len + BODY_OVERHEAD])
        .unwrap();
    assert_eq!(got, msg, "host could not decrypt the device's record");

    // Responder (host) -> initiator (device): the reverse path through the FFI.
    let reply = b"a hosted hsmd reply".to_vec();
    let rec2 = rt.encrypt(&reply);
    let body_len2 = sess.decrypt_header(rec2[..HDR_SIZE].to_vec()).unwrap() as usize;
    let got2 = sess
        .decrypt_body(rec2[HDR_SIZE..HDR_SIZE + body_len2 + BODY_OVERHEAD].to_vec())
        .unwrap();
    assert_eq!(got2, reply, "device could not decrypt the host's record");
}

/// A device pinning a DIFFERENT host key must fail host authentication at Act
/// Two (the responder holds the real host key, so the MAC won't verify) — the
/// fail-closed guarantee the hosted model leans on.
#[test]
fn noise_wrong_host_key_fails() {
    use seqln_signer::noise::{static_pubkey, Responder};

    let device_priv = [0x11u8; 32];
    let host_priv = [0x22u8; 32];
    let wrong_host_pub = static_pubkey(&[0x99u8; 32]).unwrap();
    let device_pub = static_pubkey(&device_priv).unwrap();

    // Initiator pins the WRONG host key; the real responder holds host_priv.
    let sess =
        NoiseSession::new_initiator(wrong_host_pub.to_vec(), device_priv.to_vec(), [0x33u8; 32].to_vec())
            .unwrap();
    let mut responder = Responder::new(&host_priv, &[0x44u8; 32], device_pub).unwrap();

    let act1 = sess.write_act_one().unwrap();
    // The responder can't authenticate an act one baked with the wrong host key.
    assert!(
        responder.read_act_one(&act1).is_err(),
        "handshake must fail closed on a wrong pinned host key"
    );
}
