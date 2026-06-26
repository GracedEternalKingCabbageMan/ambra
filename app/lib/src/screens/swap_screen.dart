import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/api_client.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../data/price_service.dart';
import '../data/seqdex_client.dart';
import '../data/swap_service.dart';
import '../data/wallet_repository.dart';
import '../rust/api.dart' as core;
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'xchain_swap_screen.dart';

/// SeqDEX same-chain swap: pay one Sequentia asset, receive another. (Cross-chain
/// BTC<->asset swaps are a later phase.) One composer — pick what you pay + an
/// amount, pick what you receive, and the daemon's preview fills the rest.
class SwapTab extends StatefulWidget {
  const SwapTab({super.key, this.isActive = false});
  final bool isActive;
  @override
  State<SwapTab> createState() => _SwapTabState();
}

class _SwapTabState extends State<SwapTab> {
  final _payAmount = TextEditingController();
  List<Market> _markets = [];
  List<core.AssetBalance> _balances = [];
  Map<String, BigInt> _feeRates = {};
  String? _payAsset;
  String? _receiveAsset;
  SwapQuote? _quote;
  bool _loading = true;
  bool _quoting = false;
  String? _error; // load error
  String? _quoteError; // per-quote error

  @override
  void initState() {
    super.initState();
    _payAmount.addListener(_onAmountChanged);
    _load();
  }

  @override
  void didUpdateWidget(SwapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _load();
  }

  @override
  void dispose() {
    _payAmount.removeListener(_onAmountChanged);
    _payAmount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      try {
        final rates = await ApiClient.feeRates();
        if (mounted && rates.isNotEmpty) _feeRates = rates;
      } catch (_) {/* default fee still works */}
      final markets = await SeqdexClient.markets();
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      if (!mounted) return;
      setState(() {
        _markets = markets;
        _balances = s.balances;
        _error = null;
        _loading = false;
        // Default the pay side to a held, tradable asset; clear stale picks.
        final pays = _payableAssets();
        if (_payAsset == null || !pays.contains(_payAsset)) _payAsset = pays.isNotEmpty ? pays.first : null;
        _reconcileReceive();
      });
      _requote();
    } catch (e) {
      if (mounted) {
        setState(() {
          if (_markets.isEmpty) _error = friendlyError(e, pullToRefresh: false);
          _loading = false;
        });
      }
    }
  }

  // --- asset sets ------------------------------------------------------------

  String _bal(String hex) {
    for (final b in _balances) {
      if (b.assetId == hex) return b.atoms;
    }
    return '0';
  }

  bool _holds(String hex) => (BigInt.tryParse(_bal(hex)) ?? BigInt.zero) > BigInt.zero;

  /// Every asset that trades against [other] (or every tradable asset if null).
  Set<String> _counterparts(String? other) {
    final set = <String>{};
    for (final m in _markets) {
      if (other == null) {
        set.add(m.baseAsset);
        set.add(m.quoteAsset);
      } else {
        if (m.baseAsset == other) set.add(m.quoteAsset);
        if (m.quoteAsset == other) set.add(m.baseAsset);
      }
    }
    return set;
  }

  /// Held assets that trade in some market — the candidates you can pay with.
  List<String> _payableAssets() => _counterparts(null).where(_holds).toList();

  /// Assets that trade against the chosen pay asset.
  List<String> _receivableAssets() => _counterparts(_payAsset).where((h) => h != _payAsset).toList();

  void _reconcileReceive() {
    final recv = _receivableAssets();
    if (_receiveAsset == null || !recv.contains(_receiveAsset)) {
      _receiveAsset = recv.isNotEmpty ? recv.first : null;
    }
  }

  // --- fee asset -------------------------------------------------------------

  bool _acceptedFee(String hex) {
    if (hex == SeqAssets.policy) return true; // native is always protocol-accepted
    final t = SeqAssets.labelFor(hex).ticker;
    return _feeRates[t] != null || _feeRates[hex] != null;
  }

  /// Default the fee to the asset you're paying with (no asset privileged), else
  /// tSEQ. Folded into the pay leg when it equals the pay asset.
  String _effectiveFeeAsset() {
    if (_payAsset != null && _acceptedFee(_payAsset!)) return _payAsset!;
    return SeqAssets.policy;
  }

  // --- routing + quoting -----------------------------------------------------

  /// Find the market + side for pay->receive. SELL = pay is base; BUY = pay is quote.
  ({Market market, String side})? _route() {
    final pay = _payAsset, recv = _receiveAsset;
    if (pay == null || recv == null || pay == recv) return null;
    for (final m in _markets) {
      if (m.baseAsset == pay && m.quoteAsset == recv) return (market: m, side: 'SELL');
      if (m.quoteAsset == pay && m.baseAsset == recv) return (market: m, side: 'BUY');
    }
    return null;
  }

  void _onAmountChanged() {
    setState(() {
      _quote = null;
      _quoteError = null;
    });
    _debounce(_requote);
  }

  int _reqSeq = 0;
  void _debounce(void Function() fn) {
    final my = ++_reqSeq;
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (my == _reqSeq && mounted) fn();
    });
  }

  Future<void> _requote() async {
    final route = _route();
    final payHex = _payAsset;
    if (route == null || payHex == null) {
      setState(() => _quote = null);
      return;
    }
    final payPrec = SeqAssets.labelFor(payHex).precision;
    final payAtoms = parseAtoms(_payAmount.text, payPrec);
    if (payAtoms == null || payAtoms <= BigInt.zero) {
      setState(() => _quote = null);
      return;
    }
    final my = ++_reqSeq;
    setState(() {
      _quoting = true;
      _quoteError = null;
    });
    try {
      final m = route.market;
      final side = route.side;
      final feeAsset = _effectiveFeeAsset();
      final basePrec = SeqAssets.labelFor(m.baseAsset).precision;
      final quotePrec = SeqAssets.labelFor(m.quoteAsset).precision;

      // PreviewTrade is parameterised by the BASE-leg amount. If the user typed the
      // base asset (SELL), use it; if they typed the quote asset (BUY), convert via
      // the market price first.
      BigInt baseAtoms;
      if (side == 'SELL') {
        baseAtoms = payAtoms; // pay == base
      } else {
        final bp = await SeqdexClient.basePrice(m, feeAsset); // quote units per 1 base
        final quoteUnits = payAtoms.toDouble() / _pow10(quotePrec);
        final baseUnits = quoteUnits / bp;
        final v = (baseUnits * _pow10(basePrec)).round();
        baseAtoms = BigInt.from(v < 1 ? 1 : v);
      }

      final preview = await SeqdexClient.preview(m, side, baseAtoms, feeAsset);

      // Orient the legs (proven 6d-1 mapping).
      final SwapQuote q;
      if (side == 'SELL') {
        q = SwapQuote(
          market: m, side: side,
          assetP: m.baseAsset, amountP: baseAtoms,
          assetR: preview.counterAsset, amountR: preview.counterAtoms,
          feeAsset: preview.feeAsset, feeAmount: preview.feeAmount,
        );
      } else {
        q = SwapQuote(
          market: m, side: side,
          assetP: preview.counterAsset, amountP: preview.counterAtoms,
          assetR: m.baseAsset, amountR: baseAtoms,
          feeAsset: preview.feeAsset, feeAmount: preview.feeAmount,
        );
      }
      if (my != _reqSeq || !mounted) return; // a newer request superseded this one
      setState(() {
        _quote = q;
        _quoting = false;
      });
    } catch (e) {
      if (my != _reqSeq || !mounted) return;
      setState(() {
        _quote = null;
        _quoting = false;
        _quoteError = 'Quote failed: ${_short(e)}';
      });
    }
  }

  double _pow10(int n) {
    var v = 1.0;
    for (var i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }

  String _short(Object e) {
    final s = e.toString().replaceFirst('Exception: ', '');
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(ambraSnack(m));

  // --- pickers ---------------------------------------------------------------

  Future<void> _pickPay() async {
    final picked = await _assetSheet('Pay with', _payableAssets(), withBalance: true);
    if (picked != null) {
      setState(() {
        _payAsset = picked;
        _reconcileReceive();
        _quote = null;
      });
      _requote();
    }
  }

  Future<void> _pickReceive() async {
    final recv = _receivableAssets();
    if (recv.isEmpty) return _snack('Nothing trades against ${_tk(_payAsset)} yet');
    final picked = await _assetSheet('Receive', recv);
    if (picked != null) {
      setState(() {
        _receiveAsset = picked;
        _quote = null;
      });
      _requote();
    }
  }

  Future<String?> _assetSheet(String title, List<String> ids, {bool withBalance = false}) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(title, style: AmbraText.title)),
          if (ids.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('No assets available.', style: AmbraText.muted)),
          for (final id in ids)
            ListTile(
              title: Text(SeqAssets.labelFor(id).ticker, style: AmbraText.body),
              subtitle: SeqAssets.labelFor(id).subtitle != null
                  ? Text(SeqAssets.labelFor(id).subtitle!, style: AmbraText.sub)
                  : null,
              trailing: withBalance
                  ? Text(formatAtoms(_bal(id), SeqAssets.labelFor(id).precision), style: AmbraText.mono)
                  : null,
              onTap: () => Navigator.pop(context, id),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  String _tk(String? hex) => hex == null ? '—' : SeqAssets.labelFor(hex).ticker;

  String _amtStr(String hex, BigInt atoms) {
    final l = SeqAssets.labelFor(hex);
    return '${formatAtoms(atoms.toString(), l.precision)} ${l.ticker}';
  }

  String? _refStr(String hex, BigInt atoms) {
    final l = SeqAssets.labelFor(hex);
    final v = PriceService.instance.refValue(l.ticker, atoms.toString(), l.precision);
    return v == null ? null : '≈ ${PriceService.instance.fmtRef(v)} ${PriceService.instance.ref}';
  }

  Future<void> _review() async {
    final q = _quote;
    if (q == null) return _snack('Enter an amount to get a quote first');
    final payBal = BigInt.tryParse(_bal(q.assetP)) ?? BigInt.zero;
    // The fee folds into the pay leg when it's the same asset, so require both.
    final need = q.feeAsset == q.assetP ? q.amountP + q.feeAmount : q.amountP;
    if (need > payBal) return _snack('Not enough ${_tk(q.assetP)} for the swap${q.feeAsset == q.assetP ? ' + fee' : ''}');
    if (q.feeAsset != q.assetP) {
      final feeBal = BigInt.tryParse(_bal(q.feeAsset)) ?? BigInt.zero;
      if (feeBal < q.feeAmount) return _snack('Not enough ${_tk(q.feeAsset)} to pay the fee');
    }
    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _SwapReviewSheet(quote: q),
    );
    if (txid != null && mounted) {
      _payAmount.clear();
      setState(() => _quote = null);
      ScaffoldMessenger.of(context).showSnackBar(ambraSnack(
        'Swapped · ${txid.substring(0, 16)}…',
        action: SnackBarAction(
          label: 'Copy txid',
          textColor: AmbraColors.amber,
          onPressed: () => Clipboard.setData(ClipboardData(text: txid)),
        ),
      ));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pays = _payableAssets();
    final canSwap = !_loading && _error == null && _quote != null && !_quoting;
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
          const Text('Swap', style: AmbraText.h1),
          const SizedBox(height: 6),
          const Text('Trade one Sequentia asset for another at the SeqDEX maker rate.', style: AmbraText.sub),
          const SizedBox(height: 12),
          SecondaryButton(
            label: 'Buy with Bitcoin (cross-chain)',
            icon: Icons.currency_bitcoin,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const XchainSwapScreen())),
          ),
          const SizedBox(height: 20),
          if (_loading)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
          else if (_error != null)
            AmbraCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(_error!, style: const TextStyle(color: AmbraColors.red)),
                const SizedBox(height: 14),
                SecondaryButton(label: 'Retry', icon: Icons.refresh, onPressed: _load),
              ]),
            )
          else if (_markets.isEmpty)
            const AmbraCard(child: Text('No markets are open right now. Check back shortly.', style: AmbraText.muted))
          else if (pays.isEmpty)
            const AmbraCard(
                child: Text('You hold no assets that trade yet. Receive a tradable asset, or use the faucet (More tab).',
                    style: AmbraText.muted))
          else ...[
            const SectionLabel('You pay'),
            const SizedBox(height: 8),
            _PickerRow(
              label: _tk(_payAsset),
              trailing: _payAsset == null
                  ? null
                  : 'balance ${formatAtoms(_bal(_payAsset!), SeqAssets.labelFor(_payAsset!).precision)}',
              onTap: _pickPay,
            ),
            const SizedBox(height: 12),
            AmbraField(label: 'Amount (${_tk(_payAsset)})', controller: _payAmount, hint: '0.0'),
            const SizedBox(height: 18),
            Center(child: Icon(Icons.arrow_downward, color: AmbraColors.dim, size: 22)),
            const SizedBox(height: 18),
            const SectionLabel('You receive'),
            const SizedBox(height: 8),
            _PickerRow(label: _tk(_receiveAsset), onTap: _pickReceive),
            const SizedBox(height: 18),
            AmbraCard(
              child: _quoting
                  ? const Row(children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AmbraColors.amber)),
                      SizedBox(width: 12),
                      Text('Quoting…', style: AmbraText.muted),
                    ])
                  : _quoteError != null
                      ? Text(_quoteError!, style: const TextStyle(color: AmbraColors.red))
                      : _quote == null
                          ? const Text('Enter an amount to see a rate.', style: AmbraText.muted)
                          : _QuoteView(quote: _quote!, amt: _amtStr, ref: _refStr),
            ),
          ],
        ]),
      ),
      if (canSwap)
        BottomActionBar(children: [
          PrimaryButton(label: 'Review & swap', icon: Icons.swap_horiz, onPressed: _review),
        ]),
    ]);
  }
}

class _QuoteView extends StatelessWidget {
  const _QuoteView({required this.quote, required this.amt, required this.ref});
  final SwapQuote quote;
  final String Function(String, BigInt) amt;
  final String? Function(String, BigInt) ref;

  @override
  Widget build(BuildContext context) {
    final payL = SeqAssets.labelFor(quote.assetP);
    final recvL = SeqAssets.labelFor(quote.assetR);
    final payU = quote.amountP.toDouble() / _p(payL.precision);
    final recvU = quote.amountR.toDouble() / _p(recvL.precision);
    final rate = payU > 0 ? (recvU / payU) : 0;
    final recvRef = ref(quote.assetR, quote.amountR);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Text('You receive', style: AmbraText.sub),
        const Spacer(),
        Text(amt(quote.assetR, quote.amountR),
            style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontSize: 15, fontWeight: FontWeight.w700)),
      ]),
      if (recvRef != null)
        Padding(padding: const EdgeInsets.only(top: 2), child: Align(alignment: Alignment.centerRight, child: Text(recvRef, style: AmbraText.sub))),
      const Divider(height: 20, color: AmbraColors.line),
      _kv('Rate', '1 ${payL.ticker} = ${_trim(rate)} ${recvL.ticker}'),
      _kv('Network fee', amt(quote.feeAsset, quote.feeAmount)),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text('Settles in ~1 block · anchor-bound to Bitcoin (reverts only if Bitcoin reverts).', style: AmbraText.sub),
      ),
    ]);
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [Text(k, style: AmbraText.sub), const Spacer(), Text(v, style: AmbraText.body)]),
      );

  static double _p(int n) {
    var v = 1.0;
    for (var i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }

  static String _trim(num n) {
    if (!n.isFinite) return '—';
    final r = (n * 1e8).round() / 1e8;
    return r.toString();
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({required this.label, this.trailing, this.onTap});
  final String label;
  final String? trailing;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AmbraRadii.input),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AmbraColors.panelDeep,
          border: Border.all(color: AmbraColors.line),
          borderRadius: BorderRadius.circular(AmbraRadii.input),
        ),
        child: Row(children: [
          Text(label, style: AmbraText.body),
          const Spacer(),
          if (trailing != null) Text(trailing!, style: AmbraText.sub),
          const SizedBox(width: 8),
          const Icon(Icons.expand_more, color: AmbraColors.dim, size: 20),
        ]),
      ),
    );
  }
}

/// Confirm + run a same-chain swap (propose → sign → complete). The amounts are
/// fixed from the quote shown; on confirm we authenticate, then execute.
class _SwapReviewSheet extends StatefulWidget {
  const _SwapReviewSheet({required this.quote});
  final SwapQuote quote;
  @override
  State<_SwapReviewSheet> createState() => _SwapReviewSheetState();
}

class _SwapReviewSheetState extends State<_SwapReviewSheet> {
  bool _busy = false;
  String _status = '';
  String? _error;

  String _amt(String hex, BigInt atoms) {
    final l = SeqAssets.labelFor(hex);
    return '${formatAtoms(atoms.toString(), l.precision)} ${l.ticker}';
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Authenticating…';
    });
    try {
      final ok = await WalletRepository.instance.requirePaymentAuth();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication failed or cancelled; swap not sent.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      setState(() => _status = 'Proposing & signing…');
      final txid = await SwapService.execute(m, widget.quote);
      if (mounted) Navigator.pop(context, txid);
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
    final q = widget.quote;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Review swap', style: AmbraText.h1),
          const SizedBox(height: 18),
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              _Row('You pay', _amt(q.assetP, q.amountP)),
              _Row('You receive', _amt(q.assetR, q.amountR)),
              _Row('Network fee', _amt(q.feeAsset, q.feeAmount)),
              _Row('Settlement', 'Atomic — settles in full or not at all.'),
              _Row('Finality', 'Anchor-bound to Bitcoin (reverts only if Bitcoin reverts).'),
            ]),
          ),
          const SizedBox(height: 14),
          if (_busy && _status.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_status, style: AmbraText.muted)),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(label: 'Confirm & swap', busy: _busy, icon: Icons.fingerprint, onPressed: _busy ? null : _confirm),
          const SizedBox(height: 6),
          GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        ]),
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
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 96, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: AmbraText.body)),
        ]),
      );
}
