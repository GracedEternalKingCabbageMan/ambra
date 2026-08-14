// The ROUTING-HONESTY selection rule for mixed BTC<->asset takes ([pickMixedCandidate], swap_route.dart)
// — born from the live incident where a slow bridged cross maker at the top of the price sort shadowed a
// fast P2P submarine maker resting at essentially the same price, and the taker stared at a Bitcoin
// confirmation wait for 25+ minutes. The rule under test:
//
//   * the best-priced NATIVE-fast candidate wins at an EQUAL-OR-BETTER executed price;
//   * a BRIDGED-slow candidate is chosen ONLY for a STRICTLY better executed price;
//   * prices compare on the EXECUTED amounts (the same whole-offer math the take settles —
//     [sizeSubswapTake]), exactly (BigInt cross-multiplication), for BOTH sides (buy and sell).
//
// Pure planner functions — no widgets, no IO.
//
//   cd app && flutter test test/mixed_take_planner_test.dart

import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/subswap_service.dart';
import 'package:ambra/src/data/swap_route.dart';

MixedCandidate<String> cand(String id, MixedSpeed speed, int assetAtoms, int btcSats) =>
    MixedCandidate<String>(
      offer: id,
      execAssetAtoms: BigInt.from(assetAtoms),
      execBtcSats: BigInt.from(btcSats),
      speed: speed,
    );

void main() {
  group('pickMixedCandidate — the native-first selection rule', () {
    test('the incident shape: a native maker at the SAME price beats the bridged one, '
        'regardless of list order', () {
      // The bridged (cross) maker sorts first — exactly how the incident dispatcher saw the book.
      final picked = pickMixedCandidate<String>([
        cand('bridged-cross', MixedSpeed.bridged, 1000, 5000),
        cand('native-submarine', MixedSpeed.native, 1000, 5000),
      ], buy: true);
      expect(picked!.offer, 'native-submarine');
    });

    test('native wins at a BETTER price too (buy: fewer sats per atom)', () {
      final picked = pickMixedCandidate<String>([
        cand('bridged', MixedSpeed.bridged, 1000, 5000),
        cand('native', MixedSpeed.native, 1000, 4900),
      ], buy: true);
      expect(picked!.offer, 'native');
    });

    test('bridged is chosen ONLY for a STRICTLY better executed price (buy)', () {
      // Strictly better: 4999 sats for the same atoms — the bridged candidate may win.
      final strictly = pickMixedCandidate<String>([
        cand('native', MixedSpeed.native, 1000, 5000),
        cand('bridged', MixedSpeed.bridged, 1000, 4999),
      ], buy: true);
      expect(strictly!.offer, 'bridged');
      // Equal: never — an equal price buys no reason to wait on Bitcoin confirmations.
      final equal = pickMixedCandidate<String>([
        cand('native', MixedSpeed.native, 1000, 5000),
        cand('bridged', MixedSpeed.bridged, 1000, 5000),
      ], buy: true);
      expect(equal!.offer, 'native');
      // Worse: obviously not.
      final worse = pickMixedCandidate<String>([
        cand('native', MixedSpeed.native, 1000, 5000),
        cand('bridged', MixedSpeed.bridged, 1000, 5001),
      ], buy: true);
      expect(worse!.offer, 'native');
    });

    test('SELL side flips the frame: better = MORE sats for the same atoms, same strictness', () {
      // Bridged pays strictly more BTC for the seller's atoms -> bridged may win.
      final strictly = pickMixedCandidate<String>([
        cand('native', MixedSpeed.native, 1000, 5000),
        cand('bridged', MixedSpeed.bridged, 1000, 5001),
      ], buy: false);
      expect(strictly!.offer, 'bridged');
      // Equal -> native, exactly like the buy side.
      final equal = pickMixedCandidate<String>([
        cand('bridged', MixedSpeed.bridged, 1000, 5000),
        cand('native', MixedSpeed.native, 1000, 5000),
      ], buy: false);
      expect(equal!.offer, 'native');
    });

    test('prices compare on EXECUTED amounts, exactly — equal ratios at different scales tie '
        '(and the tie goes native)', () {
      // 1 atom / 7 sats vs 1000 atoms / 7000 sats: identical executed price, only exact
      // cross-multiplication sees the tie (doubles would too here, but the contract is BigInt-exact).
      final picked = pickMixedCandidate<String>([
        cand('bridged-small', MixedSpeed.bridged, 1, 7),
        cand('native-large', MixedSpeed.native, 1000, 7000),
      ], buy: true);
      expect(picked!.offer, 'native-large');
    });

    test('executed-amount comparison uses the same whole-offer math as the take (sizeSubswapTake): '
        'a typed request below the offer still executes — and is compared as — the WHOLE offer', () {
      // The taker types 400 atoms; both offers are whole-offer rails, so the EXECUTED amounts are the
      // offers themselves. The bridged offer looks better "per requested atom" only if you (wrongly)
      // priced the request instead of the execution.
      final want = BigInt.from(400);
      final nativeSize = sizeSubswapTake(want: want, offerAtoms: BigInt.from(400), offerBtc: BigInt.from(2000));
      final bridgedSize = sizeSubswapTake(want: want, offerAtoms: BigInt.from(300), offerBtc: BigInt.from(1500));
      // Review == execution: the candidate carries EXACTLY what sizeSubswapTake says would settle.
      final picked = pickMixedCandidate<String>([
        MixedCandidate<String>(
            offer: 'native',
            execAssetAtoms: nativeSize.takeAtoms,
            execBtcSats: nativeSize.takeBtc,
            speed: MixedSpeed.native),
        MixedCandidate<String>(
            offer: 'bridged',
            execAssetAtoms: bridgedSize.takeAtoms,
            execBtcSats: bridgedSize.takeBtc,
            speed: MixedSpeed.bridged),
      ], buy: true);
      // Equal executed price (5 sats/atom both) -> native wins the tie.
      expect(picked!.offer, 'native');
    });

    test('a single class stands alone: only-bridged is honestly served, only-native likewise', () {
      expect(
          pickMixedCandidate<String>([cand('bridged', MixedSpeed.bridged, 10, 50)], buy: true)!.offer,
          'bridged');
      expect(
          pickMixedCandidate<String>([cand('native', MixedSpeed.native, 10, 50)], buy: true)!.offer,
          'native');
      expect(pickMixedCandidate<String>(const [], buy: true), isNull);
    });

    test('within a class, a tie keeps the caller\'s pre-ranked order (coverage/closeness)', () {
      final picked = pickMixedCandidate<String>([
        cand('native-first', MixedSpeed.native, 1000, 5000),
        cand('native-second', MixedSpeed.native, 2000, 10000), // same price, later in the ranking
      ], buy: true);
      expect(picked!.offer, 'native-first');
    });

    test('an unpriceable (zero-atom) candidate never wins over a priceable one', () {
      final picked = pickMixedCandidate<String>([
        cand('native-zero', MixedSpeed.native, 0, 5000),
        cand('bridged-real', MixedSpeed.bridged, 1000, 5000),
      ], buy: true);
      expect(picked!.offer, 'bridged-real');
    });
  });
}
