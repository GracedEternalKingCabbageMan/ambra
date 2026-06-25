import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rust/api.dart' as core;
import '../data/api_client.dart';
import '../data/config.dart';
import '../data/format.dart';
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
  Map<String, BigInt> _feeRates = {};
  String _assetId = SeqAssets.policy;
  String? _feeAsset; // null = pay the fee in tSEQ (the builder's default)
  bool _feeManual = false; // true once the user explicitly picks a fee asset
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(); // eager: load at launch (also reloads on activation)
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

  Future<void> _load() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      Map<String, BigInt> rates = {};
      try {
        rates = await ApiClient.feeRates();
      } catch (_) {/* fee-rate list unavailable; the default tSEQ fee still works */}
      if (!mounted) return;
      setState(() {
        _error = null; // a successful load clears any earlier (transient) error
        _balances = s.balances;
        _feeRates = rates;
        // Default the send asset to one you hold (keep the current choice if it's
        // still funded). Never default to tSEQ when its balance is 0.
        final held = _heldIds();
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
    final t = SeqAssets.labelFor(hex).ticker;
    return _feeRates[t] ?? _feeRates[hex]; // already filtered to >0 in feeRates()
  }

  String get _feeLabel => _feeAsset == null ? 'tSEQ' : SeqAssets.labelFor(_feeAsset!).ticker;

  /// 1:1 reference-unit fallback rate (atoms-per-rfa × 1e8) for an asset the node
  /// doesn't price — so the fee still builds and the relay/producers decide.
  static final BigInt _refScale = BigInt.from(100000000);

  /// Every asset you hold is a valid fee option — no asset is privileged. The
  /// '' sentinel = the policy asset (tSEQ), one option among equals.
  List<String> _feeOptions() => _heldIds().map((id) => id == SeqAssets.policy ? '' : id).toList();

  /// The fee defaults to the asset being sent (asset-agnostic). null = pay in
  /// tSEQ, only when tSEQ is what you're sending.
  String? _defaultFeeFor(String assetId) => assetId == SeqAssets.policy ? null : assetId;

  /// Build rate for the chosen fee asset: the node's published rate, or a 1:1
  /// reference fallback when the node doesn't price it (the tx still builds).
  BigInt _feeRate(String assetId) => _rateFor(assetId) ?? _refScale;

  /// True when the chosen fee asset isn't priced by the node (estimated rate).
  bool get _feeUnpriced => _feeAsset != null && _rateFor(_feeAsset!) == null;

  Future<void> _pickAsset() async {
    final picked = await _assetSheet('Choose asset', _heldIds(), withBalances: true);
    if (picked != null) {
      setState(() {
        _assetId = picked;
        // Re-apply the "fee in the asset being sent" default for the new asset.
        _feeManual = false;
        _feeAsset = _defaultFeeFor(picked);
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

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

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
      // Priced → node rate; unpriced → 1:1 reference fallback so the tx builds.
      feeAsset = core.FeeAsset(assetId: _feeAsset!, rate: _feeRate(_feeAsset!));
    }

    // Optional fee rate (sat/vB). Empty leaves it to the network default.
    double? feeRateSatKvb;
    final frText = _feeRateCtl.text.trim();
    if (frText.isNotEmpty) {
      final fr = double.tryParse(frText);
      if (fr == null || fr <= 0) return _snack('Enter a valid fee rate, or leave it blank.');
      feeRateSatKvb = fr * 1000; // sat/vB → sat/kvB
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sent · ${txid.substring(0, 16)}…'),
        action: SnackBarAction(label: 'Copy txid', onPressed: () => Clipboard.setData(ClipboardData(text: txid))),
      ));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = SeqAssets.labelFor(_assetId);
    final bal = _selected;
    final held = _heldIds();
    final canPickFee = _feeOptions().length > 1; // more than one held asset to choose from
    final canSend = !_loading && _error == null && held.isNotEmpty;
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
            else if (held.isEmpty)
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
                trailing: bal == null ? null : 'balance ${formatAtoms(bal.atoms, label.precision)}',
                onTap: _pickAsset,
              ),
              const SizedBox(height: 18),
              AmbraField(
                label: 'Recipient address',
                controller: _addr,
                hint: 'tb1… or tsqb1…',
                mono: true,
                suffix: IconButton(
                  icon: const Icon(Icons.qr_code_scanner, color: AmbraColors.amber2),
                  tooltip: 'Scan QR',
                  onPressed: _scan,
                ),
              ),
              const SizedBox(height: 18),
              AmbraField(label: 'Amount (${label.ticker})', controller: _amount, hint: '0.0'),
              const SizedBox(height: 18),
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
              AmbraField(label: 'Fee rate ($_feeLabel/vB, optional)', controller: _feeRateCtl, hint: '2'),
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
  bool _busy = false;
  String? _error;

  Future<void> _confirm() async {
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
      final pset = await core.buildSendTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        recipients: [core.Recipient(address: widget.address, assetId: widget.assetId, satoshi: widget.atoms)],
        feeRateSatKvb: widget.feeRateSatKvb,
        feeAsset: widget.feeAsset,
      );
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
              _Row('Fee rate', '${(widget.feeRateSatKvb ?? 2000) ~/ 1000} ${widget.feeLabel}/vB'),
            ]),
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(label: 'Confirm & sign', busy: _busy, icon: Icons.fingerprint, onPressed: _busy ? null : _confirm),
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
