import 'package:flutter/material.dart';

import '../data/config.dart';
import '../data/cross_lift_service.dart';
import '../data/cross_walk.dart';
import '../data/format.dart';
import '../data/trade_receipts.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// A MULTI-OFFER cross-market BUY (gap 11): the planned sweep across the resting BTC->asset offers,
/// best price first, executed ONE LEG AT A TIME through the proven single-offer lift path
/// ([CrossLiftService]: live maker quote -> validate -> lock BTC -> verify + anchor-gate -> claim).
///
/// Review states the AGGREGATE ("across N offers") plus the honest remainder that cannot fill and will
/// NOT be rested (a market order never rests — the maker's LIMIT path does). Each leg is an interactive
/// courier session persisting its OWN XchainSwapRecord (sequential execution keeps at most one leg's
/// record live at a time, so the per-leg store + its refund off-ramps work unchanged). A FAILED leg
/// STOPS the walk immediately with an honest summary — the remainder is never silently retried; the
/// failed leg's Bitcoin (if locked) stays refundable via its own record's CLTV off-ramp.
class CrossWalkScreen extends StatefulWidget {
  const CrossWalkScreen({super.key, required this.plan});
  final CrossWalkPlan plan;

  @override
  State<CrossWalkScreen> createState() => _CrossWalkScreenState();
}

class _CrossWalkScreenState extends State<CrossWalkScreen> {
  bool _busy = false;
  CrossWalkResult? _result;
  String? _error;
  String _status = '';
  int _legIndex = 0;

  String get _asset => widget.plan.legs.first.offer.seqAsset;
  String get _tk => SeqAssets.labelFor(_asset).ticker;
  int get _aprec => SeqAssets.labelFor(_asset).precision;

  String _amt(BigInt atoms) => '${formatAtoms(atoms.toString(), _aprec)} $_tk';
  String _btc(BigInt sats) => '${formatAtoms(sats.toString(), 8)} BTC';

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    final n = widget.plan.legs.length;
    final result = await runCrossWalk(widget.plan, (leg, i) async {
      if (mounted) setState(() => _legIndex = i);
      void step(String s) {
        if (mounted) setState(() => _status = 'Offer ${i + 1} of $n · $s');
      }

      // The SAME pre-lock -> confirm -> settle path a single-offer lift runs, per leg. The maker
      // quotes THIS slice live; validateCrossTerms binds it to the planned CEIL price, so a maker that
      // quotes worse than planned fails the leg (stop-on-failure) instead of silently repricing.
      step('Getting a live quote from the maker…');
      final quote =
          await CrossLiftService.requestAndValidateTerms(leg.offer, requestedAtoms: leg.partial ? leg.takeAtoms : null);
      final rec = await CrossLiftService.lockAndSettle(quote, onStep: step);
      TradeReceipts.log(
        id: 'xbuy:${rec.hashHex}',
        title: 'Bought $_tk with BTC',
        status: 'Settled (leg ${i + 1} of $n)',
        txid: rec.seqClaimTxid,
      ).ignore();
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
      _status = '';
      if (!result.complete) {
        final e = result.error;
        _error = (e == null ? 'The leg failed.' : e.toString().replaceFirst('Exception: ', ''));
      }
    });
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
    final plan = widget.plan;
    final res = _result;
    if (res != null) {
      final ok = res.complete;
      return [
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(ok ? Icons.check_circle : Icons.warning_amber_rounded,
                  color: ok ? AmbraColors.green : AmbraColors.amber, size: 20),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(ok ? 'Swap complete' : 'Walk stopped at offer ${res.legsDone + 1} of ${plan.offersUsed}',
                      style: AmbraText.title)),
            ]),
            const SizedBox(height: 10),
            Text(
              ok
                  ? 'You bought ${_amt(res.filledAtoms)} for ${_btc(res.filledBtc)} across ${res.legsDone} '
                      'resting offer${res.legsDone == 1 ? '' : 's'}, best price first.'
                  : '${res.legsDone} of ${plan.offersUsed} offers settled: ${_amt(res.filledAtoms)} bought for '
                      '${_btc(res.filledBtc)}. The failed offer STOPPED the walk — the remaining '
                      '${_amt(plan.filledAtoms - res.filledAtoms)} was NOT retried and nothing was rested. '
                      'If that leg locked your Bitcoin, it is refundable after its timeout from the '
                      'in-flight card on the Swap tab.',
              style: AmbraText.sub,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: AmbraColors.red)),
            ],
          ]),
        ),
        const SizedBox(height: 16),
        PrimaryButton(label: 'Done', icon: Icons.check, onPressed: () => Navigator.of(context).pop(true)),
      ];
    }
    return [
      const Text(
        'A market order that sweeps the book: it crosses the resting offers that meet its price, best '
        'price first, each settled as its own non-custodial swap. Your Bitcoin is refundable per leg if '
        'a swap does not complete.',
        style: AmbraText.sub,
      ),
      const SizedBox(height: 16),
      AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Review market order', style: AmbraText.title),
          const SizedBox(height: 12),
          _Row('You asked for', _amt(plan.requested)),
          _Row('Fills now', '${_amt(plan.filledAtoms)} · across ${plan.offersUsed} offers, best price first'),
          _Row('You pay', '~${_btc(plan.filledBtc)} in total'),
          if (plan.remainderAtoms > BigInt.zero)
            _Row('Cannot fill', '${_amt(plan.remainderAtoms)} has no liquidity at market and will NOT be '
                'rested — a market order never rests. Switch to Limit to rest an order.'),
          _Row('How it settles', 'One offer at a time. If a leg fails, the walk STOPS and the rest is not retried.'),
        ]),
      ),
      const SizedBox(height: 16),
      if (_busy) ...[
        AmbraCard(
          child: Row(children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AmbraColors.amber)),
            const SizedBox(width: 12),
            Expanded(
                child: Text(_status.isEmpty ? 'Working on offer ${_legIndex + 1} of ${plan.offersUsed}…' : _status,
                    style: AmbraText.sub)),
          ]),
        ),
      ] else ...[
        PrimaryButton(label: 'Lock Bitcoin & sweep ${plan.offersUsed} offers', icon: Icons.bolt, onPressed: _run),
        const SizedBox(height: 8),
        GhostButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
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
          SizedBox(width: 110, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: AmbraText.body)),
        ]),
      );
}
