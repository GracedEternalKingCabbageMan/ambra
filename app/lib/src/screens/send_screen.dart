import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rust/api.dart' as core;
import '../data/api_client.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

class SendTab extends StatefulWidget {
  const SendTab({super.key});
  @override
  State<SendTab> createState() => _SendTabState();
}

class _SendTabState extends State<SendTab> {
  final _addr = TextEditingController();
  final _amount = TextEditingController();
  List<core.AssetBalance> _balances = [];
  Map<String, BigInt> _feeRates = {};
  String _assetId = SeqAssets.policy;
  String? _feeAsset; // null = native tSEQ
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _addr.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      Map<String, BigInt> rates = {};
      try {
        rates = await ApiClient.feeRates();
      } catch (_) {/* fee asset unavailable; native fee still works */}
      if (!mounted) return;
      setState(() {
        _balances = s.balances;
        _feeRates = rates;
        final hasPolicy = s.balances.any((b) => b.assetId == SeqAssets.policy);
        _assetId = hasPolicy
            ? SeqAssets.policy
            : (s.balances.isNotEmpty ? s.balances.first.assetId : SeqAssets.policy);
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
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

  /// Owned, fee-priced, and actually funded (a different asset can't pay the fee).
  List<String> _feeEligible() => _balances
      .map((b) => b.assetId)
      .where((id) =>
          id != SeqAssets.policy &&
          _rateFor(id) != null &&
          (BigInt.tryParse(_balanceOf(id)) ?? BigInt.zero) > BigInt.zero)
      .toList();

  String get _feeLabel => _feeAsset == null ? 'tSEQ' : SeqAssets.labelFor(_feeAsset!).ticker;

  Future<void> _pickAsset() async {
    final picked = await _assetSheet('Choose asset', _balances.map((b) => b.assetId).toList(), withBalances: true);
    if (picked != null) setState(() => _assetId = picked);
  }

  Future<void> _pickFee() async {
    // '' sentinel = native tSEQ.
    final ids = ['', ..._feeEligible()];
    final picked = await _assetSheet('Pay fee in', ids, nativeLabel: 'tSEQ (native)');
    if (picked != null) setState(() => _feeAsset = picked.isEmpty ? null : picked);
  }

  Future<String?> _assetSheet(String title, List<String> ids, {bool withBalances = false, String? nativeLabel}) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(title, style: AmbraText.title)),
          for (final id in ids)
            ListTile(
              title: Text(id.isEmpty ? (nativeLabel ?? 'tSEQ') : SeqAssets.labelFor(id).ticker, style: AmbraText.body),
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

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

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
      if (_assetId == SeqAssets.policy) {
        if (atoms == bal) {
          return _snack('Leave a little tSEQ for the network fee — send a bit less.');
        }
      } else {
        final tseq = BigInt.tryParse(_balanceOf(SeqAssets.policy)) ?? BigInt.zero;
        if (tseq <= BigInt.zero) {
          return _snack('You need some tSEQ for the network fee. Use the faucet, or pay the fee in ${label.ticker}.');
        }
      }
    } else {
      final rate = _rateFor(_feeAsset!);
      if (rate == null) return _snack('No published fee rate for $_feeLabel');
      final feeBal = BigInt.tryParse(_balanceOf(_feeAsset!)) ?? BigInt.zero;
      if (feeBal <= BigInt.zero) return _snack('You have no $_feeLabel to pay the fee with.');
      feeAsset = core.FeeAsset(assetId: _feeAsset!, rate: rate);
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
      ),
    );
    if (txid != null && mounted) {
      _addr.clear();
      _amount.clear();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sent — ${txid.substring(0, 16)}…'),
        action: SnackBarAction(label: 'Copy txid', onPressed: () => Clipboard.setData(ClipboardData(text: txid))),
      ));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = SeqAssets.labelFor(_assetId);
    final bal = _selected;
    final canFeeAsset = _feeEligible().isNotEmpty;
    return Column(
      children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
            const Text('Send', style: AmbraText.h1),
            const SizedBox(height: 20),
            if (_loading)
              const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
            else if (_error != null)
              AmbraCard(child: Text(_error!, style: const TextStyle(color: AmbraColors.red)))
            else ...[
              const SectionLabel('Asset'),
              const SizedBox(height: 8),
              _PickerField(
                label: label.ticker,
                trailing: bal == null ? null : 'balance ${formatAtoms(bal.atoms, label.precision)}',
                onTap: _balances.isEmpty ? null : _pickAsset,
              ),
              const SizedBox(height: 18),
              AmbraField(label: 'Recipient address', controller: _addr, hint: 'tb1… or tsqb1…', mono: true),
              const SizedBox(height: 18),
              AmbraField(label: 'Amount (${label.ticker})', controller: _amount, hint: '0.0'),
              const SizedBox(height: 18),
              const SectionLabel('Pay fee in'),
              const SizedBox(height: 8),
              _PickerField(
                label: _feeLabel,
                trailing: canFeeAsset ? 'any accepted asset' : 'native',
                onTap: canFeeAsset ? _pickFee : null,
              ),
              const SizedBox(height: 10),
              Text(
                _feeAsset == null
                    ? 'Fee paid natively in tSEQ.'
                    : 'Fee paid in $_feeLabel at the producer\'s published rate. '
                        'Confirmation depends on producers accepting it.',
                style: AmbraText.sub,
              ),
            ],
          ]),
        ),
        if (!_loading && _error == null)
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
  });
  final String address;
  final String assetId;
  final BigInt atoms;
  final String ticker;
  final String amountStr;
  final core.FeeAsset? feeAsset;
  final String feeLabel;

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
          _error = 'Authentication failed or cancelled — payment not sent.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final pset = await core.buildSendTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        recipients: [core.Recipient(address: widget.address, assetId: widget.assetId, satoshi: widget.atoms)],
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
