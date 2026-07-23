import 'package:ambra/src/data/book_levels.dart';
import 'package:ambra/src/data/seqob_client.dart' show SeqObOffer;
import 'package:flutter_test/flutter_test.dart';

/// A resting covenant SELL of [base] atoms wanting [want] atoms. pay-per-receive (want/base) is used as
/// the display price in these tests (the frame the composer passes via priceOf).
SeqObOffer _o(int base, int want, {String id = ''}) => SeqObOffer(
      raw: const {},
      offerId: id.isEmpty ? 'o$base-$want' : id,
      baseAsset: 'A',
      quoteAsset: 'B',
      tradeDir: 1,
      baseAtoms: BigInt.from(base),
      wantAtoms: BigInt.from(want),
      minLot: BigInt.one,
      covenant: const {'covenant_txid': 'deadbeef'},
      makerPubkey: 'maker',
      verified: true,
    );

double _price(SeqObOffer o) => o.wantAtoms.toDouble() / o.baseAtoms.toDouble();

void main() {
  group('aggregateLevels (price-level book aggregation, spec §3/§7)', () {
    test('collapses same-price offers into ONE level with SUMMED size', () {
      // Three offers all at price 2.0 (want = 2 * base): 5, 20, 8 -> one level of 33.
      final levels = aggregateLevels([_o(5, 10, id: 'a'), _o(20, 40, id: 'b'), _o(8, 16, id: 'c')], _price);
      expect(levels.length, 1);
      expect(levels.first.price, 2.0);
      expect(levels.first.sizeAtoms, BigInt.from(33));
      expect(levels.first.cumAtoms, BigInt.from(33));
      expect(levels.first.offers.length, 3);
      expect(levels.first.insideOffer.offerId, 'a'); // FIFO within the level
    });

    test('distinct prices become distinct levels, cheapest-first, with cumulative depth', () {
      // 10@1.0, 5@2.0, 4@3.0 (unsorted input) -> levels sorted 1,2,3 with cum 10,15,19.
      final levels = aggregateLevels([_o(4, 12, id: 'c'), _o(10, 10, id: 'a'), _o(5, 10, id: 'b')], _price);
      expect(levels.map((l) => l.price).toList(), [1.0, 2.0, 3.0]);
      expect(levels.map((l) => l.sizeAtoms).toList(), [BigInt.from(10), BigInt.from(5), BigInt.from(4)]);
      expect(levels.map((l) => l.cumAtoms).toList(), [BigInt.from(10), BigInt.from(15), BigInt.from(19)]);
    });

    test('float dust at the same price does not split a level (10-dp key)', () {
      // Two offers whose price differs below the 10-dp key resolution collapse into one level.
      final a = _o(3, 3, id: 'a'); // 1.0
      final b = _o(1000000000, 1000000001, id: 'b'); // 1.000000001 -> keyed identically at 10dp? differs at 9dp
      final levels = aggregateLevels([a, b], _price, keyDp: 6);
      expect(levels.length, 1); // both round to 1.000000 at 6 dp
      expect(levels.first.sizeAtoms, BigInt.from(1000000003));
    });

    test('drops unfillable (non-positive price or size) offers', () {
      final levels = aggregateLevels([_o(0, 5, id: 'zero-base'), _o(10, 0, id: 'zero-want'), _o(5, 5, id: 'ok')], _price);
      expect(levels.length, 1);
      expect(levels.first.offers.single.offerId, 'ok');
    });

    test('empty input -> no levels', () {
      expect(aggregateLevels(const [], _price), isEmpty);
    });
  });
}
