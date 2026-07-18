import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api_client.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../data/lightning_service.dart';
import '../data/placed_orders.dart';
import '../data/seqdex_client.dart';
import '../data/seqob_client.dart';
import '../data/wallet_repository.dart';
import '../rust/api.dart' as core;
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'lightning_swap_screen.dart';
import 'xchain_reverse_swap_screen.dart';
import 'xchain_swap_screen.dart';

/// Estimated vByte size of a same-chain settlement tx, used to turn the optional
/// per-vB fee rate into a fee amount. Errs generous; the fee is shown for review.
const int _kSwapVbytes = 3000;

/// Default network fee, in native sat/vB, when the user doesn't override it.
const double _kDefaultSatPerVb = 0.5;

/// 1e8 = exchange_rate_scale (native atoms per reference unit).
final BigInt _kScale = BigInt.from(100000000);

/// SeqOB same-chain order book: TAKE (lift a resting covenant offer) or POST (rest
/// your own signed LIMIT order). Pay one Sequentia asset, receive another, settled
/// by the passive covenant CLOB ("the order is the coin"). Cross-chain BTC swaps
/// and the Lightning rail live behind the buttons at the top.
class SwapTab extends StatefulWidget {
  const SwapTab({super.key, this.isActive = false});
  final bool isActive;
  @override
  State<SwapTab> createState() => _SwapTabState();
}

/// Cross-reload cache so returning from background renders instantly.
class _SwapCache {
  static List<Market>? markets;
  static List<core.AssetBalance>? balances;
  static Map<String, BigInt>? feeRates;
  static String? payAsset;
  static String? receiveAsset;

  /// A monotonic maker-payout index seed (avoids taproot credit collisions
  /// between resting orders within a session).
  static int makerIndexSeed = DateTime.now().millisecondsSinceEpoch % 100000;
}

class _SwapTabState extends State<SwapTab> {
  final _payAmount = TextEditingController();
  final _recvAmount = TextEditingController();
  final _feeRateCtl = TextEditingController();

  List<Market> _markets = [];
  List<core.AssetBalance> _balances = [];
  Map<String, BigInt> _feeRates = {};
  int _tipHeight = 0;

  String? _payAsset;
  String? _receiveAsset;
  String? _feeAsset; // null => default (the paid asset)

  // Book namespace: Unblinded (transparent, the default, byte-identical to the
  // live covenant rail) vs Blinded (confidential). The Blinded book routes to the
  // relay's segregated confidential namespace (?confidential=1 / the signed
  // field-19 `confidential:true` tag) that matches confidential-vs-confidential
  // only, so BOTH swap legs blind on-chain. Persisted wallet-wide.
  static const _bookPrefKey = 'ambra.dex.book';
  String _book = 'public';
  bool get _confBook => _book == 'confidential';

  // Composer mode. TAKE lifts resting offers (fields LINKED by book price); POST
  // rests a LIMIT order at your OWN price (fields INDEPENDENT). Auto-defaults to
  // POST on an empty book so a market can be started; `_modeTouched` stops that.
  String _mode = 'take';
  bool _modeTouched = false;
  String _edited = 'pay'; // which amount the user last typed

  OrderBook? _orderBook;
  SeqObOffer? _selected;

  bool _loading = true;
  bool _bookLoading = false;
  String? _error;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _payAmount.addListener(_onPayChanged);
    _recvAmount.addListener(_onRecvChanged);
    if (_SwapCache.markets != null) {
      _markets = _SwapCache.markets!;
      _balances = _SwapCache.balances ?? [];
      _feeRates = _SwapCache.feeRates ?? {};
      _payAsset = _SwapCache.payAsset;
      _receiveAsset = _SwapCache.receiveAsset;
      _loading = false;
    }
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(_bookPrefKey);
      if (mounted) setState(() => _book = v == 'confidential' ? 'confidential' : 'public');
    } catch (_) {/* default to the transparent book */}
    await _load();
  }

  /// Switch the active book namespace. Distinct order sets: the composer reloads
  /// from the selected namespace and posts into it. Blinded is Sequentia-only and
  /// interactive-only (no covenant to lift), so it forces POST-mode.
  Future<void> _setBook(String next) async {
    next = next == 'confidential' ? 'confidential' : 'public';
    if (next == _book) return;
    setState(() {
      _book = next;
      _selected = null;
      _modeTouched = false;
      if (_confBook) _mode = 'post'; // Blinded book: post-only (lift needs co-sign).
      _actionError = null;
    });
    try {
      (await SharedPreferences.getInstance()).setString(_bookPrefKey, next);
    } catch (_) {/* the toggle still works this session */}
    _fetchBook();
  }

  @override
  void didUpdateWidget(SwapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _load();
  }

  @override
  void dispose() {
    _payAmount.removeListener(_onPayChanged);
    _recvAmount.removeListener(_onRecvChanged);
    _payAmount.dispose();
    _recvAmount.dispose();
    _feeRateCtl.dispose();
    super.dispose();
  }

  void _cache() {
    _SwapCache.markets = _markets;
    _SwapCache.balances = _balances;
    _SwapCache.feeRates = _feeRates;
    _SwapCache.payAsset = _payAsset;
    _SwapCache.receiveAsset = _receiveAsset;
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
        _tipHeight = s.tipHeight;
        _error = null;
        _loading = false;
        final pays = _payableAssets();
        if (_payAsset == null || !pays.contains(_payAsset)) _payAsset = pays.isNotEmpty ? pays.first : null;
        _reconcileReceive();
      });
      _cache();
      _fetchBook();
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
    if (hex == SeqAssets.policy) return true;
    final t = SeqAssets.labelFor(hex).ticker;
    return _feeRates[t] != null || _feeRates[hex] != null;
  }

  BigInt _rateFor(String hex) {
    // Read tSEQ's rate from the /feerates feed like every other asset — no SEQ=1 privilege (principle 3).
    // The numeraire is a sovereign per-producer config; fall back to the reference scale ONLY when the
    // feed doesn't price tSEQ (i.e. when tSEQ IS the reference), never as a hardcoded assumption.
    final t = SeqAssets.labelFor(hex).ticker;
    return _feeRates[t] ?? _feeRates[hex] ?? _kScale;
  }

  String _defaultFeeAsset() => (_payAsset != null && _acceptedFee(_payAsset!)) ? _payAsset! : SeqAssets.policy;

  String get _feeAssetHex => _feeAsset ?? _defaultFeeAsset();

  List<String> _heldAssets() =>
      _balances.where((b) => (BigInt.tryParse(b.atoms) ?? BigInt.zero) > BigInt.zero).map((b) => b.assetId).toList();

  List<String> _feeOptions() {
    final set = <String>{};
    if (_payAsset != null) set.add(_payAsset!);
    set.addAll(_heldAssets());
    set.add(SeqAssets.policy);
    return set.where(_acceptedFee).toList();
  }

  /// The fee asset actually used for a TAKE: it must NOT be the covenant's sold
  /// asset A (= what the taker receives), which the fill builder rejects.
  String _takeFeeAsset() {
    final chosen = _feeAssetHex;
    if (chosen != _receiveAsset) return chosen;
    if (_payAsset != null && _acceptedFee(_payAsset!) && _payAsset != _receiveAsset) return _payAsset!;
    return SeqAssets.policy == _receiveAsset ? (_payAsset ?? SeqAssets.policy) : SeqAssets.policy;
  }

  /// The network fee, in the given fee asset, from the (optional) per-vB override
  /// or the default rate — the same open-fee-market model as Send.
  BigInt _feeAtomsFor(String feeAsset) {
    final feeRate = _rateFor(feeAsset);
    final fr = double.tryParse(_feeRateCtl.text.trim());
    if (fr != null && fr > 0) {
      final feePrec = SeqAssets.labelFor(feeAsset).precision;
      return BigInt.from((fr * _kSwapVbytes * _pow10(feePrec)).ceil());
    }
    final nativeFee = BigInt.from((_kSwapVbytes * _kDefaultSatPerVb).ceil());
    final f = (nativeFee * _kScale + feeRate - BigInt.one) ~/ feeRate;
    return f <= BigInt.zero ? BigInt.one : f;
  }

  // --- book ------------------------------------------------------------------

  /// The book for the current direction: resting covenant SELLs of the receive
  /// asset (base) for the pay asset (quote) — the offers a TAKE lifts.
  Future<void> _fetchBook() async {
    final pay = _payAsset, recv = _receiveAsset;
    if (pay == null || recv == null || pay == recv) {
      setState(() {
        _orderBook = null;
        _selected = null;
      });
      return;
    }
    setState(() => _bookLoading = true);
    try {
      final book = await SeqObClient.fetchBook(recv, pay, confidential: _confBook);
      if (!mounted) return;
      setState(() {
        _orderBook = book;
        // Blinded offers rest as interactive intents (no covenant to lift), so
        // they are never auto-selected for a TAKE.
        _selected = _confBook ? null : book.best;
        _bookLoading = false;
        if (_confBook) {
          _mode = 'post'; // Blinded book: post-only until the co-sign courier lands.
        } else if (!_modeTouched) {
          _mode = book.isEmpty ? 'post' : 'take';
        }
      });
      _relink();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _orderBook = null;
        _selected = null;
        _bookLoading = false;
        // A missing book is not an error — it just means POST to start the market.
        _mode = 'post';
      });
    }
  }

  // --- amount linking (TAKE only) --------------------------------------------

  bool _linking = false;

  void _onPayChanged() {
    if (_linking) return;
    _edited = 'pay';
    setState(() => _actionError = null);
    if (_mode == 'take') _linkFrom('pay');
  }

  void _onRecvChanged() {
    if (_linking) return;
    _edited = 'receive';
    setState(() => _actionError = null);
    if (_mode == 'take') _linkFrom('receive');
  }

  /// In TAKE, the pay/receive fields are linked by the selected offer's price;
  /// never overwrite the field the user is typing.
  void _linkFrom(String edited) {
    final o = _selected;
    if (o == null || o.baseAtoms <= BigInt.zero) return;
    final payPrec = SeqAssets.labelFor(_payAsset!).precision;
    final recvPrec = SeqAssets.labelFor(_receiveAsset!).precision;
    // price = pay(quote) per receive(base), in DISPLAY units.
    final price = (o.wantAtoms.toDouble() / _pow10(payPrec)) / (o.baseAtoms.toDouble() / _pow10(recvPrec));
    if (!(price > 0)) return;
    _linking = true;
    if (edited == 'receive') {
      final v = double.tryParse(_recvAmount.text.trim());
      if (v != null && v > 0) _payAmount.text = _trim(v * price);
    } else {
      final v = double.tryParse(_payAmount.text.trim());
      if (v != null && v > 0) _recvAmount.text = _trim(v / price);
    }
    _linking = false;
  }

  void _relink() {
    if (_mode == 'take') _linkFrom(_edited);
  }

  // --- pickers ---------------------------------------------------------------

  Future<void> _pickPay() async {
    final picked = await _assetSheet('Pay with', _payableAssets(), withBalance: true);
    if (picked != null) {
      setState(() {
        _payAsset = picked;
        _reconcileReceive();
        _feeAsset = null;
        _feeRateCtl.clear();
      });
      _cache();
      _fetchBook();
    }
  }

  Future<void> _pickReceive() async {
    final recv = _receivableAssets();
    if (recv.isEmpty) return _snack('Nothing trades against ${_tk(_payAsset)} yet');
    final picked = await _assetSheet('Receive', recv);
    if (picked != null) {
      setState(() => _receiveAsset = picked);
      _cache();
      _fetchBook();
    }
  }

  Future<void> _pickFee() async {
    final picked = await _assetSheet('Pay fee in', _feeOptions(), withBalance: true);
    if (picked != null) setState(() => _feeAsset = picked);
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

  // --- actions ---------------------------------------------------------------

  Future<void> _submit() async {
    if (_confBook) {
      await _confPost();
    } else if (_mode == 'take') {
      await _take();
    } else {
      await _post();
    }
  }

  /// Rest a CONFIDENTIAL (blinded) same-chain offer. Unlike the transparent
  /// covenant POST, a confidential offer is NOT funded on-chain: it rests as an
  /// interactive intent carrying a blinded (blech32) receive address + its
  /// blinding pubkey and the signed `confidential:true` (field-19) tag. A taker
  /// fills it by co-signing a blinded PSET over the courier — the piece Ambra
  /// does not have yet (see the on-screen note + openIssues), so for now the
  /// offer rests and reads confidentially but is not lifted from Ambra.
  Future<void> _confPost() async {
    final pay = _payAsset, recv = _receiveAsset;
    if (pay == null || recv == null) return _snack('Pick what you pay and receive');
    final payPrec = SeqAssets.labelFor(pay).precision;
    final recvPrec = SeqAssets.labelFor(recv).precision;
    final sellAtoms = parseAtoms(_payAmount.text, payPrec);
    final buyAtoms = parseAtoms(_recvAmount.text, recvPrec);
    if (sellAtoms == null || sellAtoms <= BigInt.zero) return _snack('Enter how much ${_tk(pay)} to sell');
    if (buyAtoms == null || buyAtoms <= BigInt.zero) return _snack('Enter your price: how much ${_tk(recv)} you want');
    final payBal = BigInt.tryParse(_bal(pay)) ?? BigInt.zero;
    if (sellAtoms > payBal) return _snack('Not enough ${_tk(pay)} to rest this order');

    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _ConfPostReviewSheet(
        payAsset: pay,
        sellAtoms: sellAtoms,
        recvAsset: recv,
        buyAtoms: buyAtoms,
        feeAsset: _feeAssetHex,
      ),
    );
    if (txid != null && mounted) {
      _payAmount.clear();
      _recvAmount.clear();
      ScaffoldMessenger.of(context).showSnackBar(ambraSnack('Blinded offer posted · rests confidentially'));
      _fetchBook();
    }
  }

  Future<void> _take() async {
    final o = _selected;
    final pay = _payAsset, recv = _receiveAsset;
    if (o == null || pay == null || recv == null) return _snack('No resting offer to lift');
    final recvPrec = SeqAssets.labelFor(recv).precision;
    final takeAtoms = parseAtoms(_recvAmount.text, recvPrec);
    if (takeAtoms == null || takeAtoms <= BigInt.zero) return _snack('Enter how much ${_tk(recv)} to buy');
    var take = takeAtoms;
    if (take > o.baseAtoms) take = o.baseAtoms; // cap to the offer's available size

    final feeAsset = _takeFeeAsset();
    final feeAtoms = _feeAtomsFor(feeAsset);
    final payAtoms = _quotePayFor(o, take); // covenant-enforced ceil price
    final feeInPay = feeAsset == pay;
    final payBal = BigInt.tryParse(_bal(pay)) ?? BigInt.zero;
    final need = feeInPay ? payAtoms + feeAtoms : payAtoms;
    if (need > payBal) return _snack('Not enough ${_tk(pay)} to lift this offer${feeInPay ? ' + fee' : ''}');
    if (!feeInPay && (BigInt.tryParse(_bal(feeAsset)) ?? BigInt.zero) < feeAtoms) {
      return _snack('Not enough ${_tk(feeAsset)} to pay the fee');
    }

    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _TakeReviewSheet(
        offer: o,
        payAsset: pay,
        payAtoms: payAtoms,
        recvAsset: recv,
        recvAtoms: take,
        feeAsset: feeAsset,
        feeAtoms: feeAtoms,
      ),
    );
    if (txid != null && mounted) _onSettled(txid, 'Lifted');
  }

  Future<void> _post() async {
    final pay = _payAsset, recv = _receiveAsset;
    if (pay == null || recv == null) return _snack('Pick what you pay and receive');
    final payPrec = SeqAssets.labelFor(pay).precision;
    final recvPrec = SeqAssets.labelFor(recv).precision;
    final sellAtoms = parseAtoms(_payAmount.text, payPrec);
    final buyAtoms = parseAtoms(_recvAmount.text, recvPrec);
    if (sellAtoms == null || sellAtoms <= BigInt.zero) return _snack('Enter how much ${_tk(pay)} to sell');
    if (buyAtoms == null || buyAtoms <= BigInt.zero) return _snack('Enter your price: how much ${_tk(recv)} you want');
    final payBal = BigInt.tryParse(_bal(pay)) ?? BigInt.zero;
    if (sellAtoms > payBal) return _snack('Not enough ${_tk(pay)} to rest this order');

    final feeAsset = _feeAssetHex;
    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _PostReviewSheet(
        payAsset: pay,
        sellAtoms: sellAtoms,
        recvAsset: recv,
        buyAtoms: buyAtoms,
        feeAsset: feeAsset,
        feeAtoms: _feeAtomsFor(feeAsset),
        feeRate: _rateFor(feeAsset),
        tipHeight: _tipHeight,
      ),
    );
    if (txid != null && mounted) _onSettled(txid, 'Rested', clearBoth: true);
  }

  void _onSettled(String txid, String verb, {bool clearBoth = false}) {
    _payAmount.clear();
    if (clearBoth) _recvAmount.clear();
    ScaffoldMessenger.of(context).showSnackBar(ambraSnack(
      '$verb · ${txid.substring(0, txid.length < 16 ? txid.length : 16)}…',
      action: SnackBarAction(
        label: 'Copy txid',
        textColor: AmbraColors.amber,
        onPressed: () => Clipboard.setData(ClipboardData(text: txid)),
      ),
    ));
    _load();
  }

  /// The covenant-enforced pay for taking `take` base atoms from offer `o`:
  /// ceil(take * wantAtoms / baseAtoms) of the quote asset.
  BigInt _quotePayFor(SeqObOffer o, BigInt take) {
    if (o.baseAtoms <= BigInt.zero) return BigInt.zero;
    final num = take * o.wantAtoms;
    return (num + o.baseAtoms - BigInt.one) ~/ o.baseAtoms;
  }

  // --- helpers ---------------------------------------------------------------

  double _pow10(int n) {
    var v = 1.0;
    for (var i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }

  // Amount for an INPUT field: 8dp, trailing zeros stripped, and NEVER sci-notation — double.toString()
  // switches to "1e-7" below 1e-6, which would make the amount field unparseable.
  String _trim(num n) {
    if (!n.isFinite) return '';
    final r = (n * 1e8).round() / 1e8;
    if (r == 0) return '0';
    var s = r.toStringAsFixed(8);
    if (s.contains('.')) s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return s;
  }

  // A DISPLAY price: magnitude-appropriate precision + thousands separators, never sci-notation, and
  // never a nonzero price rendered as "0" (a cheap asset priced in BTC). Use for prices/mids/spreads;
  // use formatAtoms/_trim for raw amounts written into fields.
  String _fmtPrice(num n) {
    if (!n.isFinite) return '—';
    if (n == 0) return '0';
    final a = n.abs();
    if (a < 1e-8) return '${n < 0 ? '-' : ''}<0.00000001';
    final dp = a >= 1000 ? 2 : (a >= 1 ? 4 : (a >= 0.01 ? 6 : 8));
    var s = n.toStringAsFixed(dp);
    if (s.contains('.')) s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return _group(s);
  }

  // Thousands-group the integer part of an already-formatted decimal string.
  String _group(String s) {
    var neg = false;
    if (s.startsWith('-')) {
      neg = true;
      s = s.substring(1);
    }
    final dot = s.indexOf('.');
    final intPart = dot < 0 ? s : s.substring(0, dot);
    final frac = dot < 0 ? '' : s.substring(dot);
    final grouped = intPart.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    return (neg ? '-' : '') + grouped + frac;
  }

  String _tk(String? hex) => hex == null ? '—' : SeqAssets.labelFor(hex).ticker;

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(ambraSnack(m));

  @override
  Widget build(BuildContext context) {
    final pays = _payableAssets();
    final book = _orderBook;
    final canAct = !_loading && _error == null && _payAsset != null && _receiveAsset != null;
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
          const Text('Swap', style: AmbraText.h1),
          const SizedBox(height: 6),
          const Text('Lift a resting offer, or rest your own limit order on the SeqOB order book.',
              style: AmbraText.sub),
          const SizedBox(height: 12),
          SecondaryButton(
            label: 'Buy with Bitcoin (cross-chain)',
            icon: Icons.currency_bitcoin,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const XchainSwapScreen())),
          ),
          const SizedBox(height: 10),
          SecondaryButton(
            label: 'Sell for Bitcoin (cross-chain)',
            icon: Icons.currency_bitcoin,
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const XchainReverseSwapScreen())),
          ),
          ListenableBuilder(
            listenable: LightningService.instance,
            builder: (context, _) => LightningService.instance.available
                ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: SecondaryButton(
                      label: 'Instant (Lightning)',
                      icon: Icons.bolt,
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LightningSwapScreen())),
                    ),
                  )
                : const SizedBox.shrink(),
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
            _bookToggle(),
            const SizedBox(height: 12),
            if (_confBook) _confBookNote() else _modeToggle(),
            const SizedBox(height: 16),
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
            const SizedBox(height: 12),
            AmbraField(
              label: _mode == 'post' ? 'Your price — amount (${_tk(_receiveAsset)})' : 'Amount (${_tk(_receiveAsset)})',
              controller: _recvAmount,
              hint: _mode == 'post' ? 'how much you want' : '0.0',
            ),
            const SizedBox(height: 18),
            _bookPanel(book),
            const SizedBox(height: 18),
            const SectionLabel('Network fee'),
            const SizedBox(height: 8),
            _PickerRow(label: _tk(_feeAssetHex), trailing: 'any asset you hold', onTap: _pickFee),
            const SizedBox(height: 10),
            AmbraField(label: 'Fee rate (${_tk(_feeAssetHex)}/vB, optional)', controller: _feeRateCtl, hint: 'suggested'),
            const SizedBox(height: 8),
            Text(
              _confBook
                  ? 'A blinded offer rests confidentially (no on-chain funding); a taker fills it later by co-signing a blinded swap. Fee terms apply when it settles.'
                  : _mode == 'take'
                      ? 'Fee paid in the asset you pay (never the asset you receive). Leave the rate blank for the suggested fee.'
                      : 'Resting your order funds a covenant on-chain, then posts it to the relay. Cancel anytime; reclaim the funds after expiry.',
              style: AmbraText.sub,
            ),
            if (_actionError != null) ...[
              const SizedBox(height: 12),
              Text(_actionError!, style: const TextStyle(color: AmbraColors.red)),
            ],
          ],
        ]),
      ),
      if (canAct)
        BottomActionBar(children: [
          PrimaryButton(
            label: _confBook
                ? 'Review & post (blinded)'
                : _mode == 'take'
                    ? 'Review & take'
                    : 'Review & post',
            icon: _confBook
                ? Icons.lock_outline
                : _mode == 'take'
                    ? Icons.swap_horiz
                    : Icons.playlist_add,
            onPressed: _submit,
          ),
        ]),
    ]);
  }

  /// Unblinded (transparent, default) vs Blinded (confidential) book namespace.
  Widget _bookToggle() {
    Widget seg(String value, String title) {
      final on = _book == value;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(AmbraRadii.input),
          onTap: () => _setBook(value),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            decoration: BoxDecoration(
              color: on ? AmbraColors.amber.withValues(alpha: 0.12) : AmbraColors.panelDeep,
              border: Border.all(color: on ? AmbraColors.amber : AmbraColors.line),
              borderRadius: BorderRadius.circular(AmbraRadii.input),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(value == 'confidential' ? Icons.lock_outline : Icons.visibility_outlined,
                  size: 16, color: on ? AmbraColors.amber : AmbraColors.dim),
              const SizedBox(width: 8),
              Text(title, style: AmbraText.body.copyWith(color: on ? AmbraColors.amber : AmbraColors.txt)),
            ]),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        seg('public', 'Unblinded'),
        const SizedBox(width: 10),
        seg('confidential', 'Blinded'),
      ]),
      const SizedBox(height: 8),
      Text(
        _confBook
            ? 'Blinded book: both legs settle confidentially (amounts and assets hidden on-chain). Sequentia assets only.'
            : 'Unblinded book: transparent settlement, the default.',
        style: AmbraText.sub,
      ),
    ]);
  }

  /// Post-only banner shown in the Blinded book (no covenant to lift; interactive
  /// filling needs the co-sign courier Ambra does not have yet).
  Widget _confBookNote() {
    return AmbraCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.lock_outline, size: 18, color: AmbraColors.amber),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Post a blinded offer', style: AmbraText.body.copyWith(color: AmbraColors.amber)),
            const SizedBox(height: 4),
            const Text(
              'Your offer rests confidentially with a blinded receive address. Lifting a blinded '
              'offer needs the maker online to co-sign (coming); resting and reading the blinded '
              'book work now.',
              style: AmbraText.sub,
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _modeToggle() {
    Widget seg(String value, String title, String subtitle) {
      final on = _mode == value;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(AmbraRadii.input),
          onTap: () {
            setState(() {
              _mode = value;
              _modeTouched = true;
            });
            _relink();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
            decoration: BoxDecoration(
              color: on ? AmbraColors.amber.withValues(alpha: 0.12) : AmbraColors.panelDeep,
              border: Border.all(color: on ? AmbraColors.amber : AmbraColors.line),
              borderRadius: BorderRadius.circular(AmbraRadii.input),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AmbraText.body.copyWith(color: on ? AmbraColors.amber : AmbraColors.txt)),
              const SizedBox(height: 2),
              Text(subtitle, style: AmbraText.sub),
            ]),
          ),
        ),
      );
    }

    return Row(children: [
      seg('take', 'Take · Market', 'lift a resting offer'),
      const SizedBox(width: 10),
      seg('post', 'Post · Limit', 'rest your own price'),
    ]);
  }

  Widget _bookPanel(OrderBook? book) {
    if (_bookLoading) {
      return const AmbraCard(
        child: Row(children: [
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AmbraColors.amber)),
          SizedBox(width: 12),
          Text('Loading the order book…', style: AmbraText.muted),
        ]),
      );
    }
    if (book == null || book.isEmpty) {
      return AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
              _confBook
                  ? 'No blinded offers for ${_tk(_receiveAsset)} / ${_tk(_payAsset)} yet.'
                  : 'No resting offers for ${_tk(_receiveAsset)} / ${_tk(_payAsset)} yet.',
              style: AmbraText.muted),
          const SizedBox(height: 6),
          Text(
              _confBook
                  ? 'Post a blinded offer to start this confidential market — you set the price.'
                  : 'Post a limit order to start this market — you set the price.',
              style: AmbraText.sub),
        ]),
      );
    }
    final recvPrec = SeqAssets.labelFor(_receiveAsset!).precision;
    final payPrec = SeqAssets.labelFor(_payAsset!).precision;
    final rows = book.offers.take(6).toList();
    return AmbraCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(_confBook ? 'Blinded book · ${_tk(_receiveAsset)}' : 'Order book · buy ${_tk(_receiveAsset)}',
              style: AmbraText.sub),
          const Spacer(),
          Text('depth ${formatAtoms(book.depthBaseAtoms.toString(), recvPrec)} ${_tk(_receiveAsset)}',
              style: AmbraText.sub),
        ]),
        const Divider(height: 16, color: AmbraColors.line),
        for (final o in rows) _bookRow(o, recvPrec, payPrec),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
              _confBook
                  ? 'Blinded resting offers (read-only). Lifting needs the maker online to co-sign (coming).'
                  : 'Settles in ~1 block · anchor-bound to Bitcoin (reverts only if Bitcoin reverts).',
              style: AmbraText.sub),
        ),
      ]),
    );
  }

  Widget _bookRow(SeqObOffer o, int recvPrec, int payPrec) {
    final on = identical(o, _selected);
    final price = (o.wantAtoms.toDouble() / _pow10(payPrec)) / (o.baseAtoms.toDouble() / _pow10(recvPrec));
    return InkWell(
      onTap: _mode == 'take'
          ? () {
              setState(() => _selected = o);
              _relink();
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(on && _mode == 'take' ? Icons.radio_button_checked : Icons.circle_outlined,
              size: 16, color: on ? AmbraColors.amber : AmbraColors.dim),
          const SizedBox(width: 10),
          Expanded(
            child: Text('${_fmtPrice(price)} ${_tk(_payAsset)}/${_tk(_receiveAsset)}',
                style: AmbraText.mono.copyWith(color: on ? AmbraColors.amber : AmbraColors.txt)),
          ),
          Text(formatAtoms(o.baseAtoms.toString(), recvPrec), style: AmbraText.mono),
          const SizedBox(width: 6),
          if (!o.verified)
            const Tooltip(message: 'signature unverified', child: Icon(Icons.warning_amber, size: 14, color: AmbraColors.red)),
        ]),
      ),
    );
  }
}

/// Resolve the funded vout for a covenant scriptPubKey on the wallet's esplora.
Future<int> resolveCovenantVout(String txid, String spkHex) async {
  final r = await http
      .get(Uri.parse('${Backend.esplora}/tx/$txid'), headers: {...Backend.authHeaders})
      .timeout(const Duration(seconds: 30));
  if (r.statusCode != 200) throw Exception('esplora /tx/$txid returned ${r.statusCode}');
  final tx = jsonDecode(r.body) as Map<String, dynamic>;
  final vout = (tx['vout'] as List?) ?? const [];
  for (var i = 0; i < vout.length; i++) {
    final o = vout[i] as Map;
    if ('${o['scriptpubkey'] ?? ''}'.toLowerCase() == spkHex.toLowerCase()) return i;
  }
  throw Exception('funded covenant output not found in $txid');
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

/// Confirm + run a TAKE (permissionless covenant FILL): build the fill tx against
/// the resting covenant, then broadcast. No maker round-trip.
class _TakeReviewSheet extends StatefulWidget {
  const _TakeReviewSheet({
    required this.offer,
    required this.payAsset,
    required this.payAtoms,
    required this.recvAsset,
    required this.recvAtoms,
    required this.feeAsset,
    required this.feeAtoms,
  });
  final SeqObOffer offer;
  final String payAsset;
  final BigInt payAtoms;
  final String recvAsset;
  final BigInt recvAtoms;
  final String feeAsset;
  final BigInt feeAtoms;
  @override
  State<_TakeReviewSheet> createState() => _TakeReviewSheetState();
}

class _TakeReviewSheetState extends State<_TakeReviewSheet> {
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
          _error = 'Authentication failed or cancelled; nothing sent.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      setState(() => _status = 'Building your FILL spend…');
      final built = await core.covenantBuildFillTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        covenantTermsJson: widget.offer.covenantTermsJson,
        takeAtoms: widget.recvAtoms,
        feeAsset: widget.feeAsset,
        feeAtoms: widget.feeAtoms,
      );
      setState(() => _status = 'Broadcasting…');
      final txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: built.rawHex);
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Review · take offer', style: AmbraText.h1),
          const SizedBox(height: 18),
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              _Row('You pay', _amt(widget.payAsset, widget.payAtoms)),
              _Row('You receive', _amt(widget.recvAsset, widget.recvAtoms)),
              _Row('Network fee', _amt(widget.feeAsset, widget.feeAtoms)),
              _Row('Settlement', 'Permissionless covenant fill; settles in full or not at all.'),
              _Row('Finality', 'Anchor-bound to Bitcoin (reverts only if Bitcoin reverts).'),
            ]),
          ),
          const SizedBox(height: 14),
          if (_busy && _status.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_status, style: AmbraText.muted)),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(label: 'Confirm & take', busy: _busy, icon: Icons.fingerprint, onPressed: _busy ? null : _confirm),
          const SizedBox(height: 6),
          GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        ]),
      ),
    );
  }
}

/// Confirm + run a POST (rest a covenant LIMIT order): prepare the covenant, fund
/// it on-chain from the wallet, then sign + post the offer to the relay.
class _PostReviewSheet extends StatefulWidget {
  const _PostReviewSheet({
    required this.payAsset,
    required this.sellAtoms,
    required this.recvAsset,
    required this.buyAtoms,
    required this.feeAsset,
    required this.feeAtoms,
    required this.feeRate,
    required this.tipHeight,
  });
  final String payAsset;
  final BigInt sellAtoms;
  final String recvAsset;
  final BigInt buyAtoms;
  final String feeAsset;
  final BigInt feeAtoms;
  final BigInt feeRate;
  final int tipHeight;
  @override
  State<_PostReviewSheet> createState() => _PostReviewSheetState();
}

class _PostReviewSheetState extends State<_PostReviewSheet> {
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
          _error = 'Authentication failed or cancelled; nothing posted.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');

      setState(() => _status = 'Deriving the covenant…');
      final makerIndex = _SwapCache.makerIndexSeed++;
      final prepared = await core.covenantPrepareOffer(
        mnemonic: m,
        sellAsset: widget.payAsset,
        sellAtoms: widget.sellAtoms,
        buyAsset: widget.recvAsset,
        buyAtoms: widget.buyAtoms,
        tipHeight: widget.tipHeight,
        expiryBlocks: 0, // 0 => default ~1 day horizon
        makerIndex: makerIndex,
      );

      setState(() => _status = 'Funding the order on-chain…');
      final feeAsset = widget.feeAsset == SeqAssets.policy
          ? null
          : core.FeeAsset(assetId: widget.feeAsset, rate: widget.feeRate);
      final pset = await core.buildSendTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        recipients: [
          core.Recipient(address: prepared.covenantAddress, assetId: widget.payAsset, satoshi: widget.sellAtoms),
        ],
        feeRateSatKvb: null,
        feeAsset: feeAsset,
      );
      final signed = await core.signPset(mnemonic: m, pset: pset);
      final covTxid = await core.finalizeAndBroadcast(mnemonic: m, esploraUrl: Backend.esplora, pset: signed);

      setState(() => _status = 'Locating the funded output…');
      final covVout = await resolveCovenantVout(covTxid, prepared.covenantSpkHex);

      // FUND-SAFETY: the covenant is now funded ON-CHAIN. Persist its reclaim material (the funding
      // outpoint + preparedJson + makerIndex + expiry) BEFORE finalizing and posting, so a post failure
      // (relay reject, dropped connection) can never strand the funds without a local record to reclaim
      // them. Flip posted:true once the relay accepts the offer.
      var placed = PlacedCovenant(
        covTxid: covTxid,
        covVout: covVout,
        pay: widget.payAsset,
        receive: widget.recvAsset,
        sellAtoms: widget.sellAtoms.toString(),
        recvAtoms: widget.buyAtoms.toString(),
        makerIndex: makerIndex,
        covenantSpkHex: prepared.covenantSpkHex,
        preparedJson: prepared.preparedJson,
        expiryLocktime: prepared.expiryLocktime,
        posted: false,
        createdMs: DateTime.now().millisecondsSinceEpoch,
      );
      await PlacedOrders.put(placed);

      setState(() => _status = 'Signing & posting your order…');
      final signedOffer = await core.covenantFinalizeOffer(
        mnemonic: m,
        preparedJson: prepared.preparedJson,
        covenantTxid: covTxid,
        covenantVout: covVout,
      );
      final offer = jsonDecode(signedOffer) as Map<String, dynamic>;
      placed = placed.copyWith(offerId: offer['offer_id'] as String?);
      await PlacedOrders.put(placed);
      await SeqObClient.postOffer(offer);
      await PlacedOrders.put(placed.copyWith(posted: true));

      if (mounted) Navigator.pop(context, covTxid);
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Review · post limit order', style: AmbraText.h1),
          const SizedBox(height: 18),
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              _Row('You sell', _amt(widget.payAsset, widget.sellAtoms)),
              _Row('You want', _amt(widget.recvAsset, widget.buyAtoms)),
              _Row('Funding fee', _amt(widget.feeAsset, widget.feeAtoms)),
              _Row('Order', 'Rests as a funded covenant; a taker fills it at your price.'),
              _Row('Finality', 'Anchor-bound to Bitcoin (reverts only if Bitcoin reverts).'),
            ]),
          ),
          const SizedBox(height: 14),
          if (_busy && _status.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_status, style: AmbraText.muted)),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(label: 'Confirm & post', busy: _busy, icon: Icons.fingerprint, onPressed: _busy ? null : _confirm),
          const SizedBox(height: 6),
          GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        ]),
      ),
    );
  }
}

/// Confirm + post a CONFIDENTIAL (blinded) resting offer. No on-chain funding:
/// the offer rests as an interactive intent carrying a blinded (blech32) receive
/// address + its blinding pubkey and the signed `confidential:true` (field-19)
/// tag, so both legs blind on-chain when a maker later co-signs the fill. The
/// interactive fill itself is the documented courier residual.
class _ConfPostReviewSheet extends StatefulWidget {
  const _ConfPostReviewSheet({
    required this.payAsset,
    required this.sellAtoms,
    required this.recvAsset,
    required this.buyAtoms,
    required this.feeAsset,
  });
  final String payAsset;
  final BigInt sellAtoms;
  final String recvAsset;
  final BigInt buyAtoms;
  final String feeAsset;
  @override
  State<_ConfPostReviewSheet> createState() => _ConfPostReviewSheetState();
}

class _ConfPostReviewSheetState extends State<_ConfPostReviewSheet> {
  bool _busy = false;
  String _status = '';
  String? _error;

  String _amt(String hex, BigInt atoms) {
    final l = SeqAssets.labelFor(hex);
    return '${formatAtoms(atoms.toString(), l.precision)} ${l.ticker}';
  }

  /// A random 16-byte hex offer id (matches the web wallet's `seqob.randHex(16)`).
  String _randHex16() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
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
          _error = 'Authentication failed or cancelled; nothing posted.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');

      setState(() => _status = 'Deriving your blinded receive address…');
      final recv = await core.confidentialReceiveWithBlindingPub(mnemonic: m);

      setState(() => _status = 'Signing your blinded offer…');
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final offer = <String, dynamic>{
        'offer_id': _randHex16(),
        'schema_version': 1,
        'pair': {'base_asset': widget.payAsset, 'quote_asset': widget.recvAsset},
        'trade_dir': 1, // SELL: maker gives base (= the asset you pay)
        'base_amount': widget.sellAtoms.toString(),
        'offer_amount': widget.sellAtoms.toString(),
        'offer_asset': widget.payAsset,
        'want_amount': widget.buyAtoms.toString(),
        'want_asset': widget.recvAsset,
        'allow_partial': true,
        'created_at_unix': '$now',
        'expires_at_unix': '${now + 3600}',
        'fee_asset_hint': widget.feeAsset,
        'confidential': true, // signed book-namespace tag (field 19)
        'same_chain': {
          'maker_recv_address': recv.address,
          'maker_blinding_pub': recv.blindingPubHex,
        },
      };
      final signed = await core.seqobSignOffer(mnemonic: m, offerJson: jsonEncode(offer));

      setState(() => _status = 'Posting to the confidential book…');
      await SeqObClient.postConfidentialOffer(jsonDecode(signed) as Map<String, dynamic>);

      if (mounted) Navigator.pop(context, offer['offer_id'] as String);
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Review · post blinded offer', style: AmbraText.h1),
          const SizedBox(height: 18),
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              _Row('You sell', _amt(widget.payAsset, widget.sellAtoms)),
              _Row('You want', _amt(widget.recvAsset, widget.buyAtoms)),
              _Row('Privacy', 'Blinded book — your offer rests confidentially; a blinded receive '
                  'address and blinding pubkey are published so the counterparty can blind their leg too.'),
              _Row('Filling', 'A taker fills it by co-signing a blinded swap. In-wallet co-sign is coming; '
                  'for now the offer rests and you can cancel it anytime.'),
              _Row('Finality', 'Settles in ~1 block · anchor-bound to Bitcoin (reverts only if Bitcoin reverts).'),
            ]),
          ),
          const SizedBox(height: 14),
          if (_busy && _status.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_status, style: AmbraText.muted)),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(label: 'Confirm & post', busy: _busy, icon: Icons.fingerprint, onPressed: _busy ? null : _confirm),
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
