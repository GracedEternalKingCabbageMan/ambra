//! SeqOB passive-CLOB covenant — the DERIVATION half (the byte-exact port of the
//! web wallet's `covenant.js`).
//!
//! `lwk_wollet::seqob_covenant` (reused via a thin FFI) only ASSEMBLES + SIGNS the
//! raw Elements FILL/REFUND transaction from an ALREADY-DERIVED recipe: it takes
//! `fill_leaf` / `control_block` / the covenant scriptPubKey as pre-built bytes.
//! In the web wallet those bytes are derived in pure JS (`covenant.js`
//! `buildFillLeaf` / `buildRefundLeaf` / `deriveTaptree` / `planFill` /
//! `ceilPrice`). Ambra has no JS engine, so that derivation is ported here to Rust
//! once, byte-for-byte, and pinned to the SAME golden vectors the SWK crate ships
//! (`GOLD_FILL_LEAF` / `GOLD_CTRL_BLOCK` / `GOLD_ORDER_SPK`).
//!
//! Only the two leaf opcode scripts are hand-emitted (mirroring `covenant.js`
//! exactly); the tagged-hash / TapBranch / TapTweak-elements / control-block math
//! is REUSED from `rust-elements`' taproot module (`LeafVersion` `0xc4` =
//! `TAPROOT_LEAF_TAPSCRIPT`, `TaprootBuilder`, `ControlBlock::serialize`), which is
//! the same primitive `maker_payout_program` already proves matches this
//! covenant's output-key derivation.
//!
//! ASSET BYTE ORDER: the FILL leaf compares the introspected output asset to the
//! 32 bytes fed here, and those bytes equal the asset id's DISPLAY hex (the same
//! string the web wallet passes, and the same `AssetId` display form the fill-tx
//! builder receives). So NO byte reversal is applied — the asset hex string flows
//! unchanged into the leaf, the CovenantTerms, and `AssetId::from_str`.

use lwk_wollet::elements::hex::FromHex;
use lwk_wollet::elements::taproot::{LeafVersion, TaprootBuilder};
use lwk_wollet::elements::{secp256k1_zkp, Script};

/// BIP341 nothing-up-my-sleeve internal key (no known discrete log ⇒ no key-path
/// spend). Byte-identical to `covenant.js` `NUMS` and `leaf.go`.
pub const NUMS_HEX: &str = "50929b74c1a04954b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac0";

// Tapscript opcodes (on-wire bytes), byte-identical to `covenant.js`.
const OP_0: u8 = 0x00;
const OP_1: u8 = 0x51;
const OP_1NEGATE: u8 = 0x4f;
const OP_IF: u8 = 0x63;
const OP_ELSE: u8 = 0x67;
const OP_ENDIF: u8 = 0x68;
const OP_VERIFY: u8 = 0x69;
const OP_DROP: u8 = 0x75;
const OP_DUP: u8 = 0x76;
const OP_NIP: u8 = 0x77;
const OP_ROT: u8 = 0x7b;
const OP_SWAP: u8 = 0x7c;
const OP_EQUAL: u8 = 0x87;
const OP_EQUALVERIFY: u8 = 0x88;
const OP_1ADD: u8 = 0x8b;
const OP_ADD: u8 = 0x93;
const OP_LESSTHAN: u8 = 0x9f;
const OP_CHECKSIG: u8 = 0xac;
const OP_CHECKLOCKTIMEVERIFY: u8 = 0xb1;
const OP_INSPECTINPUTVALUE: u8 = 0xc9;
const OP_INSPECTINPUTSCRIPTPUBKEY: u8 = 0xca;
const OP_PUSHCURRENTINPUTINDEX: u8 = 0xcd;
const OP_INSPECTOUTPUTASSET: u8 = 0xce;
const OP_INSPECTOUTPUTVALUE: u8 = 0xcf;
const OP_INSPECTOUTPUTSCRIPTPUBKEY: u8 = 0xd1;
const OP_INSPECTNUMOUTPUTS: u8 = 0xd5;
const OP_SUB64: u8 = 0xd8;
const OP_MUL64: u8 = 0xd9;
const OP_DIV64: u8 = 0xda;
const OP_ADD64: u8 = 0xd7;
const OP_GREATERTHANOREQUAL64: u8 = 0xdf;

/// The covenant input at consensus index k credits the maker at output 2k
/// (`CREDIT_IDX`) and re-pays its remainder at output 2k+1 (`REM_IDX`).
const CREDIT_IDX: [u8; 3] = [OP_PUSHCURRENTINPUTINDEX, OP_DUP, OP_ADD];
const REM_IDX: [u8; 4] = [OP_PUSHCURRENTINPUTINDEX, OP_DUP, OP_ADD, OP_1ADD];

/// A minimal CScript byte builder mirroring `covenant.js` `ScriptBuilder`.
struct SB {
    b: Vec<u8>,
}

impl SB {
    fn new() -> Self {
        SB { b: Vec::new() }
    }
    fn op(&mut self, o: u8) {
        self.b.push(o);
    }
    fn ops(&mut self, os: &[u8]) {
        self.b.extend_from_slice(os);
    }
    fn raw(&mut self, os: &[u8]) {
        self.b.extend_from_slice(os);
    }
    /// Data push, exactly as `CScriptOp.encode_op_pushdata`: a direct length
    /// prefix for `< 0x4c` bytes (the only case the leaves need — 8-byte operands
    /// and 32-byte data).
    fn push(&mut self, d: &[u8]) {
        let n = d.len();
        if n < 0x4c {
            self.b.push(n as u8);
        } else if n <= 0xff {
            self.b.push(0x4c);
            self.b.push(n as u8);
        } else if n <= 0xffff {
            self.b.push(0x4d);
            self.b.push((n & 0xff) as u8);
            self.b.push(((n >> 8) & 0xff) as u8);
        } else {
            self.b.push(0x4e);
            self.b.push((n & 0xff) as u8);
            self.b.push(((n >> 8) & 0xff) as u8);
            self.b.push(((n >> 16) & 0xff) as u8);
            self.b.push(((n >> 24) & 0xff) as u8);
        }
        self.b.extend_from_slice(d);
    }
    /// Signed integer push (CScript minimal encoding). Used for the REFUND expiry.
    fn push_num(&mut self, n: u64) {
        if n == 0 {
            self.op(OP_0);
        } else if (1..=16).contains(&n) {
            self.op(OP_1 + (n as u8) - 1);
        } else {
            self.push(&bn2vch(n));
        }
        // n == -1 (OP_1NEGATE) is never needed for a non-negative expiry.
        let _ = OP_1NEGATE;
    }
    fn bytes(self) -> Vec<u8> {
        self.b
    }
}

/// Bitcoin little-endian sign-magnitude encoding for a non-negative integer.
fn bn2vch(v: u64) -> Vec<u8> {
    if v == 0 {
        return Vec::new();
    }
    let mut av = v;
    let mut out: Vec<u8> = Vec::new();
    while av > 0 {
        out.push((av & 0xff) as u8);
        av >>= 8;
    }
    if out[out.len() - 1] & 0x80 != 0 {
        out.push(0x00);
    }
    out
}

/// 64-bit little-endian operand for the `OP_*64` arithmetic opcodes.
fn le8(n: u64) -> [u8; 8] {
    n.to_le_bytes()
}

/// Parse a fixed-length hex field into exactly `want` bytes.
fn hex_fixed(hex: &str, want: usize, what: &str) -> Result<Vec<u8>, String> {
    let v = Vec::<u8>::from_hex(hex).map_err(|e| format!("invalid {what} hex: {e}"))?;
    if v.len() != want {
        return Err(format!("{what} must be {want} bytes, got {}", v.len()));
    }
    Ok(v)
}

/// The pure covenant order parameters (all asset ids as DISPLAY hex — the exact
/// bytes baked into the leaf and posted in CovenantTerms).
#[derive(Debug, Clone)]
pub struct DeriveOrder {
    pub asset_a: String,
    pub asset_b: String,
    pub rate_num: u64,
    pub rate_den: u64,
    pub min_lot: u64,
    pub maker_prog: String,
    pub maker_ver: u8,
    pub expiry_locktime: u32,
    pub maker_x: String,
    /// Optional non-NUMS internal key hex; `None` ⇒ NUMS (no key-path spend).
    pub internal_key: Option<String>,
}

/// The derived covenant taptree: everything a maker posts + a taker reconstructs.
#[derive(Debug, Clone)]
pub struct Taptree {
    pub fill_leaf: Vec<u8>,
    pub refund_leaf: Vec<u8>,
    pub merkle_path: Vec<Vec<u8>>,
    pub script_pubkey: Vec<u8>,
    pub control_block: Vec<u8>,
    pub refund_control_block: Vec<u8>,
    pub internal_key: Vec<u8>,
}

/// `buildFillLeaf` — the permissionless FILL tapscript. `asset_a`/`asset_b` are
/// 32-byte asset ids (display hex bytes); `maker_prog` is the 32-byte v1-taproot
/// maker-credit witness program.
pub fn build_fill_leaf(
    asset_a: &str,
    asset_b: &str,
    rate_num: u64,
    rate_den: u64,
    min_lot: u64,
    maker_prog: &str,
    maker_ver: u8,
) -> Result<Vec<u8>, String> {
    let a = hex_fixed(asset_a, 32, "assetA")?;
    let b = hex_fixed(asset_b, 32, "assetB")?;
    let prog = hex_fixed(maker_prog, 32, "makerProg")?;
    if rate_num < 1 || rate_den < 1 || min_lot < 1 {
        return Err("rateNum, rateDen, minLot must be >= 1".into());
    }
    if maker_ver != 1 {
        return Err("this builder pins a v1 taproot maker payout".into());
    }

    let mut s = SB::new();
    // locked = this covenant input's own value (must be explicit).
    s.ops(&[OP_PUSHCURRENTINPUTINDEX, OP_INSPECTINPUTVALUE]);
    s.ops(&[OP_1, OP_EQUALVERIFY]);

    // remainder = asset A re-paid to output 2k+1 (0 for a full fill).
    s.raw(&REM_IDX);
    s.ops(&[OP_INSPECTNUMOUTPUTS, OP_LESSTHAN]);
    s.op(OP_IF);
    {
        s.raw(&REM_IDX);
        s.op(OP_INSPECTOUTPUTASSET);
        s.ops(&[OP_1, OP_EQUALVERIFY]);
        s.push(&a);
        s.op(OP_EQUAL);
        s.op(OP_IF);
        {
            s.raw(&REM_IDX);
            s.op(OP_INSPECTOUTPUTSCRIPTPUBKEY);
            s.ops(&[OP_PUSHCURRENTINPUTINDEX, OP_INSPECTINPUTSCRIPTPUBKEY]);
            s.ops(&[OP_ROT, OP_EQUALVERIFY, OP_EQUALVERIFY]);
            s.raw(&REM_IDX);
            s.ops(&[OP_INSPECTOUTPUTVALUE, OP_1, OP_EQUALVERIFY]);
            s.op(OP_DUP);
            s.push(&le8(min_lot));
            s.ops(&[OP_GREATERTHANOREQUAL64, OP_VERIFY]);
        }
        s.op(OP_ELSE);
        {
            s.push(&le8(0));
        }
        s.op(OP_ENDIF);
    }
    s.op(OP_ELSE);
    {
        s.push(&le8(0));
    }
    s.op(OP_ENDIF);

    // filled = locked - remainder, floored by min_lot.
    s.ops(&[OP_SUB64, OP_VERIFY]);
    s.op(OP_DUP);
    s.push(&le8(min_lot));
    s.ops(&[OP_GREATERTHANOREQUAL64, OP_VERIFY]);

    // required_B = ceil(filled*num/den) = floor((filled*num + den-1)/den).
    s.push(&le8(rate_num));
    s.ops(&[OP_MUL64, OP_VERIFY]);
    s.push(&le8(rate_den - 1));
    s.ops(&[OP_ADD64, OP_VERIFY]);
    s.push(&le8(rate_den));
    s.ops(&[OP_DIV64, OP_VERIFY, OP_NIP]);

    // credit output at 2k: asset == B, spk == maker, value >= required.
    s.raw(&CREDIT_IDX);
    s.ops(&[OP_INSPECTOUTPUTASSET, OP_1, OP_EQUALVERIFY]);
    s.push(&b);
    s.op(OP_EQUALVERIFY);
    s.raw(&CREDIT_IDX);
    s.ops(&[OP_INSPECTOUTPUTSCRIPTPUBKEY, OP_1, OP_EQUALVERIFY]);
    s.push(&prog);
    s.op(OP_EQUALVERIFY);
    s.raw(&CREDIT_IDX);
    s.ops(&[OP_INSPECTOUTPUTVALUE, OP_1, OP_EQUALVERIFY]);
    s.ops(&[OP_SWAP, OP_GREATERTHANOREQUAL64]);
    Ok(s.bytes())
}

/// `buildRefundLeaf` — absolute-CLTV reclaim by the maker after expiry.
/// `maker_x` is the maker's 32-byte x-only pubkey.
pub fn build_refund_leaf(expiry_locktime: u32, maker_x: &str) -> Result<Vec<u8>, String> {
    let x = hex_fixed(maker_x, 32, "makerX")?;
    let mut s = SB::new();
    s.push_num(expiry_locktime as u64);
    s.ops(&[OP_CHECKLOCKTIMEVERIFY, OP_DROP]);
    s.push(&x);
    s.op(OP_CHECKSIG);
    Ok(s.bytes())
}

/// `deriveTaptree` — build the {FILL, REFUND} taptree and return the covenant
/// scriptPubKey, the FILL/REFUND control blocks, and the merkle path. Reuses
/// `rust-elements`' taproot builder for the tweak/branch/control-block math so
/// only the two leaf scripts are hand-emitted.
pub fn derive_taptree(order: &DeriveOrder) -> Result<Taptree, String> {
    let fill = build_fill_leaf(
        &order.asset_a,
        &order.asset_b,
        order.rate_num,
        order.rate_den,
        order.min_lot,
        &order.maker_prog,
        order.maker_ver,
    )?;
    let refund = build_refund_leaf(order.expiry_locktime, &order.maker_x)?;

    let internal_hex = order.internal_key.as_deref().unwrap_or(NUMS_HEX);
    let internal_bytes = hex_fixed(internal_hex, 32, "internalKey")?;
    let internal = secp256k1_zkp::XOnlyPublicKey::from_slice(&internal_bytes)
        .map_err(|e| format!("internal key: {e}"))?;

    let fill_script = Script::from(fill.clone());
    let refund_script = Script::from(refund.clone());

    // Both leaves sit at depth 1; TaprootBuilder + finalize compute the sorted
    // TapBranch root, the TapTweak/elements output key, and per-leaf control
    // blocks (whose merkle branch is the sibling leaf hash) — matching
    // covenant.js deriveTaptree byte-for-byte.
    let secp = secp256k1_zkp::Secp256k1::verification_only();
    let spend = TaprootBuilder::new()
        .add_leaf(1, fill_script.clone())
        .map_err(|e| format!("add fill leaf: {e:?}"))?
        .add_leaf(1, refund_script.clone())
        .map_err(|e| format!("add refund leaf: {e:?}"))?
        .finalize(&secp, internal)
        .map_err(|e| format!("finalize taptree: {e:?}"))?;

    let out_key = spend.output_key().into_inner().serialize();
    let mut spk = Vec::with_capacity(34);
    spk.push(OP_1);
    spk.push(0x20);
    spk.extend_from_slice(&out_key);

    let fill_cb = spend
        .control_block(&(fill_script, LeafVersion::default()))
        .ok_or_else(|| "no control block for FILL leaf".to_string())?
        .serialize();
    let refund_cb = spend
        .control_block(&(refund_script, LeafVersion::default()))
        .ok_or_else(|| "no control block for REFUND leaf".to_string())?
        .serialize();

    // The FILL leaf's only merkle sibling is the REFUND leaf hash — the trailing
    // 32 bytes of the FILL control block (after the 1 version + 32 internal bytes).
    let merkle_path: Vec<Vec<u8>> = if fill_cb.len() >= 33 {
        vec![fill_cb[33..].to_vec()]
    } else {
        Vec::new()
    };

    Ok(Taptree {
        fill_leaf: fill,
        refund_leaf: refund,
        merkle_path,
        script_pubkey: spk,
        control_block: fill_cb,
        refund_control_block: refund_cb,
        internal_key: internal_bytes,
    })
}

/// `ceilPrice` — required_B = ceil(filled * rateNum / rateDen), rounding in the
/// maker's favour (matches the FILL leaf's on-chain 64-bit arithmetic).
pub fn ceil_price(filled: u64, rate_num: u64, rate_den: u64) -> u64 {
    ((filled as u128 * rate_num as u128 + rate_den as u128 - 1) / rate_den as u128) as u64
}

/// `planFill` result — the covenant is always input 0 (credit at output 0,
/// remainder at output 1).
#[derive(Debug, Clone)]
pub struct FillPlan {
    pub filled: u64,
    pub remainder: u64,
    pub required_b: u64,
    pub partial: bool,
}

/// `planFill` for taking `filled` atoms of asset A from a covenant holding
/// `locked`, enforcing the covenant's own floors (min_lot on filled + remainder).
pub fn plan_fill(order: &DeriveOrder, locked: u64, filled: u64) -> Result<FillPlan, String> {
    let min_lot = order.min_lot;
    if filled == 0 || filled > locked {
        return Err(format!("filled {filled} out of range (locked {locked})"));
    }
    if filled < min_lot {
        return Err(format!("filled {filled} below min_lot {min_lot}"));
    }
    let remainder = locked - filled;
    if remainder != 0 && remainder < min_lot {
        return Err(format!(
            "remainder {remainder} below min_lot {min_lot} (would be dust-griefing)"
        ));
    }
    Ok(FillPlan {
        filled,
        remainder,
        required_b: ceil_price(filled, order.rate_num, order.rate_den),
        partial: remainder != 0,
    })
}

/// `verifyAgainstSPK` — the trustless taker check: re-derive the covenant spk and
/// confirm it equals the funded UTXO's on-chain spk. Rejects a non-NUMS internal
/// key (a hidden maker key-path cancel/rug) unless `maker_cancellable_ok`.
pub fn verify_against_spk(
    order: &DeriveOrder,
    onchain_spk: &[u8],
    maker_cancellable_ok: bool,
) -> Result<Taptree, String> {
    let nums = Vec::<u8>::from_hex(NUMS_HEX).expect("static NUMS hex");
    let internal_hex = order.internal_key.as_deref().unwrap_or(NUMS_HEX);
    let internal_bytes = hex_fixed(internal_hex, 32, "internalKey")?;
    if !maker_cancellable_ok && internal_bytes != nums {
        return Err(
            "non-NUMS internal key: order is maker-cancellable (key-path rug risk); reject unless explicitly allowed"
                .into(),
        );
    }
    let tap = derive_taptree(order)?;
    if tap.script_pubkey != onchain_spk {
        return Err(format!(
            "reconstructed spk {} != on-chain spk {}",
            hex_of(&tap.script_pubkey),
            hex_of(onchain_spk)
        ));
    }
    Ok(tap)
}

/// gcd for `computeRate` (Euclid).
fn gcd(mut a: u64, mut b: u64) -> u64 {
    while b != 0 {
        let t = a % b;
        a = b;
        b = t;
    }
    if a == 0 {
        1
    } else {
        a
    }
}

/// `computeRate` — turn "lock `sell` of A, want `recv` of B for a full fill" into
/// the covenant's reduced rate (rate_num/rate_den), so a taker owes
/// ceil(filled * rateNum/rateDen) of B.
pub fn compute_rate(sell: u64, recv: u64) -> Result<(u64, u64), String> {
    if sell < 1 || recv < 1 {
        return Err("sell and recv amounts must be >= 1".into());
    }
    let g = gcd(recv, sell);
    Ok((recv / g, sell / g))
}

/// Default REFUND horizon (~1 day of Sequentia blocks), matching
/// `covenant-flow.js` `DEFAULT_ORDER_BLOCKS`.
pub const DEFAULT_ORDER_BLOCKS: u32 = 1440;

/// `orderExpiry` — the absolute-locktime REFUND height baked into a resting order.
pub fn order_expiry(tip_height: u32, blocks: u32) -> u32 {
    tip_height.saturating_add(if blocks == 0 { DEFAULT_ORDER_BLOCKS } else { blocks })
}

fn hex_of(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{x:02x}"));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    // The exact fixed order from seqdex/daemon/pkg/covenant/leaf_test.go, pinned
    // in SWK's lwk_wollet/src/seqob_covenant.rs golden vectors: asset_a = 0..31,
    // asset_b = 32..63, rate 3/7, min_lot 5e8, maker_prog = 0x11*32, expiry 400,
    // maker_x = 0x22*32, internal_key = NUMS.
    const GOLD_FILL_LEAF: &str = "cdc95188cd76938bd59f63cd76938bce518820000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f8763cd76938bd1cdca7b8888cd76938bcf518876080065cd1d00000000df6967080000000000000000686708000000000000000068d86976080065cd1d00000000df69080300000000000000d969080600000000000000d769080700000000000000da6977cd7693ce518820202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f88cd7693d1518820111111111111111111111111111111111111111111111111111111111111111188cd7693cf51887cdf";
    const GOLD_CTRL_BLOCK: &str = "c550929b74c1a04954b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac0b36045e27b7a5812d8d7339811db86ef98751c7e382a84a1d34949a83b4ae920";
    const GOLD_ORDER_SPK: &str = "5120b22544534c99090050a06eece12231a2321f4144661ab3964408d5780821afaa";

    fn hex32(f: impl Fn(u8) -> u8) -> String {
        (0u8..32).map(|i| format!("{:02x}", f(i))).collect()
    }

    fn gold_order() -> DeriveOrder {
        DeriveOrder {
            asset_a: hex32(|i| i),        // 00..1f
            asset_b: hex32(|i| i + 32),   // 20..3f
            rate_num: 3,
            rate_den: 7,
            min_lot: 500_000_000,
            maker_prog: "11".repeat(32),
            maker_ver: 1,
            expiry_locktime: 400,
            maker_x: "22".repeat(32),
            internal_key: None,
        }
    }

    #[test]
    fn fill_leaf_matches_golden() {
        let o = gold_order();
        let leaf = build_fill_leaf(
            &o.asset_a, &o.asset_b, o.rate_num, o.rate_den, o.min_lot, &o.maker_prog, o.maker_ver,
        )
        .unwrap();
        assert_eq!(hex_of(&leaf), GOLD_FILL_LEAF);
    }

    #[test]
    fn taptree_matches_golden() {
        let tap = derive_taptree(&gold_order()).unwrap();
        assert_eq!(hex_of(&tap.fill_leaf), GOLD_FILL_LEAF, "fill leaf");
        assert_eq!(hex_of(&tap.control_block), GOLD_CTRL_BLOCK, "control block");
        assert_eq!(hex_of(&tap.script_pubkey), GOLD_ORDER_SPK, "order spk");
        // The FILL merkle path is the single REFUND-leaf sibling hash.
        assert_eq!(tap.merkle_path.len(), 1);
    }

    #[test]
    fn ceil_price_rounds_up() {
        // ceil(1000 * 3 / 7) = ceil(428.57..) = 429.
        assert_eq!(ceil_price(1000, 3, 7), 429);
        assert_eq!(ceil_price(7, 3, 7), 3); // exact
    }

    #[test]
    fn compute_rate_reduces() {
        assert_eq!(compute_rate(700_000_000, 300_000_000).unwrap(), (3, 7));
    }

    #[test]
    fn plan_fill_floors() {
        let o = gold_order();
        // filled below min_lot rejected.
        assert!(plan_fill(&o, 1_000_000_000, 1).is_err());
        // remainder below min_lot rejected.
        assert!(plan_fill(&o, 1_000_000_000, 600_000_000).is_err());
        // clean partial.
        let p = plan_fill(&o, 2_000_000_000, 1_000_000_000).unwrap();
        assert!(p.partial);
        assert_eq!(p.remainder, 1_000_000_000);
    }

    #[test]
    fn refund_leaf_expiry_push() {
        // expiry 400 -> 0x0190 -> minimal push [0x02,0x90,0x01].
        let leaf = build_refund_leaf(400, &"22".repeat(32)).unwrap();
        assert_eq!(leaf[0], 0x02);
        assert_eq!(leaf[1], 0x90);
        assert_eq!(leaf[2], 0x01);
    }
}
