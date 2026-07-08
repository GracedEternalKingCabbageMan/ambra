// Throwaway repro: build a same-chain SwapRequest from the public test mnemonic
// and print its transaction, to diagnose the daemon's "invalid swap request
// transaction" (go-elements psetv2.NewPsetFromBase64 failing on the lwk PSET).
use ambra_core::api::{seqdex_build_swap_request, sync_wallet};

const MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const ESPLORA: &str = "http://159.195.15.140/api";
const TSEQ: &str = "c8eccacf0953e1931cd31e434d8319101cc36e6c38b0e2104d8687552fae3e40";
const SILVR: &str = "57dfa6b0eff594cc3ef1de5555e0526d1eb5590289e014e7663b292edcd63f48";

#[test]
fn repro_swap_request() {
    let s = sync_wallet(MNEMONIC.to_string(), ESPLORA.to_string()).expect("sync");
    for b in &s.balances {
        eprintln!("BAL {} = {}", b.asset_id, b.atoms);
    }
    // tSEQ -> SILVR; amounts only need to build a PSET (the parse check fails first).
    match seqdex_build_swap_request(
        MNEMONIC.to_string(),
        ESPLORA.to_string(),
        TSEQ.to_string(),
        100_000_000,
        SILVR.to_string(),
        172_409,
        TSEQ.to_string(),
        0,
        0,
    ) {
        Ok(out) => {
            eprintln!("SWAP_ID={}", out.id);
            eprintln!("SWAP_JSON_BEGIN");
            println!("{}", out.swap_request_json);
            eprintln!("SWAP_JSON_END");
        }
        Err(e) => eprintln!("BUILD_ERR: {e}"),
    }
}
