// The mixed same-chain sub-asset seams: the record JSON round-trips carrying quote_asset (the on-chain
// leg's REAL asset — losing it across a reload would refund/claim on the WRONG chain), and the pure
// BUY fill sizing in quote atoms (the "btc_sats" positions carry quote atoms; the math is precision-
// blind and must equal the maker's integer ProportionalBtc(ceil)).
//
//   cd app && flutter test test/subasset_mixed_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/lsp_client.dart';
import 'package:ambra/src/data/subasset_buy_service.dart';
import 'package:ambra/src/data/subasset_sell_service.dart';

const quoteHex = '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de'; // e.g. EURX

SubBuyRecord _buyRecord({String? quoteAsset}) => SubBuyRecord(
      step: SubBuyStep.funded,
      asset: '3a0f9192219db59f8d7f87d93ac6311095dfe1255d149727b87baaa7d2cc71a1',
      ticker: 'GOLD',
      preimage: 'aa' * 32,
      hashHex: 'bb' * 32,
      nodeKey: 'node-key',
      redeem: 'deadbeef',
      p2sh: 'XQoAddr',
      p2shSpk: 'a914cafe87',
      tBtc: 4321,
      btcSats: BigInt.from(125000),
      assetAtoms: BigInt.from(50),
      makerClaimPub: '02' * 33,
      refundPub: '03' * 33,
      offerId: 'offer-1',
      makerPubkey: '02maker',
      quoteAsset: quoteAsset,
      fundingTxid: 'f' * 64,
      vout: 1,
    );

void main() {
  group('SubBuyRecord JSON round-trip', () {
    test('carries quote_asset through toJson/fromJson', () {
      final r = _buyRecord(quoteAsset: quoteHex);
      final back = SubBuyRecord.fromJson(r.toJson());
      expect(back.quoteAsset, quoteHex);
      expect(back.step, SubBuyStep.funded);
      expect(back.btcSats, BigInt.from(125000), reason: 'quote atoms in the btc_sats position');
      expect(back.assetAtoms, BigInt.from(50));
      expect(back.tBtc, 4321, reason: 'a SEQUENTIA height on the mixed shape');
      expect(back.fundingTxid, 'f' * 64);
      expect(back.vout, 1);
    });

    test('the BTC shape round-trips with quote_asset null (and an older record without the key decodes)', () {
      final r = _buyRecord();
      final j = r.toJson();
      expect(SubBuyRecord.fromJson(j).quoteAsset, isNull);
      j.remove('quoteAsset'); // a record persisted by a pre-mixed build
      final back = SubBuyRecord.fromJson(j);
      expect(back.quoteAsset, isNull);
      expect(back.btcSats, BigInt.from(125000));
    });
  });

  group('SubSellRecord JSON round-trip', () {
    test('carries quote_asset + the claim leg through toJson/fromJson', () {
      final rec = SubSellRecord(
        step: SubSellStep.claiming,
        asset: '3a0f9192219db59f8d7f87d93ac6311095dfe1255d149727b87baaa7d2cc71a1',
        ticker: 'GOLD',
        expectedBtc: BigInt.from(2500), // quote atoms
        quoteAsset: quoteHex,
        preimage: 'aa' * 32,
        hashHex: 'bb' * 32,
        btcLeg: SubBtcHtlc.fromJson({
          'txid': 'e' * 64,
          'vout': 0,
          'amount': 2500,
          'redeem_script': 'deadbeef',
          'taker_claim_pubkey': '02' * 33,
          'maker_refund_pubkey': '03' * 33,
          't_btc': 999,
        }),
        swapNonce: 'cc' * 32,
      );
      final back = SubSellRecord.fromJson(rec.toJson());
      expect(back.quoteAsset, quoteHex);
      expect(back.step, SubSellStep.claiming);
      expect(back.expectedBtc, BigInt.from(2500));
      expect(back.btcLeg, isNotNull);
      expect(back.btcLeg!.amount, BigInt.from(2500), reason: 'quote atoms in the amount position');
      expect(back.btcLeg!.tBtc, 999, reason: 'a SEQUENTIA height on the mixed shape');
      expect(back.swapNonce, 'cc' * 32);
    });

    test('the BTC shape round-trips with quote_asset null (and an older record without the key decodes)', () {
      final rec = SubSellRecord(
        step: SubSellStep.paying,
        asset: 'aabb',
        ticker: 'GOLD',
        expectedBtc: BigInt.from(1000),
        swapNonce: 'dd' * 32,
        startedMs: 12345,
      );
      final j = rec.toJson();
      expect(SubSellRecord.fromJson(j).quoteAsset, isNull);
      j.remove('quoteAsset');
      expect(SubSellRecord.fromJson(j).quoteAsset, isNull);
    });
  });

  group('sizeSubBuyFill (a mixed take, in quote atoms)', () {
    // A GOLD/EURX offer: 50 GOLD (0-dp atoms) for 125000 EURX atoms (2 dp = 1250.00 EURX).
    final offerAtoms = BigInt.from(50);
    final offerBtc = BigInt.from(125000);

    test('no request -> the whole offer', () {
      final f = sizeSubBuyFill(offerAtoms: offerAtoms, offerBtc: offerBtc, reqBtcSats: null);
      expect(f.assetAtoms, offerAtoms);
      expect(f.btcSats, offerBtc);
    });

    test('a request >= the whole offer -> the whole offer (never oversubscribes)', () {
      final f = sizeSubBuyFill(offerAtoms: offerAtoms, offerBtc: offerBtc, reqBtcSats: BigInt.from(200000));
      expect(f.assetAtoms, offerAtoms);
      expect(f.btcSats, offerBtc);
    });

    test('a partial request takes a floor asset slice at the maker\'s EXACT ceil-proportional price', () {
      // 60000 quote atoms buys floor(50 * 60000 / 125000) = 24 GOLD, priced ceil(125000 * 24 / 50) = 60000.
      final f = sizeSubBuyFill(offerAtoms: offerAtoms, offerBtc: offerBtc, reqBtcSats: BigInt.from(60000));
      expect(f.assetAtoms, BigInt.from(24));
      expect(f.btcSats, BigInt.from(60000));
      // An uneven request floors the slice and re-prices it with CEIL (the maker's integer need):
      // 61000 -> floor(50*61000/125000) = 24 -> ceil(125000*24/50) = 60000, never the raw request.
      final g = sizeSubBuyFill(offerAtoms: offerAtoms, offerBtc: offerBtc, reqBtcSats: BigInt.from(61000));
      expect(g.assetAtoms, BigInt.from(24));
      expect(g.btcSats, BigInt.from(60000));
    });

    test('a dust request clamps to 1 asset atom, ceil-priced', () {
      // 1 quote atom -> floor slice 0 clamps to 1 atom -> price ceil(125000/50) = 2500 quote atoms.
      final f = sizeSubBuyFill(offerAtoms: offerAtoms, offerBtc: offerBtc, reqBtcSats: BigInt.one);
      expect(f.assetAtoms, BigInt.one);
      expect(f.btcSats, BigInt.from(2500));
    });

    test('large offers stay exact (BigInt, no float drift)', () {
      // The overflow class the web fixed: > 2^53 intermediate products must stay exact.
      final bigAtoms = BigInt.parse('900000000000000');
      final bigBtc = BigInt.parse('123456789012345678');
      final req = BigInt.parse('12345678901234567');
      final f = sizeSubBuyFill(offerAtoms: bigAtoms, offerBtc: bigBtc, reqBtcSats: req);
      final a = (bigAtoms * req) ~/ bigBtc;
      expect(f.assetAtoms, a);
      expect(f.btcSats, (bigBtc * a + bigAtoms - BigInt.one) ~/ bigAtoms);
    });
  });
}
