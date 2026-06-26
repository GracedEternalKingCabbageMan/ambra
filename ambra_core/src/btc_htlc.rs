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

use std::str::FromStr;

use lwk_wollet::bitcoin::absolute::LockTime;
use lwk_wollet::bitcoin::consensus::encode::serialize_hex;
use lwk_wollet::bitcoin::hashes::Hash;
use lwk_wollet::bitcoin::script::{Builder, PushBytes};
use lwk_wollet::bitcoin::secp256k1::{Message, PublicKey, Secp256k1, SecretKey};
use lwk_wollet::bitcoin::sighash::SighashCache;
use lwk_wollet::bitcoin::transaction::Version;
use lwk_wollet::bitcoin::{
    opcodes, Address, Amount, EcdsaSighashType, Network, OutPoint, ScriptBuf, Sequence, Transaction, TxIn, TxOut, Txid,
    Witness,
};

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

/// A spend of an HTLC P2SH output: the funding outpoint, its value, where the
/// refund pays, and the fee to subtract.
pub struct BtcHtlcSpend {
    pub txid: String,
    pub vout: u32,
    pub amount_sats: u64,
    pub dest_spk: ScriptBuf,
    pub fee_sats: u64,
}

/// Build + sign the BTC refund: a legacy P2SH spend of the HTLC via the ELSE/CLTV
/// branch, paying `amount - fee` to `dest_spk`. Only valid once the chain tip
/// reaches `locktime` (CLTV). Returns the raw tx hex to broadcast.
///
/// The scriptSig is `<sig> OP_0 <redeemScript>`: the empty (false) item selects
/// the OP_ELSE branch, and the redeemScript push is what P2SH executes. The
/// sighash is a LEGACY SIGHASH_ALL over the redeemScript (not the P2SH spk).
pub fn build_refund_tx(
    redeem: &ScriptBuf,
    spend: &BtcHtlcSpend,
    locktime: u32,
    refund_sk: &SecretKey,
) -> AmbraResult<String> {
    let out_value = spend
        .amount_sats
        .checked_sub(spend.fee_sats)
        .ok_or_else(|| "fee exceeds the HTLC amount".to_string())?;
    if out_value == 0 {
        return Err("refund output is zero after fee".into());
    }
    let txid = Txid::from_str(&spend.txid).map_err(map)?;
    let mut tx = Transaction {
        version: Version::TWO,
        lock_time: LockTime::from_consensus(locktime),
        input: vec![TxIn {
            previous_output: OutPoint { txid, vout: spend.vout },
            script_sig: ScriptBuf::new(),
            sequence: Sequence(0xffff_fffe), // non-final (BIP68 disabled) so absolute CLTV applies
            witness: Witness::new(),
        }],
        output: vec![TxOut { value: Amount::from_sat(out_value), script_pubkey: spend.dest_spk.clone() }],
    };
    // Legacy SIGHASH_ALL over the redeemScript (the subscript), computed while the
    // cache borrows &tx; then drop it before mutating the input's scriptSig.
    let sighash = SighashCache::new(&tx)
        .legacy_signature_hash(0, redeem, EcdsaSighashType::All.to_u32())
        .map_err(map)?;
    let secp = Secp256k1::new();
    let sig = secp.sign_ecdsa(&Message::from_digest(sighash.to_byte_array()), refund_sk);
    let mut sig_bytes = sig.serialize_der().to_vec();
    sig_bytes.push(EcdsaSighashType::All.to_u32() as u8); // 0x01

    tx.input[0].script_sig = Builder::new()
        .push_slice(push_bytes(&sig_bytes)?)
        .push_opcode(opcodes::all::OP_PUSHBYTES_0) // OP_0 / false -> selects the ELSE/CLTV branch
        .push_slice(push_bytes(redeem.as_bytes())?)
        .into_script();
    Ok(serialize_hex(&tx))
}

#[cfg(test)]
mod tests {
    use lwk_wollet::bitcoin::consensus::encode::deserialize;
    use lwk_wollet::bitcoin::hex::FromHex;
    use lwk_wollet::bitcoin::secp256k1::{Secp256k1, SecretKey};
    use lwk_wollet::bitcoin::Transaction;

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

    #[test]
    fn refund_tx_shape() {
        let secp = Secp256k1::new();
        let refund_sk = SecretKey::from_slice(&[7u8; 32]).unwrap();
        let refund_pub = refund_sk.public_key(&secp).serialize();
        let redeem = super::build_htlc_redeem_script(&[0x22u8; 32], &pubkey(2), &refund_pub, 800_000).unwrap();
        let (_addr, _spk) = super::htlc_p2sh(&redeem).unwrap();
        let dest_spk = super::htlc_p2sh(&redeem).unwrap().1; // any spk for the structural check
        let spend = super::BtcHtlcSpend {
            txid: "a".repeat(64),
            vout: 1,
            amount_sats: 50_000,
            dest_spk,
            fee_sats: 2_000,
        };
        let hex = super::build_refund_tx(&redeem, &spend, 800_000, &refund_sk).unwrap();
        let raw = Vec::<u8>::from_hex(&hex).unwrap();
        let tx: Transaction = deserialize(&raw).unwrap();
        assert_eq!(tx.version, super::Version::TWO);
        assert_eq!(tx.lock_time.to_consensus_u32(), 800_000); // CLTV enforced
        assert_eq!(tx.input.len(), 1);
        assert_eq!(tx.input[0].sequence.0, 0xffff_fffe); // non-final
        assert!(tx.input[0].witness.is_empty()); // legacy P2SH, no witness
        assert_eq!(tx.output.len(), 1);
        assert_eq!(tx.output[0].value.to_sat(), 48_000); // amount - fee
        // scriptSig ends with the redeemScript push; the empty selector sits before it.
        assert!(!tx.input[0].script_sig.is_empty());
    }

    #[test]
    fn refund_rejects_fee_over_amount() {
        let secp = Secp256k1::new();
        let sk = SecretKey::from_slice(&[7u8; 32]).unwrap();
        let redeem = super::build_htlc_redeem_script(&[0x22u8; 32], &pubkey(2), &sk.public_key(&secp).serialize(), 1).unwrap();
        let spend = super::BtcHtlcSpend {
            txid: "a".repeat(64),
            vout: 0,
            amount_sats: 1_000,
            dest_spk: super::htlc_p2sh(&redeem).unwrap().1,
            fee_sats: 2_000,
        };
        assert!(super::build_refund_tx(&redeem, &spend, 1, &sk).is_err());
    }
}
