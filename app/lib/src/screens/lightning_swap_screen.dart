import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/config.dart';
import '../data/lightning_service.dart';
import '../data/lsp_client.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// The "Instant (Lightning)" swap rail: a pure-LN BTC<->asset trade through the
/// hosted-SeqLN LSP (keys stay on this device, non-custodial). Distinct from the
/// on-chain cross-chain HTLC path ([XchainSwapScreen]): nothing settles on-chain,
/// so it is genuinely instant AND final (the one state the DEX 0-conf policy lets
/// us label final — see [LightningService.finalityCopy]).
///
/// The mobile twin of the web wallet's Instant-Lightning rail (swap.js
/// `requoteLn`/`reviewLn`). A resting LN offer is taken at the LP's fixed terms,
/// so there is no per-keystroke quote round-trip — pick a direction + asset +
/// amount and settle; the exact base/quote amounts come back in the response.
class LightningSwapScreen extends StatefulWidget {
  const LightningSwapScreen({super.key});
  @override
  State<LightningSwapScreen> createState() => _LightningSwapScreenState();
}

class _LightningSwapScreenState extends State<LightningSwapScreen> {
  final _amount = TextEditingController();
  final _ln = LightningService.instance;

  String _side = 'buy'; // 'buy' = BTC -> asset; 'sell' = asset -> BTC
  String? _asset; // asset id (hex) or LSP-reported ticker
  List<String> _assets = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  LspSwapResult? _result;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    // Prefer the hosted node's routable assets; fall back to the built-in demo
    // set so the picker is never empty if /status is briefly unreachable.
    List<String> assets;
    try {
      final st = await _ln.getStatus();
      assets = st.assets;
    } catch (_) {
      assets = const [];
    }
    if (assets.isEmpty) {
      assets = SeqAssets.faucetAssets.where((a) => a.isNotEmpty).map(_idForTicker).toList();
    }
    if (!mounted) return;
    setState(() {
      _assets = assets;
      _asset = assets.isNotEmpty ? assets.first : null;
      _loading = false;
    });
  }

  /// Resolve a demo ticker to its asset id (so we post the hex the LSP keys on),
  /// falling back to the ticker itself for anything outside the built-in set.
  String _idForTicker(String ticker) {
    for (final entry in {
      'USDX': '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de',
      'EURX': 'e39685e718516156679088d9400d11a1eb82bf7cc27c5b9f5a614b8c91246d13',
      'GOLD': '3a0f9192219db59f8d7f87d93ac6311095dfe1255d149727b87baaa7d2cc71a1',
      'SILVR': '57dfa6b0eff594cc3ef1de5555e0526d1eb5590289e014e7663b292edcd63f48',
      'OILX': '4dfe69c334a9cdf4005ddf3889bba1bc397703fa8da669254877f3209caf7c8f',
    }.entries) {
      if (entry.key == ticker) return entry.value;
    }
    return ticker;
  }

  String _tk(String? asset) => asset == null ? '—' : SeqAssets.labelFor(asset).ticker;

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(ambraSnack(m));

  Future<void> _swap() async {
    final asset = _asset;
    if (asset == null) return _snack('No Lightning market available');
    final amt = double.tryParse(_amount.text.trim());
    if (amt == null || amt <= 0) return _snack('Enter an amount');
    if (!_ln.available) return _snack('The Lightning signer is not connected');
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      // The device co-signs the hosted node's commitment updates over the wss
      // link in the background during this call.
      // TODO(device-verify): needs a device + a running hosted LSP to settle a
      // real swap; the call + settle rendering are wired here.
      final r = await _ln.swap(side: _side, asset: asset, amount: amt);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = r;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Instant (Lightning)', style: AmbraText.title),
      ),
      body: AmbraBackground(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AmbraColors.amber))
              : ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: _body()),
        ),
      ),
    );
  }

  List<Widget> _body() {
    if (_result != null) return _settledView(_result!);
    final assetTk = _tk(_asset);
    final amountLabel = _side == 'buy' ? 'Amount of BTC to spend' : 'Amount of $assetTk to sell';
    return [
      const Text(
        'Swap Bitcoin and a Sequentia asset over Lightning. Non-custodial: your keys stay on this device.',
        style: AmbraText.sub,
      ),
      const SizedBox(height: 16),
      _statusChip(),
      const SizedBox(height: 16),
      if (_error != null) ...[
        AmbraCard(child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
        const SizedBox(height: 14),
      ],
      const SectionLabel('Direction'),
      const SizedBox(height: 8),
      _SideToggle(side: _side, asset: assetTk, onChanged: (s) => setState(() => _side = s)),
      const SizedBox(height: 16),
      const SectionLabel('Asset'),
      const SizedBox(height: 8),
      AmbraCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: DropdownButton<String>(
          value: _asset,
          isExpanded: true,
          dropdownColor: AmbraColors.panel,
          underline: const SizedBox.shrink(),
          items: [
            for (final a in _assets) DropdownMenuItem(value: a, child: Text(_tk(a), style: AmbraText.body)),
          ],
          onChanged: (a) => setState(() => _asset = a),
        ),
      ),
      const SizedBox(height: 16),
      const SectionLabel('Amount'),
      const SizedBox(height: 8),
      AmbraField(label: amountLabel, controller: _amount, hint: '0.0'),
      const SizedBox(height: 6),
      const Text(
        'The rate includes the LP spread; there is no separate network fee on the Lightning leg. '
        'The exact amounts settle in the confirmation.',
        style: AmbraText.sub,
      ),
      const SizedBox(height: 18),
      AmbraCard(
        child: Row(children: [
          const Icon(Icons.bolt, color: AmbraColors.amber, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(_ln.finalityCopy(), style: AmbraText.sub)),
        ]),
      ),
      const SizedBox(height: 16),
      PrimaryButton(
        label: _side == 'buy' ? 'Buy $assetTk over Lightning' : 'Sell $assetTk over Lightning',
        busy: _busy,
        icon: Icons.bolt,
        onPressed: _busy ? null : _swap,
      ),
    ];
  }

  Widget _statusChip() {
    final ok = _ln.available;
    return AmbraCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Icon(ok ? Icons.check_circle : Icons.error_outline, color: ok ? AmbraColors.green : AmbraColors.red, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            ok
                ? 'Lightning signer connected${_ln.nodeId != null ? ' · ${_ln.nodeId!.substring(0, 14)}…' : ''}'
                : 'Lightning signer not connected (${_ln.phase})',
            style: AmbraText.sub,
          ),
        ),
      ]),
    );
  }

  List<Widget> _settledView(LspSwapResult r) {
    final got = r.direction == 'sold'
        ? '${r.quoteAmount ?? '—'} ${r.quoteAsset ?? 'BTC'}'
        : '${r.baseAmount ?? '—'} ${_tk(r.asset ?? _asset)}';
    return [
      AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.check_circle, color: AmbraColors.green, size: 20),
            const SizedBox(width: 8),
            Text(r.isFinal ? 'Settled · final' : 'Settled', style: AmbraText.title),
          ]),
          const SizedBox(height: 12),
          _Row('You received', got),
          if (r.settledMs != null) _Row('Settled in', '${r.settledMs} ms'),
          _Row('Finality', _ln.finalityCopy()),
          const SizedBox(height: 8),
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: r.preimage));
              _snack('Preimage copied');
            },
            child: _Row('Preimage', r.preimage.length > 16 ? '${r.preimage.substring(0, 16)}…  (copy)' : r.preimage),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      PrimaryButton(
        label: 'Done',
        icon: Icons.check,
        onPressed: () => Navigator.of(context).pop(),
      ),
      const SizedBox(height: 8),
      GhostButton(
        label: 'Swap again',
        onPressed: () => setState(() {
          _result = null;
          _amount.clear();
        }),
      ),
    ];
  }
}

/// A two-way direction toggle: buy the asset with BTC, or sell it for BTC.
class _SideToggle extends StatelessWidget {
  const _SideToggle({required this.side, required this.asset, required this.onChanged});
  final String side;
  final String asset;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: _btn('Buy $asset', 'buy')),
      const SizedBox(width: 10),
      Expanded(child: _btn('Sell $asset', 'sell')),
    ]);
  }

  Widget _btn(String label, String value) {
    final sel = side == value;
    return InkWell(
      borderRadius: BorderRadius.circular(AmbraRadii.input),
      onTap: () => onChanged(value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel ? AmbraColors.buttonSurface : AmbraColors.panelDeep,
          border: Border.all(color: sel ? AmbraColors.amber : AmbraColors.line),
          borderRadius: BorderRadius.circular(AmbraRadii.input),
        ),
        child: Text(label, style: sel ? AmbraText.body.copyWith(color: AmbraColors.amber) : AmbraText.muted),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: AmbraText.body)),
        ]),
      );
}
