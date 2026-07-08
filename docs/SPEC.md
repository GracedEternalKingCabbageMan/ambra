# Ambra product and design spec (current state, testnet, Android-first)

Ambra is a non-custodial dual-chain wallet for Bitcoin (testnet4) + Sequentia:
a Flutter UI over the `ambra_core` Rust crate via flutter_rust_bridge, built on the
SWK kit. The Sequentia web wallet is the design and feature model, re-shaped for a
phone. This document describes the app as implemented today; the short list of
not-yet-implemented items is at the end under "Roadmap".

## Custody contract

The seed never leaves the device. The 12-word mnemonic is stored in Android
Keystore-backed encrypted preferences (iOS Keychain once iOS ships),
re-read into the core only to derive/sign, and never persisted by the core.

The app lock (biometric or device PIN, `local_auth`) is opt-in (More > Security).
When enabled it gates opening the app on cold start and re-engages whenever the app
is backgrounded, popping any sheet above the lock so nothing sensitive survives it.
Independently of the lock, Reveal recovery phrase always requires authentication,
and enabling/disabling the lock itself requires authentication.

## Finality UX (consensus law, never contradict)

Bitcoin anchoring is supreme: Sequentia reorganizes whenever Bitcoin reorganizes
away a block's anchor, overriding checkpoints and immediate finality. A transaction
is settled when it lands in a certified block (~30s slot), subject always to a
Bitcoin reorg of its anchor. There is no confirmation-count bar and no anchor-depth
gating in the general UI: a light wallet cannot watch Bitcoin itself and mirrors
backend chain state; if a sync reports a (rare, Bitcoin-reorg-driven) disconnect,
the affected transaction un-settles. The two places anchoring surfaces explicitly:

- Swap review sheets state "Anchor-bound to Bitcoin (reverts only if Bitcoin
  reverts)"; nothing on-chain is ever labeled "final".
- The cross-chain (BTC->asset) swap hard-gates its preimage reveal on verifying the
  Sequentia leg's anchor evidence, because there real BTC is at stake on the answer.
- Only the pure-Lightning rail, where nothing settles on-chain, is labeled instant
  and final.

Staked tSEQ is shown LOCKED and excluded from spendable.

## Balance model (no privileged asset)

The Balance headline is the total portfolio value across every held asset, valued
in a user-chosen reference currency (USD default; picker in the top bar, price-server
fed). Every asset counts equally toward the total: BTC (parent chain), tSEQ, issued
assets, and OpenAMP restricted assets. When prices are unavailable the headline
shows a dash and the per-asset rows carry the amounts. Below the headline, one equal
row per held asset; zero balances are hidden for every asset alike, tSEQ included.
There is no "native asset" label anywhere: the Sequence token (tSEQ) is one row among
equals, and its only special role is staking.

## Navigation

- Onboarding Navigator stack (no bottom bar): Boot > Welcome > {Create: word-grid >
  verify-words > backed-up} | {Import} > pushReplacement > Shell. (The app lock is
  configured later, in More > Security, not during onboarding.)
- Shell = bottom tab bar over an IndexedStack (state kept per tab):
  **Balance · Send · Receive · Swap · History · More**. Android back returns to
  Balance from any tab and only exits from Balance.
- Swap tab: same-chain SeqDEX composer, plus entries to "Buy with Bitcoin
  (cross-chain)" and, when a hosted LSP is configured, "Instant (Lightning)".
- More hub: Node (view/change backend), Testnet faucet, Security (app lock),
  Wallet (reveal phrase / remove wallet), Assets & staking (issue/manage assets,
  stake tSEQ).
- Modals = bottom sheets: review-&-sign, reference-currency picker, fee-asset
  picker, rescue (RBF-bump / RBF-replace / CPFP), QR scanner (full-screen route),
  recovery-phrase reveal.

## Fees (open fee market)

Sequentia sends default the fee to the asset being sent; a fee-asset picker offers
any asset the network publishes an exchange rate for (`/feerates`). A manual
fee-rate override is always denominated in the chosen fee asset's own units per
vByte, never "sat/vB" (sats are Bitcoin-only). Parent-chain BTC sends pay their own
fee in BTC at sat/vB, with no fee-asset market (that is Bitcoin, not Sequentia).

## Design tokens (ported 1:1 from the web wallet)

Colors (`app/lib/src/theme/theme.dart`): bg `#0d1014`, glowTop `#1a212b`, panel
`#161b22`, panelDeep `#0b0e12`, line `#262d36`, txt `#e6edf3`, dim `#8b949e`, amber
`#f0a500`, amber2 `#ffb733`, green `#27ae60`, red `#e0564b`, blue `#4aa3df`,
buttonSurface `#1d242d`, primaryOnGold `#1a1200`, warnFill `#2a1d0a`, warnBorder
`#6b4e12`, warnText `#ffcf7a`, monoText `#c9d4df`, dangerBorder `#5a2a26`, qrWhite
`#ffffff`. Canvas = radial gradient (`#1a212b` > `#0d1014`) behind the header.
Single-accent discipline: gold is the only brand accent and the only gradient;
green/red/blue are semantic status only. Never `#000`/`#fff` for surfaces; the QR
card is the one pure white.

Type: system sans (SF Pro / Roboto) for all prose/UI; monospace for ALL
machine-precise values (addresses, 64-hex asset ids, txids, atom amounts). The
sans/mono split is the load-bearing trust signal. Hero balance 42/w800 + amber2
unit suffix; micro-label 12/dim/uppercase; bold reserved for numbers, identifiers,
and actions.

Rounding: cards 16, controls/buttons 10-12, inputs 10, chips 8, pills capsule.

Components (`app/lib/src/widgets/widgets.dart`): AmbraCard (panel fill, 1px line,
r16, no shadow), PrimaryButton (the one gold gradient CTA per screen, `#1a1200`
text), SecondaryButton, DangerButton (red text, no fill), bottom bar with
nested-pill active state, panelDeep inset inputs with mono variant, KvRow, history
rows (semantic pill + mono txid + signed amount), WarnCallout, MnemonicWordGrid,
white QR card. Signature interactions: the any-asset fee picker and the tethered
reference dual-field ("You'll send X TICKER").

Brand: circular near-black coin with the two-stroke gold **S** (the app icon,
`assets/icon/sequentia-s.png`). Voice: self-custodial, any-asset fees with no
privileged asset, review-before-sign, Bitcoin a first-class sibling with explicit
chain badges. Resist Material defaults (colored surfaces, secondary accents, heavy
shadows).

## ambra_core API surface (implemented)

Generated bindings live in `app/lib/src/rust/`; the Rust source of truth is
`ambra_core/src/api/mod.rs` and `ambra_core/src/api/signer.rs`.

- Keys/addresses: `network_name`, `generate_mnemonic`, `validate_mnemonic`,
  `descriptor_from_mnemonic`, `receive_address`, `confidential_receive_address`,
  `receive_address_at`, `validate_address`.
- Sync/state: `set_data_dir` (on-disk wallet persistence), `set_auth_header`,
  `sync_wallet`, `wallet_transactions`, `clear_wallet_cache`.
- Send: `build_send_tx` (multi-recipient, any-asset fee, optional fee rate),
  `sign_pset`, `finalize_and_broadcast`, `pset_fee`.
- Rescue: `build_rbf_bump_tx`, `build_rbf_replace_tx`, `build_cpfp_tx`,
  `cpfp_suggested_feerate`.
- Assets/staking: `build_issue_tx`, `build_reissue_tx`, `build_burn_tx`,
  `staker_public_key`, `build_stake_tx` (enforces the 40,000 tSEQ minimum and a
  time-based CSV of ~15 days).
- Bitcoin (testnet4) wallet: `btc_sync`, `btc_prepare`, `btc_broadcast`.
- SeqDEX same-chain swap: `seqdex_build_swap_request`, `seqdex_sign_accept`.
- Cross-chain BTC->asset HTLC: `xchain_new_secret`, `xchain_seq_claim_pubkey`,
  `xchain_btc_refund_pubkey`, `xchain_btc_htlc`, `xchain_seq_redeem_script`,
  `xchain_find_btc_funding`, `xchain_verify_seq_leg_safe` (the anchor gate),
  `xchain_seq_claim`, `xchain_seq_broadcast`, `xchain_btc_refund`.
- OpenAMP: `openamp_xonly_pubkey`, `openamp_sign_sighash` (on-device Schnorr signer
  for the enclave's transfer approvals).
- Lightning device signer (`api/signer.rs`): `SeqlnSigner` (from mnemonic or
  hsm_secret, `process_frame`, enforce/permissive policy), `NoiseSession`
  (Noise_XK initiator: handshake, encrypt/decrypt), `device_pubkey`,
  `seqln_device_transport_privkey` (BIP32 m/1017'/0'/0').

## Defaults

Single wallet (mirrors the web wallet); opt-in device biometric/passcode lock;
foreground + on-resume + pull-to-refresh sync (no push); testnet/faucet cues kept;
reference currency defaults to USD. Backend defaults to the public testnet node
`http://159.195.15.140` and is user-configurable (More > Node, optional HTTP auth);
endpoints: `/api`, `/testnet4/api`, `/dex`, `/feerates`, `/prices`,
`/registry/index.minimal.json`, `/faucet`, `/openamp`, `/lsp`.

## Roadmap (not yet implemented)

- Unstaking/unbonding flow (staking is one-way in the app today).
- A live hosted LSP deployment; the Lightning rail ships dormant until
  `Backend.lnWsUrl`/`lnHostPubkey` point at one.
- iOS bring-up (scaffold exists; needs a macOS/Xcode machine) and release signing
  for Android (currently debug-signed).
- Push/background sync.
