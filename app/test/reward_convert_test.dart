// STAKING REWARD AUTO-CONVERSION — the parts that are pure.
//
// The decisions themselves (which coins are rewards, which batches convert) are
// the kit's and are tested in Rust; they cross the FFI boundary and are proved
// on a device, not here. What is tested here is what Dart owns: the whole-HTLC
// clamp, which is the guard against selling more than staking ever paid, and the
// per-asset totals a staker actually reads.

import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/reward_convert.dart';

void main() {
  group('a whole-HTLC offer is clamped to the batch', () {
    // The cross-chain rail picks the smallest offer that COVERS the request, so
    // the offer is routinely bigger than what staking paid. Taking it whole
    // would sell coins that were never rewards.
    test('a big offer sells only the batch', () {
      expect(RewardConvert.sliceForWholeHtlc(BigInt.from(5000), BigInt.from(1000)),
          BigInt.from(1000));
    });

    test('a small offer sells what it can; the rest waits', () {
      expect(RewardConvert.sliceForWholeHtlc(BigInt.from(600), BigInt.from(1000)),
          BigInt.from(600));
    });

    test('an exact match takes the whole batch', () {
      expect(RewardConvert.sliceForWholeHtlc(BigInt.from(1000), BigInt.from(1000)),
          BigInt.from(1000));
    });

    test('nothing to trade is not take-everything', () {
      expect(RewardConvert.sliceForWholeHtlc(BigInt.zero, BigInt.from(1000)), BigInt.zero);
      expect(RewardConvert.sliceForWholeHtlc(BigInt.from(5000), BigInt.zero), BigInt.zero);
      expect(RewardConvert.sliceForWholeHtlc(BigInt.from(-5), BigInt.from(10)), BigInt.zero);
    });
  });

  group('totals', () {
    test('separate what is spendable from what is still maturing', () {
      final t = rewardTotals(<Map<String, dynamic>>[
        {'asset': 'gold', 'value': 100, 'mature': true, 'spent': false, 'source': 'solo'},
        {'asset': 'gold', 'value': 250, 'mature': false, 'spent': false, 'source': 'solo'},
        {'asset': 'gold', 'value': 999, 'mature': true, 'spent': true, 'source': 'lottery'},
        {'asset': 'usdx', 'value': 7, 'mature': true, 'spent': false, 'source': 'split'},
      ]);
      final gold = t.firstWhere((x) => x['asset'] == 'gold');
      expect(gold['mature'], BigInt.from(100));
      expect(gold['immature'], BigInt.from(250));
      // A spent reward is still history worth counting, just not a holding.
      expect(gold['outputs'], 3);
      final usdx = t.firstWhere((x) => x['asset'] == 'usdx');
      expect((usdx['sources'] as Map<String, int>)['split'], 1);
    });

    test('no rewards is an empty list, not a zero row', () {
      expect(rewardTotals(<Map<String, dynamic>>[]), isEmpty);
    });
  });

  group('defaults', () {
    test('conversion is off, and Bitcoin is what it would convert into', () {
      // Off by default is not timidity: selling someone's rewards is
      // irreversible and they may have chosen those assets deliberately.
      final rc = RewardConvert();
      expect(rc.enabled, isFalse);
      expect(rc.target, RewardConvert.btc);
      expect(rc.maxSlippageBp, 200);
      expect(rc.convertedOutpoints, isEmpty);
    });
  });
}
