# Ambra — build spec (v1, testnet, Android-first)

Ambra is a non-custodial Sequentia wallet for Android + iOS (Flutter UI over the
`ambra_core` Rust crate via flutter_rust_bridge, on the SWK kit). The **Sequentia
web wallet** is the design + feature model; this is it re-shaped for a phone.

## Custody contract
Seed never leaves the device. The 12/24-word mnemonic is stored in Android
Keystore / iOS Keychain (encrypted, biometric-backed), re-read into the core only
to sign, and never persisted by the core. App-lock (biometric/passcode) gates:
opening the app, every Confirm & sign, and Reveal phrase / Remove wallet.

## Finality UX (consensus law — never contradict)
Sequentia has immediate finality: a tx is **settled the instant it lands in a
certified block** (~30s slot). NO confirmation-count bar, NO anchor-depth gating
— a light wallet cannot watch Bitcoin and just mirrors backend chain state; if a
sync reports a (rare, Bitcoin-reorg-driven) disconnect, the affected tx
un-settles. Per-asset balances only — never a summed total across assets. Staked
SEQ is shown LOCKED, excluded from spendable.

## Navigation
- Onboarding Navigator stack (no bottom bar): Boot → Welcome → {Create: word-grid
  → verify-words → backed-up} | {Import} → app-lock setup → pushReplacement → Shell.
- Shell = native bottom tab bar over an IndexedStack (state per tab):
  **Balance · Send · Receive · History · More**.
- More hub routes to: Assets, Stake, Settings, Faucet, and UI-only stubs
  Lightning / T-DEX / Managed assets.
- Modals = native bottom sheets: Review-&-sign (shared, biometric CTA),
  reference-currency picker, fee-asset picker, RBF-bump / RBF-replace / CPFP,
  QR scanner, share.

## Design tokens (ported 1:1 from the web wallet)
Colors: bg `#0d1014`, glowTop `#1a212b`, panel `#161b22`, panelDeep `#0b0e12`,
line `#262d36`, txt `#e6edf3`, dim `#8b949e`, amber `#f0a500`, amber2 `#ffb733`,
green `#27ae60`, red `#e0564b`, blue `#4aa3df`, buttonSurface `#1d242d`,
primaryOnGold `#1a1200`, warnFill `#2a1d0a`, warnBorder `#6b4e12`, warnText
`#ffcf7a`, monoText `#c9d4df`, qrWhite `#ffffff`, scrim `#000` @67%.
Badges: in {`#27ae60`/`#10241a`/`#1f4d33`}, out {`#ffb733`/`#241c0a`/`#5a4412`},
iss {`#4aa3df`/`#0d1f2a`/`#244a63`}. Canvas = radial gradient (`#1a212b`→`#0d1014`)
behind the header. Single-accent discipline: gold is the only brand accent + the
only gradient; green/red/blue are semantic status only. Never `#000`/`#fff` for
surfaces; the QR card is the one pure white.

Type: system sans (SF Pro / Roboto) for all prose/UI; monospace (SF Mono / Roboto
Mono / Menlo) for ALL machine-precise values (addresses, 64-hex asset ids, txids,
atom amounts) — the sans/mono split is the load-bearing trust signal. Scale: hero
balance 42/w800/-0.02 + 17/w700 amber2 unit suffix; h1 21/-0.01; micro-label
`.lbl` 12/dim/uppercase/0.06; body 14; kv 12.5–14; pills 11; tabs 13.5; mono 13.
Bold reserved for numbers/identifiers/actions.

Rounding: cards 16, controls/buttons 10–12, inputs 10, chips 8, pills capsule.

Components: AmbraCard (panel fill, 1px line, r16, p20, no shadow). PrimaryButton
(the one gold 135° gradient CTA per screen, `#1a1200` text, full-width, bottom
action bar). SecondaryButton (`#1d242d` + line). DangerButton (red text +
`#5a2a26` border, no fill). BottomTabBar (nested-pill active). Inputs (panelDeep
inset, mono variant, `.lbl` above + caption below). KvRow (dim key / right mono
value / hairline). HistoryRow (semantic pill + mono txid + signed amount).
BadgePill. WarnCallout (`#2a1d0a`/`#6b4e12`/`#ffcf7a`). Toast (bottom-center,
explorer deep-link, auto-dismiss). MnemonicWordGrid (3-col panelDeep chips,
FLAG_SECURE). QR card (white). Signature: any-asset **fee picker** + tethered
**reference dual-field** (segmented Asset|REF + keypad + "You'll send X TICKER").

Brand: circular near-black coin with the two-stroke gold **S** (matte ground melts
into the canvas; only the gold S floats) → app icon. Voice: self-custodial,
any-asset fees with no privileged asset, review-before-sign, Bitcoin a first-class
sibling with explicit chain badges. Resist Material defaults (colored surfaces,
secondary accents, heavy shadows).

## ambra_core API (FRB), by milestone
Have: network_name, generate_mnemonic, descriptor_from_mnemonic, receive_address,
confidential_receive_address.
- M3: `validate_mnemonic(m)`; `receive_address_at(m, index?, confidential) -> {address,index}`.
- M4: `sync_wallet(m, esplora) -> {tip_height,tip_hash,balances,txs,next_receive_index}`;
  `wallet_balances(m)`; `tip_height(m)`; `asset_metadata(ids, registry_url)`;
  `prices(prices_url)`; `faucet_request(faucet_url,address,asset?)`;
  `tx_status(esplora,txid)`.
- M5: `validate_address(a)`; `wallet_transactions(m)`; `fee_exchange_rates(url)`;
  `build_send_tx(m,recipients,fee_rate?,fee_asset?) -> pset`; `pset_details(m,pset)`;
  `sign_pset(m,pset)`; `finalize_pset(m,pset)`; `broadcast_tx(esplora,pset_or_tx)`.
- M6: `build_rbf_bump_tx`, `build_rbf_replace_tx`, `build_cpfp_tx`, `cpfp_suggested_feerate`.
- M7: `build_issue_tx`, `build_reissue_tx`, `build_burn_tx`, `staker_public_key`,
  `build_stake_tx` (enforce ≥40,000 tSEQ, csv 43200, non-confidential SEQ).

## Roadmap
- **M3** Onboarding + secure custody — create/import survives restart, locked.
- **M4** Sync + multi-asset balance + receive + settings/faucet — real testnet funds.
- **M5** Send + any-asset fee + reference dual-field + history + sign — real spending.
- **M6** RBF/CPFP rescue (cross-asset, reference-valued).
- **M7** Assets (issue/reissue/burn) + staking.
- **M8** UI stubs (Lightning/T-DEX/Managed) + iOS bring-up + hardening.

## v1 defaults (open questions, changeable)
Single wallet (mirror web); device biometric/passcode lock (wallet-PIN later);
foreground + on-resume + pull-to-refresh sync (no push yet); keep testnet/faucet
cues; reference currency defaults to USD. Backend = http://159.195.15.140
(`/api`, `/testnet4/api`, `/feerates`, `/prices`, `/registry`, `/faucet`).
