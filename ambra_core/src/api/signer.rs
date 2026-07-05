//! Phone-side SeqLN Tier-2 device signer, exposed to Dart via `flutter_rust_bridge`.
//!
//! This is the NATIVE-Rust twin of the browser WASM signer
//! (`seqln/contrib/seqln-signer/wasm`): it hands Flutter the exact same API the
//! JS SDK gets, so the Ambra app can hold the wallet's keys on-device and
//! co-sign a HOSTED SeqLN node's operations without ever shipping a key off the
//! phone. The host can never move the user's funds; it only asks the device to
//! sign, and (in enforce mode) the device refuses theft-shaped requests.
//!
//! It adds NO crypto and NO transport of its own. The whole kernel + wire +
//! frame + dispatch + validating policy + BOLT-8 Noise_XK live in the pure,
//! I/O-free `seqln-signer` crate (byte-for-byte conformance-tested against the
//! reference libhsmd). This module is the thin FRB shim: `&[u8]`/`Vec<u8>` in,
//! `Vec<u8>` out, `anyhow::Result` for errors, opaque handles for the two
//! stateful objects (the signer and a Noise session). The Dart transport glue
//! (a WebSocket to the LSP, or a raw TCP socket for the harness) lives in
//! `app/lib/src/data/seqln_signer.dart`.
//!
//! Mirrors `wasm/src/lib.rs` one-for-one:
//!   * [`SeqlnSigner`]  — `fromMnemonic` / `fromHsmSecret`, `processFrame`,
//!     `setEnforce`, `nodeId` (Signer + Signer.fromMnemonic + setEnforce in JS).
//!   * [`NoiseSession`] — the Noise_XK **initiator** the device plays when it
//!     connects OUT to the hosted proxy's responder.
//!   * [`device_pubkey`] — the transport pubkey a host pins for a device privkey.

use std::sync::Mutex;

use anyhow::{anyhow, Result};
use flutter_rust_bridge::frb;
use lwk_wollet::bitcoin::bip32::{ChildNumber, DerivationPath, Xpriv};
use lwk_wollet::bitcoin::secp256k1::Secp256k1;
use lwk_wollet::bitcoin::Network;

use seqln_signer::dispatch::{Outcome, Signer as InnerSigner};
use seqln_signer::frame;
use seqln_signer::hsm_secret;
use seqln_signer::kernel::{Kernel, BIP32_VER_TEST_PRIVATE, BIP32_VER_TEST_PUBLIC};
use seqln_signer::noise::{self, Initiator, Transport};
use seqln_signer::policy::Policy;

fn arr32(b: &[u8], what: &str) -> Result<[u8; 32]> {
    b.try_into()
        .map_err(|_| anyhow!("{what} must be 32 bytes, got {}", b.len()))
}
fn arr33(b: &[u8], what: &str) -> Result<[u8; 33]> {
    b.try_into()
        .map_err(|_| anyhow!("{what} must be 33 bytes, got {}", b.len()))
}
fn hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{x:02x}"));
    }
    s
}

/// The device signer: the mnemonic-derived crypto kernel + per-channel policy
/// state, exactly the native `dispatch::Signer`, behind a mutex so Dart holds it
/// as an opaque handle and drives it from any isolate. Also keeps the derived
/// 64-byte BIP39 seed so [`SeqlnSigner::node_id`] can report the node id before
/// any `hsmd_init` frame has flowed through the link.
#[frb(opaque)]
pub struct SeqlnSigner {
    inner: Mutex<InnerSigner>,
    seed: [u8; 64],
}

impl SeqlnSigner {
    /// Construct from the raw `hsm_secret` bytes (the on-disk mnemonic form:
    /// `32 zero bytes || mnemonic`). Throws on a malformed / unsupported secret.
    #[frb(sync)]
    pub fn from_hsm_secret(hsm_secret_bytes: Vec<u8>) -> Result<SeqlnSigner> {
        let secret = hsm_secret::parse(&hsm_secret_bytes).map_err(|e| anyhow!(e))?;
        let seed = secret.seed;
        Ok(SeqlnSigner {
            inner: Mutex::new(InnerSigner::new(secret)),
            seed,
        })
    }

    /// Construct from just the BIP-39 mnemonic (no passphrase), synthesizing the
    /// `32 zero bytes || mnemonic` on-disk form. This is the phone's normal
    /// entry point: the wallet already holds the mnemonic in secure storage.
    #[frb(sync)]
    pub fn from_mnemonic(mnemonic: String) -> Result<SeqlnSigner> {
        let mut bytes = vec![0u8; 32];
        bytes.extend_from_slice(mnemonic.trim().as_bytes());
        SeqlnSigner::from_hsm_secret(bytes)
    }

    /// Turn the validating policy on (`enforce`) or off (`permissive`). The
    /// phone has no env, so this is how the caller selects enforce mode (the
    /// device then refuses to sign a commitment that moves funds off-channel).
    #[frb(sync)]
    pub fn set_enforce(&self, enforce: bool) {
        let policy = if enforce {
            Policy::Enforce
        } else {
            Policy::Permissive
        };
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .set_policy(policy);
    }

    /// The device's compressed node id (33-byte hex). Derived straight from the
    /// mnemonic seed (`HKDF(..,"nodeid")`), so it is available immediately and
    /// matches the id the hosted node reports once it boots over the link.
    #[frb(sync)]
    pub fn node_id(&self) -> String {
        // node_id = HKDF(seed[0..32], "nodeid") -> pubkey; independent of the
        // BIP32 network version, so the testnet versions are fine here.
        let k = Kernel::new(
            self.seed.to_vec(),
            BIP32_VER_TEST_PUBLIC,
            BIP32_VER_TEST_PRIVATE,
        );
        hex(&k.node_id())
    }

    /// Drive ONE hsmd request -> reply. `frame_bytes` is a single signer-split
    /// frame (`signer_frame.h`: little-endian `u32 len | is_main | node_id? |
    /// dbid | capabilities | hsmd_msg`); the return is the single framed reply
    /// (`u32 len | hsmd_reply`, a zero-length body being the error/reject
    /// sentinel) — byte-for-byte what the native serve loop writes back. Errors
    /// only on a libhsmd-fatal condition (which closes the transport natively).
    #[frb(sync)]
    pub fn process_frame(&self, frame_bytes: Vec<u8>) -> Result<Vec<u8>> {
        let mut rd: &[u8] = &frame_bytes;
        let req = match frame::read_request(&mut rd) {
            Ok(Some(r)) => r,
            Ok(None) => return Err(anyhow!("short/empty frame")),
            Err(e) => return Err(anyhow!("frame decode error: {e}")),
        };
        let reply: Vec<u8> = {
            let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            match guard.handle(&req) {
                Outcome::Reply(bytes) => bytes,
                // Sentinel and (policy) Reject are both the zero-length sentinel.
                Outcome::Sentinel | Outcome::Reject(_) => Vec::new(),
                Outcome::Fatal(m) => return Err(anyhow!("fatal: {m}")),
            }
        };
        let mut out = Vec::with_capacity(4 + reply.len());
        frame::write_reply(&mut out, &reply).expect("write to Vec never fails");
        Ok(out)
    }
}

/// The BOLT-8 Noise_XK **initiator** session — the role the phone device plays
/// in the hosted topology (it connects OUT to the LSP's responder). Holds the
/// handshake state until Act Two, then the post-handshake transport cipher,
/// behind a mutex so Dart holds it as an opaque handle. Mirrors the WASM
/// `NoiseSession`; the phone draws the ephemeral entropy from the OS RNG (Dart's
/// `Random.secure()`) and passes it in, exactly as the browser injects
/// `crypto.getRandomValues`.
#[frb(opaque)]
pub struct NoiseSession {
    state: Mutex<NoiseInner>,
}

struct NoiseInner {
    initiator: Option<Initiator>,
    transport: Option<Transport>,
}

impl NoiseSession {
    /// Begin an initiator handshake toward a hosted proxy whose static pubkey is
    /// `host_static_pubkey` (33 bytes, pinned), using our device transport
    /// static privkey `device_static_privkey` (32 bytes) and a fresh 32-byte
    /// `ephemeral_entropy` the caller draws from the OS RNG.
    #[frb(sync)]
    pub fn new_initiator(
        host_static_pubkey: Vec<u8>,
        device_static_privkey: Vec<u8>,
        ephemeral_entropy: Vec<u8>,
    ) -> Result<NoiseSession> {
        let host = arr33(&host_static_pubkey, "host_static_pubkey")?;
        let priv_ = arr32(&device_static_privkey, "device_static_privkey")?;
        let eph = arr32(&ephemeral_entropy, "ephemeral_entropy")?;
        let ini = Initiator::new(&priv_, &eph, host).map_err(|e| anyhow!(e.0))?;
        Ok(NoiseSession {
            state: Mutex::new(NoiseInner {
                initiator: Some(ini),
                transport: None,
            }),
        })
    }

    /// Produce Act One (50 bytes) to send to the responder.
    #[frb(sync)]
    pub fn write_act_one(&self) -> Result<Vec<u8>> {
        let mut g = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let ini = g
            .initiator
            .as_mut()
            .ok_or_else(|| anyhow!("act one after handshake complete"))?;
        Ok(ini.write_act_one().to_vec())
    }

    /// Consume Act Two (50 bytes) from the responder, returning Act Three (66
    /// bytes) and transitioning to the ready transport. After this call
    /// `encrypt`/`decrypt_header`/`decrypt_body` are live. Errors if the host's
    /// static key does not match the pinned one (host authentication failed).
    #[frb(sync)]
    pub fn read_act_two(&self, act2: Vec<u8>) -> Result<Vec<u8>> {
        let mut g = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let ini = g
            .initiator
            .take()
            .ok_or_else(|| anyhow!("act two before act one / already done"))?;
        let (act3, transport) = ini
            .read_act_two_write_act_three(&act2)
            .map_err(|e| anyhow!(e.0))?;
        g.transport = Some(transport);
        Ok(act3.to_vec())
    }

    /// True once the handshake has completed and the transport is live.
    #[frb(sync)]
    pub fn is_ready(&self) -> bool {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .transport
            .is_some()
    }

    /// Encrypt one plaintext message into a full BOLT-8 transport record
    /// (18-byte encrypted length header || encrypted body+MAC).
    #[frb(sync)]
    pub fn encrypt(&self, msg: Vec<u8>) -> Result<Vec<u8>> {
        let mut g = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let t = g
            .transport
            .as_mut()
            .ok_or_else(|| anyhow!("transport not ready (handshake incomplete)"))?;
        Ok(t.encrypt(&msg))
    }

    /// Decrypt an 18-byte length header, returning the body length that follows
    /// (so the caller knows how many bytes to read next off the socket).
    #[frb(sync)]
    pub fn decrypt_header(&self, hdr: Vec<u8>) -> Result<u32> {
        let mut g = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let t = g
            .transport
            .as_mut()
            .ok_or_else(|| anyhow!("transport not ready (handshake incomplete)"))?;
        let h: [u8; noise::HDR_SIZE] = hdr
            .as_slice()
            .try_into()
            .map_err(|_| anyhow!("header must be 18 bytes"))?;
        t.decrypt_header(&h).map(|l| l as u32).map_err(|e| anyhow!(e.0))
    }

    /// Decrypt a body (`len + 16` bytes) into the plaintext message.
    #[frb(sync)]
    pub fn decrypt_body(&self, body: Vec<u8>) -> Result<Vec<u8>> {
        let mut g = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let t = g
            .transport
            .as_mut()
            .ok_or_else(|| anyhow!("transport not ready (handshake incomplete)"))?;
        t.decrypt_body(&body).map_err(|e| anyhow!(e.0))
    }
}

/// Derive the compressed static pubkey (33-byte hex) for a transport static
/// privkey (32 bytes) — the device pubkey a hosted proxy must pin. Handy for a
/// provisioning UI that shows/QRs the device's transport identity.
#[frb(sync)]
pub fn device_pubkey(static_privkey: Vec<u8>) -> Result<String> {
    let priv_ = arr32(&static_privkey, "static_privkey")?;
    noise::static_pubkey(&priv_)
        .map(|p| hex(&p))
        .map_err(|e| anyhow!(e.0))
}

/// Derive the device transport (Noise static) private key for the hosted-SeqLN
/// LSP link, deterministically from the wallet mnemonic. This is the native twin
/// of the web wallet's `lnDeviceTransportPriv`: standard BIP39 seed (no
/// passphrase) -> BIP32 `m/1017'/0'/0'` -> the 32-byte private key. It is stable
/// across reinstalls and recoverable from the mnemonic, so the LSP can pin ONE
/// device identity per wallet — and it is byte-identical to the browser client
/// for the same seed (both take the standard BIP39 seed through the same BIP32
/// path), so one hosted LSP can pin the same key whichever client the user runs.
#[frb(sync)]
pub fn seqln_device_transport_privkey(mnemonic: String) -> Result<Vec<u8>> {
    // Standard 64-byte BIP39 seed (empty passphrase), via the same path the
    // signer takes: synthesize the `32 zero bytes || mnemonic` on-disk form and
    // parse it (yields `secret.seed`, the plain BIP39 seed).
    let mut bytes = vec![0u8; 32];
    bytes.extend_from_slice(mnemonic.trim().as_bytes());
    let secret = hsm_secret::parse(&bytes).map_err(|e| anyhow!(e))?;
    let secp = Secp256k1::new();
    // The BIP32 network version affects only the (unused) xprv serialization, not
    // the derived private-key bytes, so testnet here is fine and cross-consistent.
    let master = Xpriv::new_master(Network::Testnet, &secret.seed).map_err(|e| anyhow!("{e}"))?;
    let path = DerivationPath::from(vec![
        ChildNumber::from_hardened_idx(1017).map_err(|e| anyhow!("{e}"))?,
        ChildNumber::from_hardened_idx(0).map_err(|e| anyhow!("{e}"))?,
        ChildNumber::from_hardened_idx(0).map_err(|e| anyhow!("{e}"))?,
    ]);
    let child = master.derive_priv(&secp, &path).map_err(|e| anyhow!("{e}"))?;
    Ok(child.private_key.secret_bytes().to_vec())
}
