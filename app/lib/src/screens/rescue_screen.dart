import 'package:flutter/material.dart';

import '../rust/api.dart' as core;
import '../data/api_client.dart';
import '../data/config.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

enum RescueMode { bump, cpfp }

/// Action chooser for an unconfirmed tx → runs the chosen rescue. Returns a
/// txid if one was broadcast (caller refreshes history).
Future<String?> showRescueActions(BuildContext context, core.TxRow tx) async {
  final outgoing = tx.kind == 'outgoing' ||
      tx.deltas.any((d) => (BigInt.tryParse(d.atoms) ?? BigInt.zero) < BigInt.zero);
  final action = await showModalBottomSheet<RescueMode>(
    context: context,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(16), child: Text('Rescue unconfirmed payment', style: AmbraText.title)),
        if (outgoing)
          ListTile(
            leading: const Icon(Icons.trending_up, color: AmbraColors.amber2),
            title: const Text('Bump fee', style: AmbraText.body),
            subtitle: const Text('Re-send the same payment at a higher fee (RBF)', style: AmbraText.sub),
            onTap: () => Navigator.pop(context, RescueMode.bump),
          ),
        ListTile(
          leading: const Icon(Icons.bolt, color: AmbraColors.amber2),
          title: const Text('Speed up', style: AmbraText.body),
          subtitle: const Text('Pay a child fee in any asset to pull it in (CPFP)', style: AmbraText.sub),
          onTap: () => Navigator.pop(context, RescueMode.cpfp),
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (action == null || !context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) => _RescueFeeSheet(tx: tx, mode: action),
  );
}

class _RescueFeeSheet extends StatefulWidget {
  const _RescueFeeSheet({required this.tx, required this.mode});
  final core.TxRow tx;
  final RescueMode mode;
  @override
  State<_RescueFeeSheet> createState() => _RescueFeeSheetState();
}

class _RescueFeeSheetState extends State<_RescueFeeSheet> {
  final _rate = TextEditingController(text: '1000');
  List<core.AssetBalance> _balances = [];
  Map<String, BigInt> _feeRates = {};
  String? _feeAsset; // null = native tSEQ
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _isBump => widget.mode == RescueMode.bump;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _rate.dispose();
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
      } catch (_) {}
      double? suggested;
      if (!_isBump) {
        try {
          suggested = await core.cpfpSuggestedFeerate(
              mnemonic: m, esploraUrl: Backend.esplora, parentTxid: widget.tx.txid, targetFeerate: 1000.0);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _balances = s.balances;
        _feeRates = rates;
        if (suggested != null && suggested > 0) _rate.text = suggested.round().toString();
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

  BigInt? _rateFor(String hex) {
    final t = SeqAssets.labelFor(hex).ticker;
    return _feeRates[t] ?? _feeRates[hex];
  }

  String _balanceOf(String id) {
    for (final b in _balances) {
      if (b.assetId == id) return b.atoms;
    }
    return '0';
  }

  List<String> _feeEligible() => _balances
      .map((b) => b.assetId)
      .where((id) =>
          id != SeqAssets.policy && _rateFor(id) != null && (BigInt.tryParse(_balanceOf(id)) ?? BigInt.zero) > BigInt.zero)
      .toList();

  String get _feeLabel => _feeAsset == null ? 'tSEQ' : SeqAssets.labelFor(_feeAsset!).ticker;

  Future<void> _pickFee() async {
    final ids = ['', ..._feeEligible()];
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('Pay fee in', style: AmbraText.title)),
          for (final id in ids)
            ListTile(
              title: Text(id.isEmpty ? 'tSEQ (native)' : SeqAssets.labelFor(id).ticker, style: AmbraText.body),
              onTap: () => Navigator.pop(context, id),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (picked != null) setState(() => _feeAsset = picked.isEmpty ? null : picked);
  }

  Future<void> _confirm() async {
    final rate = double.tryParse(_rate.text.trim());
    if (rate == null || rate <= 0) {
      setState(() => _error = 'Enter a fee rate (sat/kvB)');
      return;
    }
    core.FeeAsset? feeAsset;
    if (_feeAsset != null) {
      final r = _rateFor(_feeAsset!);
      if (r == null) {
        setState(() => _error = 'No published fee rate for $_feeLabel');
        return;
      }
      feeAsset = core.FeeAsset(assetId: _feeAsset!, rate: r);
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await WalletRepository.instance.requirePaymentAuth();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication failed or cancelled.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final String pset;
      if (_isBump) {
        pset = await core.buildRbfBumpTx(
            mnemonic: m, esploraUrl: Backend.esplora, txid: widget.tx.txid, feeRateSatKvb: rate, feeAsset: feeAsset);
      } else {
        pset = await core.buildCpfpTx(
            mnemonic: m, esploraUrl: Backend.esplora, parentTxid: widget.tx.txid, feeRateSatKvb: rate, feeAsset: feeAsset);
      }
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
    final canFeeAsset = _feeEligible().isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: _loading
            ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(_isBump ? 'Bump fee' : 'Speed up (CPFP)', style: AmbraText.h1),
                const SizedBox(height: 6),
                Text(
                  _isBump
                      ? 'Re-broadcasts the same payment with a higher fee. Must exceed the original (in reference value).'
                      : 'Spends the stuck output with a high-fee child to pull both in. Can\'t fix a wrong fee asset — use Replace.',
                  style: AmbraText.sub,
                ),
                const SizedBox(height: 18),
                const SectionLabel('Pay fee in'),
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(AmbraRadii.input),
                  onTap: canFeeAsset ? _pickFee : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: AmbraColors.panelDeep,
                      border: Border.all(color: AmbraColors.line),
                      borderRadius: BorderRadius.circular(AmbraRadii.input),
                    ),
                    child: Row(children: [
                      Text(_feeLabel, style: AmbraText.body),
                      const Spacer(),
                      if (canFeeAsset) const Icon(Icons.expand_more, color: AmbraColors.dim, size: 20),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                AmbraField(label: 'Fee rate (sat/kvB)', controller: _rate),
                const SizedBox(height: 16),
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

String _pretty(Object e) {
  final s = e.toString().replaceFirst('Exception: ', '');
  if (s.contains('bad-txns-spends-conflicting') || s.toLowerCase().contains('insufficient')) {
    return 'Rescue failed — try a higher fee rate, or pay the fee in a more widely-accepted asset.';
  }
  return s.length > 200 ? '${s.substring(0, 200)}…' : s;
}
