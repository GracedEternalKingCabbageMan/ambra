// Unit tests for the cross-market MULTI-OFFER walk (cross_walk.dart), gap 11:
//
//   1. PLANNING — the sweep crosses the sorted asks best price first, per-leg sized by the SAME rule as
//      a single-offer take (whole lift = the offer's own btcSats; partial slice = the maker's CEIL
//      price), states the TRUE aggregate, and reports the uncancelled remainder honestly (a market
//      order never rests). Dust-small partial slices are skipped, never force-grown.
//   2. EXECUTION — legs run ONE AT A TIME in plan order; a FAILED leg STOPS the walk immediately (the
//      remaining legs are never attempted, the remainder never silently retried) and the summary states
//      exactly how far it got.
//
//   cd app && flutter test test/cross_walk_test.dart

import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/cross_walk.dart';
import 'package:ambra/src/data/seqob_client.dart' show CrossOffer;

CrossOffer _ask(String id, int atoms, int sats) => CrossOffer(
      offerId: id,
      seqAsset: 'aa11',
      makerSellsAsset: true,
      assetAtoms: BigInt.from(atoms),
      btcSats: BigInt.from(sats),
      makerPubkey: '02$id',
    );

void main() {
  group('planCrossWalk (pure planning)', () {
    test('a request larger than the best offer sweeps the depth behind it, best price first', () {
      // cheap: 10 atoms @ 10k sats (1000 sats/atom); mid: 20 @ 24k (1200); dear: 50 @ 75k (1500).
      final offers = [_ask('dear', 50, 75000), _ask('cheap', 10, 10000), _ask('mid', 20, 24000)];
      final plan = planCrossWalk(offers: offers, want: BigInt.from(40));
      expect(plan.offersUsed, 3);
      expect(plan.legs[0].offer.offerId, 'cheap', reason: 'best price first (defensive re-sort)');
      expect(plan.legs[1].offer.offerId, 'mid');
      expect(plan.legs[2].offer.offerId, 'dear');
      // Whole lifts of cheap + mid, a partial slice of dear (10 of 50 -> CEIL(75000*10/50) = 15000).
      expect(plan.legs[0].takeAtoms, BigInt.from(10));
      expect(plan.legs[0].takeBtc, BigInt.from(10000));
      expect(plan.legs[0].partial, isFalse);
      expect(plan.legs[1].takeAtoms, BigInt.from(20));
      expect(plan.legs[1].takeBtc, BigInt.from(24000));
      expect(plan.legs[2].takeAtoms, BigInt.from(10));
      expect(plan.legs[2].takeBtc, BigInt.from(15000));
      expect(plan.legs[2].partial, isTrue);
      // AGGREGATE = the sum of per-leg amounts (each leg independently valid), not a pro-rated total.
      expect(plan.filledAtoms, BigInt.from(40));
      expect(plan.filledBtc, BigInt.from(10000 + 24000 + 15000));
      expect(plan.complete, isTrue);
      expect(plan.remainderAtoms, BigInt.zero);
      // The VWAP the review must show is worse than the inside price (depth was swept).
      expect(plan.vwapSatsPerAtom, greaterThan(1000));
    });

    test('a thin book leaves an HONEST remainder — never rested, never silently retried', () {
      final plan = planCrossWalk(offers: [_ask('only', 10, 10000)], want: BigInt.from(43));
      expect(plan.offersUsed, 1);
      expect(plan.filledAtoms, BigInt.from(10));
      expect(plan.remainderAtoms, BigInt.from(33));
      expect(plan.partial, isTrue);
      expect(plan.complete, isFalse);
    });

    test('per-leg CEIL pricing matches the single-offer partial-fill rule exactly', () {
      // CEIL(10000 * 3 / 7) = CEIL(4285.71) = 4286 — the maker's exact integer ProportionalBtc.
      expect(proportionalBtcCeil(BigInt.from(10000), BigInt.from(3), BigInt.from(7)), BigInt.from(4286));
    });

    test('a dust-small PARTIAL slice is skipped (never force-grown); a small WHOLE offer still fills', () {
      // Slicing 1 atom of 'big' would cost 100 sats (< dust floor) -> the partial leg is skipped.
      final partial = planCrossWalk(offers: [_ask('big', 100, 10000)], want: BigInt.one);
      expect(partial.isEmpty, isTrue, reason: 'an unsettleable slice is refused, not grown past the ask');
      expect(partial.remainderAtoms, BigInt.one);
      // But a WHOLE offer of the same tiny value is the maker's own resting size — taken as-is.
      final whole = planCrossWalk(offers: [_ask('tiny', 1, 100)], want: BigInt.one);
      expect(whole.offersUsed, 1);
      expect(whole.legs.single.partial, isFalse);
    });

    test('zero in, zero out (the blanked-composer lesson) + non-ask offers are ignored', () {
      expect(planCrossWalk(offers: [_ask('a', 10, 10000)], want: BigInt.zero).isEmpty, isTrue);
      final bid = CrossOffer(
        offerId: 'bid',
        seqAsset: 'aa11',
        makerSellsAsset: false, // a BID (maker gives BTC) — never walked by the BUY planner
        assetAtoms: BigInt.from(10),
        btcSats: BigInt.from(10000),
        makerPubkey: '02bid',
      );
      expect(planCrossWalk(offers: [bid], want: BigInt.from(5)).isEmpty, isTrue);
    });
  });

  group('runCrossWalk (sequential execution, stop-on-failure)', () {
    final offers = [_ask('a', 10, 10000), _ask('b', 20, 24000), _ask('c', 50, 75000)];

    test('all legs settle IN ORDER, one at a time; the summary states the full fill', () async {
      final plan = planCrossWalk(offers: offers, want: BigInt.from(80));
      final ran = <String>[];
      var concurrent = 0, maxConcurrent = 0;
      final res = await runCrossWalk(plan, (leg, i) async {
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        await Future<void>.delayed(Duration.zero);
        ran.add(leg.offer.offerId);
        concurrent--;
      });
      expect(ran, ['a', 'b', 'c'], reason: 'plan order, best price first');
      expect(maxConcurrent, 1, reason: 'ONE leg at a time — each is its own interactive session');
      expect(res.complete, isTrue);
      expect(res.legsDone, 3);
      expect(res.filledAtoms, BigInt.from(80));
      expect(res.filledBtc, BigInt.from(10000 + 24000 + 75000));
    });

    test('a failed leg STOPS the walk: later legs never run, the summary is honest', () async {
      final plan = planCrossWalk(offers: offers, want: BigInt.from(80));
      final ran = <String>[];
      final res = await runCrossWalk(plan, (leg, i) async {
        if (leg.offer.offerId == 'b') throw Exception('maker vanished mid-lift');
        ran.add(leg.offer.offerId);
      });
      expect(ran, ['a'], reason: 'leg c must NOT be attempted after b fails');
      expect(res.complete, isFalse);
      expect(res.legsDone, 1);
      expect(res.filledAtoms, BigInt.from(10), reason: 'only what actually settled');
      expect(res.filledBtc, BigInt.from(10000));
      expect(res.failedLeg!.offer.offerId, 'b');
      expect('${res.error}', contains('maker vanished'));
    });

    test('a failure on the FIRST leg reports zero fill (nothing settled, nothing retried)', () async {
      final plan = planCrossWalk(offers: offers, want: BigInt.from(80));
      final res = await runCrossWalk(plan, (leg, i) async => throw Exception('no terms'));
      expect(res.legsDone, 0);
      expect(res.filledAtoms, BigInt.zero);
      expect(res.failedLeg!.offer.offerId, 'a');
    });
  });
}
