import 'package:flutter/material.dart';

import '../rust/api.dart' as core;
import '../data/api_client.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../data/tx_flow.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Precision Ambra issues/displays unnamed assets at (matches the unknown-asset
/// display fallback, so an issued "1000" shows back as "1000").
const int _issuePrecision = 8;

class AssetsScreen extends StatefulWidget {
  const AssetsScreen({super.key});
  @override
  State<AssetsScreen> createState() => _AssetsScreenState();
}

class _AssetsScreenState extends State<AssetsScreen> {
  final _issueAmount = TextEditingController();
  final _issueTokens = TextEditingController(text: '1');
  final _otherAsset = TextEditingController();
  final _otherAmount = TextEditingController();
  List<core.AssetBalance> _balances = [];
  Map<String, BigInt> _feeRates = {}; // /feerates, keyed by ticker or hex
  bool _busy = false;

  @override
  void dispose() {
    _issueAmount.dispose();
    _issueTokens.dispose();
    _otherAsset.dispose();
    _otherAmount.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    try {
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      if (mounted) setState(() => _balances = s.balances);
    } catch (_) {}
    try {
      final rates = await ApiClient.feeRates();
      if (mounted && rates.isNotEmpty) setState(() => _feeRates = rates);
    } catch (_) {}
  }

  BigInt _bal(String id) {
    for (final b in _balances) {
      if (b.assetId == id) return BigInt.tryParse(b.atoms) ?? BigInt.zero;
    }
    return BigInt.zero;
  }

  bool _tooBig(BigInt v) => v >= (BigInt.one << 64);

  /// 1:1 reference-unit fallback for an asset the node doesn't price (the fee
  /// still builds and the relay/producers decide). Mirrors the send screen.
  static final BigInt _refScale = BigInt.from(100000000);

  /// The node's fee rate for an asset, looked up by ticker or hex (deployments
  /// vary). null = the node doesn't price this asset for fees.
  BigInt? _rateFor(String hex) {
    final t = SeqAssets.labelFor(hex).ticker;
    return _feeRates[t] ?? _feeRates[hex];
  }

  /// Asset ids you actually hold (positive balance). Any of these can fund the
  /// network fee — no asset is privileged, including tSEQ.
  List<String> _heldIds() =>
      _balances.where((b) => (BigInt.tryParse(b.atoms) ?? BigInt.zero) > BigInt.zero).map((b) => b.assetId).toList();

  /// Pick the asset to pay the fee in. Prefer [preferHex] when it's held;
  /// otherwise the largest holding (tSEQ gets no special treatment). Returns
  /// null only when the wallet holds nothing.
  String? _pickFeeAsset(String? preferHex) {
    final held = _heldIds();
    if (held.isEmpty) return null;
    if (preferHex != null && held.contains(preferHex)) return preferHex;
    held.sort((a, b) => _bal(b).compareTo(_bal(a)));
    return held.first;
  }

  /// The fee_asset argument for the builders: null when paying in tSEQ (the
  /// policy asset, the builder's native default), else an explicit FeeAsset.
  core.FeeAsset? _feeAssetParam(String hex) =>
      hex == SeqAssets.policy ? null : core.FeeAsset(assetId: hex, rate: _rateFor(hex) ?? _refScale);

  String _feeTicker(String hex) => SeqAssets.labelFor(hex).ticker;
  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<bool> _confirm({required String title, required String body, bool danger = false}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: Text(title, style: AmbraText.title),
        content: Text(body, style: AmbraText.muted),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(danger ? 'Burn' : 'Confirm',
                style: TextStyle(color: danger ? AmbraColors.red : AmbraColors.amber2, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _run(String action, Future<String> Function(String m) build) async {
    setState(() => _busy = true);
    try {
      final txid = await authorizeBuildBroadcast(build);
      if (mounted) _snack('$action · ${txid.substring(0, 16)}…');
      _load();
    } catch (e) {
      if (mounted) _snack('$action failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _issue() async {
    final amt = parseAtoms(_issueAmount.text, _issuePrecision);
    final tok = BigInt.tryParse(_issueTokens.text.trim()) ?? BigInt.zero;
    if (amt == null || amt <= BigInt.zero) return _snack('Enter an amount to issue');
    if (tok < BigInt.zero) return _snack('Reissuance token count cannot be negative');
    if (_tooBig(amt) || _tooBig(tok)) return _snack('Amount is too large');
    final feeHex = _pickFeeAsset(null);
    if (feeHex == null) return _snack('You need some funds to pay the network fee. Use the faucet (More tab).');
    final ok = await _confirm(
      title: 'Issue new asset',
      body: 'Mint ${formatAtoms(amt.toString(), _issuePrecision)} units of a new asset'
          '${tok > BigInt.zero ? ' + $tok reissuance token(s)' : ''} to this wallet.\n\n'
          'The network fee is paid in ${_feeTicker(feeHex)}. The asset has no name/ticker metadata yet.',
    );
    if (!ok || !mounted) return;
    _run('Issued asset',
        (m) => core.buildIssueTx(mnemonic: m, esploraUrl: Backend.esplora, assetSats: amt, tokenSats: tok, feeAsset: _feeAssetParam(feeHex)));
  }

  Future<void> _reissueOrBurn(bool burn) async {
    final id = _otherAsset.text.trim().toLowerCase();
    final label = SeqAssets.labelFor(id);
    final amt = parseAtoms(_otherAmount.text, label.precision);
    if (id.length != 64 || amt == null || amt <= BigInt.zero) return _snack('Enter a 64-hex asset id + amount');
    if (_tooBig(amt)) return _snack('Amount is too large');
    // Reissue defaults the fee to the asset being reissued; burn defaults to the
    // largest holding so destroying your whole balance still leaves a fee source.
    final feeHex = _pickFeeAsset(burn ? null : id);
    if (feeHex == null) return _snack('You need some funds to pay the network fee. Use the faucet (More tab).');
    final known = label.subtitle != null; // a built-in asset => precision is known
    // Show the raw atom count only for an unknown-precision asset, where the body copy below relies
    // on it ("the atom amount above ..."); for a known asset it is just jargon, so drop the suffix.
    final line = known
        ? '${formatAtoms(amt.toString(), label.precision)} ${label.ticker}'
        : '${formatAtoms(amt.toString(), label.precision)} ${label.ticker}  (${amt.toString()} atoms)';
    final feeLine = '\n\nThe network fee is paid in ${_feeTicker(feeHex)}.';
    final ok = await _confirm(
      title: burn ? 'Burn asset' : 'Reissue asset',
      danger: burn,
      body: burn
          ? 'Permanently destroy $line.$feeLine\n\nThis CANNOT be undone.'
              '${known ? '' : "\n\nThis asset's precision is unknown; the atom amount above is exactly what will be destroyed."}'
          : 'Reissue $line. This needs the asset\'s reissuance token in this wallet.$feeLine'
              '${known ? '' : "\n\nPrecision unknown; the atom amount above is what will be minted."}',
    );
    if (!ok || !mounted) return;
    if (burn) {
      _run('Burned',
          (m) => core.buildBurnTx(mnemonic: m, esploraUrl: Backend.esplora, assetId: id, satoshi: amt, feeAsset: _feeAssetParam(feeHex)));
    } else {
      _run('Reissued',
          (m) => core.buildReissueTx(mnemonic: m, esploraUrl: Backend.esplora, assetId: id, satoshi: amt, feeAsset: _feeAssetParam(feeHex)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Assets', style: AmbraText.title),
        iconTheme: const IconThemeData(color: AmbraColors.dim),
      ),
      body: AmbraBackground(
        child: AbsorbPointer(
          absorbing: _busy,
          child: ListView(padding: const EdgeInsets.all(20), children: [
            AmbraCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Issue a new asset'),
                const SizedBox(height: 12),
                AmbraField(label: 'Amount to issue (units)', controller: _issueAmount, hint: '1000'),
                const SizedBox(height: 14),
                AmbraField(label: 'Reissuance tokens', controller: _issueTokens),
                const SizedBox(height: 16),
                SecondaryButton(label: 'Issue', icon: Icons.add, onPressed: _busy ? null : _issue),
              ]),
            ),
            const SizedBox(height: 14),
            AmbraCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Reissue or burn an existing asset'),
                const SizedBox(height: 12),
                AmbraField(label: 'Asset id (64-hex)', controller: _otherAsset, mono: true),
                const SizedBox(height: 14),
                AmbraField(label: 'Amount', controller: _otherAmount),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(child: SecondaryButton(label: 'Reissue', onPressed: _busy ? null : () => _reissueOrBurn(false))),
                  const SizedBox(width: 12),
                  Expanded(child: DangerButton(label: 'Burn', onPressed: _busy ? null : () => _reissueOrBurn(true))),
                ]),
              ]),
            ),
            const SizedBox(height: 14),
            const Text(
              "Reissue needs the asset's reissuance token in this wallet. Burn permanently destroys "
              'the amount and asks you to confirm first.',
              style: AmbraText.sub,
            ),
            if (_busy)
              const Padding(padding: EdgeInsets.only(top: 24), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber))),
          ]),
        ),
      ),
    );
  }
}
