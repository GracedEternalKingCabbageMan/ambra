//! SEQUENTIA staking rewards, for the phone: which coins a staker was PAID, and
//! which of them to convert.
//!
//! Layers 1 and 2 of reward auto-conversion (the node repo's
//! `doc/sequentia/reward-autoconvert-design.md`). Neither decision is made here:
//! both come straight from the kit (`lwk_wollet::staking_rewards`), which is the
//! same code the node's wallet, the web wallet and the browser extension use. A
//! phone that disagreed with a desktop about which of a staker's coins were
//! rewards would be a phone that sold the wrong ones.
//!
//! JSON in, JSON out, deliberately: the same DTOs the wasm bindings carry, so
//! the Dart side and the browser side speak one shape and neither has to be
//! translated when the other changes.

use anyhow::Result;
use std::collections::{HashMap, HashSet};
use std::str::FromStr;

use lwk_wollet::elements::hashes::Hash as _;
use lwk_wollet::elements::hex::FromHex;
use lwk_wollet::elements::{AssetId, OutPoint, Script, Txid};
use lwk_wollet::staking_rewards::{
    attribute_rewards, batches, decide, AutoConvertSettings, ConvertTarget, Decision, OwnedOutput,
    Quote, RewardBatch, RewardSource, SignerRelation, StakingReward, TxFacts,
    SEQUENTIA_COINBASE_MATURITY,
};
use serde::{Deserialize, Serialize};

/// Lowercase hex, the one spelling every side of this feature uses.
fn hexenc(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{x:02x}"));
    }
    s
}

fn rerr<E: std::fmt::Debug>(e: E) -> anyhow::Error {
    anyhow::Error::msg(format!("{e:?}"))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnedOutputDto {
    vout: u32,
    script_pubkey: String,
    asset: String,
    value: u64,
    #[serde(default)]
    spent: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TxFactsDto {
    txid: String,
    #[serde(default)]
    height: Option<u32>,
    is_coinbase: bool,
    #[serde(default)]
    from_me: bool,
    owned_outputs: Vec<OwnedOutputDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StakingKeyDto {
    script_pubkey: String,
    pubkey: String,
    #[serde(default)]
    delegated: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StakingRewardDto {
    txid: String,
    vout: u32,
    asset: String,
    value: u64,
    source: String,
    #[serde(default)]
    height: Option<u32>,
    blocks_to_maturity: u32,
    mature: bool,
    spent: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SettingsDto {
    #[serde(default)]
    enabled: bool,
    /// Asset id to convert into, or omitted for native parent-chain BTC -- the
    /// default, and the top of every picker. Never SBTC.
    #[serde(default)]
    target: Option<String>,
    #[serde(default)]
    exclude: Vec<String>,
    min_receive: u64,
    max_slippage_bp: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RewardBatchDto {
    asset: String,
    inputs: Vec<String>,
    value: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct QuoteDto {
    receives: u64,
    reference: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DecisionDto {
    decision: String,
    converts: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    receives: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    floor: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    slippage_bp: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cap_bp: Option<u32>,
    reason: String,
}

fn asset(s: &str) -> Result<AssetId> {
    AssetId::from_str(s.trim()).map_err(rerr)
}

fn script(s: &str) -> Result<Script> {
    Ok(Script::from(Vec::<u8>::from_hex(s.trim()).map_err(rerr)?))
}

fn outpoint_str(o: &OutPoint) -> String {
    format!("{}:{}", o.txid, o.vout)
}

fn outpoint(s: &str) -> Result<OutPoint> {
    let (t, v) = s
        .rsplit_once(':')
        .ok_or_else(|| anyhow::Error::msg(format!("bad outpoint {s}")))?;
    Ok(OutPoint::new(
        Txid::from_str(t.trim()).map_err(rerr)?,
        v.trim().parse::<u32>().map_err(rerr)?,
    ))
}

fn settings(dto: &SettingsDto) -> Result<AutoConvertSettings> {
    let target = match dto.target.as_deref().map(str::trim) {
        None | Some("") => ConvertTarget::NativeBtc,
        Some(h) => ConvertTarget::Asset(asset(h)?),
    };
    let mut exclude = HashSet::new();
    for a in &dto.exclude {
        exclude.insert(asset(a)?);
    }
    Ok(AutoConvertSettings {
        enabled: dto.enabled,
        target,
        exclude,
        min_receive: dto.min_receive,
        max_slippage_bp: dto.max_slippage_bp,
    })
}

/// Every staking reward in `txs_json`, newest first, as JSON.
///
/// The two shapes attribution recognises are the two ways the consensus rules
/// pay a staker: a coinbase output the wallet owns, and an output paid to
/// `P2WPKH(controller)` by a pool's claim.
pub fn attribute_staking_rewards(
    txs_json: String,
    staking_keys_json: String,
    tip_height: u32,
    coinbase_maturity: u32,
) -> Result<String> {
    let txs: Vec<TxFactsDto> = serde_json::from_str(&txs_json).map_err(rerr)?;
    let keys: Vec<StakingKeyDto> = serde_json::from_str(&staking_keys_json).map_err(rerr)?;

    let mut scripts = HashMap::new();
    let mut relations = HashMap::new();
    for k in &keys {
        let pk = lwk_wollet::elements::secp256k1_zkp::PublicKey::from_str(k.pubkey.trim())
            .map_err(rerr)?;
        scripts.insert(script(&k.script_pubkey)?, pk);
        relations.insert(
            pk,
            if k.delegated {
                SignerRelation::Delegated
            } else {
                SignerRelation::SelfSigning
            },
        );
    }

    let mut facts = Vec::with_capacity(txs.len());
    for t in &txs {
        let mut owned = Vec::with_capacity(t.owned_outputs.len());
        for o in &t.owned_outputs {
            owned.push(OwnedOutput {
                vout: o.vout,
                script_pubkey: script(&o.script_pubkey)?,
                asset: asset(&o.asset)?,
                value: o.value,
                spent: o.spent,
            });
        }
        facts.push(TxFacts {
            txid: Txid::from_str(t.txid.trim()).map_err(rerr)?,
            height: t.height,
            is_coinbase: t.is_coinbase,
            from_me: t.from_me,
            owned_outputs: owned,
        });
    }

    let rewards = attribute_rewards(&facts, &scripts, &relations, tip_height, coinbase_maturity);
    let out: Vec<StakingRewardDto> = rewards
        .iter()
        .map(|r| StakingRewardDto {
            txid: r.outpoint.txid.to_string(),
            vout: r.outpoint.vout,
            asset: r.asset.to_string(),
            value: r.value,
            source: r.source.as_str().to_string(),
            height: r.height,
            blocks_to_maturity: r.blocks_to_maturity,
            mature: r.mature(),
            spent: r.spent,
        })
        .collect();
    serde_json::to_string(&out).map_err(rerr)
}

/// Group convertible rewards into one batch per asset, skipping the target
/// itself and anything excluded.
///
/// `already_converted_json` is the outpoints a conversion has already committed
/// to -- the whole of the idempotence that stops a restart selling the same
/// reward twice.
pub fn plan_reward_batches(
    rewards_json: String,
    settings_json: String,
    already_converted_json: String,
) -> Result<String> {
    let rewards: Vec<StakingRewardDto> = serde_json::from_str(&rewards_json).map_err(rerr)?;
    let s: SettingsDto = serde_json::from_str(&settings_json).map_err(rerr)?;
    let already: Vec<String> = serde_json::from_str(&already_converted_json).map_err(rerr)?;

    let mut coins = Vec::with_capacity(rewards.len());
    for d in &rewards {
        let source = match d.source.as_str() {
            "solo" => RewardSource::Solo,
            "direct" => RewardSource::Direct,
            "lottery" => RewardSource::Lottery,
            "split" => RewardSource::Split,
            other => return Err(anyhow::Error::msg(format!("unknown reward source {other}"))),
        };
        coins.push(StakingReward {
            outpoint: OutPoint::new(Txid::from_str(d.txid.trim()).map_err(rerr)?, d.vout),
            asset: asset(&d.asset)?,
            value: d.value,
            source,
            height: d.height,
            blocks_to_maturity: d.blocks_to_maturity,
            spent: d.spent,
        });
    }

    let mut done = HashSet::new();
    for o in &already {
        done.insert(outpoint(o)?);
    }

    let out: Vec<RewardBatchDto> = batches(&coins, &settings(&s)?, &done)
        .iter()
        .map(|b| RewardBatchDto {
            asset: b.asset.to_string(),
            inputs: b.inputs.iter().map(outpoint_str).collect(),
            value: b.value,
        })
        .collect();
    serde_json::to_string(&out).map_err(rerr)
}

/// Whether one batch converts, given what the book is offering.
///
/// `quote_json` is `"null"` when there is no market for the pair, or none deep
/// enough. That is not an error: it is the ordinary state of a young pair, and
/// the batch waits.
pub fn decide_reward_conversion(
    batch_json: String,
    quote_json: String,
    settings_json: String,
) -> Result<String> {
    let b: RewardBatchDto = serde_json::from_str(&batch_json).map_err(rerr)?;
    let q: Option<QuoteDto> = serde_json::from_str(&quote_json).map_err(rerr)?;
    let s: SettingsDto = serde_json::from_str(&settings_json).map_err(rerr)?;

    let mut inputs = Vec::with_capacity(b.inputs.len());
    for i in &b.inputs {
        inputs.push(outpoint(i)?);
    }
    let batch = RewardBatch {
        asset: asset(&b.asset)?,
        inputs,
        value: b.value,
    };

    let d = decide(
        &batch,
        q.map(|q| Quote {
            receives: q.receives,
            reference: q.reference,
        }),
        &settings(&s)?,
    );

    let dto = match d {
        Decision::Convert { receives } => DecisionDto {
            decision: "convert".into(),
            converts: true,
            receives: Some(receives),
            floor: None,
            slippage_bp: None,
            cap_bp: None,
            reason: "converting".into(),
        },
        Decision::Disabled => DecisionDto {
            decision: "disabled".into(),
            converts: false,
            receives: None,
            floor: None,
            slippage_bp: None,
            cap_bp: None,
            reason: "Automatic conversion is switched off.".into(),
        },
        Decision::NotConverted => DecisionDto {
            decision: "notConverted".into(),
            converts: false,
            receives: None,
            floor: None,
            slippage_bp: None,
            cap_bp: None,
            reason: "This asset is the one you convert into, or you chose to keep it.".into(),
        },
        Decision::TooSmallToPrice => DecisionDto {
            decision: "tooSmallToPrice".into(),
            converts: false,
            receives: None,
            floor: None,
            slippage_bp: None,
            cap_bp: None,
            reason: "There is a market, but this much is worth less than one unit of what you are converting into. These rewards wait until there are more of them.".into(),
        },
        Decision::NoMarket => DecisionDto {
            decision: "noMarket".into(),
            converts: false,
            receives: None,
            floor: None,
            slippage_bp: None,
            cap_bp: None,
            reason: "No market for this pair right now. These rewards wait; they convert if one appears.".into(),
        },
        Decision::BelowFloor { receives, floor } => DecisionDto {
            decision: "belowFloor".into(),
            converts: false,
            receives: Some(receives),
            floor: Some(floor),
            slippage_bp: None,
            cap_bp: None,
            reason: "Not yet worth converting: these rewards would fetch less than your minimum. They wait for the next ones.".into(),
        },
        Decision::SlippageTooHigh { slippage_bp, cap_bp } => DecisionDto {
            decision: "slippageTooHigh".into(),
            converts: false,
            receives: None,
            floor: None,
            slippage_bp: Some(slippage_bp),
            cap_bp: Some(cap_bp),
            reason: "The market is quoting too far from the reference price. These rewards wait for a better one.".into(),
        },
    };
    serde_json::to_string(&dto).map_err(rerr)
}

/// How much of a batch a WHOLE-HTLC offer may take.
///
/// The cross-chain rail rests whole offers and the one picked is the smallest
/// that COVERS the request, which can be far larger than the batch. Taking it
/// whole would sell coins staking never paid; selling less is normal, and the
/// remainder waits. Zero means "no fill", never "take everything".
pub fn reward_slice_for_whole_htlc(offer_atoms: u64, batch_atoms: u64) -> u64 {
    if offer_atoms == 0 || batch_atoms == 0 {
        return 0;
    }
    offer_atoms.min(batch_atoms)
}


/// Sequentia's coinbase maturity, in blocks -- 1,000, not Bitcoin's 100.
///
/// The protection is a wall-clock one and this chain runs at 60 seconds, so 100
/// blocks here would buy a tenth of what Bitcoin's 100 buys. Exposed so the Dart
/// side never has to hard-code it, and cannot hard-code it wrong: a wallet using
/// 100 calls a reward spendable 900 blocks early and then builds a transaction
/// the chain rejects.
pub fn sequentia_coinbase_maturity() -> u32 {
    SEQUENTIA_COINBASE_MATURITY
}

/// The facts attribution needs, gathered from a synced wallet.
///
/// The Dart side has no wollet handle of its own, and it should not: assembling
/// this is exactly the sort of thing that drifts when two languages each do half
/// of it. So the wallet is opened, synced and read here, and Dart receives the
/// same JSON the browser wallets assemble for themselves.
pub fn wallet_tx_facts(mnemonic: String, esplora_url: String) -> Result<String> {
    super::with_synced_wollet(&mnemonic, &esplora_url, |wollet| {
        let mut out: Vec<TxFactsDto> = Vec::new();
        for tx in wollet.transactions().map_err(rerr)? {
            let mut owned = Vec::new();
            for o in tx.outputs.iter().flatten() {
                owned.push(OwnedOutputDto {
                    vout: o.outpoint.vout,
                    script_pubkey: hexenc(o.script_pubkey.as_bytes()),
                    asset: o.unblinded.asset.to_string(),
                    value: o.unblinded.value,
                    spent: o.is_spent,
                });
            }
            if owned.is_empty() {
                continue;
            }
            let is_coinbase = tx.tx.is_coinbase();
            out.push(TxFactsDto {
                txid: tx.txid.to_string(),
                height: tx.height,
                is_coinbase,
                // A coinbase is never anyone's to send; off that path, "we sent
                // it" is what excludes our own withdrawal or re-pointing, which
                // pay back to the very staking key a pool payout would.
                from_me: !is_coinbase && tx.type_ == "outgoing",
                owned_outputs: owned,
            });
        }
        serde_json::to_string(&out).map_err(rerr)
    })
}

/// The staking keys a reward can be paid on, with the `P2WPKH` script that pays
/// them. `delegated` tells `solo` from `lottery`; both are coinbase payments to
/// a staking key, and the difference is whether that key was signing for itself.
pub fn staking_key_facts(mnemonic: String, delegated: bool) -> Result<String> {
    let pubkey = super::staker_public_key(mnemonic)?;
    let bytes = Vec::<u8>::from_hex(&pubkey).map_err(rerr)?;
    // P2WPKH, built from the bytes rather than through a key type: the script
    // the coinbase pays is `OP_0 <hash160(pubkey)>` and nothing else, and this
    // is the form every other implementation of this check uses.
    let h = lwk_wollet::elements::hashes::hash160::Hash::hash(&bytes);
    let mut spk_bytes = vec![0x00u8, 0x14u8];
    spk_bytes.extend_from_slice(&h[..]);
    let dto = vec![StakingKeyDto {
        script_pubkey: hexenc(&spk_bytes),
        pubkey,
        delegated,
    }];
    serde_json::to_string(&dto).map_err(rerr)
}

/// This wallet's view of the chain tip, which maturity is judged against.
pub fn tip_height(mnemonic: String, esplora_url: String) -> Result<u32> {
    super::with_synced_wollet(&mnemonic, &esplora_url, |wollet| Ok(wollet.tip().height()))
}
