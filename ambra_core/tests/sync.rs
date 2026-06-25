//! Live integration test: full-scan the wallet against the Sequentia testnet
//! esplora on the box. Network-dependent (run explicitly):
//!
//!   cargo test --test sync -- --nocapture

use ambra_core::api::{build_send_tx, receive_address_at, sign_pset, sync_wallet, Recipient};

const MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const ESPLORA: &str = "http://159.195.15.140/api";
const TSEQ: &str = "c8eccacf0953e1931cd31e434d8319101cc36e6c38b0e2104d8687552fae3e40";

#[test]
fn sync_against_live_testnet() {
    let s = sync_wallet(MNEMONIC.to_string(), ESPLORA.to_string()).expect("sync failed");
    assert!(s.tip_height > 0, "tip height should be > 0, got {}", s.tip_height);
    println!(
        "synced: tip={} hash={} next_index={} assets={}",
        s.tip_height,
        s.tip_hash,
        s.next_index,
        s.balances.len()
    );
    for b in &s.balances {
        println!("  {} = {}", b.asset_id, b.atoms);
    }
}

/// Build + SIGN a tiny self-send PSET against real funds (no broadcast — proves
/// the money path's build/sign without moving funds or racing the shared
/// public mnemonic). Skips if the wallet holds no tSEQ.
#[test]
fn build_and_sign_self_send() {
    let s = sync_wallet(MNEMONIC.to_string(), ESPLORA.to_string()).expect("sync");
    let tseq = s
        .balances
        .iter()
        .find(|b| b.asset_id == TSEQ)
        .and_then(|b| b.atoms.parse::<u64>().ok())
        .unwrap_or(0);
    println!("tSEQ atoms held: {tseq}");
    if tseq < 2000 {
        println!("not enough tSEQ for a send test — skipping build+sign");
        return;
    }
    let addr = receive_address_at(MNEMONIC.to_string(), 0, false).expect("addr").address;
    let recipients = vec![Recipient {
        address: addr,
        asset_id: TSEQ.to_string(),
        satoshi: 1000,
    }];
    let pset = build_send_tx(MNEMONIC.to_string(), ESPLORA.to_string(), recipients, None, None)
        .expect("build_send_tx");
    assert!(!pset.is_empty(), "PSET should be non-empty");
    let signed = sign_pset(MNEMONIC.to_string(), pset).expect("sign_pset");
    assert!(!signed.is_empty(), "signed PSET should be non-empty");
    println!("built + signed a self-send PSET ({} chars) — NOT broadcast", signed.len());
}
