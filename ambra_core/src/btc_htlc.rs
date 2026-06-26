//! Bitcoin parent-chain (testnet4) HTLC leg for cross-chain SeqDEX swaps.
//!
//! The wallet is Alice (the secret holder): she funds the BTC HTLC, the maker
//! (Bob) claims it by revealing the preimage, and Alice refunds via the CLTV
//! branch if Bob never claims. The redeemScript is byte-for-byte identical to the
//! Sequentia leg's (`lwk_wollet::build_htlc_redeem_script`) and to the daemon's
//! `xchain` HTLCScript — the daemon rejects any difference — so this builder is
//! cross-checked against the proven SEQ builder in the tests below.
//!
//!   OP_IF  OP_SHA256 <H> OP_EQUALVERIFY <claimPub> OP_CHECKSIG
//!   OP_ELSE  <locktime> OP_CLTV OP_DROP <refundPub> OP_CHECKSIG
//!   OP_ENDIF                                            (paid to a bare P2SH)
//!
//! Legacy (non-segwit) P2SH: the refund spend uses a legacy SIGHASH_ALL over the
//! redeemScript and a hand-built scriptSig `<sig> OP_FALSE <redeemScript>` to
//! select the ELSE branch (the generic signer won't template the OP_FALSE
//! selector). The BTC claim is Bob's path and is not built here.

use lwk_wollet::bitcoin::script::{Builder, PushBytes};
use lwk_wollet::bitcoin::secp256k1::PublicKey;
use lwk_wollet::bitcoin::{opcodes, Address, Network, ScriptBuf};

use crate::AmbraResult;

fn map<E: std::fmt::Debug>(e: E) -> String {
    format!("{e:?}")
}

fn push_bytes(b: &[u8]) -> AmbraResult<&PushBytes> {
    <&PushBytes>::try_from(b).map_err(map)
}

/// Build the HTLC redeemScript. `hash` is the 32-byte SHA256 hashlock; `claim_pub`
/// / `refund_pub` are 33-byte compressed pubkeys; `locktime` is the CLTV height.
/// Byte-identical to the daemon's HTLCScript (validated against the SEQ builder).
pub fn build_htlc_redeem_script(
    hash: &[u8],
    claim_pub: &[u8],
    refund_pub: &[u8],
    locktime: u32,
) -> AmbraResult<ScriptBuf> {
    if hash.len() != 32 {
        return Err(format!("hashlock H must be 32 bytes, got {}", hash.len()));
    }
    // Compressed-key sanity: the byte-match depends on 33-byte keys (OP_PUSHBYTES_33);
    // also confirm each parses on secp256k1.
    for (label, pk) in [("claim", claim_pub), ("refund", refund_pub)] {
        if pk.len() != 33 {
            return Err(format!("{label} pubkey must be 33-byte compressed, got {}", pk.len()));
        }
        PublicKey::from_slice(pk).map_err(|e| format!("invalid {label} pubkey: {e}"))?;
    }
    let script = Builder::new()
        .push_opcode(opcodes::all::OP_IF)
        .push_opcode(opcodes::all::OP_SHA256)
        .push_slice(push_bytes(hash)?)
        .push_opcode(opcodes::all::OP_EQUALVERIFY)
        .push_slice(push_bytes(claim_pub)?)
        .push_opcode(opcodes::all::OP_CHECKSIG)
        .push_opcode(opcodes::all::OP_ELSE)
        .push_int(locktime as i64) // minimal CScriptNum, matches btcd AddInt64
        .push_opcode(opcodes::all::OP_CLTV)
        .push_opcode(opcodes::all::OP_DROP)
        .push_slice(push_bytes(refund_pub)?)
        .push_opcode(opcodes::all::OP_CHECKSIG)
        .push_opcode(opcodes::all::OP_ENDIF)
        .into_script();
    Ok(script)
}

/// The bare-P2SH address + scriptPubKey for an HTLC redeemScript, on testnet4
/// (testnet `2…` base58 P2SH). The wallet funds this address; it locates the
/// funding output by matching this scriptPubKey.
pub fn htlc_p2sh(redeem: &ScriptBuf) -> AmbraResult<(Address, ScriptBuf)> {
    let address = Address::p2sh(redeem, Network::Testnet).map_err(map)?;
    Ok((address, redeem.to_p2sh()))
}

#[cfg(test)]
mod tests {
    use lwk_wollet::bitcoin::secp256k1::{Secp256k1, SecretKey};

    fn pubkey(byte: u8) -> [u8; 33] {
        let secp = Secp256k1::new();
        let sk = SecretKey::from_slice(&[byte; 32]).unwrap();
        sk.public_key(&secp).serialize()
    }

    // The whole fund-safety chain rests on the BTC redeemScript being byte-identical
    // to what the daemon recomputes. lwk's SEQ-leg build_htlc_redeem_script is the
    // proven reference (and the daemon matches it), so cross-check against it.
    #[test]
    fn btc_redeem_matches_seq_builder() {
        let hash = [0x11u8; 32];
        let claim = pubkey(2);
        let refund = pubkey(3);
        let locktime = 1_234_567u32;

        let btc = super::build_htlc_redeem_script(&hash, &claim, &refund, locktime).unwrap();
        let seq = lwk_wollet::build_htlc_redeem_script(&hash, &claim, &refund, locktime).unwrap();
        assert_eq!(btc.as_bytes(), seq.as_bytes(), "BTC HTLC script must byte-match the SEQ/daemon script");

        // P2SH derives + is testnet ("2…").
        let (addr, spk) = super::htlc_p2sh(&btc).unwrap();
        assert!(addr.to_string().starts_with('2'), "testnet P2SH base58 starts with 2, got {addr}");
        assert_eq!(spk.as_bytes()[0], 0xa9, "P2SH spk starts with OP_HASH160");
    }

    #[test]
    fn rejects_bad_inputs() {
        let ok = pubkey(2);
        assert!(super::build_htlc_redeem_script(&[0u8; 31], &ok, &ok, 1).is_err()); // short hash
        assert!(super::build_htlc_redeem_script(&[0u8; 32], &ok[..32], &ok, 1).is_err()); // short key
    }
}
