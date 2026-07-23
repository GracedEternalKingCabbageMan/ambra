// Pure, unit-testable planner for a SAME-CHAIN MARKET order that WALKS the covenant book — the mobile
// twin of the web wallet's `takeMarketWalk` (swap.js). Spec §4: a market order crosses the resting
// offers that meet its price, best price first, PARTIAL-filling each, and NEVER rests a remainder (that
// is the maker's LIMIT path). This is the "buy-10-of-43" fix: asking to buy 10 sweeps 10 across as many
// resting SELLs as it takes, each partially, and cancels (does not rest) anything with no liquidity
// behind it.
//
// This file is PLANNING ONLY — no IO, no Flutter — so the sweep math is deterministic and testable. The
// composer's review sheet executes the plan by looping the PROVEN covenant FILL primitive
// (`covenantBuildFillTx` → broadcast) once per level; each fill is atomic (settles in full or not at
// all) and consensus-exact (the ceil price is enforced on-chain), so a mid-walk failure strands nothing.

import 'seqob_client.dart' show SeqObOffer;

/// The default slippage bound: walk down to 15% worse than the inside price, then stop (a partial fill,
/// never a rested remainder). Mirrors the web wallet's `MARKET_SLIP`.
const double kMarketSlip = 0.15;

/// One planned fill against a single resting covenant SELL: take [take] base atoms (the RECEIVE asset =
/// covenant asset A) from [offer], paying [pay] quote atoms (the PAY asset = asset B) for it. [pay] is the
/// covenant-enforced ceil price for the slice — the same relation the on-chain FILL builder enforces.
class MarketFill {
  const MarketFill({required this.offer, required this.take, required this.pay});
  final SeqObOffer offer;
  final BigInt take; // base atoms (receive asset) taken from this offer
  final BigInt pay; // quote atoms (pay asset) owed for [take], ceil price

  /// Pay-per-receive (quote per base) for this fill, in the OFFER's own frame.
  double get pricePayPerRecv => take > BigInt.zero ? pay.toDouble() / take.toDouble() : 0;
}

/// The result of planning a market sweep: the ordered per-level fills plus the aggregate the review shows
/// (so Review == execution, spec §6). Prices are pay-per-receive (quote per base) in the OFFER frame; the
/// composer re-expresses them in the pair's canonical display frame for the user.
class MarketWalkPlan {
  const MarketWalkPlan({
    required this.fills,
    required this.requested,
    required this.totalRecv,
    required this.totalPay,
    required this.bestPrice,
    required this.worstPrice,
  });

  final List<MarketFill> fills;
  final BigInt requested; // base atoms the taker asked for
  final BigInt totalRecv; // base atoms this plan actually fills
  final BigInt totalPay; // quote atoms this plan pays
  final double bestPrice; // pay-per-receive of the inside (cheapest) offer touched
  final double worstPrice; // pay-per-receive of the worst level touched

  bool get isEmpty => fills.isEmpty;

  /// The plan fills less than the taker asked for (thin book / slippage-bounded): the remainder is
  /// CANCELLED, never rested (spec §4). True whenever the walk could not source the full size.
  bool get partial => totalRecv < requested;

  /// Size-weighted average pay-per-receive (quote per base) across the swept levels, in the OFFER frame.
  double get vwap => totalRecv > BigInt.zero ? totalPay.toDouble() / totalRecv.toDouble() : bestPrice;

  /// Slippage of the realised sweep vs the inside price, as a fraction (0.02 = 2%). Frame-independent
  /// (a magnitude), so the composer can show it whichever way it displays prices.
  double get slippageFraction => bestPrice > 0 ? (vwap - bestPrice).abs() / bestPrice : 0;
}

/// The covenant-enforced pay for taking [take] base atoms from offer [o]: ceil(take · wantAtoms /
/// baseAtoms) of the quote asset. Matches the on-chain FILL builder's rounding exactly (an underpay is
/// rejected by consensus), so the plan's numbers are what actually executes.
BigInt quotePayForOffer(SeqObOffer o, BigInt take) {
  if (o.baseAtoms <= BigInt.zero) return BigInt.zero;
  final num = take * o.wantAtoms;
  return (num + o.baseAtoms - BigInt.one) ~/ o.baseAtoms;
}

/// Plan a same-chain MARKET sweep to BUY [wantBase] base atoms (the receive asset) by walking the resting
/// covenant SELLs cheapest-first. [offers] must be the fillable covenant SELLs for the direction, sorted
/// cheapest pay-per-receive first (as [OrderBook] already provides). Each fill is capped to the offer's
/// available size, so one fill NEVER over-takes an offer (spec §2.4). The walk stops once a level is
/// worse than [slipFraction] below the inside price (slippage bound); the unfilled remainder is simply
/// not planned — a market order rests nothing. The taker's OWN offers ([ownMakerPubkey]) are skipped so
/// a sweep never self-fills.
MarketWalkPlan planMarketWalk({
  required List<SeqObOffer> offers,
  required BigInt wantBase,
  String? ownMakerPubkey,
  double slipFraction = kMarketSlip,
}) {
  final mine = (ownMakerPubkey ?? '').toLowerCase();
  // Fillable, non-self offers with a real price, cheapest-first. [offers] is already sorted, but re-sort
  // defensively so the walk is correct even if a caller passes an unsorted list.
  final asks = <SeqObOffer>[
    for (final o in offers)
      if (o.baseAtoms > BigInt.zero &&
          o.wantAtoms > BigInt.zero &&
          (mine.isEmpty || o.makerPubkey.toLowerCase() != mine))
        o,
  ]..sort((a, b) => a.priceAtomsPerBase.compareTo(b.priceAtomsPerBase));

  if (asks.isEmpty || wantBase <= BigInt.zero) {
    return MarketWalkPlan(
        fills: const [], requested: wantBase, totalRecv: BigInt.zero, totalPay: BigInt.zero, bestPrice: 0, worstPrice: 0);
  }

  final best = asks.first.priceAtomsPerBase; // pay-per-receive of the inside offer
  final maxPrice = best * (1 + slipFraction); // refuse to pay worse than this
  var remaining = wantBase;
  var totRecv = BigInt.zero, totPay = BigInt.zero;
  var worst = best;
  final fills = <MarketFill>[];
  for (final o in asks) {
    if (remaining <= BigInt.zero) break;
    // asks are best-first, so once a level is past the slippage floor every later level is too — stop.
    if (o.priceAtomsPerBase > maxPrice + 1e-12) break;
    final take = remaining < o.baseAtoms ? remaining : o.baseAtoms; // never over-take this offer
    if (take <= BigInt.zero) continue;
    // A PARTIAL slice below this covenant's minimum lot is not fillable on-chain — SKIP this offer (a
    // smaller later offer may still fit the remainder), never over-take to reach the min. When the take is
    // the offer's WHOLE size (take == baseAtoms) it always clears minLot (minLot <= baseAtoms), so an
    // all-or-nothing offer that fits the remainder still fills.
    if (take < o.minLot && take < o.baseAtoms) continue;
    final pay = quotePayForOffer(o, take);
    if (pay <= BigInt.zero) continue;
    fills.add(MarketFill(offer: o, take: take, pay: pay));
    totRecv += take;
    totPay += pay;
    worst = o.priceAtomsPerBase;
    remaining -= take;
  }
  return MarketWalkPlan(
    fills: fills,
    requested: wantBase,
    totalRecv: totRecv,
    totalPay: totPay,
    bestPrice: best,
    worstPrice: worst,
  );
}
