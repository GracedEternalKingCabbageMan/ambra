import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/config.dart';
import '../data/format.dart';
import '../data/trade_receipts.dart';
import '../data/xchain_swap_service.dart';
import '../rust/api.dart' as core;
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// RESUME + REFUND surface for an in-flight cross-chain swap (BTC locked, Sequentia asset
/// incoming). Lifts are STARTED by the order-book courier (CrossLiftScreen); this screen is
/// how the persisted record is resumed and, above all, how its CLTV "Refund BTC" off-ramp
/// stays reachable — the composer's in-flight banner opens it. The reveal of the preimage is
/// HARD-gated on the anchor check.
class XchainSwapScreen extends StatefulWidget {
  const XchainSwapScreen({super.key});

  @override
  State<XchainSwapScreen> createState() => _XchainSwapScreenState();
}

class _XchainSwapScreenState extends State<XchainSwapScreen> {
  XchainSwapRecord? _rec;
  core.AnchorEvidence? _anchor;
  bool _refundReady = false;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String _status = '';
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      var rec = await XchainStore.load();
      // FUND-SAFETY: reconcile a funding step whose confirmed lock was never recorded (e.g. the app
      // died mid-broadcast). Safe + non-broadcasting; see XchainSwapService.resumeFunding.
      if (rec != null) rec = await XchainSwapService.resumeFunding(rec);
      if (!mounted) return;
      setState(() {
        _rec = rec;
        _loading = false;
      });
      _arm(); // resume polling for the current step
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
    if (r.step == XStep.btcFunding) {
      _poll = Timer.periodic(const Duration(seconds: 15), (_) => _checkBtcLock());
    } else if (r.step == XStep.seqLocked || r.step == XStep.seqVerified) {
      _poll = Timer.periodic(const Duration(seconds: 12), (_) => _refreshAnchor());
    } else if (r.refundable) {
      // btcLocked (and a failed record still holding locked BTC) has nothing this screen can drive:
      // the maker's Sequentia leg arrives over the courier session, not from here. The one thing that
      // DOES change under us is the CLTV maturity, so poll it on the same gentle cadence as the other
      // waiting steps. Without the timer the refund button would sit on its startup verdict and keep
      // reading "Refund (waiting for timeout)" until the user left the screen and came back, hiding
      // the fund-recovery off-ramp exactly when it matures.
      _refreshRefundReady();
      _poll = Timer.periodic(const Duration(seconds: 30), (_) => _refreshRefundReady());
    }
  }

  String _seqAmt(BigInt atoms, String assetId) {
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

  Future<void> _fundBtc() => _run('Locking BTC…', () async {
        try {
          final rec = await XchainSwapService.fundBtc(_rec!);
          if (mounted) setState(() => _rec = rec);
          TradeReceipts.log(
            id: 'buy:${rec.quoteId}',
            title: 'Buying ${SeqAssets.labelFor(rec.seqAsset).ticker} with BTC',
            status: 'BTC locked',
            txid: rec.btcFundingTxid,
          ).ignore();
        } catch (_) {
          // FUND-SAFETY: fundBtc persists the record (with the funding txid) at btcFunding BEFORE it
          // broadcasts. If the broadcast throws, reload the PERSISTED record so the in-memory _rec
          // reflects what actually happened — otherwise _rec stays stale at secretReady and the UI
          // re-shows "Lock BTC", and a re-tap would re-fund (picking different UTXOs if the first tx
          // is already in the mempool) and double-lock the BTC. On a pre-save throw (auth/prepare)
          // the persisted step is unchanged, so the Lock button correctly remains. Rethrow so _run
          // still surfaces the error; recovery from btcFunding is the poll/refund off-ramp.
          final saved = await XchainStore.load();
          if (saved != null && mounted) setState(() => _rec = saved);
          rethrow;
        }
      });

  /// Reconcile the BTC lock's confirmation. Non-broadcasting; the maker's asset leg arrives
  /// over the courier (CrossLiftService), so there is nothing to propose from here.
  Future<void> _checkBtcLock() async {
    if (_busy) return;
    try {
      final locked = await XchainSwapService.pollBtcLock(_rec!);
      if (locked && mounted) {
        setState(() {});
        _arm();
      }
    } catch (_) {/* keep polling */}
  }

  Future<void> _refreshAnchor() async {
    if (_busy || _rec?.seqLeg == null) return;
    try {
      final ev = await XchainSwapService.checkAnchor(_rec!);
      if (mounted) setState(() => _anchor = ev);
    } catch (_) {}
  }

  Future<void> _claim() => _run('Revealing + claiming the asset…', () async {
        final rec = await XchainSwapService.claimSeq(_rec!);
        if (mounted) setState(() => _rec = rec);
        TradeReceipts.log(
          id: 'buy:${rec.quoteId}',
          title: 'Bought ${SeqAssets.labelFor(rec.seqAsset).ticker} with BTC',
          status: 'Asset received',
          txid: rec.seqClaimTxid,
        ).ignore();
      });

  Future<void> _refreshRefundReady() async {
    try {
      final ready = await XchainSwapService.refundReady(_rec!);
      if (mounted) setState(() => _refundReady = ready);
    } catch (_) {}
  }

  Future<void> _refund() => _run('Refunding BTC…', () async {
        final rec = await XchainSwapService.refundBtc(_rec!);
        if (mounted) setState(() => _rec = rec);
        TradeReceipts.log(
          id: 'buy:${rec.quoteId}',
          title: '${SeqAssets.labelFor(rec.seqAsset).ticker} buy refunded',
          status: 'BTC refunded',
          txid: rec.btcRefundTxid,
        ).ignore();
      });

  Future<void> _reset() async {
    await XchainStore.clear();
    _poll?.cancel();
    if (mounted) {
      setState(() {
        _rec = null;
        _anchor = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Buy with Bitcoin', style: AmbraText.title),
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
      const Text('Cross-chain swap: lock Bitcoin (testnet4), receive a Sequentia asset.', style: AmbraText.sub),
      const SizedBox(height: 16),
    ];
    if (_error != null) {
      children
        ..add(AmbraCard(child: Text(_error!, style: const TextStyle(color: AmbraColors.red))))
        ..add(const SizedBox(height: 14));
    }
    if (r == null) {
      children.add(const AmbraCard(
          child: Text('No cross-chain swap is in progress. Start one from the Swap tab by taking a resting Bitcoin offer.',
              style: AmbraText.muted)));
    } else {
      children.addAll(_stepView(r));
    }
    return children;
  }

  List<Widget> _stepView(XchainSwapRecord r) {
    final w = <Widget>[
      AmbraCard(
        child: Column(children: [
          _Row('You receive', _seqAmt(r.seqAmount, r.seqAsset)),
          _Row('You lock', _btc(r.btcAmount)),
          _Row('Maker fee', _btc(r.feeBtc)),
          _Row('Status', _stepLabel(r.step)),
        ]),
      ),
      const SizedBox(height: 16),
    ];

    switch (r.step) {
      case XStep.secretReady:
        w.addAll([
          AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel('Lock your Bitcoin'),
              const SizedBox(height: 8),
              Text('Funds ${_btc(r.btcAmount)} into the on-chain lock address:', style: AmbraText.sub),
              const SizedBox(height: 6),
              SelectableText(r.btcP2shAddress, style: AmbraText.mono.copyWith(fontSize: 13)),
            ]),
          ),
          const SizedBox(height: 14),
          PrimaryButton(label: 'Lock BTC', busy: _busy, icon: Icons.lock, onPressed: _busy ? null : _fundBtc),
        ]);
        break;
      case XStep.btcFunding:
        w.add(const _Waiting('Waiting for the Bitcoin lock to confirm (~1 block)…'));
        w.add(_checkButton(_checkBtcLock));
        break;
      case XStep.btcLocked:
        // The maker locks its Sequentia leg over the courier session (CrossLiftScreen). Nothing to
        // drive from here; the refund off-ramp below stays available if the maker never delivers.
        w.add(const _Waiting('BTC locked. Waiting for the maker to lock the Sequentia asset…'));
        break;
      case XStep.seqLocked:
      case XStep.seqVerified:
        w.addAll(_anchorGate(r));
        break;
      case XStep.seqClaimed:
        w.add(const AmbraCard(
            child: Text('You received the asset. The maker sweeps your Bitcoin with the revealed secret; nothing further is needed from you.',
                style: AmbraText.body)));
        if (r.seqClaimTxid.isNotEmpty) w.add(_txRow('Sequentia claim', r.seqClaimTxid));
        w.add(const SizedBox(height: 10));
        w.add(SecondaryButton(label: 'Done', icon: Icons.check, onPressed: _reset));
        break;
      // REACHABLE ONLY FROM A PRE-UPGRADE RECORD. Removing pollSettle left this step with no setter:
      // nothing in this build advances a swap to btcClaimed, because the maker's BTC claim is no
      // longer something this wallet observes. It is kept, rather than dropped from the enum, so a
      // record persisted by an older build still decodes and still renders its true terminal state —
      // dropping the value would need a fromJson migration and would show those users a wrong step.
      case XStep.btcClaimed:
        w.add(const AmbraCard(child: Text('Swap complete. You received the asset; the maker took the BTC.', style: AmbraText.body)));
        if (r.seqClaimTxid.isNotEmpty) w.add(_txRow('Sequentia claim', r.seqClaimTxid));
        w.add(const SizedBox(height: 10));
        w.add(SecondaryButton(label: 'Done', icon: Icons.check, onPressed: _reset));
        break;
      case XStep.refunded:
        w.add(const AmbraCard(child: Text('BTC refunded. The swap was aborted; your Bitcoin is back in your wallet.', style: AmbraText.body)));
        if (r.btcRefundTxid.isNotEmpty) w.add(_txRow('BTC refund', r.btcRefundTxid));
        w.add(const SizedBox(height: 10));
        w.add(SecondaryButton(label: 'Done', icon: Icons.check, onPressed: _reset));
        break;
      case XStep.failed:
        w.add(SecondaryButton(label: 'Clear', icon: Icons.delete_outline, onPressed: _reset));
        break;
    }

    // Refund off-ramp: only while the BTC is committed and the secret hasn't been
    // revealed. Enabled once the timelock matures.
    if (r.refundable && r.step != XStep.secretReady) {
      w.addAll([
        const SizedBox(height: 18),
        const Divider(color: AmbraColors.line),
        const SizedBox(height: 6),
        Text(
          _refundReady
              ? 'The lock timeout has passed; you can refund your BTC if you no longer want the swap.'
              : 'If the swap stalls, your BTC becomes refundable after the lock timeout (block ${r.btcLocktime}).',
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

  List<Widget> _anchorGate(XchainSwapRecord r) {
    final ev = _anchor;
    final ok = ev?.ok ?? false;
    return [
      AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SectionLabel('Safety check'),
          const SizedBox(height: 8),
          const Text(
            'Before revealing the secret, the Sequentia leg must be Bitcoin-anchored '
            'at or above your BTC lock and confirmed by the node.',
            style: AmbraText.sub,
          ),
          const SizedBox(height: 10),
          if (ev == null)
            const Row(children: [
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AmbraColors.amber)),
              SizedBox(width: 10),
              Text('Checking the anchor…', style: AmbraText.muted),
            ])
          else ...[
            _Row('Sequentia anchor height', ev.seqAnchorHeight < 0 ? 'not anchored yet' : '${ev.seqAnchorHeight}'),
            _Row('Your BTC lock height', '${ev.btcLegHeight}'),
            _Row('Anchor depth', ev.depth < 0 ? '—' : '${ev.depth} conf'),
            _Row('Anchor status', ev.anchorStatus),
            _Row('Safe to claim', ok ? 'yes' : 'not yet'),
          ],
        ]),
      ),
      const SizedBox(height: 14),
      PrimaryButton(
        label: ok ? 'Claim the asset (reveal secret)' : 'Claim (not safe yet)',
        busy: _busy,
        icon: Icons.verified_user,
        onPressed: (_busy || !ok) ? null : _claim,
      ),
      const SizedBox(height: 8),
      GhostButton(label: 'Re-check', onPressed: _busy ? null : _refreshAnchor),
    ];
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

  String _stepLabel(XStep s) => switch (s) {
        XStep.secretReady => 'Ready to lock BTC',
        XStep.btcFunding => 'Locking BTC',
        XStep.btcLocked => 'BTC locked',
        XStep.seqLocked => 'Maker locked the asset',
        XStep.seqVerified => 'Asset leg verified',
        XStep.seqClaimed => 'Asset claimed',
        XStep.btcClaimed => 'Complete',
        XStep.refunded => 'Refunded',
        XStep.failed => 'Failed',
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
