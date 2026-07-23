import 'package:ambra/src/data/market_walk.dart';
import 'package:ambra/src/data/seqob_client.dart' show SeqObOffer;
import 'package:flutter_test/flutter_test.dart';

/// A resting covenant SELL: sells [base] atoms of the receive asset, wants [want] atoms of the pay asset.
/// pay-per-receive (the price a buyer pays, cheaper = better) = want/base.
SeqObOffer _offer(int base, int want, {String maker = 'maker1', String id = '', int minLot = 1}) => SeqObOffer(
      raw: const {},
      offerId: id.isEmpty ? 'o$base-$want' : id,
      baseAsset: 'A',
      quoteAsset: 'B',
      tradeDir: 1,
      baseAtoms: BigInt.from(base),
      wantAtoms: BigInt.from(want),
      minLot: BigInt.from(minLot),
      covenant: const {'covenant_txid': 'deadbeef'},
      makerPubkey: maker,
      verified: true,
    );

void main() {
  group('planMarketWalk (same-chain market book-walk, spec §4)', () {
    test('buy 10 of a resting 43 takes only 10 (partial fill of one offer, never 43)', () {
      // One offer selling 43 at price 2 (want 86 for 43). Buying 10 must take 10, pay ceil(10*86/43)=20.
      final plan = planMarketWalk(offers: [_offer(43, 86)], wantBase: BigInt.from(10));
      expect(plan.fills.length, 1);
      expect(plan.fills.first.take, BigInt.from(10));
      expect(plan.fills.first.pay, BigInt.from(20)); // ceil(10 * 86 / 43)
      expect(plan.totalRecv, BigInt.from(10));
      expect(plan.partial, isFalse); // asked 10, got 10
    });

    test('sweeps ACROSS price levels best-first, partial-filling each', () {
      // Three levels within the slippage bound: 5@1.00 (want 5), 20@1.05 (want 21), 20@1.10 (want 22).
      // Buy 30: take 5 from L1, 20 from L2, 5 from L3 — walking best-first, the last level partial.
      final offers = [_offer(5, 5, id: 'l1'), _offer(20, 21, id: 'l2'), _offer(20, 22, id: 'l3')];
      final plan = planMarketWalk(offers: offers, wantBase: BigInt.from(30));
      expect(plan.fills.length, 3);
      expect(plan.fills[0].take, BigInt.from(5));
      expect(plan.fills[1].take, BigInt.from(20));
      expect(plan.fills[2].take, BigInt.from(5)); // partial fill of the 20-atom L3
      expect(plan.totalRecv, BigInt.from(30));
      expect(plan.partial, isFalse);
      // VWAP is between best and worst.
      expect(plan.vwap >= plan.bestPrice, isTrue);
      expect(plan.vwap <= plan.worstPrice, isTrue);
    });

    test('remainder with no liquidity is CANCELLED, not rested (IOC): partial=true', () {
      // Only 8 rest; asking 20 fills 8 and leaves the rest un-planned (a market order never rests).
      final plan = planMarketWalk(offers: [_offer(8, 8)], wantBase: BigInt.from(20));
      expect(plan.totalRecv, BigInt.from(8));
      expect(plan.partial, isTrue);
    });

    test('slippage bound stops the walk past 15% worse than the inside', () {
      // Inside price 1.0; a far level at 2.0 (100% worse) must NOT be swept.
      final offers = [_offer(5, 5, id: 'cheap'), _offer(100, 200, id: 'far')];
      final plan = planMarketWalk(offers: offers, wantBase: BigInt.from(50));
      // Only the cheap 5 fill; the 2.0 level is past the slippage floor.
      expect(plan.totalRecv, BigInt.from(5));
      expect(plan.partial, isTrue);
      expect(plan.fills.length, 1);
    });

    test('a level within the slippage bound IS swept', () {
      // Inside 1.0; a level at 1.1 (10% worse, under the 15% bound) is swept.
      final offers = [_offer(5, 5, id: 'a'), _offer(10, 11, id: 'b')];
      final plan = planMarketWalk(offers: offers, wantBase: BigInt.from(12));
      expect(plan.fills.length, 2);
      expect(plan.totalRecv, BigInt.from(12));
    });

    test('never self-fills (skips the taker own offers)', () {
      final offers = [_offer(10, 10, maker: 'ME', id: 'mine'), _offer(10, 12, maker: 'other', id: 'theirs')];
      final plan = planMarketWalk(offers: offers, wantBase: BigInt.from(5), ownMakerPubkey: 'me');
      expect(plan.fills.length, 1);
      expect(plan.fills.first.offer.offerId, 'theirs');
    });

    test('respects an all-or-nothing (minLot == size) offer: skips it when the remainder is smaller', () {
      // A cheap all-or-nothing 10 (minLot 10) then a divisible 20. Buying 5 can't partial the AON 10,
      // so it skips to the 20 and takes 5 there (never over-takes the AON offer to 10).
      final offers = [_offer(10, 10, id: 'aon', minLot: 10), _offer(20, 22, id: 'div')];
      final plan = planMarketWalk(offers: offers, wantBase: BigInt.from(5));
      expect(plan.fills.length, 1);
      expect(plan.fills.first.offer.offerId, 'div');
      expect(plan.fills.first.take, BigInt.from(5));
    });

    test('an all-or-nothing offer that FITS the remainder is taken whole', () {
      final offers = [_offer(10, 10, id: 'aon', minLot: 10)];
      final plan = planMarketWalk(offers: offers, wantBase: BigInt.from(10));
      expect(plan.fills.length, 1);
      expect(plan.fills.first.take, BigInt.from(10));
    });

    test('empty book / zero size -> empty plan', () {
      expect(planMarketWalk(offers: const [], wantBase: BigInt.from(10)).isEmpty, isTrue);
      expect(planMarketWalk(offers: [_offer(10, 10)], wantBase: BigInt.zero).isEmpty, isTrue);
    });
  });
}
