//! Architecture smoke test: proves `ambra_core` can drive the Sequentia kit end
//! to end with the `sequentia` feature ON — including the builder methods that
//! `lwk_bindings` (default features) cannot reach.

use ambra_core::{
    build_wollet, confidential_receive_address, descriptor_from_mnemonic, receive_address,
    sequentia_testnet,
};
use lwk_wollet::TxBuilder;

// Standard BIP39 test vector mnemonic (well-known; testnet only).
const MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

#[test]
fn sequentia_core_is_reachable() {
    // 1. The Sequentia testnet network is correctly defined.
    let net = sequentia_testnet();
    assert_eq!(net.as_str(), "sequentia-testnet");

    // 2. A standard Sequentia CT descriptor derives from a mnemonic.
    let desc = descriptor_from_mnemonic(MNEMONIC).expect("descriptor");
    assert!(desc.starts_with("ct("), "expected a CT descriptor, got: {desc}");

    // 3. A watch-only wallet builds and yields a non-confidential tb1 address by
    //    default (Sequentia testnet default), with the confidential tsqb1 form
    //    available as the opt-in private-receive path.
    let wollet = build_wollet(&desc).expect("wollet");
    let addr = receive_address(&wollet, 0).expect("address");
    assert!(addr.starts_with("tb1"), "expected non-confidential tb1 address, got: {addr}");
    let caddr = confidential_receive_address(&wollet, 0).expect("confidential address");
    assert!(caddr.starts_with("tsqb1"), "expected confidential tsqb1 address, got: {caddr}");
    println!("receive (default, non-confidential) = {addr}");
    println!("receive (opt-in confidential)       = {caddr}");

    // 4. THE PROOF: the `sequentia`-gated builder methods compile and are
    //    reachable here. These do NOT exist on lwk_bindings' default-feature
    //    build — this is exactly why Ambra's core consumes lwk_wollet directly
    //    with the feature on rather than going through lwk_bindings.
    let _builder = TxBuilder::new(net)
        .enable_rbf(true)
        .fee_asset(*net.policy_asset(), 100_000_000);
    println!("sequentia send-flow (enable_rbf + fee_asset) reachable ✔");
}
