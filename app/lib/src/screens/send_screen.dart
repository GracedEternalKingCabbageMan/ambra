import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rust/api.dart' as core;
import '../data/api_client.dart';
import '../data/btc_state.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../data/openamp_service.dart';
import '../data/price_service.dart';
import '../data/wallet_cache.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'scan_screen.dart';

class SendTab extends StatefulWidget {
  const SendTab({super.key, this.isActive = false});
  final bool isActive;
  @override
  State<SendTab> createState() => _SendTabState();
}

class _SendTabState extends State<SendTab> {
  final _addr = TextEditingController();
  final _amount = TextEditingController();
  final _feeRateCtl = TextEditingController(); // sat/vB, optional; empty = network default
  List<core.AssetBalance> _balances = [];
  core.BtcBalance? _btc; // parent-chain (testnet4) balance, sendable like any asset
  Map<String, BigInt> _feeRates = {};
  String _assetId = SeqAssets.policy;
  String? _feeAsset; // null = pay the fee in tSEQ (the builder's default)
  bool _feeManual = false; // true once the user explicitly picks a fee asset
  bool _loading = true;
  String? _error;

  /// The synthetic asset id for parent-chain Bitcoin in the picker/state.
  static const _btcId = 'BTC';

  @override
  void initState() {
    super.initState();
    _btc = BtcState.instance.last; // show BTC at once if the Balance tab already scanned
    _loadCached(); // render the form from last-known balances at once
    _load(); // eager: load at launch (also reloads on activation)
  }

  /// Show the send form instantly using the last-known balances (shared with the
  /// Balance tab's cache), so a cold start never blocks on a spinner. The live
  /// sync below refreshes balances and fee rates in the background.
  Future<void> _loadCached() async {
    final b = await WalletCache.loadBalances();
    if (b == null || !mounted || _balances.isNotEmpty) return; // don't clobber a finished sync
    setState(() {
      // Restricted (OpenAMP) assets are sendable among equals; show last-known.
      _balances = [...b, ...OpenAmpService.instance.balances];
      final sendable = _sendableIds();
      if (!sendable.contains(_assetId)) {
        _assetId = sendable.isNotEmpty ? sendable.first : SeqAssets.policy;
      }
      if (!_feeManual) _feeAsset = _defaultFeeFor(_assetId);
      _loading = false;
    });
  }

  @override
  void didUpdateWidget(SendTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-sync when the tab is opened so newly-received assets are sendable
    // without restarting the app. Form fields are preserved across the reload.
    if (widget.isActive && !oldWidget.isActive) _load();
  }

  @override
  void dispose() {
    _addr.dispose();
    _amount.dispose();
    _feeRateCtl.dispose();
    super.dispose();
  }

  /// Asset ids the wallet actually holds (balance > 0). tSEQ is not privileged,
  /// so it only appears here when funded — just like every other asset.
  List<String> _heldIds() => _balances
      .where((b) => (BigInt.tryParse(b.atoms) ?? BigInt.zero) > BigInt.zero)
      .map((b) => b.assetId)
      .toList();

  bool get _isBtc => _assetId == _btcId;
  bool get _hasBtc => (BigInt.tryParse(_btc?.balanceSats ?? '0') ?? BigInt.zero) > BigInt.zero;

  /// Everything sendable, BTC included as a first-class asset (parent chain first
  /// when held, so a BTC-only wallet defaults to it).
  List<String> _sendableIds() => [if (_hasBtc) _btcId, ..._heldIds()];

  Future<void> _load() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      // Fee rates are independent of the chain sync; fetch + apply them first so
      // fee pricing stays correct even if the sync is slow or fails.
      try {
        final rates = await ApiClient.feeRates();
        if (mounted && rates.isNotEmpty) setState(() => _feeRates = rates);
      } catch (_) {/* fee-rate list unavailable; the default fee still works */}
      // Scan the parent chain concurrently; a BTC failure must not block sending
      // Sequentia assets, so it resolves to null on error.
      final btcF = () async {
        try {
          return await core.btcSync(mnemonic: m, t4Api: Backend.testnet4);
        } catch (_) {
          return null;
        }
      }();
      final ampF = OpenAmpService.instance.refresh(m); // restricted assets, fail-soft
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      final btc = await btcF;
      final amp = await ampF;
      WalletCache.saveBalances(s.balances); // keep the shared cache fresh
      if (btc != null) BtcState.instance.observe(btc: btc, seqNext: s.nextIndex);
      if (!mounted) return;
      setState(() {
        _error = null; // a successful load clears any earlier (transient) error
        _balances = [...s.balances, ...amp];
        if (btc != null) _btc = btc;
        // Default the send asset to one you hold (keep the current choice if it's
        // still funded). Never default to tSEQ when its balance is 0.
        final held = _sendableIds();
        if (!held.contains(_assetId)) {
          _assetId = held.isNotEmpty ? held.first : SeqAssets.policy;
        }
        // Default the fee to the asset being sent (asset-agnostic). Keep the
        // user's manual fee choice while they still hold it; otherwise re-apply
        // the default for the current send asset.
        if (_feeManual && _feeAsset != null && !_heldIds().contains(_feeAsset)) {
          _feeManual = false;
        }
        if (!_feeManual) _feeAsset = _defaultFeeFor(_assetId);
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          // Keep last-good data on a transient reload error; only surface it when
          // there's nothing to show. Send has no pull-to-refresh, so don't tell
          // the user to "pull down" — the error card carries a Retry button.
          if (_balances.isEmpty) _error = friendlyError(e, pullToRefresh: false);
          _loading = false;
        });
      }
    }
  }

  core.AssetBalance? get _selected {
    for (final b in _balances) {
      if (b.assetId == _assetId) return b;
    }
    return null;
  }

  /// The published fee rate (atoms per reference unit) for an asset, keyed in
  /// /feerates by ticker or hex (deployments vary). null = not fee-priced.
  BigInt? _rateFor(String hex) {
    // The policy asset (tSEQ) is keyed "bitcoin" in the feed (Elements naming). Resolve it from
    // that key like any other asset — so tSEQ is priced ONLY when this node's feed prices it. NO
    // privilege: a node whose fee reference is USD and ignores SEQ omits "bitcoin" -> tSEQ unpriced
    // -> gated out of the fee options, exactly like any unpriced asset (first-principle: SEQ equal
    // standing). We never fabricate a rate.
    if (hex == SeqAssets.policy) return _feeRates['bitcoin'];
    final t = SeqAssets.labelFor(hex).ticker;
    return _feeRates[t] ?? _feeRates[hex]; // already filtered to >0 in feeRates()
  }

  String get _feeLabel => _feeAsset == null ? 'tSEQ' : SeqAssets.labelFor(_feeAsset!).ticker;

  /// The policy asset (tSEQ) is the Elements tx format's NATIVE fee unit: a tSEQ fee is built
  /// natively by the PSET builder (no FeeAsset passed) at the reference scale. This is a STRUCTURAL
  /// fact of the tx format, not a privilege — whether tSEQ is OFFERED as a fee choice is still gated
  /// purely on the producer feed (see _rateFor / _feeOptions).
  static final BigInt _policyScale = BigInt.from(100000000);

  /// True when the send asset is a restricted (OpenAMP enclave) asset — moved via
  /// the enclave transfer flow, not an on-chain PSET, and addressed by account id.
  bool get _isRestricted => OpenAmpService.instance.isRestricted(_assetId);

  /// A held asset is a valid fee option iff some producer prices it for fees (it's in the /feerates
  /// feed) — no asset is privileged, tSEQ (the '' sentinel) is judged by the exact same feed as
  /// every issued asset. Restricted (enclave-held) assets can't pay an on-chain fee, so excluded.
  /// An unpriced held asset is NOT offered (a fabricated rate would build a fee no producer accepts).
  List<String> _feeOptions() => _heldIds()
      .where((id) => !OpenAmpService.instance.isRestricted(id) && _rateFor(id) != null)
      .map((id) => id == SeqAssets.policy ? '' : id)
      .toList();

  /// The fee defaults to the asset being sent WHEN a producer prices it; else tSEQ when the feed
  /// prices it; else the first priced held asset. No privileged tSEQ fallback — if the feed doesn't
  /// price SEQ, tSEQ isn't chosen. (null = pay natively in tSEQ.)
  String? _defaultFeeFor(String assetId) {
    if (assetId != SeqAssets.policy && _rateFor(assetId) != null) return assetId;
    if (_rateFor(SeqAssets.policy) != null) return null; // tSEQ, only because the feed prices it
    final priced = _feeOptions();
    if (priced.isEmpty) return null;                     // feed unavailable: fall to the tx-format's native tSEQ path
    return priced.first.isEmpty ? null : priced.first;
  }

  /// Build rate for a chosen NON-policy fee asset: the node's published rate. Fee options are gated
  /// to priced assets (see _feeOptions), so this is always present; a null here is a programming
  /// error (an unpriced asset must never reach the builder), surfaced as a hard error.
  BigInt _feeRate(String assetId) => _rateFor(assetId)!;

  /// True when the chosen fee asset isn't priced by the node. With strict gating this should never
  /// hold for an offered asset; kept as a last-line guard.
  bool get _feeUnpriced => _feeAsset != null && _rateFor(_feeAsset!) == null;

  Future<void> _pickAsset() async {
    final picked = await _assetSheet('Choose asset', _sendableIds(), withBalances: true);
    if (picked != null) {
      setState(() {
        _assetId = picked;
        // Re-apply the "fee in the asset being sent" default for the new asset.
        // (BTC pays its own fee in BTC, so the fee-asset picker doesn't apply.)
        _feeManual = false;
        _feeAsset = picked == _btcId ? null : _defaultFeeFor(picked);
        _feeRateCtl.clear(); // the rate unit differs (sat/vB for BTC, asset/vB otherwise)
      });
    }
  }

  Future<void> _pickFee() async {
    final picked = await _assetSheet('Pay fee in', _feeOptions());
    if (picked != null) {
      setState(() {
        _feeManual = true;
        _feeAsset = picked.isEmpty ? null : picked;
      });
    }
  }

  Future<String?> _assetSheet(String title, List<String> ids, {bool withBalances = false}) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(title, style: AmbraText.title)),
          for (final id in ids)
            ListTile(
              title: Text(id.isEmpty ? 'tSEQ' : SeqAssets.labelFor(id).ticker, style: AmbraText.body),
              trailing: withBalances
                  ? Text(formatAtoms(_balanceOf(id), SeqAssets.labelFor(id).precision), style: AmbraText.mono)
                  : null,
              onTap: () => Navigator.pop(context, id),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  String _balanceOf(String id) {
    if (id == _btcId) return _btc?.balanceSats ?? '0';
    for (final b in _balances) {
      if (b.assetId == id) return b.atoms;
    }
    return '0';
  }

  /// Warning copy when the chosen fee asset isn't priced by this node — the rate
  /// is estimated and producers may reject it (rescue via RBF).
  String _feeUnpricedMessage() =>
      '$_feeLabel isn\'t priced for fees by this node, so the fee rate is estimated. '
      'Producers may not accept it. If it stalls, speed it up or replace it (RBF) from History.';

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(ambraSnack(m));

  /// Scan a QR into the recipient field. Accepts a plain address or a BIP21-style
  /// URI (scheme:address?amount=...); the build step validates the address.
  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (raw == null || !mounted) return;
    var s = raw.trim();
    if (s.contains(':')) s = s.substring(s.indexOf(':') + 1); // drop any URI scheme
    String? amount;
    final q = s.indexOf('?');
    if (q >= 0) {
      amount = Uri.splitQueryString(s.substring(q + 1))['amount'];
      s = s.substring(0, q);
    }
    setState(() {
      _addr.text = s;
      if (amount != null && double.tryParse(amount) != null) _amount.text = amount;
    });
  }

  Future<void> _review() async {
    if (_isBtc) return _reviewBtc();
    if (_isRestricted) return _reviewOpenamp();
    final label = SeqAssets.labelFor(_assetId);
    final addr = _addr.text.trim();
    final atoms = parseAtoms(_amount.text, label.precision);
    if (addr.isEmpty) return _snack('Enter a recipient address');
    if (atoms == null || atoms <= BigInt.zero) return _snack('Enter a valid amount');
    if (atoms >= (BigInt.one << 64)) return _snack('Amount is too large.'); // u64 FFI guard
    final bal = BigInt.tryParse(_selected?.atoms ?? '0') ?? BigInt.zero;
    if (atoms > bal) return _snack('Amount exceeds your ${label.ticker} balance');

    // Fund checks (fees are multi-asset — another asset's balance can't cover a
    // fee), so the user isn't asked to authorize a doomed payment.
    core.FeeAsset? feeAsset;
    if (_feeAsset == null) {
      // Paying in the policy asset (tSEQ) — only happens when you're sending it;
      // leave a little behind for the fee.
      if (_assetId == SeqAssets.policy && atoms == bal) {
        return _snack('Leave a little tSEQ for the network fee; send a bit less.');
      }
    } else {
      final feeBal = BigInt.tryParse(_balanceOf(_feeAsset!)) ?? BigInt.zero;
      if (feeBal <= BigInt.zero) return _snack('You have no $_feeLabel to pay the fee with.');
      // The chosen fee asset is gated to producer-priced (see _feeOptions), so its rate is present.
      feeAsset = core.FeeAsset(assetId: _feeAsset!, rate: _feeRate(_feeAsset!));
    }

    // Optional fee rate in the chosen asset's own units per vByte (never sat/vB,
    // which is a Bitcoin unit). Convert it to the internal rate lwk needs:
    // r × 10^precision × R / 1e5, where R is the asset's published rate (tSEQ, the
    // native asset, uses the 1e8 reference scale). Empty = network default.
    double? feeRateSatKvb;
    final frText = _feeRateCtl.text.trim();
    if (frText.isNotEmpty) {
      final fr = double.tryParse(frText);
      if (fr == null || fr <= 0) return _snack('Enter a valid fee rate, or leave it blank.');
      final label = SeqAssets.labelFor(_feeAsset ?? SeqAssets.policy);
      // Policy asset (tSEQ) pays natively at the reference scale (structural); a non-policy fee asset
      // is gated to priced, so its published rate is present — no fabricated fallback.
      final rate = (_feeAsset == null) ? _policyScale : _rateFor(_feeAsset!)!;
      feeRateSatKvb = fr * math.pow(10, label.precision) * rate.toDouble() / 100000;
    }

    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _ReviewSheet(
        address: addr,
        assetId: _assetId,
        atoms: atoms,
        ticker: label.ticker,
        amountStr: formatAtoms(atoms.toString(), label.precision),
        feeAsset: feeAsset,
        feeLabel: _feeLabel,
        feeRateSatKvb: feeRateSatKvb,
      ),
    );
    if (txid != null && mounted) {
      _addr.clear();
      _amount.clear();
      ScaffoldMessenger.of(context).showSnackBar(ambraSnack(
        'Sent · ${txid.substring(0, 16)}…',
        action: SnackBarAction(
          label: 'Copy txid',
          textColor: AmbraColors.amber,
          onPressed: () => Clipboard.setData(ClipboardData(text: txid)),
        ),
      ));
      _load();
    }
  }

  /// Review + send a parent-chain Bitcoin (testnet4) payment. BTC pays its own fee
  /// in BTC (sat/vB), so there's no fee-asset market here — a different path from
  /// the Sequentia send above.
  Future<void> _reviewBtc() async {
    final addr = _addr.text.trim();
    final atoms = parseAtoms(_amount.text, 8); // BTC has 8 decimals
    if (addr.isEmpty) return _snack('Enter a recipient address');
    if (atoms == null || atoms <= BigInt.zero) return _snack('Enter a valid amount');
    if (atoms >= (BigInt.one << 64)) return _snack('Amount is too large.');
    final bal = BigInt.tryParse(_balanceOf(_btcId)) ?? BigInt.zero;
    if (atoms > bal) return _snack('Amount exceeds your BTC balance');

    double feeRate = 0; // 0 => the core uses the testnet4 default
    final frText = _feeRateCtl.text.trim();
    if (frText.isNotEmpty) {
      final fr = double.tryParse(frText);
      if (fr == null || fr <= 0) return _snack('Enter a valid fee rate (sat/vB), or leave it blank.');
      feeRate = fr;
    }

    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _BtcReviewSheet(
        address: addr,
        amountSats: atoms,
        amountStr: formatAtoms(atoms.toString(), 8),
        feeRate: feeRate,
      ),
    );
    if (txid != null && mounted) {
      _addr.clear();
      _amount.clear();
      ScaffoldMessenger.of(context).showSnackBar(ambraSnack(
        'Sent BTC · ${txid.substring(0, 16)}…',
        action: SnackBarAction(
          label: 'Copy txid',
          textColor: AmbraColors.amber,
          onPressed: () => Clipboard.setData(ClipboardData(text: txid)),
        ),
      ));
      _load();
    }
  }

  /// Review + send a restricted (OpenAMP) asset. The enclave holds the funds; the
  /// recipient is addressed by their OpenAMP account id (AID), not an address, and
  /// the fee is taken by conversion inside the enclave (no any-asset fee market).
  /// The wallet drafts the transfer, Schnorr-signs each sighash on-device, and
  /// completes it — the signing key never leaves the phone.
  Future<void> _reviewOpenamp() async {
    final label = SeqAssets.labelFor(_assetId);
    final recipient = _addr.text.trim();
    final atoms = parseAtoms(_amount.text, label.precision);
    if (recipient.isEmpty) return _snack('Enter a recipient account id (AID)');
    if (atoms == null || atoms <= BigInt.zero) return _snack('Enter a valid amount');
    if (atoms >= (BigInt.one << 64)) return _snack('Amount is too large.');
    final bal = BigInt.tryParse(_selected?.atoms ?? '0') ?? BigInt.zero;
    if (atoms > bal) return _snack('Amount exceeds your ${label.ticker} balance');

    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _OpenampReviewSheet(
        recipientAid: recipient,
        assetId: _assetId,
        atoms: atoms,
        ticker: label.ticker,
        amountStr: formatAtoms(atoms.toString(), label.precision),
      ),
    );
    if (txid != null && mounted) {
      _addr.clear();
      _amount.clear();
      ScaffoldMessenger.of(context).showSnackBar(ambraSnack(
        'Sent · ${txid.substring(0, txid.length < 16 ? txid.length : 16)}…',
        action: SnackBarAction(
          label: 'Copy txid',
          textColor: AmbraColors.amber,
          onPressed: () => Clipboard.setData(ClipboardData(text: txid)),
        ),
      ));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = SeqAssets.labelFor(_assetId);
    final held = _heldIds();
    final canPickFee = _feeOptions().length > 1; // more than one held asset to choose from
    final canSend = !_loading && _error == null && (held.isNotEmpty || _hasBtc);
    final balStr = formatAtoms(_balanceOf(_assetId), label.precision);
    return Column(
      children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
            const Text('Send', style: AmbraText.h1),
            const SizedBox(height: 20),
            if (_loading)
              const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
            else if (_error != null)
              AmbraCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(_error!, style: const TextStyle(color: AmbraColors.red)),
                  const SizedBox(height: 14),
                  SecondaryButton(label: 'Retry', icon: Icons.refresh, onPressed: _load),
                ]),
              )
            else if (held.isEmpty && !_hasBtc)
              const AmbraCard(
                  child: Text(
                      'No assets to send yet. Get free testnet coins from the faucet (More tab), '
                      'or receive funds to your address.',
                      style: AmbraText.muted))
            else ...[
              const SectionLabel('Asset'),
              const SizedBox(height: 8),
              _PickerField(
                label: label.ticker,
                trailing: 'balance $balStr',
                onTap: _pickAsset,
              ),
              const SizedBox(height: 18),
              AmbraField(
                label: _isRestricted ? 'Recipient account id (AID)' : 'Recipient address',
                controller: _addr,
                hint: _isRestricted ? 'their OpenAMP account id' : 'tb1… or tsqb1…',
                mono: true,
                suffix: _isRestricted
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.qr_code_scanner, color: AmbraColors.amber2),
                        tooltip: 'Scan QR',
                        onPressed: _scan,
                      ),
              ),
              const SizedBox(height: 18),
              AmbraField(label: 'Amount (${label.ticker})', controller: _amount, hint: '0.0'),
              const SizedBox(height: 18),
              if (_isRestricted) ...[
                // Restricted (OpenAMP) assets move inside the enclave; the fee is
                // taken by conversion there, so there's no any-asset fee market.
                const Text('Restricted asset: sent via the OpenAMP enclave to a recipient '
                    'account id. The fee is taken by conversion inside the enclave.',
                    style: AmbraText.sub),
              ] else if (_isBtc) ...[
                // Parent-chain Bitcoin pays its own fee in BTC (sat/vB is a Bitcoin
                // unit and only correct here); there's no any-asset fee market.
                const Text('Bitcoin (testnet4): the fee is paid in BTC at the rate below.', style: AmbraText.sub),
                const SizedBox(height: 16),
                AmbraField(label: 'Fee rate (sat/vB, optional)', controller: _feeRateCtl, hint: 'default 2'),
              ] else ...[
                const SectionLabel('Pay fee in'),
                const SizedBox(height: 8),
                _PickerField(
                  label: _feeLabel,
                  trailing: canPickFee ? 'any asset you hold' : null,
                  onTap: canPickFee ? _pickFee : null,
                ),
                const SizedBox(height: 10),
                if (_feeUnpriced)
                  WarnCallout(_feeUnpricedMessage())
                else
                  Text(
                    _feeAsset == null
                        ? 'Fee paid in tSEQ at the network rate.'
                        : 'Fee paid in $_feeLabel at the node\'s published rate. '
                            'Confirmation depends on producers accepting it.',
                    style: AmbraText.sub,
                  ),
                const SizedBox(height: 16),
                // The fee rate in the chosen asset's own units per vByte (e.g. OILX/vB, tSEQ/vB);
                // the actual fee is shown, estimated, on the review screen. Blank = network default.
                AmbraField(label: 'Fee rate ($_feeLabel/vB, optional)', controller: _feeRateCtl, hint: ''),
              ],
            ],
          ]),
        ),
        if (canSend)
          BottomActionBar(children: [
            PrimaryButton(label: 'Review & send', icon: Icons.north_east, onPressed: _review),
          ]),
      ],
    );
  }
}

class _PickerField extends StatelessWidget {
  const _PickerField({required this.label, this.trailing, this.onTap});
  final String label;
  final String? trailing;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AmbraRadii.input),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AmbraColors.panelDeep,
          border: Border.all(color: AmbraColors.line),
          borderRadius: BorderRadius.circular(AmbraRadii.input),
        ),
        child: Row(children: [
          Text(label, style: AmbraText.body),
          const Spacer(),
          if (trailing != null) Text(trailing!, style: AmbraText.sub),
          if (onTap != null) ...[const SizedBox(width: 8), const Icon(Icons.expand_more, color: AmbraColors.dim, size: 20)],
        ]),
      ),
    );
  }
}

class _ReviewSheet extends StatefulWidget {
  const _ReviewSheet({
    required this.address,
    required this.assetId,
    required this.atoms,
    required this.ticker,
    required this.amountStr,
    required this.feeAsset,
    required this.feeLabel,
    required this.feeRateSatKvb,
  });
  final String address;
  final String assetId;
  final BigInt atoms;
  final String ticker;
  final String amountStr;
  final core.FeeAsset? feeAsset;
  final String feeLabel;
  final double? feeRateSatKvb;

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  bool _busy = false; // signing + broadcasting
  bool _loading = true; // building the tx to estimate the fee
  String? _error;
  String? _pset; // built up front so the fee estimate is the exact tx we send
  core.PsetFee? _feeEst;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  /// Build the actual transaction now so the review can show the real fee (in
  /// the chosen asset), then reuse that exact PSET on confirm.
  Future<void> _prepare() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final pset = await core.buildSendTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        recipients: [core.Recipient(address: widget.address, assetId: widget.assetId, satoshi: widget.atoms)],
        feeRateSatKvb: widget.feeRateSatKvb,
        feeAsset: widget.feeAsset,
      );
      core.PsetFee? fee;
      try {
        fee = await core.psetFee(pset: pset);
      } catch (_) {/* the estimate is best-effort; the send still works */}
      if (mounted) {
        setState(() {
          _pset = pset;
          _feeEst = fee;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _pretty(e);
          _loading = false;
        });
      }
    }
  }

  /// The estimated fee in the asset it's paid in, plus the reference equivalent.
  String _feeEstStr() {
    final f = _feeEst!;
    final label = SeqAssets.labelFor(f.assetId);
    final amt = formatAtoms(f.atoms, label.precision);
    final ref = PriceService.instance.refValue(label.ticker, f.atoms, label.precision);
    final refStr = ref != null ? '  (≈ ${PriceService.instance.fmtRef(ref)} ${PriceService.instance.ref})' : '';
    return '$amt ${label.ticker}$refStr';
  }

  Future<void> _confirm() async {
    final pset = _pset;
    if (pset == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await WalletRepository.instance.requirePaymentAuth();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication failed or cancelled; payment not sent.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final signed = await core.signPset(mnemonic: m, pset: pset);
      final txid = await core.finalizeAndBroadcast(mnemonic: m, esploraUrl: Backend.esplora, pset: signed);
      if (mounted) Navigator.pop(context, txid);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _pretty(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Confirm payment', style: AmbraText.h1),
          const SizedBox(height: 18),
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              _Row('Amount', '${widget.amountStr} ${widget.ticker}'),
              _Row('To', widget.address, mono: true),
              _Row('Network', 'sequentia-testnet'),
              _Row('Fee paid in', widget.feeLabel),
              _Row('Network fee (est.)', _loading ? 'estimating…' : (_feeEst != null ? _feeEstStr() : 'unavailable')),
            ]),
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(
              label: 'Confirm & sign',
              busy: _busy,
              icon: Icons.fingerprint,
              onPressed: (_busy || _loading || _pset == null) ? null : _confirm),
          const SizedBox(height: 6),
          GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        ]),
      ),
    );
  }
}

/// Review + broadcast a parent-chain Bitcoin (testnet4) payment. Builds + signs
/// up front (via [core.btcPrepare]) so the review shows the real fee, then
/// broadcasts that exact transaction on confirm.
class _BtcReviewSheet extends StatefulWidget {
  const _BtcReviewSheet({
    required this.address,
    required this.amountSats,
    required this.amountStr,
    required this.feeRate,
  });
  final String address;
  final BigInt amountSats;
  final String amountStr;
  final double feeRate;

  @override
  State<_BtcReviewSheet> createState() => _BtcReviewSheetState();
}

class _BtcReviewSheetState extends State<_BtcReviewSheet> {
  bool _busy = false; // broadcasting
  bool _loading = true; // building + signing to estimate the fee
  String? _error;
  core.BtcTx? _tx;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final tx = await core.btcPrepare(
        mnemonic: m,
        t4Api: Backend.testnet4,
        address: widget.address,
        amountSats: widget.amountSats,
        feeRate: widget.feeRate,
      );
      if (mounted) {
        setState(() {
          _tx = tx;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _pretty(e);
          _loading = false;
        });
      }
    }
  }

  String _feeStr() {
    final tx = _tx!;
    final amt = formatAtoms(tx.feeSats, 8);
    final ref = PriceService.instance.refValue('BTC', tx.feeSats, 8);
    final refStr = ref != null ? '  (≈ ${PriceService.instance.fmtRef(ref)} ${PriceService.instance.ref})' : '';
    return '$amt BTC$refStr · ${tx.inputs} input${tx.inputs == 1 ? '' : 's'}, ${tx.vsize} vB';
  }

  String _totalStr() {
    final fee = BigInt.tryParse(_tx!.feeSats) ?? BigInt.zero;
    return '${formatAtoms((widget.amountSats + fee).toString(), 8)} BTC';
  }

  Future<void> _confirm() async {
    final tx = _tx;
    if (tx == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await WalletRepository.instance.requirePaymentAuth();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication failed or cancelled; payment not sent.';
        });
        return;
      }
      final txid = await core.btcBroadcast(t4Api: Backend.testnet4, txHex: tx.hex);
      if (mounted) Navigator.pop(context, txid);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _pretty(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Confirm Bitcoin payment', style: AmbraText.h1),
          const SizedBox(height: 18),
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              _Row('Amount', '${widget.amountStr} BTC'),
              _Row('To', widget.address, mono: true),
              _Row('Network', 'Bitcoin testnet4'),
              _Row('Network fee', _loading ? 'estimating…' : (_tx != null ? _feeStr() : 'unavailable')),
              if (!_loading && _tx != null) _Row('Total', _totalStr()),
            ]),
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(
              label: 'Confirm & send',
              busy: _busy,
              icon: Icons.fingerprint,
              onPressed: (_busy || _loading || _tx == null) ? null : _confirm),
          const SizedBox(height: 6),
          GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        ]),
      ),
    );
  }
}

/// Review + send a restricted (OpenAMP) asset. Two-phase, like [_ReviewSheet]:
/// `_prepare` drafts the transfer and VERIFIES it on-device (recompute every
/// enclave sighash, refuse on any mismatch, decode the real effects) before the
/// user sees anything; `_confirm` signs the locally recomputed digests and
/// completes it. The signing key never leaves the phone, and the wallet never
/// blind-signs the server's digest (spec 0.4(3)).
class _OpenampReviewSheet extends StatefulWidget {
  const _OpenampReviewSheet({
    required this.recipientAid,
    required this.assetId,
    required this.atoms,
    required this.ticker,
    required this.amountStr,
  });
  final String recipientAid;
  final String assetId;
  final BigInt atoms;
  final String ticker;
  final String amountStr;

  @override
  State<_OpenampReviewSheet> createState() => _OpenampReviewSheetState();
}

class _OpenampReviewSheetState extends State<_OpenampReviewSheet> {
  bool _busy = false; // signing + completing
  bool _loading = true; // drafting + verifying + decoding
  String? _error;
  OpenampPrepared? _prepared;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final prepared = await OpenAmpService.instance.prepareTransfer(
        mnemonic: m,
        assetId: widget.assetId,
        recipientAid: widget.recipientAid,
        atoms: widget.atoms,
      );
      if (mounted) {
        setState(() {
          _prepared = prepared;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _pretty(e);
          _loading = false;
        });
      }
    }
  }

  String _tickerOf(String assetHex) => SeqAssets.labelFor(assetHex).ticker;
  int _precisionOf(String assetHex) => SeqAssets.labelFor(assetHex).precision;

  /// The decoded, locally verified effects as review rows.
  List<Widget> _effectRows() {
    final p = _prepared;
    if (p == null) return const [];
    final e = p.effects;
    final rows = <Widget>[];
    final spent = e.myInputsSpent.length;
    rows.add(_Row('Spending', '$spent of your ${widget.ticker} enclave ${spent == 1 ? 'output' : 'outputs'}'));
    if (p.convertAtoms != null && p.convertAtoms! > BigInt.zero) {
      rows.add(_Row('Fee (converted)',
          '${formatAtoms(p.convertAtoms!.toString(), _precisionOf(widget.assetId))} ${widget.ticker} (in-asset)'));
    }
    for (final o in e.outputs) {
      if (o.isFee) continue; // the fee is summarised above
      final amt = (o.value != null && o.asset != null)
          ? '${formatAtoms(o.value!.toString(), _precisionOf(o.asset!))} ${_tickerOf(o.asset!)}'
          : 'confidential';
      final dest = o.mine ? 'to you (change/receipt)' : 'to recipient';
      rows.add(_Row('Output', '$amt · $dest'));
    }
    return rows;
  }

  Future<void> _confirm() async {
    final prepared = _prepared;
    if (prepared == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await WalletRepository.instance.requirePaymentAuth();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication failed or cancelled; payment not sent.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final txid = await OpenAmpService.instance.completePrepared(prepared, m);
      if (mounted) Navigator.pop(context, txid);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _pretty(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _prepared;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Confirm transfer', style: AmbraText.h1),
          const SizedBox(height: 18),
          if (_loading)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
          else if (p != null) ...[
            AmbraCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(children: [
                _Row('Amount', '${widget.amountStr} ${widget.ticker}'),
                _Row('To (AID)', widget.recipientAid, mono: true),
                _Row('Via', 'OpenAMP enclave (verified on-device)'),
                ..._effectRows(),
              ]),
            ),
            if (p.effects.anyConfidential)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                    'This transfer contains confidential outputs the wallet cannot fully decode. '
                    'Review carefully before signing.',
                    style: TextStyle(color: AmbraColors.red)),
              ),
          ],
          const SizedBox(height: 14),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(
              label: 'Confirm & sign',
              busy: _busy,
              icon: Icons.fingerprint,
              onPressed: (_busy || _loading || _prepared == null) ? null : _confirm),
          const SizedBox(height: 6),
          GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.k, this.v, {this.mono = false});
  final String k;
  final String v;
  final bool mono;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 90, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: mono ? AmbraText.mono : AmbraText.body)),
        ]),
      );
}

String _pretty(Object e) {
  final s = e.toString().replaceFirst('Exception: ', '');
  if (s.toLowerCase().contains('insufficient') || s.contains('InsufficientFunds')) {
    return 'Not enough funds to cover the amount plus the network fee. Try a smaller amount.';
  }
  return s.length > 200 ? '${s.substring(0, 200)}…' : s;
}
