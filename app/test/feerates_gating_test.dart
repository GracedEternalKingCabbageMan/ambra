// Mobile twin of the web wallet's feerates-gating.test.mjs. Pins the first-principle fee rule:
// tSEQ (the policy asset) is de-privileged — it is offered as a fee option ONLY when this node's
// /feerates feed prices it, judged by the EXACT same predicate as every issued asset, with no
// fabricated fallback rate. The feed keys the policy/reference asset under "bitcoin" (Elements
// naming); every other asset by ticker or hex.
//
// This re-implements send_screen.dart's `_rateFor` / `_feeOptions` predicates standalone (the real
// logic lives in the SendScreen State), so keep it in lockstep with send_screen.dart if that changes.
//
//   cd app && flutter test test/feerates_gating_test.dart
import 'package:flutter_test/flutter_test.dart';

const policy = 'pppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppp'; // stand-in tSEQ id
const gold = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const oilx = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _ticker = {policy: 'tSEQ', gold: 'GOLD', oilx: 'OILX'};

// Mirror of send_screen.dart `_rateFor`: the policy asset resolves from the feed's "bitcoin"
// reference key like any asset; others by ticker or hex. null = not producer-priced.
BigInt? rateFor(Map<String, BigInt> feed, String hex) {
  if (hex == policy) return feed['bitcoin'];
  final t = _ticker[hex];
  return (t != null ? feed[t] : null) ?? feed[hex];
}

// Mirror of send_screen.dart `_feeOptions`: a held asset is offered iff a producer prices it (no
// policy-asset exception, no fabricated fallback). '' = the policy asset (tSEQ), one option among equals.
List<String> feeOptions(Map<String, BigInt> feed, List<String> held) => held
    .where((id) => rateFor(feed, id) != null)
    .map((id) => id == policy ? '' : id)
    .toList();

void main() {
  test('feed PRICES tSEQ -> tSEQ offered + priced assets offered, unpriced gated out', () {
    final feed = {'bitcoin': BigInt.from(100000000), 'GOLD': BigInt.from(200000000)}; // OILX absent
    final offered = feeOptions(feed, [policy, gold, oilx]);
    expect(offered.contains(''), isTrue, reason: 'tSEQ offered when the feed prices it (via "bitcoin")');
    expect(offered.contains(gold), isTrue, reason: 'a priced held asset is offered');
    expect(offered.contains(oilx), isFalse, reason: 'an unpriced held asset is gated out — same rule as tSEQ');
    expect(rateFor(feed, policy), BigInt.from(100000000), reason: 'tSEQ rate comes from the feed reference, not fabricated');
  });

  test('feed OMITS tSEQ -> tSEQ NOT offered (de-privileged), other priced assets still offered', () {
    final feed = {'GOLD': BigInt.from(200000000), 'OILX': BigInt.from(3)}; // no "bitcoin" -> SEQ not accepted
    expect(rateFor(feed, policy), isNull, reason: 'no fabricated reference when the feed omits it');
    final offered = feeOptions(feed, [policy, gold, oilx]);
    expect(offered.contains(''), isFalse, reason: 'tSEQ is NOT offered when the feed omits it (no privilege)');
    expect(offered.contains(gold), isTrue);
    expect(offered.contains(oilx), isTrue);
  });
}
