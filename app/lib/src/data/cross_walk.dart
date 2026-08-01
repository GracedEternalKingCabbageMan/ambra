// ---------------------------------------------------------------------------
// cross_walk.dart — MULTI-OFFER planning for a CROSS-market (BTC -> asset) MARKET take: the mobile twin
// of the web wallet's walkBook (subswap.js) applied to the on-chain cross book, closing gap 11 (the
// take used to lift only the single best offer, so a request larger than it never reached the depth
// behind it).
//
// PLANNING ONLY — no IO, no persistence (the market_walk.dart idiom). The composer's review shows this
// plan's aggregate (true total + the uncancelled remainder) and the executor walks the SAME legs, so
// review and execution can never disagree. Legs execute ONE AT A TIME: each cross leg is an interactive
// courier session with its own recovery material (its own XchainSwapRecord, persisted by the existing
// per-leg lift path), so sequential execution means at most one leg's record is non-terminal at a time.
// A FAILED leg STOPS the walk — the remainder is never silently retried (web walkBook execution rule).
//
// PER-LEG SIZING (web: "summing per-leg amounts — rather than pro-rating the total — is what keeps
// every leg independently valid"): each leg is priced by the SAME rule as a single-offer take — a
// partial slice pays CEIL(offerBtc · slice / offerAtoms) sats (the maker's exact integer
// ProportionalBtc, which validateCrossTerms then binds the maker to), a whole lift pays the offer's
// own btcSats. A partial slice too small to settle (its BTC below dust + spend headroom) is SKIPPED,
// never force-grown past what the user asked for; a deeper offer may still fit the remainder.
// ---------------------------------------------------------------------------

import 'seqob_client.dart' show CrossOffer;

/// Bitcoin's canonical P2SH dust value + a conservative per-leg spend headroom: a partial slice whose
/// BTC side lands below this cannot settle (the post-fee claim/refund output would not relay), so the
/// planner skips it pre-session (mirror xminslice.go / kXrBtcDustLimit + kXrLegSpendFeeFloor).
final BigInt kCrossWalkMinLegSats = BigInt.from(546) + BigInt.from(2) * BigInt.from(1000);

/// The maker's exact integer price for a partial slice: CEIL(offerBtc · take / offerAtoms) — the same
/// value [validateCrossTerms] binds the maker's quote to, so the plan's numbers are what executes.
BigInt proportionalBtcCeil(BigInt offerBtc, BigInt take, BigInt offerAtoms) {
  if (offerAtoms <= BigInt.zero) return BigInt.zero;
  return (offerBtc * take + offerAtoms - BigInt.one) ~/ offerAtoms;
}

/// One planned leg: lift [takeAtoms] of [offer] for [takeBtc] sats ([partial] = a slice, not the whole
/// offer). Executed as its own interactive courier session with its own persisted record.
class CrossWalkLeg {
  const CrossWalkLeg({required this.offer, required this.takeAtoms, required this.takeBtc, required this.partial});
  final CrossOffer offer;
  final BigInt takeAtoms;
  final BigInt takeBtc;
  final bool partial;
}

/// The planned sweep: ordered legs (best price first) + the aggregate the review states, including the
/// honest remainder that CANNOT fill and will NOT be rested (a market order never rests — spec §4).
class CrossWalkPlan {
  const CrossWalkPlan({
    required this.legs,
    required this.requested,
    required this.filledAtoms,
    required this.filledBtc,
    required this.remainderAtoms,
  });

  final List<CrossWalkLeg> legs;
  final BigInt requested; // asset atoms the taker asked for
  final BigInt filledAtoms; // what the plan actually fills
  final BigInt filledBtc; // summed per-leg CEIL prices (what is actually paid)
  final BigInt remainderAtoms; // cannot fill from the book — cancelled, never rested

  int get offersUsed => legs.length;
  bool get isEmpty => legs.isEmpty;
  bool get complete => remainderAtoms == BigInt.zero && filledAtoms > BigInt.zero;
  bool get partial => filledAtoms > BigInt.zero && remainderAtoms > BigInt.zero;

  /// Volume-weighted sats per asset atom across the whole walk — the price that ACTUALLY executes
  /// (worse than the inside offer's when depth is swept), which is what the review must show.
  double get vwapSatsPerAtom =>
      filledAtoms > BigInt.zero ? filledBtc.toDouble() / filledAtoms.toDouble() : 0;
}

/// Plan a BUY of [want] asset atoms across the resting cross asks (maker-sells-asset offers),
/// cheapest first. [offers] should already be price-sorted; the walk re-sorts defensively. Offers with
/// no real size/price are skipped. Zero in, zero out — a caller that wants the whole best offer asks
/// for its size (the walkBook lesson: a blanked composer input must never rebuild as the full offer).
CrossWalkPlan planCrossWalk({required List<CrossOffer> offers, required BigInt want}) {
  final empty = CrossWalkPlan(
      legs: const [],
      requested: want > BigInt.zero ? want : BigInt.zero,
      filledAtoms: BigInt.zero,
      filledBtc: BigInt.zero,
      remainderAtoms: want > BigInt.zero ? want : BigInt.zero);
  if (want <= BigInt.zero || offers.isEmpty) return empty;
  final asks = <CrossOffer>[
    for (final o in offers)
      if (o.makerSellsAsset && o.assetAtoms > BigInt.zero && o.btcSats > BigInt.zero) o,
  ]..sort((a, b) => a.btcPerAssetAtom.compareTo(b.btcPerAssetAtom));
  if (asks.isEmpty) return empty;

  var left = want;
  var filledAtoms = BigInt.zero, filledBtc = BigInt.zero;
  final legs = <CrossWalkLeg>[];
  for (final o in asks) {
    if (left <= BigInt.zero) break;
    final whole = left >= o.assetAtoms;
    final take = whole ? o.assetAtoms : left;
    final btc = whole ? o.btcSats : proportionalBtcCeil(o.btcSats, take, o.assetAtoms);
    if (btc <= BigInt.zero) continue;
    // A partial slice below the settleable floor is SKIPPED (its own leg could not relay post-fee);
    // a whole-offer lift is the maker's own resting size and is taken as-is.
    if (!whole && btc < kCrossWalkMinLegSats) continue;
    legs.add(CrossWalkLeg(offer: o, takeAtoms: take, takeBtc: btc, partial: !whole));
    filledAtoms += take;
    filledBtc += btc;
    left -= take;
  }
  return CrossWalkPlan(
    legs: legs,
    requested: want,
    filledAtoms: filledAtoms,
    filledBtc: filledBtc,
    remainderAtoms: left > BigInt.zero ? left : BigInt.zero,
  );
}

/// The executor's honest summary: how far the walk got, and why it stopped.
class CrossWalkResult {
  const CrossWalkResult({
    required this.legsDone,
    required this.filledAtoms,
    required this.filledBtc,
    this.failedLeg,
    this.error,
  });

  final int legsDone; // legs that settled
  final BigInt filledAtoms;
  final BigInt filledBtc;
  final CrossWalkLeg? failedLeg; // the leg that stopped the walk (null = all settled)
  final Object? error; // what the failed leg threw

  bool get complete => failedLeg == null;
}

/// Execute [plan]'s legs ONE AT A TIME through [runLeg] (each an interactive session persisting its own
/// record). A failed leg STOPS the walk immediately — the remaining legs are NOT attempted and the
/// remainder is never silently retried; the caller reports the honest summary. Pure control flow over
/// the injected leg runner, so the stop-on-failure rule is unit-testable without a courier.
Future<CrossWalkResult> runCrossWalk(
  CrossWalkPlan plan,
  Future<void> Function(CrossWalkLeg leg, int index) runLeg,
) async {
  var done = 0;
  var atoms = BigInt.zero, btc = BigInt.zero;
  for (var i = 0; i < plan.legs.length; i++) {
    final leg = plan.legs[i];
    try {
      await runLeg(leg, i);
    } catch (e) {
      return CrossWalkResult(legsDone: done, filledAtoms: atoms, filledBtc: btc, failedLeg: leg, error: e);
    }
    done++;
    atoms += leg.takeAtoms;
    btc += leg.takeBtc;
  }
  return CrossWalkResult(legsDone: done, filledAtoms: atoms, filledBtc: btc);
}
