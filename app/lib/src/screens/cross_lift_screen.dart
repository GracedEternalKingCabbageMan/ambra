import 'package:flutter/material.dart';

import '../data/cross_lift_service.dart';
import '../data/format.dart';
import '../data/config.dart';
import '../data/seqob_client.dart' show CrossOffer;
import '../data/trade_receipts.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// A cross (BTC<->asset) lift over the relay order-book courier — buy a Sequentia asset with Bitcoin
/// against a resting cross offer. Non-custodial: fetch a LIVE quote from the maker over the E2E courier,
/// show the exact terms, and only on confirm lock the Bitcoin leg + settle the HTLC. The taker's BTC is
/// always refundable after the timeout, and the secret reveals only on a verified, anchor-safe asset leg.
class CrossLiftScreen extends StatefulWidget {
  const CrossLiftScreen({super.key, required this.offer, this.requestedAtoms});
  final CrossOffer offer;

  /// The asset amount (atoms) the user typed in the composer, if any. The cross rail lifts the chosen
  /// offer WHOLE (no partial fill), so when the offer's size differs materially from this we say so
  /// explicitly — otherwise a user who typed "1" could lock the Bitcoin for a 12-unit offer unaware.
  final BigInt? requestedAtoms;

  @override
  State<CrossLiftScreen> createState() => _CrossLiftScreenState();
}

class _CrossLiftScreenState extends State<CrossLiftScreen> {
  CrossLiftQuote? _quote;
  bool _loading = true;
  bool _busy = false;
  bool _done = false;
  String? _error;
  String _status = '';

  String get _tk => SeqAssets.labelFor(widget.offer.seqAsset).ticker;
  int get _aprec => SeqAssets.labelFor(widget.offer.seqAsset).precision;

  /// The quoted offer's whole size is materially (>2%) larger than what the user typed — worth an
  /// explicit note so a whole-offer lift is never a silent overshoot.
  bool get _overshoot {
    final req = widget.requestedAtoms;
    final q = _quote;
    if (req == null || req <= BigInt.zero || q == null) return false;
    final got = q.terms.assetAtoms;
    return got > req && (got - req) * BigInt.from(100) > req * BigInt.from(2);
  }

  @override
  void initState() {
    super.initState();
    _getQuote();
  }

  @override
  void dispose() {
    _quote?.close();
    super.dispose();
  }

  Future<void> _getQuote() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final q = await CrossLiftService.requestAndValidateTerms(widget.offer);
      if (!mounted) {
        await q.close();
        return;
      }
      setState(() {
        _quote = q;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  Future<void> _swap() async {
    final q = _quote;
    if (q == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rec = await CrossLiftService.lockAndSettle(q, onStep: (s) {
        if (mounted) setState(() => _status = s);
      });
      TradeReceipts.log(
        id: 'xbuy:${rec.hashHex}',
        title: 'Bought $_tk with BTC',
        status: 'Settled',
        txid: rec.seqClaimTxid,
      ).ignore();
      if (mounted) {
        setState(() {
          _busy = false;
          _done = true;
          _quote = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString().replaceFirst('Exception: ', '');
          _quote = null; // the session is closed after a failed lift
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
        title: Text('Buy $_tk with Bitcoin', style: AmbraText.title),
      ),
      body: AmbraBackground(
        child: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: _body()),
        ),
      ),
    );
  }

  List<Widget> _body() {
    if (_done) {
      return [
        AmbraCard(
          child: Row(children: [
            const Icon(Icons.check_circle, color: AmbraColors.green, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text('Swap complete: $_tk claimed, anchor-bound to Bitcoin.', style: AmbraText.body)),
          ]),
        ),
        const SizedBox(height: 16),
        PrimaryButton(label: 'Done', icon: Icons.check, onPressed: () => Navigator.of(context).pop()),
      ];
    }
    return [
      const Text(
        'A cross-chain swap against a resting order: you lock Bitcoin, the maker locks the asset, and you '
        'claim it. Non-custodial — your Bitcoin is refundable if the swap does not complete.',
        style: AmbraText.sub,
      ),
      const SizedBox(height: 16),
      if (_error != null) ...[
        AmbraCard(child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
        const SizedBox(height: 14),
      ],
      if (_loading)
        const Padding(
          padding: EdgeInsets.only(top: 20),
          child: Center(child: Column(children: [
            CircularProgressIndicator(color: AmbraColors.amber),
            SizedBox(height: 12),
            Text('Getting a live quote from the maker…', style: AmbraText.sub),
          ])),
        )
      else if (_quote != null) ...[
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Live quote', style: AmbraText.title),
            const SizedBox(height: 12),
            _Row('You pay', '${formatAtoms(_quote!.terms.btcSats.toString(), 8)} BTC'),
            _Row('You receive', '${formatAtoms(_quote!.terms.assetAtoms.toString(), _aprec)} $_tk'),
            if (_quote!.terms.feeBtcSats > BigInt.zero)
              _Row('Maker fee', '${formatAtoms(_quote!.terms.feeBtcSats.toString(), 8)} BTC'),
            if (_overshoot) ...[
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.info_outline, size: 15, color: AmbraColors.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This offer fills in full — ${formatAtoms(_quote!.terms.assetAtoms.toString(), _aprec)} $_tk, '
                    'more than the ${formatAtoms(widget.requestedAtoms!.toString(), _aprec)} $_tk you entered. '
                    'Partial fills are not possible on the cross rail.',
                    style: AmbraText.sub.copyWith(color: AmbraColors.amber),
                  ),
                ),
              ]),
            ],
            _Row('Settles', 'On-chain HTLC, anchor-bound to Bitcoin (about one block each leg).'),
            _Row('If it stalls', 'Your Bitcoin is refundable after the timeout; your secret stays hidden.'),
          ]),
        ),
        const SizedBox(height: 16),
        if (_busy) ...[
          AmbraCard(
            child: Row(children: [
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AmbraColors.amber)),
              const SizedBox(width: 12),
              Expanded(child: Text(_status.isEmpty ? 'Working…' : _status, style: AmbraText.sub)),
            ]),
          ),
        ] else
          PrimaryButton(
            label: 'Lock Bitcoin & swap',
            icon: Icons.bolt,
            onPressed: _swap,
          ),
      ] else ...[
        SecondaryButton(label: 'Get a quote again', icon: Icons.refresh, onPressed: _getQuote),
      ],
    ];
  }
}

class _Row extends StatelessWidget {
  const _Row(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 96, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: AmbraText.body)),
        ]),
      );
}
