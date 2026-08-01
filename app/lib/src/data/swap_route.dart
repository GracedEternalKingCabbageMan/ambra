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

  /// True when this is a SAME-CHAIN asset↔asset pair with the QUOTE asset standing in BTC's structural
  /// place: pure Lightning (kind `ln` — both legs asset-over-LN, bound by one preimage) or MIXED (kind
  /// `mixed` — one asset-LN HTLC + one ON-CHAIN HTLC on the quote asset on the Sequentia chain). The
  /// LSP `/swap` carries [quoteAsset] as the counter asset. False for every BTC pair and the covenant book.
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

  /// The settlement rail of the BTC leg / the asset leg for a BTC<->asset route. On a BUY (pay BTC) the
  /// asset is the RECEIVE leg; on a SELL (pay the asset) the asset is the PAY leg. Null-safe defaults to
  /// 'chain' for a same-chain / invalid route (no BTC leg).
  String get _btcRail => payIsBtc ? payRail : recvRail;
  String get _assetRail => payIsBtc ? recvRail : payRail;

  /// A SUBMARINE mixed shape: the BTC leg on Lightning + the asset leg on-chain — the one that crosses on
  /// the BTC leg and settles via the P2P submarine taker (or the LSP leg-bridge fallback). Distinct from
  /// [isSubAsset] (the asset leg on Lightning + the BTC leg on-chain -> the LSP asset-over-LN rail).
  bool get isSubmarine => kind == SwapRouteKind.mixed && _btcRail == 'ln' && _assetRail == 'chain';

  /// A SUB-ASSET mixed shape: the asset leg on Lightning + the BTC leg on-chain (the LSP sub-asset rail).
  bool get isSubAsset => kind == SwapRouteKind.mixed && _assetRail == 'ln' && _btcRail == 'chain';

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
        if (assetAsset) {
          // Same-chain mixed: the on-chain leg is an HTLC on the QUOTE asset on Sequentia, not Bitcoin.
          return 'Mixed swap. One leg settles over Lightning, the other on-chain as an HTLC on the '
              'quote asset, bound by one secret.';
        }
        if (isSubmarine) {
          // BTC leg over Lightning + asset leg on-chain -> the peer-to-peer submarine taker.
          return payIsBtc
              ? 'Submarine swap. You pay Bitcoin over Lightning and receive the asset on-chain, '
                  'bound by one secret. Anchored to Bitcoin (reverts only if Bitcoin reverts).'
              : 'Submarine swap. You pay the asset on-chain and receive Bitcoin over Lightning, '
                  'bound by one secret. Anchored to Bitcoin (reverts only if Bitcoin reverts).';
        }
        // Asset leg over Lightning + BTC leg on-chain -> the sub-asset rail.
        return payIsBtc
            ? 'Sub-asset swap. You lock Bitcoin on-chain and receive the asset over Lightning, '
                'bound by one secret.'
            : 'Sub-asset swap. You pay the asset over Lightning and receive Bitcoin on-chain, '
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
    // MIXED same-chain (exactly one leg Lightning): a first-class combination (spec §5/§6.5), settled
    // P2P as the SUB-ASSET construction with the pair's canonical QUOTE asset standing in BTC's
    // structural place — one asset-LN HTLC (the base) + one ON-CHAIN HTLC on the QUOTE asset on the
    // Sequentia chain, bound by one preimage (mirror web findRoute's mixedSame branch). Same honest
    // gating as the BTC shapes: an 'ln' preference resolves only while Lightning is available (both
    // legs then read 'chain' -> the covenant book), and an unknown quote falls through to the covenant
    // book (never guess the frame). payIsBtc keeps its structural meaning of "paying the QUOTE side"
    // (= a BUY of the base). The orientations whose LIGHTNING leg is the quote are classified here too
    // ([isSubmarine]); dispatch refuses those by name — never a silent fall-through to `same`.
    if (payRailLn != null &&
        recvRailLn != null &&
        sameChainQuote != null &&
        sameChainQuote.isNotEmpty &&
        (pay == sameChainQuote || recv == sameChainQuote)) {
      final p = lnAvailable && payRailLn ? 'ln' : 'chain';
      final r = lnAvailable && recvRailLn ? 'ln' : 'chain';
      if (p != r) {
        final quote = sameChainQuote;
        final base = quote == pay ? recv : pay;
        return SwapRoute(
          kind: SwapRouteKind.mixed,
          pay: pay,
          recv: recv,
          seqAsset: base,
          quoteAsset: quote,
          assetAsset: true,
          payIsBtc: pay == quote,
          payRail: p,
          recvRail: r,
        );
      }
    }
    return SwapRoute(kind: SwapRouteKind.same, pay: pay, recv: recv);
  }
  final payIsBtc = pay == kBtcSentinel;
  final seqAsset = payIsBtc ? recv : pay;
  // HONEST gating: a leg may sit on 'ln' only while Lightning is available. A null (unselected) or
  // downgraded 'ln' preference resolves to 'chain' here, so the book/quote always renders and a stale
  // rail state can never route into a dead Lightning path — the proven cross rail is the fallback.
  final p = lnAvailable && (payRailLn ?? false) ? 'ln' : 'chain';
  final r = lnAvailable && (recvRailLn ?? false) ? 'ln' : 'chain';
  // Ambra serves FOUR BTC<->asset shapes, and the route now returns the REAL one for BOTH directions —
  // no silent degrade of the SUBMARINE leg to on-chain (which used to misroute a submarine into the cross
  // rail): pure-LN (both legs on Lightning), sub-asset (the ASSET leg on Lightning + the BTC leg
  // on-chain), SUBMARINE (the BTC leg on Lightning + the ASSET leg on-chain), and cross (both on-chain).
  // The mixed kind covers BOTH mixed-rail shapes; [SwapRoute.isSubmarine] / [SwapRoute.isSubAsset]
  // distinguish them off the per-leg rails so dispatch routes each correctly (submarine -> the P2P
  // submarine taker; sub-asset -> the LSP asset-over-LN rail).
  final SwapRouteKind kind;
  if (p == 'ln' && r == 'ln') {
    kind = SwapRouteKind.ln; // both legs on Lightning -> pure-LN
  } else if (p == 'chain' && r == 'chain') {
    kind = SwapRouteKind.cross; // both legs on-chain -> cross-chain HTLC
  } else {
    kind = SwapRouteKind.mixed; // one leg on Lightning + one on-chain -> submarine OR sub-asset
  }
  return SwapRoute(
      kind: kind, pay: pay, recv: recv, seqAsset: seqAsset, payIsBtc: payIsBtc, payRail: p, recvRail: r);
}

/// How a rail-blind cross route settles given the resting offer's signed capabilities — the Dart twin of
/// settlement-router.mjs `chooseSettlementPath` + subswap.js `dispatchSubswap`.
enum SettlementPath {
  /// Both legs settle on the rail each endpoint already wanted (no bridge, no submarine).
  native,

  /// A DIRECT peer-to-peer submarine (no LSP in the value path): the maker is interactive + accepts
  /// BTC-LN. ln_direction 1 = BUY (reverse submarine), 0 = SELL (normal submarine).
  p2pSubmarine,

  /// The LSP leg-bridge terminates the LN end (fallback vs an on-chain-only / passive covenant maker).
  lspBridge,

  /// The crossing has no single on-chain asset HTLC to settle (the maker rests the asset over Lightning),
  /// so neither the P2P submarine nor the LSP leg-bridge can settle it — honest-disable, never misroute.
  unsupported,
}

/// The settlement decision for a rail-blind cross route: which [path], and for a submarine which side is
/// on Lightning ([lnSide] 'payer' = a BUY, 'receiver' = a SELL) + the [lnDirection] the P2P submarine
/// taker runs (1 = reverse/buy, 0 = normal/sell).
class SettlementDispatch {
  const SettlementDispatch({required this.path, this.lnDirection, this.lnSide, this.reason});
  final SettlementPath path;
  final int? lnDirection;
  final String? lnSide;
  final String? reason;
}

/// The SPEED CLASS of a mixed-take candidate: how the taker's crossed leg settles once committed.
/// [native] = the maker itself serves the taker's rails (a P2P submarine / an asset-over-LN maker), so
/// the take settles at Sequentia speed — typically about a minute, no Bitcoin-confirmation wait.
/// [bridged] = the maker-first bridged path (the LSP terminates the crossed leg): settlement waits on
/// Bitcoin confirmations, typically 10-60+ minutes on testnet4, unless the LSP fronts from inventory.
enum MixedSpeed { native, bridged }

/// One candidate for a mixed BTC<->asset take, priced by its EXECUTED amounts — the amounts the take
/// itself would settle (for the whole-offer submarine/bridge rails: [sizeSubswapTake]'s take amounts),
/// never the advertised unit price. Review must equal execution, so selection compares the same numbers.
class MixedCandidate<T> {
  const MixedCandidate({
    required this.offer,
    required this.execAssetAtoms,
    required this.execBtcSats,
    required this.speed,
  });

  /// The book offer this candidate wraps (opaque to the planner).
  final T offer;

  /// The EXECUTED leg amounts — what would actually move, computed with the same proportional/rounding
  /// math the take uses.
  final BigInt execAssetAtoms;
  final BigInt execBtcSats;

  final MixedSpeed speed;
}

/// ROUTING HONESTY (the stared-at-a-conf-wait incident): choose the candidate for a mixed take AFTER
/// classifying every candidate's settlement path, never before. The rule: the best-priced NATIVE-fast
/// candidate wins whenever its executed price is EQUAL-OR-BETTER; a BRIDGED-slow candidate is chosen
/// ONLY when its executed price is STRICTLY better than every native one — a taker paying BTC over
/// Lightning must never wait on Bitcoin confirmations for the sake of an equal price. Executed price is
/// compared EXACTLY (BigInt cross-multiplication over the executed amounts — no float rounding); ties
/// inside a class keep the caller's order (the caller pre-ranks by coverage/closeness). [buy] true =
/// the taker pays BTC (fewer sats per atom is better); false = the taker receives BTC (more is better).
/// Returns null only for an empty candidate list. PURE.
MixedCandidate<T>? pickMixedCandidate<T>(List<MixedCandidate<T>> candidates, {required bool buy}) {
  // negative = a prices strictly better than b for this side. A zero-atom candidate is unpriceable and
  // compares as worst (never chosen over a priceable one).
  int cmp(MixedCandidate<T> a, MixedCandidate<T> b) {
    final aDead = a.execAssetAtoms <= BigInt.zero, bDead = b.execAssetAtoms <= BigInt.zero;
    if (aDead || bDead) return aDead == bDead ? 0 : (aDead ? 1 : -1);
    final c = (a.execBtcSats * b.execAssetAtoms).compareTo(b.execBtcSats * a.execAssetAtoms);
    return buy ? c : -c;
  }

  MixedCandidate<T>? bestOf(MixedSpeed s) {
    MixedCandidate<T>? best;
    for (final c in candidates) {
      if (c.speed != s) continue;
      if (best == null || cmp(c, best) < 0) best = c; // strict < keeps the caller's order on ties
    }
    return best;
  }

  final native = bestOf(MixedSpeed.native);
  final bridged = bestOf(MixedSpeed.bridged);
  if (native == null) return bridged;
  if (bridged == null) return native;
  return cmp(bridged, native) < 0 ? bridged : native; // bridged ONLY on a STRICTLY better executed price
}

/// Route a rail-blind cross [route] to its settlement PATH given the resting offer's caps — the Dart twin
/// of settlement-router.mjs `chooseSettlementPath` + subswap.js `dispatchSubswap`. The rail crossing is
/// always on the BTC leg (the asset leg is Sequentia on-chain); its lnSide names who is on Lightning.
/// An interactive maker that accepts BTC-LN settles PEER-TO-PEER (no LSP in the value path); else the LSP
/// leg-bridge. A crossing whose asset leg ALSO crosses ([makerAssetOnchain] false — the offer rests the
/// asset over Lightning) is 'unsupported': there is no single on-chain asset HTLC to settle. PURE.
SettlementDispatch chooseSettlementPath(
  SwapRoute route, {
  required bool makerInteractive,
  required bool makerBtcLn,
  bool makerAssetOnchain = true,
}) {
  // Only a SUBMARINE mixed shape (the BTC leg on Lightning + the asset leg on-chain) crosses on the BTC
  // leg. Every other shape is native to the composer's proven paths (cross / pure-LN / sub-asset).
  if (route.kind != SwapRouteKind.mixed || !route.isSubmarine) {
    return const SettlementDispatch(path: SettlementPath.native);
  }
  final side = route.payIsBtc ? 'buy' : 'sell';
  final lnSide = route.payIsBtc ? 'payer' : 'receiver'; // payer = BUY pays BTC-LN, receiver = SELL
  if (!makerAssetOnchain) {
    return SettlementDispatch(
        path: SettlementPath.unsupported,
        lnSide: lnSide,
        reason: 'the maker rests the asset over Lightning; this rail crossing needs an on-chain asset leg');
  }
  if (makerInteractive && makerBtcLn) {
    return SettlementDispatch(
        path: SettlementPath.p2pSubmarine, lnDirection: side == 'buy' ? 1 : 0, lnSide: lnSide);
  }
  return SettlementDispatch(path: SettlementPath.lspBridge, lnSide: lnSide);
}
