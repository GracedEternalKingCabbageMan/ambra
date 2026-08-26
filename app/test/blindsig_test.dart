// Checked against the JS the coordinator's own end-to-end test proves: every vector here
// was produced by the vendored blindsig.js (seqcj/blindsig.mjs), so a credential this
// wallet mints is one that coordinator accepts. Nothing is asserted against Dart's own
// output — that would only prove it agrees with itself.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ambra/src/data/blindsig.dart';

const _n = 'df85ffbe284766063dc2c61755a0c40f52b4ce140dfd71d3621323a5ee9189cd'
    'fe9b952dcb70a5eeb66d75502be45816636f7f1ee30200a06985b351d5b023b6'
    '3d407db0cd5a2891b35e1cb77be5dbdc054acbd1ab2bafe421ffaca757b03902'
    '4fdf3bb0b0bbf2ba48f21311a0483d99106b256dba1fdc3447c47ab193383a21';
const _e = '010001';
const _blinded = 'b17c0d9d7fb7e27dfcb989ccf669d4ebd99e7fb6dfc66874d824031dc59f78b5'
    '0d7db5bb15850caec174afe21c2a0673674e3ceddd2bc147f05ff59d84fc3720'
    '89af64546f06afc01c2a762a12320cbea33a714865179eaff95b74c23211a5a3'
    '523388dfe35876af38697ccf7cc49fb68a5d87a51d661e54bdad7527be25d34b';
const _sBlinded = '6c9e170d810c22fbb362e2d135466707e0aa21318e926b55613e5357ea07ef28'
    'ac0e17f5f3792cc6e3b6d055bf1a414425f94f10ef75cb643ffb73b4aa5b647f'
    'eb63ba19435a00796842deaae0adf1e87c5945b649fb0cd6b2a5210a855039e1'
    '8ee2ede3f99dcab99af47f29394885c2da17679ddba2493446684b805625a4ab';
const _sig = '1650434a6e0c9ed1627911610953c4c63610af3f158ae04831a61b20ebe53e97'
    '4dffde8209880e9868f2a175ae7fcc3c30b1240715b11439e22125d22df64a60'
    '2bb189776c297537de52ab91f82853d1da291c1886bb0f4060fbf286b614a857'
    '92b552d8c323030394c502f00a51de3eaacc37302050afee3743966a00ce9717';
const _nonceHex = '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20';
final _nonce = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
final _key = BlindKey(_n, _e);
final _factor = BigInt.parse('123456789012345678901234567890');

void main() {
  test('the full-domain hash matches the JS', () {
    final m = fdh(_nonce, 128);
    expect(m.toRadixString(16).startsWith('8e6a307c879400d744b9032812db3a2e'), isTrue);
    // 127 bytes: strictly below the modulus, which is what makes the scheme sound.
    expect(m.toRadixString(16).length, 254);
  });

  test('blinding a nonce reproduces the JS blinded value', () {
    final b = blind(_key, nonce: _nonce, fixedFactor: _factor);
    expect(b.blinded, _blinded);
    expect(b.klen, 128);
  });

  test("unblinding the coordinator's answer yields the JS credential", () {
    final b = blind(_key, nonce: _nonce, fixedFactor: _factor);
    final cred = unblind(_key, _sBlinded, b);
    expect(cred.sig, _sig);
    expect(cred.nonce, _nonceHex);
    expect(verifyCredential(_key, cred), isTrue);
  });

  test('a garbled blind signature is caught at unblinding, not later', () {
    final b = blind(_key, nonce: _nonce, fixedFactor: _factor);
    final tampered = '${_sBlinded.substring(0, _sBlinded.length - 2)}00';
    expect(() => unblind(_key, tampered, b), throwsA(isA<StateError>()));
  });

  test('a credential for another nonce does not verify', () {
    expect(verifyCredential(_key, Credential(_nonceHex, _sig)), isTrue);
    final other = '00${_nonceHex.substring(2)}';
    expect(verifyCredential(_key, Credential(other, _sig)), isFalse);
  });

  test('a malformed credential is refused rather than thrown at the caller', () {
    for (final bad in ['', 'zz', '00']) {
      expect(verifyCredential(_key, Credential(_nonceHex, bad)), isFalse);
    }
  });

  test('every drawn nonce is fresh', () {
    final seen = <String>{};
    for (var i = 0; i < 50; i++) {
      expect(seen.add(toHex(randomBytes(32))), isTrue);
    }
  });
}
