//! Live integration test: full-scan the wallet against the Sequentia testnet
//! esplora on the box. Network-dependent (run explicitly):
//!
//!   cargo test --test sync -- --nocapture

use ambra_core::api::sync_wallet;

const MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const ESPLORA: &str = "http://159.195.15.140/api";

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
}
