import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/config.dart';
import '../data/format.dart';
import '../data/lightning_service.dart';
import '../data/lsp_client.dart';
import '../data/subasset_sell_service.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Sub-asset SELL wizard: pay a Sequentia asset over Lightning, receive Bitcoin (testnet4) via an
/// on-chain HTLC the wallet CLAIMS with the maker-revealed preimage.
///
/// The asset is paid FIRST over Lightning (claim-or-lose — there is no BTC refund path in this
/// direction). So once the LN pay settles, the preimage + the maker's BTC HTLC terms are persisted
/// BEFORE the on-chain claim, and the claim is retried (here and on cold start) until it confirms.
class SubassetSellScreen extends StatefulWidget {
  const SubassetSellScreen({super.key, required this.asset, this.assetAmount});

  /// The Sequentia asset to sell for Bitcoin (paid over Lightning).
  final String asset;

  /// Optional composer seed: prefill the amount of [asset] to sell (a display
  /// string). Ignored when a swap is already in flight (never clobbers a resume).
  final String? assetAmount;

  @override
  State<SubassetSellScreen> createState() => _SubassetSellScreenState();
}

class _SubassetSellScreenState extends State<SubassetSellScreen> {
  final _amount = TextEditingController();
  SubSellRecord? _rec;
  SubOffer? _offer; // best resting sell offer (economic gate's expected BTC)
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String _status = '';
  Timer? _poll;

  String get _ticker => SeqAssets.labelFor(widget.asset).ticker;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rec = await SubSellStore.load();
      // Best-effort: source the best resting sell offer for the economic gate (expected BTC).
      SubOffer? offer;
      try {
        final book = await LightningService.instance.subassetBook(widget.asset);
        if (book.sellOffers.isNotEmpty) offer = book.sellOffers.first;
      } catch (_) {/* rail-agnostic: a sell can proceed without a pinned offer */}
      if (!mounted) return;
      // Composer seed: prefill the amount to sell, but only when nothing is in flight.
      if (rec == null && widget.assetAmount != null && widget.assetAmount!.trim().isNotEmpty) {
        _amount.text = widget.assetAmount!.trim();
      }
      setState(() {
        _rec = rec;
        _offer = offer;
        _loading = false;
      });
      _arm();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e, pullToRefresh: false);
          _loading = false;
        });
      }
    }
  }

  // While the asset is paid but the BTC claim hasn't confirmed, retry the claim on a gentle poll.
  void _arm() {
    _poll?.cancel();
    if (_rec?.step == SubSellStep.claiming) {
      _poll = Timer.periodic(const Duration(seconds: 15), (_) => _retryClaim());
    }
  }

  String _amt(BigInt atoms, String assetId) {
    final l = SeqAssets.labelFor(assetId);
    return '${formatAtoms(atoms.toString(), l.precision)} ${l.ticker}';
  }

  String _btc(BigInt sats) => '${formatAtoms(sats.toString(), 8)} BTC';

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(ambraSnack(m));

  Future<void> _run(String status, Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = status;
    });
    try {
      await body();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
        _arm();
      }
    }
  }

  Future<void> _begin() async {
    final l = SeqAssets.labelFor(widget.asset);
    final amt = double.tryParse(_amount.text.trim());
    if (amt == null || amt <= 0) return _snack('Enter an amount of ${l.ticker} to sell');
    await _run('Paying ${l.ticker} over Lightning…', () async {
      try {
        final rec = await SubassetSellService.begin(asset: widget.asset, amount: amt, offer: _offer);
        if (mounted) setState(() => _rec = rec);
      } catch (_) {
        // FUND-SAFETY: begin() pays the asset over Lightning, then persists the preimage + HTLC terms
        // at 'claiming' BEFORE the on-chain claim. If the claim (or anything after the pay) throws,
        // reload the PERSISTED record so the UI reflects that the asset is paid and the BTC is
        // claimable — never re-show the "Sell" form (a re-tap must not re-pay the asset).
        final saved = await SubSellStore.load();
        if (saved != null && mounted) setState(() => _rec = saved);
        rethrow;
      }
    });
  }

  Future<void> _retryClaim() async {
    if (_busy || _rec?.step != SubSellStep.claiming) return;
    await _run('Claiming your BTC on-chain…', () async {
      final rec = await SubassetSellService.claim(_rec!);
      if (mounted) setState(() => _rec = rec);
    });
  }

  Future<void> _reset() async {
    await SubSellStore.clear();
    _poll?.cancel();
    if (mounted) {
      setState(() {
        _rec = null;
        _amount.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Sell $_ticker over Lightning', style: AmbraText.title),
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
    final r = _rec;
    final children = <Widget>[
      Text('Pay $_ticker over Lightning, receive Bitcoin (testnet4) on-chain, bound by one secret.',
          style: AmbraText.sub),
      const SizedBox(height: 16),
    ];
    if (_error != null) {
      children
        ..add(AmbraCard(child: Text(_error!, style: const TextStyle(color: AmbraColors.red))))
        ..add(const SizedBox(height: 14));
    }
    if (r == null) {
      children.addAll(_quoteForm());
    } else {
      children.addAll(_stepView(r));
    }
    return children;
  }

  List<Widget> _quoteForm() {
    return [
      const SectionLabel('Sell'),
      const SizedBox(height: 8),
      AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AmbraField(label: 'Amount ($_ticker)', controller: _amount, hint: '0.0'),
          if (_offer != null) ...[
            const SizedBox(height: 8),
            Text('Best resting bid locks ${_btc(_offer!.btcSats)} for ${_amt(_offer!.assetAmount, widget.asset)}.',
                style: AmbraText.sub),
          ],
        ]),
      ),
      const SizedBox(height: 16),
      PrimaryButton(
          label: 'Sell over Lightning', busy: _busy, icon: Icons.bolt, onPressed: _busy ? null : _begin),
    ];
  }

  List<Widget> _stepView(SubSellRecord r) {
    final w = <Widget>[
      AmbraCard(
        child: Column(children: [
          _Row('You sell', _ticker),
          _Row('You receive', 'Bitcoin (on-chain HTLC)'),
          if (r.gotBtc > BigInt.zero) _Row('BTC amount', _btc(r.gotBtc)),
          _Row('Status', _stepLabel(r.step)),
        ]),
      ),
      const SizedBox(height: 16),
    ];

    switch (r.step) {
      case SubSellStep.paying:
        w.add(const _Waiting('Paying the asset over Lightning…'));
        break;
      case SubSellStep.claiming:
        w.add(const _Waiting('Asset paid over Lightning. Claiming your Bitcoin on-chain…'));
        if (r.shortfall) {
          w.add(Padding(
            padding: const EdgeInsets.only(top: 12),
            child: WarnCallout(
                'The Bitcoin HTLC is worth ${_btc(r.gotBtc)}, less than the quoted amount. Claiming it anyway.'),
          ));
        }
        w.add(Padding(
          padding: const EdgeInsets.only(top: 12),
          child: SecondaryButton(
              label: 'Retry claim', icon: Icons.undo, onPressed: _busy ? null : _retryClaim),
        ));
        break;
      case SubSellStep.done:
        w.add(AmbraCard(
            child: Text(
                'Swap complete. You paid $_ticker over Lightning and claimed ${_btc(r.gotBtc)} on-chain.',
                style: AmbraText.body)));
        if (r.shortfall) {
          w.add(const Padding(
            padding: EdgeInsets.only(top: 12),
            child: WarnCallout('The claimed Bitcoin came in below the quoted amount.'),
          ));
        }
        if (r.claimTxid.isNotEmpty) w.add(_txRow('BTC claim', r.claimTxid));
        w.add(const SizedBox(height: 10));
        w.add(SecondaryButton(label: 'Done', icon: Icons.check, onPressed: _reset));
        break;
      case SubSellStep.failed:
        w.add(SecondaryButton(label: 'Clear', icon: Icons.delete_outline, onPressed: _reset));
        break;
    }

    if (_status.isNotEmpty) {
      w
        ..add(const SizedBox(height: 12))
        ..add(Text(_status, style: AmbraText.muted));
    }
    return w;
  }

  Widget _txRow(String label, String txid) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: txid));
            _snack('$label txid copied');
          },
          child: _Row(label, '${txid.substring(0, 16)}…  (copy)'),
        ),
      );

  String _stepLabel(SubSellStep s) => switch (s) {
        SubSellStep.paying => 'Paying over Lightning',
        SubSellStep.claiming => 'Claiming your BTC',
        SubSellStep.done => 'Complete',
        SubSellStep.failed => 'Failed',
      };
}

class _Waiting extends StatelessWidget {
  const _Waiting(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => AmbraCard(
        child: Row(children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AmbraColors.amber)),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: AmbraText.muted)),
        ]),
      );
}

class _Row extends StatelessWidget {
  const _Row(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: AmbraText.body)),
        ]),
      );
}
