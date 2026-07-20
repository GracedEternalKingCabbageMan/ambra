import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api_client.dart';
import '../data/btc_state.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../data/lightning_service.dart';
import '../data/ln_rail.dart';
import '../data/placed_orders.dart';
import '../data/price_service.dart';
import '../data/sbtc_peg_service.dart';
import '../data/seqdex_client.dart';
import '../data/seqln_keys.dart' as lnkeys;
import '../data/seqob_client.dart';
import '../data/swap_route.dart';
import '../data/trade_receipts.dart';
import '../data/wallet_repository.dart';
import '../data/xchain_client.dart';
import '../data/xchain_swap_service.dart';
import '../rust/api.dart' as core;
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'cross_lift_screen.dart';
import 'lightning_swap_screen.dart';
import 'my_orders_screen.dart';
import 'subasset_buy_screen.dart';
import 'subasset_sell_screen.dart';
import 'xchain_swap_screen.dart';

/// Estimated vByte size of a same-chain settlement tx, used to turn the optional
/// per-vB fee rate into a fee amount. Errs generous; the fee is shown for review.
const int _kSwapVbytes = 3000;

/// Default network fee, in native sat/vB, when the user doesn't override it.
const double _kDefaultSatPerVb = 0.5;

/// 1e8 = exchange_rate_scale (native atoms per reference unit).
final BigInt _kScale = BigInt.from(100000000);

/// Derived 24h stats for the active pair, in the canonical quote-per-base frame.
/// `pts` are the in-window closes (for the sparkline); `sizeAsset` is the hex of
/// the asset `vol` is denominated in (the candle feed's base/size asset).
typedef _PairStats = ({List<double> pts, double changePct, double hi, double lo, BigInt vol, String sizeAsset});

/// Unified, rail-agnostic swap composer. Pick what you pay and what you receive —
/// BTC is a first-class picker asset alongside every Sequentia asset — and the
/// composer routes the settlement automatically ([route]): a same-chain pair
/// settles on the passive covenant CLOB (TAKE a resting offer or POST your own
/// LIMIT order, "the order is the coin"); a BTC pair dispatches to the cross-chain
/// HTLC, pure-Lightning, or sub-asset submarine flow, with a per-leg rail toggle.
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

class _SwapTabState extends State<SwapTab> with WidgetsBindingObserver {
  final _payAmount = TextEditingController();
  final _recvAmount = TextEditingController();
  final _feeRateCtl = TextEditingController();

  List<Market> _markets = [];
  // Cross-chain (BTC <-> Sequentia asset) markets. Their presence is what makes BTC
  // a first-class picker asset and sources every BTC pair the composer can route.
  List<XchainMarket> _xmarkets = [];
  List<core.AssetBalance> _balances = [];
  Map<String, BigInt> _feeRates = {};
  int _tipHeight = 0;

  String? _payAsset;
  String? _receiveAsset;
  String? _feeAsset; // null => default (the paid asset)

  // The two settlement PREFERENCES the user sets per order: how they PAY and how they RECEIVE, each
  // Lightning (true) or on-chain (false). RAIL-BLIND (spec §5): these never touch the book/matching/price
  // — they are honored at settlement. They start NULL — there is NO default (spec §6.5): an order cannot
  // be placed until BOTH are chosen, on EVERY pair. Fed into [route] as settlement prefs only.
  bool? _payRailLn;
  bool? _recvRailLn;
  XchainSwapRecord? _xInFlight; // a persisted cross-swap with locked BTC needing resume/refund (banner)

  // This wallet's OWN Lightning channels (node_key present), from a best-effort /status fetch. Feeds
  // ln_rail's railAvailability so the composer offers/auto-selects the Lightning rail for a leg ONLY
  // when that asset (or BTC) has a real usable channel — never merely "the LSP is configured".
  List<Map> _lnChannels = const [];

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
  // KEEP RESTING WHILE OFFLINE (spec §5 / SBTC design §5). Relevant ONLY for an on-chain-BTC-pay
  // LIMIT order: ON -> silently peg the maker's BTC to SBTC and rest it in a covenant that survives
  // the wallet going offline, peg back out to real BTC on fill; OFF -> a native-BTC HTLC (needs the
  // wallet online). Default ON. Market orders and any Lightning leg IGNORE it — pure native BTC.
  bool _keepResting = true;
  String _edited = 'pay'; // which amount the user last typed

  // Price DISPLAY direction toggle. The book prices a pair ONE canonical way ("1 base = N
  // quote", the higher-rank asset is the quote) so buy and sell read the same; this flips the
  // display only. Per-pair (reset on a pair change), and forced off on a BTC (cross) pair.
  bool _priceFlip = false;

  OrderBook? _orderBook;
  SeqObOffer? _selected;

  // Resting CROSS (BTC<->asset) offers from the relay order book, shown for a BTC pair (the same-chain
  // covenant book does not apply there). These are the durable cross offers restored by the relay fix.
  List<CrossOffer> _crossOffers = const [];

  // Resting SBTC silent-peg COVENANTS advertised as BTC for the current BTC pair (funded, offline-
  // resting bids). A taker SELLING the asset for BTC fills one with the covenant FILL primitive
  // (paying the asset, receiving SBTC) and pegs the SBTC out to real BTC. Loaded alongside _crossOffers.
  List<SeqObOffer> _peggedOffers = const [];

  bool _loading = true;
  bool _bookLoading = false;
  String? _error;
  String? _actionError;

  // --- live market data (foreground poll; the web uses a WS, mobile polls) -----
  // A 5s foreground poll refreshes the book + trades + stats. It pauses in the
  // background (battery) via the app-lifecycle observer, and never surfaces a
  // market-data fetch error; the sections just stay empty on a transient failure.
  Timer? _poll;
  bool _appActive = true; // false while backgrounded; gates the poll
  bool _refreshing = false; // in-flight guard so polls never pile up
  int _tradesReq = 0; // request-seq: drop a superseded trades fetch (pair changed)
  int _statsReq = 0; // request-seq for the stats fetch

  // Recent trades for the active pair, plus which asset `size` is denominated in.
  // A pair has ONE canonical direction, so the feed is either canonical or its
  // inverse; `_tradesInv` inverts the shown price, and the size asset follows the
  // direction that actually returned data (canonical => base, inverse => quote).
  List<SeqObTrade> _trades = const [];
  bool _tradesInv = false;
  String? _tradesSizeAsset;

  // Derived 24h stats + sparkline points for the active pair (null => render none).
  _PairStats? _stats;

  // A small local activity log (same-chain covenant fills + posts logged below).
  List<TradeReceipt> _receipts = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Repaint when Lightning comes up / goes down: it gates the rail toggles and the
    // route a BTC pair resolves to (the composer no longer wraps a ListenableBuilder).
    LightningService.instance.addListener(_onLnChanged);
    _payAmount.addListener(_onPayChanged);
    _recvAmount.addListener(_onRecvChanged);
    _startPoll();
    _loadReceipts();
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
      if (_confBook && (_payAsset == kBtcSentinel || _receiveAsset == kBtcSentinel)) {
        // The blinded book is Sequentia-only: drop a BTC pick and fall back to a same-chain pair.
        final pays = _payableAssets();
        _payAsset = pays.isNotEmpty ? pays.first : null;
        _reconcileReceive();
      }
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
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    LightningService.instance.removeListener(_onLnChanged);
    _payAmount.removeListener(_onPayChanged);
    _recvAmount.removeListener(_onRecvChanged);
    _payAmount.dispose();
    _recvAmount.dispose();
    _feeRateCtl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause the poll in the background; on resume, refresh once immediately.
    final active = state == AppLifecycleState.resumed;
    _appActive = active;
    if (active) _pollTick();
  }

  /// Lightning came up or went down: repaint so the rail toggles and route summary
  /// reflect it. When Lightning drops, forget any stale LN rail pick so a BTC pair
  /// falls back to the proven on-chain cross route.
  void _onLnChanged() {
    if (!mounted) return;
    setState(() {
      if (!LightningService.instance.available) {
        // Lightning went away: any leg the user had set to Lightning is no longer honorable, so clear it
        // back to unselected (never silently force a rail). On-chain picks stand.
        if (_payRailLn == true) _payRailLn = null;
        if (_recvRailLn == true) _recvRailLn = null;
      }
    });
  }

  // --- live market data ------------------------------------------------------

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _pollTick());
  }

  /// One poll iteration: re-fetch the book (quietly, no loading flash) + trades +
  /// stats, but only when foregrounded, a pair is chosen, and nothing heavier is
  /// already in flight. All fetches are best-effort and never surface an error.
  Future<void> _pollTick() async {
    if (!mounted || !_appActive || _refreshing) return;
    if (_loading || _bookLoading) return; // a full load / pair-change fetch owns it
    final pay = _payAsset, recv = _receiveAsset;
    if (pay == null || recv == null || pay == recv || _isCrossPair) return; // BTC pairs have no covenant book
    _refreshing = true;
    try {
      await _refreshBookQuiet(pay, recv);
      await _refreshTrades(pay, recv);
      await _refreshStats(pay, recv);
    } finally {
      _refreshing = false;
    }
  }

  /// Re-fetch the book WITHOUT the loading flash (for the poll). Preserves the
  /// user's selected offer if it still rests (matched by id), else falls back to
  /// the best offer, mirroring [_fetchBook]'s selection/mode rules.
  Future<void> _refreshBookQuiet(String pay, String recv) async {
    try {
      final book = await SeqObClient.fetchBook(recv, pay, confidential: _confBook);
      if (!mounted || _payAsset != pay || _receiveAsset != recv) return;
      setState(() {
        _orderBook = book;
        if (_confBook) {
          _selected = null;
          _mode = 'post';
        } else {
          final prevId = _selected?.offerId;
          SeqObOffer? keep;
          if (prevId != null && prevId.isNotEmpty) {
            for (final o in book.offers) {
              if (o.offerId == prevId) {
                keep = o;
                break;
              }
            }
          }
          _selected = keep ?? book.best;
          if (!_modeTouched) _mode = book.isEmpty ? 'post' : 'take';
        }
      });
      _relink();
    } catch (_) {
      // Best-effort live refresh; keep the last good book on a transient failure.
    }
  }

  /// Recent trades for the active pair. Queries the canonical direction, falls back
  /// to the inverse (inverting the shown price), and stores which asset `size` is
  /// in. A request-seq guards against a superseded pair. Never throws.
  Future<void> _refreshTrades(String pay, String recv) async {
    final req = ++_tradesReq;
    final dir = _pairDir(pay, recv);
    var inv = false;
    var sizeAsset = dir.base;
    var trades = await SeqObClient.fetchTrades(dir.base, dir.quote);
    if (trades.isEmpty) {
      final alt = await SeqObClient.fetchTrades(dir.quote, dir.base);
      if (alt.isNotEmpty) {
        trades = alt;
        inv = true;
        sizeAsset = dir.quote;
      }
    }
    if (!mounted || req != _tradesReq) return; // superseded by a newer pair
    setState(() {
      _trades = trades;
      _tradesInv = inv;
      _tradesSizeAsset = sizeAsset;
    });
  }

  /// 24h stats + sparkline points for the active pair, from the /candles feed.
  /// Same canonical-direction handling as [_refreshTrades]; inverting an inverse
  /// feed swaps each candle's high and low. Never throws.
  Future<void> _refreshStats(String pay, String recv) async {
    final req = ++_statsReq;
    final dir = _pairDir(pay, recv);
    var inv = false;
    var sizeAsset = dir.base;
    var candles = await SeqObClient.fetchCandles(dir.base, dir.quote);
    if (candles.isEmpty) {
      final alt = await SeqObClient.fetchCandles(dir.quote, dir.base);
      if (alt.isNotEmpty) {
        candles = alt;
        inv = true;
        sizeAsset = dir.quote;
      }
    }
    if (!mounted || req != _statsReq) return;
    if (candles.isEmpty) {
      setState(() => _stats = null);
      return;
    }
    // Normalise every candle to the canonical quote-per-base frame.
    double iv(double x) => x > 0 ? 1 / x : 0;
    final norm = candles
        .map((c) => inv
            ? (t: c.t, o: iv(c.o), c: iv(c.c), h: iv(c.l), l: iv(c.h), v: c.v)
            : (t: c.t, o: c.o, c: c.c, h: c.h, l: c.l, v: c.v))
        .toList();
    final cutoff = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 86400;
    var win = norm.where((c) => c.t >= cutoff).toList();
    if (win.isEmpty) win = [norm.last]; // nothing in 24h => show the latest as a flat point
    var hi = double.negativeInfinity, lo = double.infinity;
    var vol = BigInt.zero;
    for (final c in win) {
      if (c.h > hi) hi = c.h;
      if (c.l < lo) lo = c.l;
      vol += c.v;
    }
    final first = win.first, last = win.last;
    final changePct = first.o > 0 ? (last.c - first.o) / first.o * 100 : 0.0;
    final pts = <double>[for (final c in win) if (c.c.isFinite) c.c];
    setState(() => _stats = (pts: pts, changePct: changePct, hi: hi, lo: lo, vol: vol, sizeAsset: sizeAsset));
  }

  Future<void> _loadReceipts() async {
    try {
      final r = await TradeReceipts.list();
      if (mounted) setState(() => _receipts = r);
    } catch (_) {
      // the activity log is best-effort; never blocks the composer
    }
  }

  /// Compact "N s/m/h/d ago" for trade + receipt timestamps (unix seconds).
  String _ago(int ts) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final s = now - ts;
    final v = s < 0 ? 0 : s;
    if (v < 60) return '${v}s';
    if (v < 3600) return '${v ~/ 60}m';
    if (v < 86400) return '${v ~/ 3600}h';
    return '${v ~/ 86400}d';
  }

  /// Flip the price DISPLAY direction, and re-fetch trades + stats so they read the
  /// same way as the (instantly-reframed) book rather than lagging until the poll.
  void _toggleFlip() {
    setState(() => _priceFlip = !_priceFlip);
    final pay = _payAsset, recv = _receiveAsset;
    if (pay != null && recv != null && pay != recv) {
      unawaited(_refreshTrades(pay, recv));
      unawaited(_refreshStats(pay, recv));
    }
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
      // Surface any in-flight cross-chain swap with locked BTC so its resume/refund
      // surface (XchainSwapScreen) is REACHABLE — the courier composer path no longer
      // opens that screen directly, so without this banner a mid-flight swap (and its
      // CLTV refund) would be stranded off-screen.
      try { _xInFlight = await XchainStore.inFlightWithFunds(); } catch (_) { _xInFlight = null; }
      try {
        final rates = await ApiClient.feeRates();
        if (mounted && rates.isNotEmpty) _feeRates = rates;
      } catch (_) {/* default fee still works */}
      // The composer settles on the seqob covenant book, so the pickers MUST come
      // from the seqob markets (resolvable registry ids), not the /dex daemon (whose
      // reissued ids resolve to neither built-in nor registry -> hex placeholders).
      final markets = await SeqObClient.markets();
      // Cross-chain BTC<->asset markets come from the RELAY order book (the /dex RFQ daemon is retired):
      // an asset is BTC-tradeable when the relay quotes it against BTC. Best-effort; absence never blocks
      // the same-chain composer, and BTC stays a first-class picker asset regardless (see _btcOffered).
      List<XchainMarket> xmarkets;
      try {
        xmarkets = [
          for (final a in await SeqObClient.crossMarketAssets())
            XchainMarket(btcAsset: '', seqAsset: a, name: 'BTC/${SeqAssets.labelFor(a).ticker}', priceSeqPerBtc: 0),
        ];
      } catch (_) {
        xmarkets = const [];
      }
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      // This wallet's OWN Lightning channels (best-effort), so the rail toggles gate on REAL per-asset
      // liquidity, not "LSP configured" (mirrors the web's railAvail off a live /status). OWN-only:
      // pass the device's reconstructed node keys as ?nodes= and keep only node_key-tagged channels.
      var lnCh = const <Map>[];
      if (LightningService.instance.configured) {
        try {
          // Derive a node key for EVERY registry-known asset, not just assets with an on-chain balance:
          // an asset held only INSIDE a channel (a sub-asset JIT-inbound buy, or all of it Moved to
          // Lightning) has zero on-chain balance yet still has a node + channel. Keying off balances
          // alone hid that channel, so the LN rail was falsely gated off with a "Move to Lightning" hint
          // for funds already there. Set-dedup; union the balance assets in case any sit outside registry.
          final nodes = <String>{
            lnkeys.ownNodeKeyForBtc(m),
            for (final id in SeqAssets.resolvedIds) lnkeys.ownNodeKeyForAsset(m, id),
            for (final b in s.balances) lnkeys.ownNodeKeyForAsset(m, b.assetId),
          }.toList();
          final st = await LightningService.instance.getStatus(nodes: nodes);
          lnCh = ((st.raw['channels'] as List?) ?? const []).whereType<Map>().toList();
        } catch (_) {/* best-effort; toggles still work, the notes just say "no channel yet" */}
      }
      if (!mounted) return;
      setState(() {
        _markets = markets;
        _xmarkets = xmarkets;
        _balances = s.balances;
        _tipHeight = s.tipHeight;
        _lnChannels = lnCh;
        _error = null;
        _loading = false;
        final pays = _payableAssets();
        if (_payAsset == null || !pays.contains(_payAsset)) _payAsset = pays.isNotEmpty ? pays.first : null;
        _reconcileReceive();
      });
      _cache();
      _fetchBook();
      // Resume any SBTC peg-in that was mid-flight when the wallet last closed: if its SBTC has since
      // been credited, finish by posting the covenant (mirrors the web wallet's resumePegIns on load).
      // Fire-and-forget + best-effort — never blocks the composer, and a still-pending peg-in is left
      // for a later load. FUND-SAFETY: the bridge credits SBTC regardless, so nothing is ever lost.
      unawaited(SbtcPegService.resumePegIns(
        mnemonic: m,
        tipHeight: _tipHeight,
        nextMakerIndex: () => _SwapCache.makerIndexSeed++,
      ));
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
    // BTC is the parent-chain leg: its balance comes from the shared Bitcoin state,
    // not the Sequentia asset balances, so it formats like any other picker asset.
    if (hex == kBtcSentinel) return BtcState.instance.last?.balanceSats ?? '0';
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

  /// The Sequentia assets that have a cross-chain (BTC) market — the assets BTC can
  /// pair with. Every BTC pair the composer offers is backed by one of these, so the
  /// cross/ln/mixed flows always find their market when seeded.
  Set<String> _btcMarketAssets() => {for (final m in _xmarkets) m.seqAsset};

  /// BTC is a FIRST-CLASS dual-chain asset, so it is offered as a composer asset on the whole
  /// transparent book — it pairs with ANY Sequentia asset (mirroring the web's counterpartsOf, where
  /// BTC is a valid cross counterpart for every asset, the book may just be empty until a maker posts).
  /// It is dropped ONLY on the Blinded book: BTC lives on the parent chain, which has no confidential
  /// transactions, so a BTC leg cannot blind. Deliberately NOT gated on [_xmarkets] loading — a
  /// first-class asset must never vanish because one market fetch was slow or empty.
  bool get _btcOffered => !_confBook;

  /// True when either leg is BTC — a cross pair, routed off the same-chain book.
  bool get _isCrossPair => _payAsset == kBtcSentinel || _receiveAsset == kBtcSentinel;

  /// Assets you can pay with: every asset the book trades, plus every asset with a
  /// BTC market, plus BTC itself (when offered). Named (resolvable) or held — NOT
  /// filtered to holdings, so an empty wallet still sees the full market (the
  /// review/balance check gates the actual trade). Unnameable dust you do not hold
  /// is dropped so no hex placeholders surface. BTC is added LAST so the default
  /// pay asset stays a Sequentia asset (a same-chain pair by default).
  /// Collapse candidate ids to ONE per resolved ticker (mirrors the web's startableAssets dedup): a
  /// reissued/stale id can resolve to the same ticker as the current one, or to a metadata-less
  /// placeholder. Keep one id per ticker (preferring a held id), and drop unresolved ids the wallet
  /// does not hold (dust of a dead id) so no hex placeholder ever surfaces in the picker.
  List<String> _dedupByTicker(Iterable<String> ids) {
    final byKey = <String, String>{};
    for (final h in ids) {
      if (h == kBtcSentinel) continue; // BTC is added by the caller, positioned deliberately
      final resolved = SeqAssets.resolved(h);
      final held = _holds(h);
      if (!resolved && !held) continue; // stale dust with no metadata: hide it
      final key = resolved ? SeqAssets.labelFor(h).ticker : h; // group resolved by ticker; unresolved-held stays unique
      final cur = byKey[key];
      if (cur == null) {
        byKey[key] = h;
      } else if (held && !_holds(cur)) {
        byKey[key] = h; // prefer the id the wallet actually holds
      }
    }
    return byKey.values.toList();
  }

  List<String> _payableAssets() {
    // Every asset the book trades, every asset with a BTC market, AND every registered/known asset —
    // so a newly-issued asset with no market yet is still startable (post a covenant offer to open one).
    final out = _dedupByTicker(<String>{
      ..._counterparts(null),
      ..._btcMarketAssets(),
      ...SeqAssets.resolvedIds,
    });
    if (_btcOffered) out.add(kBtcSentinel); // BTC LAST so the default pay stays a Sequentia asset
    return out;
  }

  /// Assets that can be received against the chosen pay asset. When paying BTC, any asset with a BTC
  /// market is a counterpart; otherwise ANY other Sequentia asset is a valid same-chain counterpart
  /// (any two distinct assets form a market — startable), plus BTC when the pay asset has a BTC market.
  List<String> _receivableAssets() {
    final pay = _payAsset;
    if (pay == kBtcSentinel) {
      // Paying BTC: any Sequentia asset is a valid counterpart (buy it with Bitcoin). Not gated on a
      // pre-existing cross market — the cross/LN book may be empty until a maker posts.
      return _dedupByTicker(<String>{
        ..._counterparts(null),
        ..._btcMarketAssets(),
        ...SeqAssets.resolvedIds,
      });
    }
    final out = _dedupByTicker(<String>{
      ..._counterparts(pay),
      ...SeqAssets.resolvedIds,
    }..removeWhere((h) => h == pay));
    if (_btcOffered && pay != null) out.add(kBtcSentinel); // any Sequentia asset can be sold for Bitcoin
    return out;
  }

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
        _crossOffers = const [];
        _peggedOffers = const [];
        _trades = const [];
        _stats = null;
      });
      return;
    }
    // A BTC pair is not on the same-chain covenant book: show the RELAY cross order book (the durable
    // BTC<->asset offers) instead, so the user sees real cross depth for the pair.
    if (_isCrossPair) {
      final seqAsset = pay == kBtcSentinel ? recv : pay;
      setState(() {
        _orderBook = null;
        _selected = null;
        _trades = const [];
        _stats = null;
      });
      try {
        final xoffers = await SeqObClient.crossBook(seqAsset);
        if (mounted) setState(() => _crossOffers = xoffers);
      } catch (_) {
        if (mounted) setState(() => _crossOffers = const []);
      }
      // Also load the SBTC silent-peg covenants advertised as BTC on this pair (the offline-resting bids
      // a SELL-asset-for-BTC taker can fill). Separate from crossBook, which drops covenants (item 6).
      try {
        final pegged = await SeqObClient.peggedBtcCovenants(seqAsset);
        if (mounted) setState(() => _peggedOffers = pegged);
      } catch (_) {
        if (mounted) setState(() => _peggedOffers = const []);
      }
      return;
    }
    setState(() {
      _crossOffers = const [];
      _peggedOffers = const [];
      _bookLoading = true;
    });
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
    // Live-data companions for this pair (best-effort; independent of the book).
    unawaited(_refreshTrades(pay, recv));
    unawaited(_refreshStats(pay, recv));
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
        _priceFlip = false; // display flip is per-pair
        _payRailLn = null; // new pair -> rails unselected (no default; the user must choose)
        _recvRailLn = null;
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
      setState(() {
        _receiveAsset = picked;
        _priceFlip = false; // display flip is per-pair
        _payRailLn = null; // new pair -> rails unselected (no default; the user must choose)
        _recvRailLn = null;
      });
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
      // Let the sheet grow and SCROLL, capped at 70% of the screen, so a long asset list is never
      // clipped behind the bottom navigation bar (SafeArea pads for it). Was a non-scrollable Column
      // whose last rows (e.g. GOLD) hid behind the nav bar and could not be selected.
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.all(16), child: Text(title, style: AmbraText.title)),
            if (ids.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('No assets available.', style: AmbraText.muted)),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                children: [
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
                ],
              ),
            ),
          ]),
        ),
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
    _loadReceipts();
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

  // --- canonical price direction (mirrors the web wallet's swap.js) -----------

  /// Fixed pricing-numeraire rank: in a pair, the higher-rank asset is the QUOTE, so a market
  /// reads ONE way ("1 base = N quote") whether you buy or sell. Only genuine units of account
  /// (BTC + the fiat stablecoins) are numeraires; the Sequence token and the commodities keep
  /// EQUAL standing as ordinary base assets (Principle 3) at the generic tier.
  int _quoteRank(String hex) {
    final t = SeqAssets.labelFor(hex).ticker.toUpperCase();
    if (t == 'BTC') return 1000;
    const r = {'USDX': 900, 'EURX': 890, 'FEEUSD': 880, 'USDT': 870, 'USDC': 865, 'USD': 860};
    return r[t] ?? 400; // unknown issued asset (incl. tSEQ/SEQ/GOLD/SILVR/OILX): generic base tier
  }

  /// True when either side of a pair is BTC — a cross pair, whose ladder is fixed to "1 asset =
  /// N BTC" and can't honour the flip toggle (so the toggle is hidden + the flip forced off).
  bool _pairIsCross(String a, String b) => _quoteRank(a) == 1000 || _quoteRank(b) == 1000;

  /// The pair's DISPLAY direction {base, quote}: the higher-rank asset is the quote, ties broken
  /// by asset id so the direction is stable across buy/sell. Honours the flip toggle, except on a
  /// cross pair where the flip is ignored.
  ({String base, String quote}) _pairDir(String a, String b) {
    final ra = _quoteRank(a), rb = _quoteRank(b);
    final canon = ra != rb
        ? (ra > rb ? (base: b, quote: a) : (base: a, quote: b))
        : (a.compareTo(b) < 0 ? (base: a, quote: b) : (base: b, quote: a));
    final flip = _priceFlip && !_pairIsCross(a, b);
    return flip ? (base: canon.quote, quote: canon.base) : canon;
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(ambraSnack(m));

  @override
  Widget build(BuildContext context) {
    final pays = _payableAssets();
    final book = _orderBook;
    final isCross = _isCrossPair;
    // Resolve the settlement route for a BTC pair from the current rail picks; same-chain pairs
    // route to the covenant book and never touch this.
    final r = isCross
        ? route(_payAsset, _receiveAsset,
            payRailLn: _payRailLn, recvRailLn: _recvRailLn, lnAvailable: LightningService.instance.available)
        : null;
    // The reverse (asset -> BTC on-chain) cross courier is NOT built, so a cross SELL is a dead rail:
    // route() still returns kind=cross/isValid=true, which would enable Review on a settlement that only
    // yields a "coming" snack. Treat it as not-actionable and explain inline (route summary), pointing at
    // the live sell rails (pure-LN / sub-asset), instead of an enabled button that promises settlement.
    final crossSellDead = isCross && r != null && r.kind == SwapRouteKind.cross && !r.payIsBtc;
    // The pair is tradeable (book renders, quote works) — but placement also needs both settlement rails
    // chosen (spec §6.5, no default). canQuote gates showing the CTA; railsChosen gates enabling it.
    final canQuote = !_loading &&
        _error == null &&
        _payAsset != null &&
        _receiveAsset != null &&
        !crossSellDead &&
        (!isCross || (r?.isValid ?? false));
    final railsChosen = _payRailLn != null && _recvRailLn != null;
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
          const Text('Swap', style: AmbraText.h1),
          const SizedBox(height: 6),
          const Text('Trade any Sequentia asset, or Bitcoin, from one order book. You choose how you pay and receive; the book matches on price and size.',
              style: AmbraText.sub),
          const SizedBox(height: 16),
          if (_xInFlight != null) ...[
            _inFlightCrossBanner(_xInFlight!),
            const SizedBox(height: 14),
          ],
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
          else if (_markets.isEmpty && _xmarkets.isEmpty)
            const AmbraCard(child: Text('No markets are open right now. Check back shortly.', style: AmbraText.muted))
          else if (pays.isEmpty)
            const AmbraCard(
                child: Text('You hold no assets that trade yet. Receive a tradable asset, or use the faucet (More tab).',
                    style: AmbraText.muted))
          else if (isCross) ...[
            // BTC pair on the SAME unified terminal (spec §7): the Market/Limit toggle, price stats, the
            // two-sided book, rail picks, and recent trades — exactly like a same-chain pair. No degraded
            // chrome. (_crossComposerChildren already carries the pickers + amount + _railPicks + book.)
            _modeToggle(),
            const SizedBox(height: 16),
            _pairStatsStrip(),
            ..._crossComposerChildren(r!),
            _recentTradesPanel(),
            if (_actionError != null) ...[
              const SizedBox(height: 12),
              Text(_actionError!, style: const TextStyle(color: AmbraColors.red)),
            ],
          ] else ...[
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
            _railPicks(), // rail-blind settlement prefs on EVERY pair (spec §5) — a same-chain asset can move over SeqLN too
            _offlineRestToggle(), // on-chain-BTC-pay + LIMIT only: rest as pegged SBTC while offline (spec §5)
            _pairStatsStrip(),
            _bookPanel(book),
            _recentTradesPanel(),
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
          _myOrdersLink(),
          _recentActivity(),
        ]),
      ),
      if (canQuote)
        BottomActionBar(children: [
          PrimaryButton(
            label: !railsChosen
                ? 'Choose how you pay & receive'
                : isCross
                    ? 'Review swap'
                    : _confBook
                        ? 'Review & post (blinded)'
                        : _mode == 'take'
                            ? 'Review & take'
                            : 'Review & post',
            icon: !railsChosen
                ? Icons.alt_route
                : isCross
                    ? Icons.swap_horiz
                    : _confBook
                        ? Icons.lock_outline
                        : _mode == 'take'
                            ? Icons.swap_horiz
                            : Icons.playlist_add,
            // Disabled (null) until both rails are chosen — no order on an unstated settlement choice.
            onPressed: !railsChosen ? null : (isCross ? () => _dispatchCross(r!) : _submit),
          ),
        ]),
    ]);
  }

  /// The cross (BTC pair) composer body: pay + receive pickers, ONE amount field on
  /// the Sequentia-asset leg (a BUY quotes its Bitcoin amount in the wizard; a SELL
  /// is denominated in the asset), the per-leg rail picks, and the route summary.
  List<Widget> _crossComposerChildren(SwapRoute r) {
    final asset = r.seqAsset;
    final assetTk = _tk(asset); // r.seqAsset is non-null for any BTC pair reachable from the pickers
    final payIsAsset = _payAsset != kBtcSentinel; // the Sequentia-asset leg is the PAY leg
    return [
      const SectionLabel('You pay'),
      const SizedBox(height: 8),
      _PickerRow(
        label: _tk(_payAsset),
        trailing: _payAsset == null
            ? null
            : 'balance ${formatAtoms(_bal(_payAsset!), SeqAssets.labelFor(_payAsset!).precision)}',
        onTap: _pickPay,
      ),
      if (payIsAsset) ...[
        const SizedBox(height: 12),
        AmbraField(label: 'Amount ($assetTk)', controller: _payAmount, hint: '0.0'),
      ],
      // Pegged BUY-with-BTC LIMIT (keep-resting): the user sets BOTH sides of a limit bid — the BTC they
      // pay (here) and the asset they want (below). Only when buying the asset with BTC in post mode with
      // "keep resting" on; every other cross flow quotes the BTC amount from the book instead.
      if (!payIsAsset && _mode == 'post' && _keepResting) ...[
        const SizedBox(height: 12),
        AmbraField(label: 'Amount (BTC you pay)', controller: _payAmount, hint: '0.0'),
      ],
      const SizedBox(height: 18),
      Center(child: Icon(Icons.arrow_downward, color: AmbraColors.dim, size: 22)),
      const SizedBox(height: 18),
      const SectionLabel('You receive'),
      const SizedBox(height: 8),
      _PickerRow(label: _tk(_receiveAsset), onTap: _pickReceive),
      if (!payIsAsset) ...[
        const SizedBox(height: 12),
        AmbraField(
          label: _mode == 'post' ? 'Your price — amount ($assetTk)' : 'Amount ($assetTk)',
          controller: _recvAmount,
          hint: _mode == 'post' ? 'how much you want' : '0.0',
        ),
      ],
      const SizedBox(height: 18),
      _railPicks(),
      _offlineRestToggle(), // on-chain-BTC-pay + LIMIT only: rest as pegged SBTC while offline (spec §5)
      _routeSummary(r),
      _crossBookPanel(asset),
      const SizedBox(height: 8),
      const Text('Review opens a guided swap that quotes the exact Bitcoin amount and settles it step by step.',
          style: AmbraText.sub),
    ];
  }

  /// The relay's resting CROSS (BTC<->asset) order book for the current pair — real depth now that cross
  /// offers rest durably. Read-only for now (lifting runs the interactive courier in the swap wizard).
  Widget _crossBookPanel(String? asset) {
    if (asset == null) return const SizedBox.shrink();
    // Split by direction and slice EACH side, else a single ascending sort + take(N) hides the entire
    // tappable BUY side whenever enough reverse bids rest (true on every live BTC market). Asks (maker
    // sells the asset -> the taker BUYS, tappable) go cheapest-first = best; bids (the taker could sell)
    // richest-first = best. Show the best few of each so the ladder reflects the real two-sided market.
    final asks = _crossOffers.where((o) => o.makerSellsAsset).toList()
      ..sort((a, b) => a.btcPerAssetAtom.compareTo(b.btcPerAssetAtom));
    final bids = _crossOffers.where((o) => !o.makerSellsAsset).toList()
      ..sort((a, b) => b.btcPerAssetAtom.compareTo(a.btcPerAssetAtom));
    final offers = [...asks.take(5), ...bids.take(5)];
    final aprec = SeqAssets.labelFor(asset).precision;
    final tk = _tk(asset);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('$tk / BTC order book', style: AmbraText.body),
            Text(_crossOffers.isEmpty ? 'no offers yet' : '${_crossOffers.length} resting', style: AmbraText.sub),
          ]),
          const SizedBox(height: 8),
          if (offers.isEmpty)
            const Text('No resting offers for this pair yet. Place an order to start the market.', style: AmbraText.sub)
          else ...[
            for (final o in offers)
              // A maker SELLING the asset (for BTC) is a BUY the taker can lift now (lock BTC -> get the
              // asset). The reverse (maker gives BTC) is the sell direction — read-only until the reverse
              // courier lands.
              InkWell(
                onTap: o.makerSellsAsset ? () => _liftCross(o) : null,
                borderRadius: BorderRadius.circular(AmbraRadii.input),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
                  child: Row(children: [
                    SizedBox(
                      width: 58,
                      child: Text(o.makerSellsAsset ? 'buy $tk' : 'sell $tk',
                          style: AmbraText.sub.copyWith(color: o.makerSellsAsset ? AmbraColors.green : AmbraColors.red)),
                    ),
                    Expanded(
                      child: Text('${formatAtoms(o.assetAtoms.toString(), aprec)} $tk',
                          textAlign: TextAlign.right, style: AmbraText.mono),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('${formatAtoms(o.btcSats.toString(), 8)} BTC',
                          textAlign: TextAlign.right, style: AmbraText.mono),
                    ),
                    SizedBox(
                      width: 20,
                      child: o.makerSellsAsset
                          ? const Icon(Icons.chevron_right, size: 16, color: AmbraColors.dim)
                          : null,
                    ),
                  ]),
                ),
              ),
            const SizedBox(height: 6),
            const Text('Tap a “buy” offer to lock Bitcoin and swap. Non-custodial; refundable if it does not complete.',
                style: AmbraText.sub),
          ],
          if (_peggedOffers.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(color: AmbraColors.line, height: 1),
            const SizedBox(height: 10),
            Text('Offline-resting BTC bids for $tk', style: AmbraText.body),
            const SizedBox(height: 6),
            // SBTC silent-peg covenants (advertised BTC, lock SBTC). Tap to SELL the asset: pay the
            // asset, receive SBTC, auto-peg-out to real BTC. Funded + fillable while the maker is offline.
            for (final o in _peggedOffers.take(5))
              InkWell(
                onTap: () => _takePeggedCovenant(o),
                borderRadius: BorderRadius.circular(AmbraRadii.input),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
                  child: Row(children: [
                    SizedBox(width: 58, child: Text('sell $tk', style: AmbraText.sub.copyWith(color: AmbraColors.red))),
                    Expanded(
                      child: Text('${formatAtoms(o.wantAtoms.toString(), aprec)} $tk',
                          textAlign: TextAlign.right, style: AmbraText.mono),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('${formatAtoms(o.baseAtoms.toString(), 8)} BTC',
                          textAlign: TextAlign.right, style: AmbraText.mono),
                    ),
                    const SizedBox(width: 20, child: Icon(Icons.chevron_right, size: 16, color: AmbraColors.dim)),
                  ]),
                ),
              ),
            const SizedBox(height: 6),
            Text('Tap to sell $tk for Bitcoin. You receive pegged BTC (SBTC) and it is redeemed to real BTC automatically.',
                style: AmbraText.sub),
          ],
        ]),
      ),
    );
  }

  /// The per-leg Lightning-rail verdict for the current BTC pair, off this wallet's OWN channels
  /// (ln_rail.railAvailability). Null when the pair is not a BTC pair or a leg is unselected — so the
  /// composer offers/auto-selects Lightning for a leg ONLY when that asset (or BTC) has a real channel.
  RailAvailability? _railAvail() {
    if (!_isCrossPair) return null;
    final pay = _payAsset, recv = _receiveAsset;
    if (pay == null || recv == null) return null;
    RailTarget t(String a) =>
        a == kBtcSentinel ? RailTarget.btc() : RailTarget.asset(hex: a, ticker: SeqAssets.labelFor(a).ticker);
    return railAvailability(channels: _lnChannels, payTarget: t(pay), recvTarget: t(recv));
  }

  /// Per-leg Lightning rail toggles for a BTC pair (the twin of the web's #swRailPicks + renderRailNote).
  /// Shown only while Lightning is available; each toggle feeds [route], so the pair re-routes live
  /// between the on-chain cross, pure-Lightning, and sub-asset flows. When a leg is set to Lightning but
  /// has no usable channel yet, an honest note says so rather than silently promising "Instant".
  Widget _railPicks() {
    final ra = LightningService.instance.available ? _railAvail() : null;
    // ln is NULLABLE: null = unselected (no default). Neither button highlights until the user picks.
    Widget leg(String label, bool? ln, LegOption? verdict, ValueChanged<bool> onChanged) {
      Widget opt(String text, IconData icon, bool value) {
        final on = ln == value;
        return Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(AmbraRadii.input),
            onTap: () => onChanged(value),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? AmbraColors.amber.withValues(alpha: 0.12) : AmbraColors.panelDeep,
                border: Border.all(color: on ? AmbraColors.amber : AmbraColors.line),
                borderRadius: BorderRadius.circular(AmbraRadii.input),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 15, color: on ? AmbraColors.amber : AmbraColors.dim),
                const SizedBox(width: 6),
                Text(text, style: AmbraText.body.copyWith(color: on ? AmbraColors.amber : AmbraColors.txt)),
              ]),
            ),
          ),
        );
      }

      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AmbraText.sub),
        const SizedBox(height: 6),
        Row(children: [
          opt('On-chain', Icons.link, false),
          const SizedBox(width: 10),
          opt('Lightning', Icons.bolt, true),
        ]),
        // Honest per-leg note: this leg is set to Lightning but has no usable channel yet (mirrors the
        // web's renderRailNote). Never silently promise "Instant" when a channel must be arranged first.
        if (ln == true && !LightningService.instance.available) ...[
          const SizedBox(height: 6),
          Text('Lightning isn\'t set up yet · choose On-chain, or open a channel from the Balance tab.',
              style: AmbraText.sub.copyWith(color: AmbraColors.dim)),
        ] else if (ln == true && verdict != null && !verdict.ok) ...[
          const SizedBox(height: 6),
          Text('${verdict.reason} ${verdict.hint}', style: AmbraText.sub.copyWith(color: AmbraColors.dim)),
        ],
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel('How you pay & receive'),
      const SizedBox(height: 4),
      Text(_payRailLn == null || _recvRailLn == null
          ? 'Choose a settlement rail for each leg (there is no default). The book matches on price, not rail.'
          : 'Settlement preference · the book matches on price, not rail.',
          style: AmbraText.sub),
      const SizedBox(height: 8),
      leg('Pay from', _payRailLn, ra?.payLn, (v) => setState(() => _payRailLn = v)),
      const SizedBox(height: 12),
      leg('Receive to', _recvRailLn, ra?.recvLn, (v) => setState(() => _recvRailLn = v)),
      const SizedBox(height: 14),
    ]);
  }

  /// TRUE when the user is PAYING real Bitcoin ON-CHAIN. The "keep resting while offline" peg is
  /// relevant ONLY for this pay leg (not Lightning, not paying a Sequentia asset).
  bool get _payingBtcOnChain => _payAsset == kBtcSentinel && _payRailLn == false;

  /// The "Keep resting while offline" opt-out (spec §5, SBTC design §5) — the ONE place SBTC touches
  /// the DEX. Shown ONLY when paying on-chain BTC AND placing a LIMIT (post) order; hidden and
  /// irrelevant otherwise (market orders and any Lightning leg are pure native BTC). Default ON: the
  /// order rests as pegged BTC (SBTC) so it stays live while offline, and funds return as real BTC on
  /// fill/cancel. OFF: a native-BTC HTLC that needs the wallet online. The placement path reads
  /// _keepResting only when _payingBtcOnChain && _mode == 'post'.
  Widget _offlineRestToggle() {
    if (!(_payingBtcOnChain && _mode == 'post')) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        borderRadius: BorderRadius.circular(AmbraRadii.input),
        onTap: () => setState(() => _keepResting = !_keepResting),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 40,
            child: Switch(value: _keepResting, onChanged: (v) => setState(() => _keepResting = v)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _keepResting
                    ? 'Keep this order resting while you\'re offline. It rests as pegged BTC (SBTC) so it stays live without the app open; your funds return as regular BTC if it fills or is cancelled.'
                    : 'Rests as native BTC — keep the app open so the order stays live. Turn on to rest as pegged BTC and stay live while offline.',
                style: AmbraText.sub.copyWith(color: AmbraColors.dim),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// One-line "how it settles" summary for the resolved cross route, with an honest caveat when a
  /// Lightning leg has no usable channel yet (so we never promise a bare "Instant" before one opens).
  Widget _routeSummary(SwapRoute r) {
    var text = r.timing;
    // Dead rail: selling an asset for BTC on-chain (reverse cross courier) isn't built. Say so plainly
    // and point at the live sell rails, instead of the timing line that reads as a promise of settlement.
    final crossSellDead = r.kind == SwapRouteKind.cross && !r.payIsBtc;
    if (crossSellDead) {
      text = 'Selling ${_tk(r.seqAsset)} for Bitcoin on-chain is not available yet. '
          'Turn on the Lightning rail to sell over pure-LN, or use a sub-asset sell.';
    } else if (r.kind == SwapRouteKind.ln || r.kind == SwapRouteKind.mixed) {
      final ra = _railAvail();
      final payUnready = r.payRail == 'ln' && ra != null && !ra.payLn.ok;
      final recvUnready = r.recvRail == 'ln' && ra != null && !ra.recvLn.ok;
      if (payUnready || recvUnready) {
        text = '$text A Lightning channel may need to open first, which can take a moment.';
      }
    }
    return AmbraCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(crossSellDead ? Icons.info_outline : (r.kind == SwapRouteKind.ln ? Icons.bolt : Icons.schedule),
            size: 18, color: AmbraColors.amber),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: AmbraText.sub)),
      ]),
    );
  }

  /// Single dispatch for a BTC pair: push the downstream flow the resolved [route]
  /// selects, seeded with the composer's asset + amount so the user does not re-enter
  /// them. Same-chain pairs never reach here (they settle on the covenant book via
  /// [_submit]); this only wires the composer to the existing flows, it does not touch
  /// their fund-safety internals.
  /// Lift a resting cross (BTC->asset) offer from the book: open the courier lift wizard, then refresh
  /// the book + balances on return.
  /// The asset amount (atoms) the user typed in the cross composer, if any — the amount field sits on
  /// whichever leg is the Sequentia asset (_payAmount when paying the asset, _recvAmount when buying it).
  BigInt? _typedAssetAtoms(String asset, int aprec) {
    final t = (_payAsset == asset ? _payAmount : _recvAmount).text.trim();
    if (t.isEmpty) return null;
    final a = parseAtoms(t, aprec);
    return (a != null && a > BigInt.zero) ? a : null;
  }

  Future<void> _liftCross(CrossOffer o, {BigInt? requestedAtoms}) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => CrossLiftScreen(offer: o, requestedAtoms: requestedAtoms)));
    if (mounted) {
      _fetchBook();
      _load();
    }
  }

  /// A tappable banner for a persisted cross-chain swap that still holds locked BTC. Opens the
  /// mature XchainSwapScreen, which resumes the record (find-by-txid, non-broadcasting) and exposes
  /// the CLTV "Refund BTC" off-ramp — the reachable recovery surface for a courier lift.
  Widget _inFlightCrossBanner(XchainSwapRecord r) {
    final tk = SeqAssets.labelFor(r.seqAsset).ticker;
    return InkWell(
      borderRadius: BorderRadius.circular(AmbraRadii.card),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const XchainSwapScreen()));
        if (mounted) _load();
      },
      child: AmbraCard(
        child: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: AmbraColors.amber, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Cross-chain swap in progress · $tk', style: AmbraText.body),
              const SizedBox(height: 2),
              const Text('Your Bitcoin is locked. Tap to resume, or refund it after the timeout.', style: AmbraText.sub),
            ]),
          ),
          const Icon(Icons.chevron_right, size: 18, color: AmbraColors.dim),
        ]),
      ),
    );
  }

  Future<void> _dispatchCross(SwapRoute r) async {
    final asset = r.seqAsset;
    if (asset == null || !r.isValid) return;

    // LIMIT (post) on a BTC pair.
    if (_mode == 'post') {
      // BUY-with-on-chain-BTC + "keep resting while offline" ON: the SBTC silent peg (spec §5, the ONE
      // place SBTC touches the DEX). Peg the maker's real BTC to SBTC and rest it in a covenant
      // ADVERTISED as BTC so the order stays live while the wallet is offline; funds return as real BTC
      // on fill/cancel. Any OTHER post on a BTC pair still needs the native cross-offer poster this build
      // lacks, so it stays honest.
      if (_payingBtcOnChain && _keepResting) {
        await _placePeggedBtcOrder(asset);
        return;
      }
      _snack('Resting a Bitcoin order at your own price is coming. Use Market to take a resting offer now, '
          'or place a limit order on a same-chain pair.');
      return;
    }

    // On-chain cross (BTC<->asset) settles over the relay ORDER-BOOK COURIER (the durable book), NOT the
    // retired /dex RFQ. Review = lift the best resting offer, exactly like tapping it in the book.
    if (r.kind == SwapRouteKind.cross) {
      if (r.payIsBtc) {
        // BUY the asset with Bitcoin. The rail lifts one resting "buy" offer (maker sells the asset) IN
        // FULL — so pick the offer CLOSEST in size to what the user typed (tie-break cheaper), not just
        // the cheapest, else typing "1" could lift a 60-unit offer. With no typed amount, the cheapest.
        final aprec = SeqAssets.labelFor(asset).precision;
        final reqAtoms = _typedAssetAtoms(asset, aprec);
        final asks = _crossOffers.where((o) => o.makerSellsAsset).toList();
        if (asks.isEmpty) {
          _snack('No resting Bitcoin offer for ${_tk(asset)} yet — the makers post continuously; check back in a moment.');
          return;
        }
        if (reqAtoms != null && reqAtoms > BigInt.zero) {
          asks.sort((a, b) {
            final c = (a.assetAtoms - reqAtoms).abs().compareTo((b.assetAtoms - reqAtoms).abs());
            return c != 0 ? c : a.btcPerAssetAtom.compareTo(b.btcPerAssetAtom);
          });
        } else {
          asks.sort((a, b) => a.btcPerAssetAtom.compareTo(b.btcPerAssetAtom));
        }
        await _liftCross(asks.first, requestedAtoms: reqAtoms);
      } else {
        // SELL the asset for Bitcoin. The reverse HTLC courier isn't live, but the SBTC silent-peg
        // covenants ARE fillable: pay the asset, receive SBTC, peg the SBTC out to real BTC. Lift the
        // resting pegged covenant CLOSEST in asset size to what the user typed (tie-break cheapest asset
        // per BTC), matching the buy path's "lift in full" selection.
        if (_peggedOffers.isEmpty) {
          _snack('No resting Bitcoin bid for ${_tk(asset)} yet — check back in a moment, or sell over Lightning / a sub-asset swap.');
          return;
        }
        final aprec = SeqAssets.labelFor(asset).precision;
        final reqAtoms = _typedAssetAtoms(asset, aprec);
        final offers = List<SeqObOffer>.from(_peggedOffers);
        if (reqAtoms != null && reqAtoms > BigInt.zero) {
          offers.sort((a, b) {
            final c = (a.wantAtoms - reqAtoms).abs().compareTo((b.wantAtoms - reqAtoms).abs());
            return c != 0 ? c : a.priceAtomsPerBase.compareTo(b.priceAtomsPerBase);
          });
        } else {
          offers.sort((a, b) => a.priceAtomsPerBase.compareTo(b.priceAtomsPerBase));
        }
        await _takePeggedCovenant(offers.first);
      }
      return;
    }

    // The cross composer's single amount field sits on the Sequentia-asset leg (see _crossComposerChildren).
    final amtText = (_payAsset == asset ? _payAmount : _recvAmount).text.trim();
    final assetAmount = amtText.isEmpty ? null : amtText;
    final Widget? screen = switch (r.kind) {
      // Sub-asset submarine swap (asset over LN + BTC on-chain) — LSP-served, not /dex.
      SwapRouteKind.mixed => r.payIsBtc
          ? SubassetBuyScreen(asset: asset)
          : SubassetSellScreen(asset: asset, assetAmount: assetAmount),
      // Pure-LN: a BUY amount is BTC-to-spend (quoted in the wizard); a SELL amount is the asset.
      SwapRouteKind.ln => LightningSwapScreen(
          initialSide: r.payIsBtc ? 'buy' : 'sell',
          initialAsset: asset,
          initialAmount: r.payIsBtc ? null : assetAmount,
        ),
      SwapRouteKind.cross || SwapRouteKind.same || SwapRouteKind.invalid => null,
    };
    if (screen == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) _load(); // refresh balances + markets on return
  }

  // --- SBTC silent peg (spec §5) --------------------------------------------

  /// MAKER: rest a BUY-with-on-chain-BTC LIMIT order as a pegged (SBTC) covenant advertised as BTC, so
  /// it stays live while the wallet is offline. [asset] is the Sequentia asset being bought. The BTC
  /// bid amount is the pay leg (_payAmount, 8 dp); the asset wanted is the receive leg (_recvAmount).
  Future<void> _placePeggedBtcOrder(String asset) async {
    final aprec = SeqAssets.labelFor(asset).precision;
    final btcSats = parseAtoms(_payAmount.text, 8);
    final assetAtoms = parseAtoms(_recvAmount.text, aprec);
    if (btcSats == null || btcSats <= BigInt.zero) return _snack('Enter the amount of Bitcoin you pay.');
    if (assetAtoms == null || assetAtoms <= BigInt.zero) return _snack('Enter how much ${_tk(asset)} you want.');
    final btcBal = BigInt.tryParse(_bal(kBtcSentinel)) ?? BigInt.zero;
    if (btcSats > btcBal) return _snack('You only hold ${formatAtoms(btcBal.toString(), 8)} BTC.');
    if (SbtcPegService.sbtcAssetId() == null) {
      return _snack('SBTC (the pegged-BTC asset) isn\'t available on this network. Turn off '
          '"keep resting while offline" to rest as native BTC.');
    }
    final makerIndex = _SwapCache.makerIndexSeed++;
    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _PeggedPostReviewSheet(
        assetHex: asset,
        btcSats: btcSats,
        assetAtoms: assetAtoms,
        makerIndex: makerIndex,
        tipHeight: _tipHeight,
      ),
    );
    if (txid != null && mounted) {
      _payAmount.clear();
      _recvAmount.clear();
      _onSettled(txid, 'Order resting (pegged BTC)', clearBoth: true);
    }
  }

  /// TAKER: fill a resting pegged (SBTC-locking, BTC-advertised) covenant — pay the asset, receive SBTC,
  /// then peg the SBTC OUT to real BTC. Mirrors takePeggedCovenant + onCovMatched's peg-out branch.
  Future<void> _takePeggedCovenant(SeqObOffer offer) async {
    // Fill the covenant IN FULL (take all locked SBTC/BTC; pay all the asset it wants). The taker must
    // hold the asset + a small tSEQ fee.
    final asset = offer.quoteAsset; // asset_b — what the taker pays
    final payBal = BigInt.tryParse(_bal(asset)) ?? BigInt.zero;
    if (offer.wantAtoms > payBal) {
      return _snack('Not enough ${_tk(asset)} to fill this offer (needs ${formatAtoms(offer.wantAtoms.toString(), SeqAssets.labelFor(asset).precision)}).');
    }
    // Fee in the policy asset (tSEQ): the fill builder rejects the covenant's sold asset A (= the SBTC we
    // RECEIVE) as the fee asset, and tSEQ is universally accepted. Funded from the taker's own coins.
    final feeAsset = SeqAssets.policy;
    final feeAtoms = _feeAtomsFor(feeAsset);
    if ((BigInt.tryParse(_bal(feeAsset)) ?? BigInt.zero) < feeAtoms) {
      return _snack('Not enough ${_tk(feeAsset)} to pay the network fee.');
    }
    final txid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => _PeggedTakeReviewSheet(offer: offer, asset: asset, feeAsset: feeAsset, feeAtoms: feeAtoms),
    );
    if (txid != null && mounted) _onSettled(txid, 'Sold for BTC');
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
          // Flip the price DISPLAY direction (hidden on a BTC/cross pair, which is fixed to "1 asset = N BTC").
          if (!_pairIsCross(_payAsset!, _receiveAsset!)) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'Flip price direction',
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: _toggleFlip,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.swap_vert, size: 16, color: AmbraColors.dim),
                ),
              ),
            ),
          ],
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
    // pay-per-receive (quote-per-base in the OFFER's frame, whose base is the receive asset)…
    final payPerRecv = (o.wantAtoms.toDouble() / _pow10(payPrec)) / (o.baseAtoms.toDouble() / _pow10(recvPrec));
    // …re-expressed in the pair's CANONICAL display frame so buy and sell read identically:
    // qpb = quote per base = pay-per-receive when the display base is the receive asset, else its inverse.
    final dir = _pairDir(_payAsset!, _receiveAsset!);
    final qpb = dir.base == _receiveAsset ? payPerRecv : (payPerRecv > 0 ? 1 / payPerRecv : 0);
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
            child: Text('1 ${_tk(dir.base)} = ${_fmtPrice(qpb)} ${_tk(dir.quote)}',
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

  // --- live-data sections (24h stats, recent trades, recent activity) ---------

  /// One-line 24h strip near the book header: sparkline, 24h change, high, low,
  /// volume. Renders nothing until candle data exists (honest on an empty market).
  Widget _pairStatsStrip() {
    final s = _stats;
    if (s == null) return const SizedBox.shrink();
    final up = s.changePct >= 0;
    final col = up ? const Color(0xFF3DDC84) : AmbraColors.amber2;
    final chg = '${up ? '+' : ''}${s.changePct.toStringAsFixed(2)}%';
    final vl = SeqAssets.labelFor(s.sizeAsset);
    Widget chip(String label, String value) => Text.rich(TextSpan(style: AmbraText.sub, children: [
          TextSpan(text: '$label '),
          TextSpan(text: value, style: AmbraText.mono),
        ]));
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (s.pts.length >= 2)
            SizedBox(width: 84, height: 20, child: CustomPaint(painter: _SparklinePainter(s.pts, col))),
          Text.rich(TextSpan(style: AmbraText.sub, children: [
            const TextSpan(text: '24h '),
            TextSpan(text: chg, style: TextStyle(color: col, fontWeight: FontWeight.w700, fontSize: 13)),
          ])),
          if (s.hi.isFinite) chip('H', _fmtPrice(s.hi)),
          if (s.lo.isFinite) chip('L', _fmtPrice(s.lo)),
          chip('vol', '${formatAtoms(s.vol.toString(), vl.precision)} ${vl.ticker}'),
        ],
      ),
    );
  }

  /// Compact recent-trades feed under the book panel. Renders nothing when the
  /// active pair has no trades. Price is the canonical quote-per-base (inverted
  /// when the feed came back on the inverse direction); size is the size asset.
  Widget _recentTradesPanel() {
    final trades = _trades;
    if (trades.isEmpty || _payAsset == null || _receiveAsset == null) return const SizedBox.shrink();
    final dir = _pairDir(_payAsset!, _receiveAsset!);
    final bl = SeqAssets.labelFor(dir.base), ql = SeqAssets.labelFor(dir.quote);
    final sl = SeqAssets.labelFor(_tradesSizeAsset ?? dir.base);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: AmbraCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('Recent trades', style: AmbraText.body.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('price ${bl.ticker}/${ql.ticker}', style: AmbraText.sub),
          ]),
          const SizedBox(height: 4),
          for (final t in trades.take(12)) _tradeRow(t, sl.ticker, sl.precision),
        ]),
      ),
    );
  }

  Widget _tradeRow(SeqObTrade t, String sizeTicker, int sizePrec) {
    final p = _tradesInv ? (t.price > 0 ? 1 / t.price : 0) : t.price;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(child: Text(_fmtPrice(p), style: AmbraText.mono)),
        Text('${formatAtoms(t.size.toString(), sizePrec)} $sizeTicker',
            style: AmbraText.mono.copyWith(color: AmbraColors.dim)),
        const SizedBox(width: 10),
        SizedBox(width: 34, child: Text(_ago(t.ts), textAlign: TextAlign.right, style: AmbraText.sub)),
      ]),
    );
  }

  /// A minimal local activity log (newest ~5): same-chain covenant fills + posts
  /// logged from the review sheets. Cross-chain / Lightning receipts live elsewhere.
  /// Entry to the maker's resting-orders surface (view + reclaim a posted covenant
  /// order after it expires). Always available so a maker can find + manage orders.
  Widget _myOrdersLink() => Align(
        alignment: Alignment.centerLeft,
        child: GhostButton(
          label: 'My resting orders →',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => MyOrdersScreen(tipHeight: _tipHeight)),
          ),
        ),
      );

  Widget _recentActivity() {
    if (_loading || _receipts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionLabel('Recent activity'),
        const SizedBox(height: 8),
        AmbraCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(children: [
            for (final r in _receipts.take(5)) _receiptRow(r),
          ]),
        ),
      ]),
    );
  }

  Widget _receiptRow(TradeReceipt r) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.title, style: AmbraText.body),
              const SizedBox(height: 2),
              Text(r.status, style: AmbraText.sub),
            ]),
          ),
          const SizedBox(width: 10),
          Text(_ago(r.ts), style: AmbraText.sub),
        ]),
      );
}

/// A tiny polyline sparkline of the in-window closes, min/max-normalised to the
/// paint box. Under 2 points it draws nothing (the strip hides it anyway).
class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.points, this.color);
  final List<double> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    var min = points.first, max = points.first;
    for (final p in points) {
      if (p < min) min = p;
      if (p > max) max = p;
    }
    final rng = (max - min) == 0 ? 1.0 : (max - min);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = i / (points.length - 1) * size.width;
      final y = size.height - (points[i] - min) / rng * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.color != color || old.points != points;
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

/// The fee amount in its own asset plus a reference-currency approximation when the asset is
/// priced, e.g. "12.3 GOLD  (≈ 49.20 USD)". Falls back to just the amount when the asset is
/// unpriced (PriceService.approx returns null for an asset the feed can't value).
String _feeWithApprox(String hex, BigInt atoms) {
  final l = SeqAssets.labelFor(hex);
  final amt = '${formatAtoms(atoms.toString(), l.precision)} ${l.ticker}';
  final approx = PriceService.instance.approx(l.ticker, atoms.toString(), l.precision);
  return approx == null ? amt : '$amt  ($approx)';
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
      // Local activity receipt for the completed same-chain covenant fill.
      final recvTk = SeqAssets.labelFor(widget.recvAsset).ticker;
      final payTk = SeqAssets.labelFor(widget.payAsset).ticker;
      await TradeReceipts.log(id: 'take:$txid', title: 'Bought $recvTk with $payTk', status: 'Filled', txid: txid);
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
              _Row('Network fee', _feeWithApprox(widget.feeAsset, widget.feeAtoms)),
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

      // Local activity receipt: the offer is now accepted by the relay and resting.
      final sellTk = SeqAssets.labelFor(widget.payAsset).ticker;
      final wantTk = SeqAssets.labelFor(widget.recvAsset).ticker;
      final offerId = '${offer['offer_id'] ?? ''}';
      await TradeReceipts.log(
        id: 'post:${offerId.isEmpty ? covTxid : offerId}',
        title: 'Posted $sellTk→$wantTk order',
        status: 'Resting',
      );

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
              _Row('Funding fee', _feeWithApprox(widget.feeAsset, widget.feeAtoms)),
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

/// Confirm + run the SBTC silent-peg MAKER flow (spec §5): peg the maker's real BTC IN to SBTC, then
/// rest that SBTC in a covenant ADVERTISED as BTC so the order stays live while the wallet is offline;
/// funds return as real BTC on fill/cancel. Delegates to [SbtcPegService.placePeggedBtcCovenant], which
/// persists a pending peg-in BEFORE broadcasting the deposit and a PlacedCovenant BEFORE posting.
class _PeggedPostReviewSheet extends StatefulWidget {
  const _PeggedPostReviewSheet({
    required this.assetHex,
    required this.btcSats,
    required this.assetAtoms,
    required this.makerIndex,
    required this.tipHeight,
  });
  final String assetHex;
  final BigInt btcSats;
  final BigInt assetAtoms;
  final int makerIndex;
  final int tipHeight;
  @override
  State<_PeggedPostReviewSheet> createState() => _PeggedPostReviewSheetState();
}

class _PeggedPostReviewSheetState extends State<_PeggedPostReviewSheet> {
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
      // Payment auth up front (fail-closed): the flow SPENDS real BTC (the peg-in deposit) and funds a
      // covenant. One auth covers the whole flow (mirrors subasset_buy.fund).
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
      final placed = await SbtcPegService.placePeggedBtcCovenant(
        mnemonic: m,
        assetHex: widget.assetHex,
        btcSats: widget.btcSats,
        assetAtoms: widget.assetAtoms,
        makerIndex: widget.makerIndex,
        tipHeight: widget.tipHeight,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      final assetTk = SeqAssets.labelFor(widget.assetHex).ticker;
      await TradeReceipts.log(
        id: 'peg:${placed.covTxid}',
        title: 'Posted BTC→$assetTk order (offline-resting)',
        status: 'Resting',
        txid: placed.covTxid,
      );
      if (mounted) Navigator.pop(context, placed.covTxid);
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
          const Text('Review · rest a Bitcoin bid', style: AmbraText.h1),
          const SizedBox(height: 18),
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              _Row('You pay', _amt(kBtcSentinel, widget.btcSats)),
              _Row('You want', _amt(widget.assetHex, widget.assetAtoms)),
              _Row('Rests as', 'Pegged BTC (SBTC) in a covenant advertised as BTC — stays live while you\'re offline.'),
              _Row('On fill / cancel', 'Your funds return as real BTC (auto-redeemed at the bridge).'),
              _Row('Finality', 'Anchor-bound to Bitcoin (reverts only if Bitcoin reverts).'),
            ]),
          ),
          const SizedBox(height: 14),
          if (_busy && _status.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_status, style: AmbraText.muted)),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Pegging in can take a few blocks. Keep the app open; if you close it, the order '
                  'finishes automatically next time you open Swap.', style: AmbraText.sub),
            ),
          PrimaryButton(label: 'Confirm & rest', busy: _busy, icon: Icons.fingerprint, onPressed: _busy ? null : _confirm),
          const SizedBox(height: 6),
          GhostButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)),
        ]),
      ),
    );
  }
}

/// Confirm + run the SBTC silent-peg TAKER flow: fill a resting pegged covenant (advertised BTC, locks
/// SBTC) with the covenant FILL primitive — pay the asset, receive SBTC — then peg the SBTC OUT to real
/// BTC. Mirrors takePeggedCovenant + onCovMatched's peg-out branch. The peg-out is best-effort + safe:
/// on any failure the user simply holds redeemable SBTC (never lost).
class _PeggedTakeReviewSheet extends StatefulWidget {
  const _PeggedTakeReviewSheet({
    required this.offer,
    required this.asset,
    required this.feeAsset,
    required this.feeAtoms,
  });
  final SeqObOffer offer;
  final String asset; // asset_b — what the taker pays
  final String feeAsset;
  final BigInt feeAtoms;
  @override
  State<_PeggedTakeReviewSheet> createState() => _PeggedTakeReviewSheetState();
}

class _PeggedTakeReviewSheetState extends State<_PeggedTakeReviewSheet> {
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
      // Fill the covenant IN FULL: take all locked SBTC, pay the asset it wants. The covenant re-derives
      // + is checked against its on-chain scriptPubKey inside the FFI (anti-relay-lie).
      setState(() => _status = 'Building your FILL spend…');
      final built = await core.covenantBuildFillTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        covenantTermsJson: widget.offer.covenantTermsJson,
        takeAtoms: widget.offer.baseAtoms,
        feeAsset: widget.feeAsset,
        feeAtoms: widget.feeAtoms,
      );
      setState(() => _status = 'Broadcasting…');
      final txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: built.rawHex);
      final assetTk = SeqAssets.labelFor(widget.asset).ticker;
      await TradeReceipts.log(id: 'pegtake:$txid', title: 'Sold $assetTk for BTC', status: 'Filled', txid: txid);

      // Peg the received SBTC OUT to real BTC (we were buying BTC). Best-effort + safe: on any failure
      // the user simply holds redeemable SBTC. Mirrors pegOutReceivedSbtc / onCovMatched.
      if (SbtcPegService.isPeggedFillToRedeem(widget.offer)) {
        setState(() => _status = 'Redeeming your SBTC to BTC at the bridge…');
        try {
          await SbtcPegService.pegOutReceivedSbtc(mnemonic: m, atoms: widget.offer.baseAtoms);
        } catch (_) {
          // Non-fatal: the fill already settled. Leave a note; the SBTC is redeemable.
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(ambraSnack('Filled. You received SBTC (redeemable to BTC); auto-redeem will retry.'));
          }
        }
      }
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
          const Text('Review · sell for Bitcoin', style: AmbraText.h1),
          const SizedBox(height: 18),
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              _Row('You pay', _amt(widget.asset, widget.offer.wantAtoms)),
              _Row('You receive', _amt(kBtcSentinel, widget.offer.baseAtoms)),
              _Row('Network fee', _feeWithApprox(widget.feeAsset, widget.feeAtoms)),
              _Row('Settlement', 'Permissionless covenant fill; you receive pegged BTC (SBTC), auto-redeemed to real BTC.'),
              _Row('Finality', 'Anchor-bound to Bitcoin (reverts only if Bitcoin reverts).'),
            ]),
          ),
          const SizedBox(height: 14),
          if (_busy && _status.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_status, style: AmbraText.muted)),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AmbraColors.red))),
          PrimaryButton(label: 'Confirm & sell', busy: _busy, icon: Icons.fingerprint, onPressed: _busy ? null : _confirm),
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
