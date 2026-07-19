// The pre-lock fund-safety gate for a cross (BTC<->asset) lift: a taker must never lock BTC on a maker
// terms mismatch. Pure logic, no native lib.
//
//   cd app && flutter test test/cross_terms_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/cross_terms.dart';
import 'package:ambra/src/data/seqob_client.dart';

CrossOffer offer() => CrossOffer(
      offerId: 'x1',
      seqAsset: 'gold',
      makerSellsAsset: true,
      assetAtoms: BigInt.from(1244524),
      btcSats: BigInt.from(67173),
      makerPubkey: '03aa',
    );

CrossTerms terms({
  BigInt? btc,
  BigInt? asset,
  String claim = '03bb',
  String refund = '03cc',
  int bl = 200,
  int sl = 100,
  BigInt? fee,
}) =>
    CrossTerms(
      makerBtcClaimPub: claim,
      makerSeqRefundPub: refund,
      btcLocktime: bl,
      seqLocktime: sl,
      feeBtcSats: fee ?? BigInt.from(100),
      btcSats: btc ?? BigInt.from(67173),
      assetAtoms: asset ?? BigInt.from(1244524),
    );

void main() {
  test('matching terms with safe locktimes + small fee -> OK to lock', () {
    expect(validateCrossTerms(offer: offer(), terms: terms()), isNull);
  });

  test('BTC amount mismatch -> refused', () {
    expect(validateCrossTerms(offer: offer(), terms: terms(btc: BigInt.from(99999))), contains('Bitcoin amount'));
  });

  test('asset amount mismatch -> refused', () {
    expect(validateCrossTerms(offer: offer(), terms: terms(asset: BigInt.from(999))), contains('asset amount'));
  });

  test('missing maker key -> refused', () {
    expect(validateCrossTerms(offer: offer(), terms: terms(claim: '')), contains('missing a key'));
    expect(validateCrossTerms(offer: offer(), terms: terms(refund: '')), contains('missing a key'));
  });

  test('T_btc must exceed T_seq -> refused', () {
    expect(validateCrossTerms(offer: offer(), terms: terms(bl: 100, sl: 100)), contains('locktime ordering'));
    expect(validateCrossTerms(offer: offer(), terms: terms(bl: 90, sl: 100)), contains('locktime ordering'));
  });

  test('maker fee over ~1% + 1000 of the trade -> refused', () {
    // 67173 sats trade; cap = 67173/100 + 1000 = 1671. 2000 is over, 1500 is under.
    expect(validateCrossTerms(offer: offer(), terms: terms(fee: BigInt.from(2000))), contains('fee is too high'));
    expect(validateCrossTerms(offer: offer(), terms: terms(fee: BigInt.from(1500))), isNull);
  });
}
