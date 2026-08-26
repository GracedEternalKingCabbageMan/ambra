// The signing gate, ported rule for rule from the module the browser wallet vendors from
// seqcj — and tested with the same cases, because this is the one function whose failure
// costs real money. A round that fails any of these is simply not signed, and unsigned
// coins were never spent.
import 'package:flutter_test/flutter_test.dart';
import 'package:ambra/src/data/coinjoin_protocol.dart';

final denom = BigInt.from(100000000);
final change = BigInt.from(250000);
final asset = 'aa' * 32;
const mixA = '0014aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const mixB = '0014bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const chg = '0014cccccccccccccccccccccccccccccccccccccccc';

MineOutput out(String spk, BigInt v, {String? a}) =>
    MineOutput(scriptPubkey: spk, asset: a ?? asset, value: v);

BigInt gate(List<MineOutput> mine, {String? changeScript = chg, BigInt? ch}) => verifyRoundOutputs(
      mine: mine,
      mixScripts: const [mixA, mixB],
      changeScript: changeScript,
      denom: denom,
      change: ch ?? change,
      asset: asset,
    );

void main() {
  test('a round that pays exactly what it promised is accepted', () {
    final credited = gate([out(mixA, denom), out(mixB, denom), out(chg, change)]);
    expect(credited, denom * BigInt.two + change);
  });

  test('a missing mixed output is refused', () {
    expect(() => gate([out(mixA, denom), out(chg, change)]), throwsA(isA<StateError>()));
  });

  test('a short-changed denomination is refused', () {
    expect(() => gate([out(mixA, denom), out(mixB, denom - BigInt.one), out(chg, change)]),
        throwsA(isA<StateError>()));
  });

  test('a mixed output in the wrong asset is refused', () {
    expect(() => gate([out(mixA, denom), out(mixB, denom, a: 'bb' * 32), out(chg, change)]),
        throwsA(isA<StateError>()));
  });

  test('missing or altered change is refused', () {
    expect(() => gate([out(mixA, denom), out(mixB, denom)]), throwsA(isA<StateError>()));
    expect(() => gate([out(mixA, denom), out(mixB, denom), out(chg, change - BigInt.one)]),
        throwsA(isA<StateError>()));
  });

  test('an unexpected output of mine is refused', () {
    // Not free money: an output of ours we did not register means this is not the round we
    // agreed to, and very likely a de-anonymising marker.
    expect(
        () => gate([out(mixA, denom), out(mixB, denom), out(chg, change), out('0014${'dd' * 20}', BigInt.one)]),
        throwsA(isA<StateError>()));
  });

  test('the same address paid twice is refused', () {
    expect(() => gate([out(mixA, denom), out(mixA, denom), out(chg, change)]),
        throwsA(isA<StateError>()));
  });

  test('change owed but never registered is refused', () {
    expect(() => gate([out(mixA, denom), out(mixB, denom)], changeScript: null),
        throwsA(isA<StateError>()));
  });

  test('an exact registration needs no change output', () {
    final credited = gate([out(mixA, denom), out(mixB, denom)],
        changeScript: null, ch: BigInt.zero);
    expect(credited, denom * BigInt.two);
  });

  test('script comparison is case-insensitive but exact otherwise', () {
    expect(gate([out(mixA.toUpperCase(), denom), out(mixB, denom), out(chg, change)]),
        denom * BigInt.two + change);
    final almost = '${mixA.substring(0, mixA.length - 1)}b';
    expect(() => gate([out(almost, denom), out(mixB, denom), out(chg, change)]),
        throwsA(isA<StateError>()));
  });
}
