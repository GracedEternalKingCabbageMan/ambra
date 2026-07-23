// Pure, unit-testable price-LEVEL aggregation of the same-chain covenant book — the mobile twin of the
// web wallet's `aggregateLevels` (swap.js P2.7). Spec §3/§7: the terminal renders a real two-sided book
// "aggregated by price level, with size at each level and cumulative depth", not one row per resting
// offer. Many small offers at the same price collapse into ONE level whose size is the SUM, and the N
// best LEVELS (not the N best offers) show with running cumulative depth.
//
// PLANNING/DISPLAY ONLY — no IO, no Flutter — so it is deterministic and testable. Prices arrive already
// re-expressed in the pair's canonical DISPLAY frame (quote-per-base) via the caller's [priceOf], so the
// aggregation reads identically to the ladder Price column whichever way the composer displays it.

import 'seqob_client.dart' show SeqObOffer;

/// One aggregated price level: every resting offer at [price] (in the display frame), its summed base
/// size, the running cumulative depth best→here, and the constituent offers (so a tap can lift/select
/// the level's inside offer). Best-first ordering is the caller's responsibility via [aggregateLevels].
class BookLevel {
  BookLevel({required this.price, required this.sizeAtoms, required this.cumAtoms, required this.offers});

  /// Quote-per-base in the pair's canonical display frame (as [aggregateLevels]'s `priceOf` returned).
  final double price;

  /// Summed base atoms resting at this exact price level.
  final BigInt sizeAtoms;

  /// Cumulative base atoms from the inside (best) level through this one — the depth-to-fill readout.
  final BigInt cumAtoms;

  /// The constituent resting offers at this level, oldest-first as the book delivered them (FIFO within
  /// a level, spec §4). The inside offer ([offers.first]) is what a level tap lifts/selects.
  final List<SeqObOffer> offers;

  /// The best (inside) offer at this level, for selection/lift.
  SeqObOffer get insideOffer => offers.first;
}

/// Collapse [offers] into price LEVELS best-first. [priceOf] maps an offer to its display-frame
/// quote-per-base price (the caller supplies the frame so this stays pure); [keyDp] is the decimal
/// precision the price is keyed at so float dust never splits a level (mirrors the web's 10-dp key).
///
/// Offers with a non-positive price or size are dropped (unfillable). Levels are returned cheapest-price
/// first (ascending) — the natural best-first order for the covenant SELL ladder a buyer walks — with
/// [BookLevel.cumAtoms] accumulated in that order. Within a level, constituent offers keep their input
/// order (FIFO).
List<BookLevel> aggregateLevels(
  List<SeqObOffer> offers,
  double Function(SeqObOffer) priceOf, {
  int keyDp = 10,
}) {
  final byKey = <String, ({double price, List<SeqObOffer> offers})>{};
  final order = <String>[]; // preserve first-seen key order before the final sort
  for (final o in offers) {
    final p = priceOf(o);
    if (!(p > 0) || o.baseAtoms <= BigInt.zero) continue;
    final key = p.toStringAsFixed(keyDp);
    final lv = byKey[key];
    if (lv == null) {
      byKey[key] = (price: p, offers: [o]);
      order.add(key);
    } else {
      lv.offers.add(o);
    }
  }
  final levels = [for (final k in order) byKey[k]!]
    ..sort((a, b) => a.price.compareTo(b.price)); // cheapest (best for a buyer) first
  var cum = BigInt.zero;
  final out = <BookLevel>[];
  for (final lv in levels) {
    final size = lv.offers.fold(BigInt.zero, (a, o) => a + o.baseAtoms);
    cum += size;
    out.add(BookLevel(price: lv.price, sizeAtoms: size, cumAtoms: cum, offers: lv.offers));
  }
  return out;
}
