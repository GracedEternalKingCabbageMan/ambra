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
    this.payIsBtc = false,
  });

  final SwapRouteKind kind;
  final String? pay;
  final String? recv;

  /// The Sequentia asset in a BTC<->asset route (null for `same` / `invalid`).
  final String? seqAsset;

  /// True when the PAY leg is BTC (a BUY of [seqAsset] with Bitcoin); false when
  /// the pay leg is the asset (a SELL of [seqAsset] for Bitcoin).
  final bool payIsBtc;

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
  bool payRailLn = false,
  bool recvRailLn = false,
  bool lnAvailable = true,
}) {
  if (pay == null || recv == null || pay.isEmpty || recv.isEmpty || pay == recv) {
    return const SwapRoute(kind: SwapRouteKind.invalid);
  }
  if (pay == kBtcSentinel && recv == kBtcSentinel) {
    return const SwapRoute(kind: SwapRouteKind.invalid); // BTC<->BTC is not a market
  }
  final btcPair = (pay == kBtcSentinel) != (recv == kBtcSentinel); // exactly one side BTC
  if (!btcPair) {
    return SwapRoute(kind: SwapRouteKind.same, pay: pay, recv: recv);
  }
  final payIsBtc = pay == kBtcSentinel;
  final seqAsset = payIsBtc ? recv : pay;
  // HONEST gating: a leg may sit on 'ln' only while Lightning is available. Any 'ln'
  // preference is downgraded to 'chain' here, so stale rail state can never route
  // into a dead Lightning path — the proven cross rail is the fallback.
  final p = lnAvailable && payRailLn ? 'ln' : 'chain';
  final r = lnAvailable && recvRailLn ? 'ln' : 'chain';
  final SwapRouteKind kind;
  if (p == 'ln' && r == 'ln') {
    kind = SwapRouteKind.ln; // both legs on Lightning -> pure-LN
  } else if (p == 'chain' && r == 'chain') {
    kind = SwapRouteKind.cross; // both legs on-chain -> cross-chain HTLC
  } else {
    kind = SwapRouteKind.mixed; // one leg each -> submarine swap
  }
  return SwapRoute(kind: kind, pay: pay, recv: recv, seqAsset: seqAsset, payIsBtc: payIsBtc);
}
