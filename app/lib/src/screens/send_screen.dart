import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rust/api.dart' as core;
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
  String _assetId = SeqAssets.policy;
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
      if (!mounted) return;
      setState(() {
        _balances = s.balances;
        final hasPolicy = s.balances.any((b) => b.assetId == SeqAssets.policy);
        _assetId = hasPolicy
            ? SeqAssets.policy
            : (s.balances.isNotEmpty ? s.balances.first.assetId : SeqAssets.policy);
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
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

  Future<void> _pickAsset() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('Choose asset', style: AmbraText.title)),
          for (final b in _balances)
            ListTile(
              title: Text(SeqAssets.labelFor(b.assetId).ticker, style: AmbraText.body),
              trailing: Text(formatAtoms(b.atoms, SeqAssets.labelFor(b.assetId).precision), style: AmbraText.mono),
              onTap: () => Navigator.pop(context, b.assetId),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (picked != null) setState(() => _assetId = picked);
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _review() async {
    final label = SeqAssets.labelFor(_assetId);
    final addr = _addr.text.trim();
    final atoms = parseAtoms(_amount.text, label.precision);
    if (addr.isEmpty) return _snack('Enter a recipient address');
    if (atoms == null || atoms <= BigInt.zero) return _snack('Enter a valid amount');
    final bal = BigInt.tryParse(_selected?.atoms ?? '0') ?? BigInt.zero;
    if (atoms > bal) return _snack('Amount exceeds your ${label.ticker} balance');

    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _ReviewSheet(
        address: addr,
        assetId: _assetId,
        atoms: atoms,
        ticker: label.ticker,
        amountStr: formatAtoms(atoms.toString(), label.precision),
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
    return Column(
      children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
            const Text('Send', style: AmbraText.h1),
            const SizedBox(height: 20),
            if (_loading)
              const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
            else if (_error != null)
              AmbraCard(child: Text('Could not load wallet: $_error', style: const TextStyle(color: AmbraColors.red)))
            else ...[
              const SectionLabel('Asset'),
              const SizedBox(height: 8),
              InkWell(
                borderRadius: BorderRadius.circular(AmbraRadii.input),
                onTap: _balances.isEmpty ? null : _pickAsset,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(
                    color: AmbraColors.panelDeep,
                    border: Border.all(color: AmbraColors.line),
                    borderRadius: BorderRadius.circular(AmbraRadii.input),
                  ),
                  child: Row(children: [
                    Text(label.ticker, style: AmbraText.body),
                    const Spacer(),
                    if (bal != null)
                      Text('balance ${formatAtoms(bal.atoms, label.precision)}', style: AmbraText.sub),
                    const SizedBox(width: 8),
                    const Icon(Icons.expand_more, color: AmbraColors.dim, size: 20),
                  ]),
                ),
              ),
              const SizedBox(height: 18),
              AmbraField(label: 'Recipient address', controller: _addr, hint: 'tb1… or tsqb1…', mono: true),
              const SizedBox(height: 18),
              AmbraField(label: 'Amount (${label.ticker})', controller: _amount, hint: '0.0'),
              const SizedBox(height: 12),
              Text('Fee is paid in the network default for now; any-asset fees + a reference value come next.',
                  style: AmbraText.sub),
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

class _ReviewSheet extends StatefulWidget {
  const _ReviewSheet({
    required this.address,
    required this.assetId,
    required this.atoms,
    required this.ticker,
    required this.amountStr,
  });
  final String address;
  final String assetId;
  final BigInt atoms;
  final String ticker;
  final String amountStr;

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
      final ok = await WalletRepository.instance.authenticate(reason: 'Authorize this payment');
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication cancelled';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final pset = await core.buildSendTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        recipients: [core.Recipient(address: widget.address, assetId: widget.assetId, satoshi: widget.atoms)],
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
              const _Row('Fee', 'network default'),
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
          SizedBox(width: 80, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: mono ? AmbraText.mono : AmbraText.body)),
        ]),
      );
}

String _pretty(Object e) {
  final s = e.toString().replaceFirst('Exception: ', '');
  return s.length > 200 ? '${s.substring(0, 200)}…' : s;
}
