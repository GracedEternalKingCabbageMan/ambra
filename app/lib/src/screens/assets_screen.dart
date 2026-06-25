import 'package:flutter/material.dart';

import '../rust/api.dart' as core;
import '../data/config.dart';
import '../data/format.dart';
import '../data/tx_flow.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

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
  bool _busy = false;

  @override
  void dispose() {
    _issueAmount.dispose();
    _issueTokens.dispose();
    _otherAsset.dispose();
    _otherAmount.dispose();
    super.dispose();
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _run(String action, Future<String> Function(String m) build) async {
    setState(() => _busy = true);
    try {
      final txid = await authorizeBuildBroadcast(build);
      if (mounted) _snack('$action — ${txid.substring(0, 16)}…');
    } catch (e) {
      if (mounted) _snack('$action failed: ${_short(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _issue() {
    final amt = BigInt.tryParse(_issueAmount.text.trim());
    final tok = BigInt.tryParse(_issueTokens.text.trim()) ?? BigInt.zero;
    if (amt == null || amt <= BigInt.zero) return _snack('Enter an amount to issue');
    _run('Issued asset',
        (m) => core.buildIssueTx(mnemonic: m, esploraUrl: Backend.esplora, assetSats: amt, tokenSats: tok));
  }

  void _reissueOrBurn(bool burn) {
    final id = _otherAsset.text.trim();
    final amt = parseAtoms(_otherAmount.text, SeqAssets.labelFor(id).precision);
    if (id.length < 64 || amt == null || amt <= BigInt.zero) return _snack('Enter a 64-hex asset id + amount');
    if (burn) {
      _run('Burned', (m) => core.buildBurnTx(mnemonic: m, esploraUrl: Backend.esplora, assetId: id, satoshi: amt));
    } else {
      _run('Reissued', (m) => core.buildReissueTx(mnemonic: m, esploraUrl: Backend.esplora, assetId: id, satoshi: amt));
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
                AmbraField(label: 'Amount to issue', controller: _issueAmount, hint: '1000'),
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
              "Reissue needs the asset's reissuance token in this wallet. Burn permanently destroys the amount.",
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

String _short(Object e) {
  final s = e.toString().replaceFirst('Exception: ', '');
  return s.length > 140 ? '${s.substring(0, 140)}…' : s;
}
