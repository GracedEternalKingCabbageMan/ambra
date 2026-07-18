import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/api_client.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../data/trade_receipts.dart';
import '../data/xchain_client.dart';
import '../data/xchain_reverse_swap_service.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Reverse cross-chain swap wizard: SELL a Sequentia asset for Bitcoin (testnet4).
///
/// The mirror of the forward buy. Here the remote MAKER holds the secret and locks
/// the BTC leg FIRST; the wallet (taker) verifies that leg, waits for it to
/// confirm, funds the asset leg, then claims the BTC once the maker reveals the
/// secret by taking the asset. The wallet NEVER reveals a preimage, so the anchor
/// reveal-discipline holds by construction; a CLTV asset refund is the off-ramp.
class XchainReverseSwapScreen extends StatefulWidget {
  const XchainReverseSwapScreen({super.key});
  @override
  State<XchainReverseSwapScreen> createState() => _XchainReverseSwapScreenState();
}

class _XchainReverseSwapScreenState extends State<XchainReverseSwapScreen> {
  final _amount = TextEditingController();
  List<XchainMarket> _markets = [];
  XchainMarket? _market;
  RSwapRecord? _rec;
  Map<String, BigInt> _feeRates = {};
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
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rec = await RSwapStore.load();
      final markets = await XchainClient.markets();
      if (!mounted) return;
      setState(() {
        _rec = rec;
        _markets = markets;
        _market = markets.isNotEmpty ? markets.first : null;
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

  void _arm() {
    _poll?.cancel();
    final r = _rec;
    if (r == null) return;
    switch (r.step) {
      case RStep.btcLocked:
        _poll = Timer.periodic(const Duration(seconds: 15), (_) => _checkBtcConf());
        break;
      case RStep.seqFunding:
        _poll = Timer.periodic(const Duration(seconds: 12), (_) => _checkSeqFund());
        break;
      case RStep.seqSubmitted:
        _poll = Timer.periodic(const Duration(seconds: 12), (_) => _checkReveal());
        _refreshRefundReady();
        break;
      case RStep.seqClaimed:
        _autoClaim();
        break;
      default:
        break;
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

  Future<void> _begin() async {
    final m = _market;
    if (m == null) return _snack('No cross-chain markets available');
    final l = SeqAssets.labelFor(m.seqAsset);
    final atoms = parseAtoms(_amount.text, l.precision);
    if (atoms == null || atoms <= BigInt.zero) return _snack('Enter an amount of ${l.ticker} to sell');
    await _run('Quoting…', () async {
      final rec = await XchainReverseSwapService.begin(m.seqAsset, atoms);
      if (mounted) setState(() => _rec = rec);
      await _open();
    });
  }

  Future<void> _open() => _run('Asking the maker to lock BTC…', () async {
        try {
          final rec = await XchainReverseSwapService.open(_rec!);
          if (mounted) setState(() => _rec = rec);
        } on XchainFail catch (f) {
          if (mounted) setState(() => _error = 'Maker: ${f.message}');
        }
      });

  Future<void> _checkBtcConf() async {
    if (_busy) return;
    try {
      final ok = await XchainReverseSwapService.pollBtcConf(_rec!);
      if (ok && mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _fundSeq() => _run('Locking your asset…', () async {
        final rec = await XchainReverseSwapService.fundSeq(_rec!);
        if (mounted) setState(() => _rec = rec);
      });

  Future<void> _checkSeqFund() async {
    if (_busy) return;
    try {
      final submitted = await XchainReverseSwapService.pollSeqFundAndSubmit(_rec!);
      if (mounted) setState(() {});
      if (submitted) _refreshRefundReady();
    } on XchainFail catch (f) {
      // The leg is funded but the maker won't admit it yet (not anchored) — retry.
      if (mounted) setState(() => _error = 'Maker: ${f.message} (will retry)');
    } catch (_) {/* keep polling */}
  }

  Future<void> _checkReveal() async {
    if (_busy) return;
    try {
      final revealed = await XchainReverseSwapService.pollReveal(_rec!);
      if (mounted) setState(() {});
      if (revealed) await _autoClaim();
    } catch (_) {}
  }

  Future<void> _autoClaim() => _run('Claiming your Bitcoin…', () async {
        final rec = await XchainReverseSwapService.claimBtc(_rec!);
        if (mounted) setState(() => _rec = rec);
        TradeReceipts.log(
          id: 'sell:${rec.quoteId}',
          title: 'Sold ${SeqAssets.labelFor(rec.seqAsset).ticker} for BTC',
          status: 'BTC claimed',
          txid: rec.btcClaimTxid,
        ).ignore();
      });

  Future<void> _refreshRefundReady() async {
    try {
      final ready = await XchainReverseSwapService.refundReady(_rec!);
      if (mounted) setState(() => _refundReady = ready);
    } catch (_) {}
  }

  Future<void> _refund() => _run('Refunding your asset…', () async {
        if (_feeRates.isEmpty) {
          try {
            _feeRates = await ApiClient.feeRates();
          } catch (_) {}
        }
        final rec = await XchainReverseSwapService.refundSeq(_rec!, _feeRates);
        if (mounted) setState(() => _rec = rec);
        TradeReceipts.log(
          id: 'sell:${rec.quoteId}',
          title: '${SeqAssets.labelFor(rec.seqAsset).ticker} sale refunded',
          status: 'Asset refunded',
          txid: rec.seqRefundTxid,
        ).ignore();
      });

  Future<void> _reset() async {
    await RSwapStore.clear();
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
        title: const Text('Sell for Bitcoin', style: AmbraText.title),
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
      const Text('Cross-chain swap: sell a Sequentia asset, receive Bitcoin (testnet4).', style: AmbraText.sub),
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
    if (_markets.isEmpty) {
      return [const AmbraCard(child: Text('No cross-chain markets are open right now.', style: AmbraText.muted))];
    }
    return [
      const SectionLabel('Sell'),
      const SizedBox(height: 8),
      AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButton<XchainMarket>(
            value: _market,
            isExpanded: true,
            dropdownColor: AmbraColors.panel,
            underline: const SizedBox.shrink(),
            items: [
              for (final m in _markets)
                DropdownMenuItem(value: m, child: Text(SeqAssets.labelFor(m.seqAsset).ticker, style: AmbraText.body)),
            ],
            onChanged: (m) => setState(() => _market = m),
          ),
          const SizedBox(height: 8),
          AmbraField(label: 'Amount (${SeqAssets.labelFor(_market!.seqAsset).ticker})', controller: _amount, hint: '0.0'),
        ]),
      ),
      const SizedBox(height: 16),
      PrimaryButton(label: 'Get quote & start', busy: _busy, icon: Icons.swap_horiz, onPressed: _busy ? null : _begin),
    ];
  }

  List<Widget> _stepView(RSwapRecord r) {
    final w = <Widget>[
      AmbraCard(
        child: Column(children: [
          _Row('You sell', _seqAmt(r.seqAmount, r.seqAsset)),
          _Row('You receive', _btc(r.btcAmount)),
          if (r.feeBtc > BigInt.zero) _Row('Maker fee', _btc(r.feeBtc)),
          _Row('Status', _stepLabel(r.step)),
        ]),
      ),
      const SizedBox(height: 16),
    ];

    switch (r.step) {
      case RStep.rQuoted:
        w.add(const _Waiting('Asking the maker to lock the Bitcoin…'));
        w.add(_checkButton(_open));
        break;
      case RStep.btcLocked:
        w.addAll(_safetyCard(r, confirmed: false));
        w.add(const SizedBox(height: 12));
        w.add(const _Waiting('Waiting for the maker’s Bitcoin lock to confirm (~1 block)…'));
        w.add(_checkButton(_checkBtcConf));
        break;
      case RStep.btcConfirmed:
        w.addAll(_safetyCard(r, confirmed: true));
        w.addAll([
          const SizedBox(height: 14),
          AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel('Fund your asset'),
              const SizedBox(height: 8),
              Text(
                'The maker can take your ${SeqAssets.labelFor(r.seqAsset).ticker} only by revealing a secret, '
                'which lets you claim the Bitcoin. If the maker stalls, you refund after the timeout.',
                style: AmbraText.sub,
              ),
            ]),
          ),
          const SizedBox(height: 14),
          PrimaryButton(label: 'Lock my asset', busy: _busy, icon: Icons.lock, onPressed: _busy ? null : _fundSeq),
        ]);
        break;
      case RStep.seqFunding:
        w.add(const _Waiting('Waiting for your asset lock to confirm on Sequentia…'));
        if (r.seqFundTxid.isNotEmpty) w.add(_txRow('Asset leg', r.seqFundTxid, parent: false));
        w.add(_checkButton(_checkSeqFund));
        break;
      case RStep.seqSubmitted:
        w.add(const _Waiting('Asset locked. Waiting for the maker to take it and reveal the secret…'));
        if (r.seqFundTxid.isNotEmpty) w.add(_txRow('Asset leg', r.seqFundTxid, parent: false));
        w.add(_checkButton(_checkReveal));
        break;
      case RStep.seqClaimed:
        w.add(const _Waiting('Secret revealed. Claiming your Bitcoin…'));
        w.add(_checkButton(_autoClaim));
        break;
      case RStep.btcClaimed:
        w.add(const AmbraCard(
            child: Text('Swap complete. You sold the asset and received Bitcoin, linked by the secret.',
                style: AmbraText.body)));
        if (r.btcClaimTxid.isNotEmpty) w.add(_txRow('Your BTC claim', r.btcClaimTxid, parent: true));
        w.add(const SizedBox(height: 10));
        w.add(SecondaryButton(label: 'Done', icon: Icons.check, onPressed: _reset));
        break;
      case RStep.refunded:
        w.add(const AmbraCard(
            child: Text('Asset refunded. The swap was aborted; your asset is back in your wallet.', style: AmbraText.body)));
        if (r.seqRefundTxid.isNotEmpty) w.add(_txRow('Asset refund', r.seqRefundTxid, parent: false));
        w.add(const SizedBox(height: 10));
        w.add(SecondaryButton(label: 'Done', icon: Icons.check, onPressed: _reset));
        break;
      case RStep.failed:
        w.add(SecondaryButton(label: 'Clear', icon: Icons.delete_outline, onPressed: _reset));
        break;
    }

    // Refund off-ramp: only while our asset is funded and the maker has not taken
    // it. Enabled once the Sequentia timeout matures.
    if (r.refundable) {
      w.addAll([
        const SizedBox(height: 18),
        const Divider(color: AmbraColors.line),
        const SizedBox(height: 6),
        Text(
          _refundReady
              ? 'The lock timeout has passed; you can refund your asset if the maker never took it.'
              : 'If the swap stalls, your asset becomes refundable after the timeout (Sequentia block ${r.seqLocktime}).',
          style: AmbraText.sub,
        ),
        const SizedBox(height: 8),
        SecondaryButton(
          label: _refundReady ? 'Refund my asset' : 'Refund (waiting for timeout)',
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

  List<Widget> _safetyCard(RSwapRecord r, {required bool confirmed}) {
    return [
      AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SectionLabel('Safety check'),
          const SizedBox(height: 8),
          const Text(
            'The maker locked the Bitcoin first, into an on-chain lock only your secret-claim key can '
            'take. We rebuilt and matched its script before continuing, and wait for it to '
            'confirm so your asset lock anchors at or above it. You commit nothing until then.',
            style: AmbraText.sub,
          ),
          const SizedBox(height: 10),
          _Row('Maker BTC leg', 'verified'),
          _Row('BTC lock confirmed', confirmed ? 'yes (height ${r.btcLegHeight})' : 'waiting'),
          _Row('Timeouts', 'BTC ${r.btcLocktime} · Sequentia ${r.seqLocktime}'),
          _Row('Settlement', 'anchor-bound to Bitcoin; reverts only if Bitcoin reverts'),
        ]),
      ),
    ];
  }

  Widget _checkButton(Future<void> Function() onTap) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: GhostButton(label: 'Check now', onPressed: _busy ? null : () => onTap()),
      );

  Widget _txRow(String label, String txid, {required bool parent}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: txid));
            _snack('$label txid copied');
          },
          child: _Row(label, '${txid.substring(0, 16)}…  (copy)'),
        ),
      );

  String _stepLabel(RStep s) => switch (s) {
        RStep.rQuoted => 'Quoted',
        RStep.btcLocked => 'Maker locked BTC',
        RStep.btcConfirmed => 'BTC lock confirmed',
        RStep.seqFunding => 'Locking your asset',
        RStep.seqSubmitted => 'Asset locked',
        RStep.seqClaimed => 'Secret revealed',
        RStep.btcClaimed => 'Complete',
        RStep.refunded => 'Refunded',
        RStep.failed => 'Failed',
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
