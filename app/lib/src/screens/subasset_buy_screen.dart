import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/btc_state.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../data/lightning_service.dart';
import '../data/lsp_client.dart';
import '../data/subasset_buy_service.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// A small BTC miner-fee headroom (sats) reserved on top of the locked amount in the affordability
/// pre-check: funding the BTC HTLC also pays an on-chain fee, so a near-max buy that ignored it would
/// pass the form then fail at btcPrepare. The exact fee is computed when the funding tx is built.
final BigInt _kBtcMinerHeadroomSats = BigInt.from(1000);

/// Sub-asset BUY wizard: fund a Bitcoin (testnet4) on-chain HTLC, receive a Sequentia asset over
/// Lightning, bound by ONE preimage the DEVICE owns.
///
/// The BTC HTLC is funded BEFORE the maker is asked to pay, so an in-flight buy is persisted and
/// resumable: once the asset payment is HELD at the device's node, the device settles with the
/// preimage (asset in + preimage revealed for the maker to claim the BTC); if the maker never pays,
/// the BTC is refunded via its CLTV timeout. The preimage reveal happens ONLY after `held`.
class SubassetBuyScreen extends StatefulWidget {
  const SubassetBuyScreen({super.key, required this.asset});

  /// The Sequentia asset to buy (received over Lightning).
  final String asset;

  @override
  State<SubassetBuyScreen> createState() => _SubassetBuyScreenState();
}

class _SubassetBuyScreenState extends State<SubassetBuyScreen> {
  final _amount = TextEditingController(); // BTC to spend (blank => take the whole offer)
  SubBuyRecord? _rec;
  SubOffer? _offer;
  bool _refundReady = false;
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
      final rec = await SubBuyStore.load();
      SubOffer? offer;
      try {
        final book = await LightningService.instance.subassetBook(widget.asset);
        if (book.buyOffers.isNotEmpty) offer = book.buyOffers.first;
      } catch (_) {/* the offer may have rested away; begin() re-checks */}
      if (!mounted) return;
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

  // Drive the waiting steps with a gentle poll.
  void _arm() {
    _poll?.cancel();
    final r = _rec;
    if (r == null) return;
    if (r.step == SubBuyStep.funding) {
      _poll = Timer.periodic(const Duration(seconds: 15), (_) => _pollFund());
    } else if (r.step == SubBuyStep.funded || r.step == SubBuyStep.holding) {
      _poll = Timer.periodic(const Duration(seconds: 6), (_) => _drive());
      if (r.refundable) _refreshRefundReady();
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
    final offer = _offer;
    if (offer == null) return _snack('No resting $_ticker buy offer right now; try again shortly.');
    final reqBtcSats = parseAtoms(_amount.text, 8); // blank / invalid => whole offer
    await _run('Preparing your buy…', () async {
      final rec = await SubassetBuyService.begin(asset: widget.asset, offer: offer, reqBtcSats: reqBtcSats);
      // Affordability pre-check: funding the BTC HTLC needs the locked amount PLUS an on-chain miner
      // fee, so require a little headroom. Block here (nothing has moved yet) instead of failing later
      // at fund/btcPrepare. Best-effort: skip when the BTC balance isn't known yet. No money moved, so
      // discard the secretReady stub before bailing.
      final bal = BigInt.tryParse(BtcState.instance.last?.balanceSats ?? '');
      if (bal != null && rec.btcSats + _kBtcMinerHeadroomSats > bal) {
        await SubBuyStore.clear();
        throw Exception(
            'You only hold ${_btc(bal)}. Locking ${_btc(rec.btcSats)} plus an on-chain fee needs more; reduce the amount.');
      }
      if (mounted) setState(() => _rec = rec);
    });
  }

  Future<void> _fundBtc() => _run('Locking BTC…', () async {
        try {
          final rec = await SubassetBuyService.fund(_rec!);
          if (mounted) setState(() => _rec = rec);
        } catch (_) {
          // FUND-SAFETY: fund() persists the record (with the funding txid) at 'funding' BEFORE it
          // broadcasts. If the broadcast throws, reload the PERSISTED record so the in-memory _rec
          // reflects what actually happened — otherwise _rec stays stale at secretReady and the UI
          // re-shows "Lock BTC", and a re-tap would re-fund (different UTXOs) and DOUBLE-LOCK the BTC.
          // On a pre-save throw (auth / invoice / prepare) the persisted step is unchanged, so the Lock
          // button correctly remains. Rethrow so _run surfaces the error; recovery is the poll/refund.
          final saved = await SubBuyStore.load();
          if (saved != null && mounted) setState(() => _rec = saved);
          rethrow;
        }
      });

  Future<void> _pollFund() async {
    if (_busy) return;
    try {
      final swapped = await SubassetBuyService.pollFundAndSwap(_rec!);
      if (mounted) setState(() {});
      if (swapped) {
        _arm();
        await _drive();
      }
    } catch (_) {/* keep polling */}
  }

  Future<void> _drive() async {
    if (_busy || _rec == null) return;
    try {
      final rec = await SubassetBuyService.drive(_rec!);
      if (mounted) setState(() => _rec = rec);
      if (rec.refundable) _refreshRefundReady();
      _arm();
    } catch (_) {/* keep driving */}
  }

  Future<void> _refreshRefundReady() async {
    try {
      final ready = await SubassetBuyService.refundReady(_rec!);
      if (mounted) setState(() => _refundReady = ready);
    } catch (_) {}
  }

  Future<void> _refund() => _run('Refunding BTC…', () async {
        final rec = await SubassetBuyService.refund(_rec!);
        if (mounted) setState(() => _rec = rec);
      });

  Future<void> _reset() async {
    await SubBuyStore.clear();
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
        title: Text('Buy $_ticker over Lightning', style: AmbraText.title),
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
      Text('Lock Bitcoin (testnet4) in an on-chain HTLC, receive $_ticker over Lightning, bound by one secret.',
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
    if (_offer == null) {
      return [
        AmbraCard(child: Text('No resting $_ticker buy offers right now. Check back shortly.', style: AmbraText.muted)),
      ];
    }
    final o = _offer!;
    return [
      const SectionLabel('Buy'),
      const SizedBox(height: 8),
      AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Best resting offer: ${_amt(o.assetAmount, widget.asset)} for ${_btc(o.btcSats)}.',
              style: AmbraText.sub),
          const SizedBox(height: 10),
          AmbraField(label: 'Bitcoin to spend (blank = whole offer)', controller: _amount, hint: '0.0'),
        ]),
      ),
      const SizedBox(height: 16),
      PrimaryButton(label: 'Start buy', busy: _busy, icon: Icons.bolt, onPressed: _busy ? null : _begin),
    ];
  }

  List<Widget> _stepView(SubBuyRecord r) {
    final w = <Widget>[
      AmbraCard(
        child: Column(children: [
          _Row('You receive', _amt(r.assetAtoms, r.asset)),
          _Row('You lock', _btc(r.btcSats)),
          _Row('Status', _stepLabel(r.step)),
        ]),
      ),
      const SizedBox(height: 16),
    ];

    switch (r.step) {
      case SubBuyStep.secretReady:
        w.addAll([
          AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel('Lock your Bitcoin'),
              const SizedBox(height: 8),
              Text('Funds ${_btc(r.btcSats)} into the on-chain lock address:', style: AmbraText.sub),
              const SizedBox(height: 6),
              SelectableText(r.p2sh, style: AmbraText.mono.copyWith(fontSize: 13)),
            ]),
          ),
          const SizedBox(height: 14),
          PrimaryButton(label: 'Lock BTC', busy: _busy, icon: Icons.lock, onPressed: _busy ? null : _fundBtc),
        ]);
        break;
      case SubBuyStep.funding:
        w.add(const _Waiting('Waiting for the Bitcoin lock to confirm (~1 block)…'));
        w.add(_checkButton(_pollFund));
        break;
      case SubBuyStep.funded:
        w.add(_Waiting('Bitcoin locked. Waiting for the maker to pay you $_ticker over Lightning…'));
        if (r.fundingTxid.isNotEmpty) w.add(_txRow('BTC lock', r.fundingTxid));
        w.add(_checkButton(_drive));
        break;
      case SubBuyStep.holding:
        w.add(_Waiting('Payment received. Releasing your $_ticker and revealing the secret…'));
        w.add(_checkButton(_drive));
        break;
      case SubBuyStep.settled:
        w.add(AmbraCard(
            child: Text('Swap complete. Your Bitcoin bought ${_amt(r.assetAtoms, r.asset)}, received over Lightning.',
                style: AmbraText.body)));
        w.add(const SizedBox(height: 10));
        w.add(SecondaryButton(label: 'Done', icon: Icons.check, onPressed: _reset));
        break;
      case SubBuyStep.refunded:
        w.add(const AmbraCard(
            child: Text('The maker didn\'t pay in time; your Bitcoin was refunded on-chain.', style: AmbraText.body)));
        if (r.refundTxid.isNotEmpty) w.add(_txRow('BTC refund', r.refundTxid));
        w.add(const SizedBox(height: 10));
        w.add(SecondaryButton(label: 'Done', icon: Icons.check, onPressed: _reset));
        break;
      case SubBuyStep.failed:
        w.add(SecondaryButton(label: 'Clear', icon: Icons.delete_outline, onPressed: _reset));
        break;
    }

    // Refund off-ramp: only while the BTC is committed and not yet settled. Enabled once the CLTV
    // timeout matures (a live "Refund BTC" button).
    if (r.refundable && r.step != SubBuyStep.secretReady) {
      w.addAll([
        const SizedBox(height: 18),
        const Divider(color: AmbraColors.line),
        const SizedBox(height: 6),
        Text(
          _refundReady
              ? 'The lock timeout has passed; you can refund your BTC if the maker never paid.'
              : 'If the maker stalls, your BTC becomes refundable after the lock timeout (block ${r.tBtc}).',
          style: AmbraText.sub,
        ),
        const SizedBox(height: 8),
        SecondaryButton(
          label: _refundReady ? 'Refund my BTC' : 'Refund (waiting for timeout)',
          icon: Icons.undo,
          onPressed: (_busy || !_refundReady) ? null : _refund,
        ),
      ]);
    }
    if (_status.isNotEmpty) {
      w
        ..add(const SizedBox(height: 12))
        ..add(Text(_status, style: AmbraText.muted));
    }
    return w;
  }

  Widget _checkButton(Future<void> Function() onTap) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: GhostButton(label: 'Check now', onPressed: _busy ? null : () => onTap()),
      );

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

  String _stepLabel(SubBuyStep s) => switch (s) {
        SubBuyStep.secretReady => 'Ready to lock BTC',
        SubBuyStep.funding => 'Locking BTC',
        SubBuyStep.funded => 'BTC locked · awaiting the maker',
        SubBuyStep.holding => 'Payment received · settling',
        SubBuyStep.settled => 'Complete',
        SubBuyStep.refunded => 'Refunded',
        SubBuyStep.failed => 'Failed',
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
