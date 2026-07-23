// Pure rail router for the unified swap composer — the Dart port of the web
// wallet's swap.js `findRoute` (swap.js:531-592). It classifies a (pay, receive)
// pair into ONE settlement route so the composer can dispatch to the right flow
// with no separate RFQ buttons: same-chain covenant book, cross-chain HTLC book,
// pure-Lightning, or the sub-asset submarine swap. 100% pure (no IO, no Flutter),
// so it is unit-testable and every caller reads the same verdict.

/// The sentinel string for the Bitcoin parent-chain leg in the composer's pickers.
/// BTC is not a Sequentia asset id (it lives on the parent chain), so it is
/// represented by this fixed string everywhere the composer reasons about a leg —
/// mirroring the web wallet's `'BTC'` sentinel in swap.js.
const String kBtcSentinel = 'BTC';

/// How a (pay, receive) pair settles.
enum SwapRouteKind {
  /// Not a routable pair: nothing selected, the same asset twice, or BTC<->BTC.
  invalid,

  /// Both legs are Sequentia assets -> the same-chain covenant order book.
  same,

  /// One leg is BTC, both legs settle on-chain -> the cross-chain HTLC order book.
  cross,

  /// One leg is BTC, both legs settle over Lightning -> the pure-LN LSP route.
  ln,

  /// One leg over Lightning, the other on-chain -> the sub-asset submarine swap.
  mixed,
}

/// The resolved settlement route for a composer pair.
class SwapRoute {
  const SwapRoute({
    required this.kind,
    this.pay,
    this.recv,
    this.seqAsset,
    this.quoteAsset,
    this.assetAsset = false,
    this.payIsBtc = false,
    this.payRail = 'chain',
    this.recvRail = 'chain',
  });

  final SwapRouteKind kind;
  final String? pay;
  final String? recv;

  /// The Sequentia asset in a BTC<->asset route, OR the BASE asset in a same-chain pure-LN route
  /// ([assetAsset] true) — the one the counter/quote leg is priced against (null for `same` / `invalid`).
  final String? seqAsset;

  /// The COUNTER (quote) asset in a same-chain pure-LN route ([assetAsset] true) — it takes BTC's
  /// structural place as the leg the base is priced in. Null for a BTC<->asset or covenant route.
  final String? quoteAsset;

  /// True when this is a SAME-CHAIN asset↔asset pair settling over pure Lightning (both legs asset-over-LN,
  /// bound by one preimage), not a BTC<->asset LN route. The LSP `/swap` carries [quoteAsset] as the
  /// counter asset (priority D). False for every BTC pair and the covenant book.
  final bool assetAsset;

  /// True when the PAY leg is BTC (a BUY of [seqAsset] with Bitcoin); false when
  /// the pay leg is the asset (a SELL of [seqAsset] for Bitcoin).
  final bool payIsBtc;

  /// The RESOLVED settlement rail for each leg: 'ln' or 'chain'. Carried on the route (like the web
  /// wallet's route.payRail/recvRail) so dispatch reads the actual per-leg decision — the one bit that
  /// distinguishes a sub-asset swap (asset leg on Lightning) from a submarine (BTC leg on Lightning).
  final String payRail;
  final String recvRail;

  bool get isValid => kind != SwapRouteKind.invalid;

  /// A one-line, ticker-free description of HOW this route settles and its timing,
  /// for the composer's route summary (the mobile twin of the web's #swTiming banner).
  String get timing {
    switch (kind) {
      case SwapRouteKind.same:
        return 'Same-chain covenant swap. Settles in about one block, anchor-bound to Bitcoin '
            '(reverts only if Bitcoin reverts).';
      case SwapRouteKind.cross:
        return 'On-chain cross-chain swap. Both legs settle on-chain (about one block each), '
            'anchor-bound to Bitcoin.';
      case SwapRouteKind.ln:
        return 'Instant Lightning swap. Nothing settles on-chain, so there is no Bitcoin-reorg risk.';
      case SwapRouteKind.mixed:
        return payIsBtc
            ? 'Submarine swap. You lock Bitcoin on-chain and receive the asset over Lightning, '
                'bound by one secret.'
            : 'Submarine swap. You pay the asset over Lightning and receive Bitcoin on-chain, '
                'bound by one secret.';
      case SwapRouteKind.invalid:
        return '';
    }
  }
}

/// Classify a (pay, receive) pair into a settlement route. A direct port of the
/// web wallet's swap.js `findRoute`, simplified to Ambra's orchestration: the
/// per-leg rail PREFERENCES arrive as [payRailLn] / [recvRailLn] (set by the
/// composer's rail toggles, which only appear for a BTC leg while Lightning is
/// available), and [lnAvailable] gates them.
///
///   both Sequentia assets             -> same    (covenant book)
///   one BTC, both legs on-chain        -> cross   (cross-chain HTLC book)
///   one BTC, both legs over Lightning  -> ln      (pure-LN LSP route)
///   one BTC, one leg LN, one on-chain  -> mixed   (sub-asset submarine swap)
///   BTC<->BTC / same asset / empty     -> invalid
///
/// Without [lnAvailable], both legs are forced on-chain (the proven cross route),
/// independent of any stale rail preference — mirroring findRoute's lnDeployed gate.
SwapRoute route(
  String? pay,
  String? recv, {
  bool? payRailLn, // settlement preference; NULL = unselected (no default). Treated as on-chain for
  bool? recvRailLn, // the route KIND (so the book/quote renders); the UI gates placement on both != null.
  bool lnAvailable = true,
  String? sameChainQuote, // the canonical QUOTE asset of a same-chain pair (the composer's pairDir.quote),
  // so a both-Lightning same-chain pair can be classified as pure-LN with the counter asset (priority D).
}) {
  if (pay == null || recv == null || pay.isEmpty || recv.isEmpty || pay == recv) {
    return const SwapRoute(kind: SwapRouteKind.invalid);
  }
  if (pay == kBtcSentinel && recv == kBtcSentinel) {
    return const SwapRoute(kind: SwapRouteKind.invalid); // BTC<->BTC is not a market
  }
  final btcPair = (pay == kBtcSentinel) != (recv == kBtcSentinel); // exactly one side BTC
  if (!btcPair) {
    // Same-chain asset↔asset can settle over PURE Lightning too (two asset-LN HTLCs bound by one preimage),
    // the counter (quote) asset taking BTC's structural place — spec §5, web findRoute. Route there ONLY
    // when BOTH legs are set to Lightning AND Lightning is available AND we know the canonical quote;
    // otherwise the same-chain covenant order book. A stale/unselected rail resolves to the covenant book.
    final bothLn = lnAvailable && (payRailLn ?? false) && (recvRailLn ?? false);
    if (bothLn && sameChainQuote != null && sameChainQuote.isNotEmpty && (pay == sameChainQuote || recv == sameChainQuote)) {
      final quote = sameChainQuote;
      final base = quote == pay ? recv : pay; // the base leg is priced in the quote leg
      return SwapRoute(
        kind: SwapRouteKind.ln,
        pay: pay,
        recv: recv,
        seqAsset: base,
        quoteAsset: quote,
        assetAsset: true,
        payIsBtc: pay == quote, // "paying the quote" is the structural analog of paying BTC (a BUY of base)
        payRail: 'ln',
        recvRail: 'ln',
      );
    }
    return SwapRoute(kind: SwapRouteKind.same, pay: pay, recv: recv);
  }
  final payIsBtc = pay == kBtcSentinel;
  final seqAsset = payIsBtc ? recv : pay;
  // HONEST gating: a leg may sit on 'ln' only while Lightning is available. A null (unselected) or
  // downgraded 'ln' preference resolves to 'chain' here, so the book/quote always renders and a stale
  // rail state can never route into a dead Lightning path — the proven cross rail is the fallback.
  var p = lnAvailable && (payRailLn ?? false) ? 'ln' : 'chain';
  var r = lnAvailable && (recvRailLn ?? false) ? 'ln' : 'chain';
  // Ambra serves three BTC<->asset shapes: pure-LN (both legs on Lightning), sub-asset (the ASSET leg
  // on Lightning + the BTC leg on-chain), and cross (both on-chain). The fourth shape — SUBMARINE, the
  // BTC leg on Lightning + the ASSET leg on-chain — is not yet built on mobile, so degrade its
  // Lightning leg to on-chain here: the pair falls back to the proven on-chain cross rail (honest — the
  // user still gets a working swap) rather than misrouting to a sub-asset screen that does the inverse.
  // The asset leg is the RECEIVE leg on a BUY (pay BTC), the PAY leg on a SELL (pay the asset).
  final btcRail = payIsBtc ? p : r;
  final assetRail = payIsBtc ? r : p;
  if (btcRail == 'ln' && assetRail == 'chain') {
    p = 'chain';
    r = 'chain';
  }
  final SwapRouteKind kind;
  if (p == 'ln' && r == 'ln') {
    kind = SwapRouteKind.ln; // both legs on Lightning -> pure-LN
  } else if (p == 'chain' && r == 'chain') {
    kind = SwapRouteKind.cross; // both legs on-chain -> cross-chain HTLC
  } else {
    kind = SwapRouteKind.mixed; // asset leg on Lightning + BTC on-chain -> sub-asset submarine swap
  }
  return SwapRoute(
      kind: kind, pay: pay, recv: recv, seqAsset: seqAsset, payIsBtc: payIsBtc, payRail: p, recvRail: r);
}
