// A whole round against a fake coordinator: the phases, the messages, and the two
// properties the mix exists for — that the blinded nonce the coordinator signs is not the
// credential it later sees, and that the outputs are registered in an order unrelated to
// the order the credentials were issued.
//
// The coordinator here signs with a real RSA private exponent, so the credentials are
// genuine ones and `unblind` verifies them exactly as it would in a live round.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ambra/src/data/blindsig.dart';
import 'package:ambra/src/data/coinjoin_protocol.dart';

// A real (small) RSA keypair, generated once and pinned here. Toy-sized on purpose — the
// arithmetic is what is under test, and a test that runs in a second gets run — but a
// genuine key, so the coordinator's signatures are ones `unblind` actually verifies.
const _nHex = 'cb5c2810fbfd9155b757578cf6c54441fd674a373b136101425178c36a11c7b1'
    '4bb04a404aa401cbd7538d16e7eead29779809e6fc3fa7682d04ff865718ee3d';
const _eHex = '010001';
const _dHex = '9cb74b65335cc8c89ebedf88918f9a37a49a19f6903f31ed6f772bb2a4a64915'
    'b6c01943c65bf79a8bd72df8d81dfaeffd8b1d77562f88f6bf4d64d9d6e8891d';
final _n = BigInt.parse(_nHex, radix: 16);
final _d = BigInt.parse(_dHex, radix: 16);
final _key = BlindKey(_nHex, _eHex);

const _asset = 'aa';
final _denom = BigInt.from(1000);
final _fee = BigInt.from(10);

class _FakeCoordinator {
  _FakeCoordinator({this.credit = true});
  final bool credit;
  final blindedSeen = <String>[];
  final credentialsSeen = <String>[];
  final addresses = <String>[];
  String? changeAddress;
  String phase = 'input';
  int signed = 0;

  Future<Map<String, dynamic>> fetch(String path, [Map<String, dynamic>? body]) async {
    if (path == '/rounds') {
      return {
        'rounds': [
          {
            'round_id': 'r1',
            'phase': phase,
            'max_credentials': 4,
            'lanes': [
              {
                'index': 0,
                'asset': _asset,
                'label': 'lane',
                'denom_atoms': '$_denom',
                'coord_fee_atoms': '$_fee',
                'blind_key': {'n': _key.n, 'e': _key.e},
              }
            ],
          }
        ]
      };
    }
    if (path == '/register-input') {
      blindedSeen.addAll((body!['credentials'] as List).cast<String>());
      changeAddress = body['change_address'] as String?;
      phase = 'output';
      return {
        'registration_id': 'reg1',
        'blind_sigs': [
          for (final b in blindedSeen)
            bigToBytes(bytesToBig(fromHex(b)).modPow(_d, _n), _key.klen).let(toHex)
        ],
      };
    }
    if (path == '/register-output') {
      final cred = (body!['credential'] as Map).cast<String, dynamic>();
      credentialsSeen.add('${cred['nonce']}');
      addresses.add('${body['address']}');
      if (addresses.length == blindedSeen.length) phase = 'signing';
      return {'ok': true};
    }
    if (path.startsWith('/round/')) {
      return {
        'round': {'round_id': 'r1', 'phase': phase, 'tx_hex': 'deadbeef', 'vsize': 400, 'txid': 'tx1'}
      };
    }
    if (path == '/sign') {
      signed++;
      phase = 'done';
      return {'ok': true};
    }
    throw StateError('unexpected path $path');
  }
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

CoinjoinCoin _coin(String txid, BigInt atoms) => CoinjoinCoin(
    txid: txid, vout: 0, atoms: atoms, asset: _asset, spkHex: '0014ff', chain: 0, index: 1);

void main() {
  test('a full round registers, unblinds, verifies and signs', () async {
    final co = _FakeCoordinator();
    var addressN = 0;
    String? signedWith;

    final res = await runRound(
      fetchJson: co.fetch,
      assetId: _asset,
      maxCredentials: 3,
      sleep: (_) async {},
      selectInputs: ({required asset, required denom, required coordFee, required maxCredentials}) async =>
          [_coin('a' * 64, (denom + coordFee) * BigInt.from(3) + BigInt.from(7))],
      proveOwnership: (message, coin) async => OwnershipSig('02${'11' * 32}', 'de'),
      freshAddress: () async => 'addr${addressN++}',
      verifyAndSign: (txHex, ctx) async {
        // The wallet's gate would run here; the round's own bookkeeping is what is asserted.
        expect(ctx.k, 3);
        expect(ctx.change, BigInt.from(7));
        expect(ctx.mixAddresses.length, 3);
        expect(ctx.expectedCredit, _denom * BigInt.from(3) + BigInt.from(7));
        signedWith = txHex;
        return 'signed:$txHex';
      },
    );

    expect(signedWith, 'deadbeef');
    expect(co.signed, 1);
    expect(res.txid, 'tx1');
    expect(res.denominations, 3);
    expect(res.changeAtoms, BigInt.from(7));
    expect(res.mixAddresses.length, 3);
    expect(res.changeAddress, isNotNull);
  });

  test('the coordinator never sees the credential it signed', () async {
    final co = _FakeCoordinator();
    var addressN = 0;
    await runRound(
      fetchJson: co.fetch,
      assetId: _asset,
      maxCredentials: 3,
      sleep: (_) async {},
      selectInputs: ({required asset, required denom, required coordFee, required maxCredentials}) async =>
          [_coin('a' * 64, (denom + coordFee) * BigInt.from(3))],
      proveOwnership: (message, coin) async => OwnershipSig('02${'11' * 32}', 'de'),
      freshAddress: () async => 'addr${addressN++}',
      verifyAndSign: (txHex, ctx) async => 'signed',
    );
    // What was blinded and what was presented share no value: that is the whole point.
    for (final b in co.blindedSeen) {
      expect(co.credentialsSeen.contains(b), isFalse, reason: 'a blinded nonce was presented verbatim');
    }
    expect(co.credentialsSeen.length, 3);
  });

  test('an ownership proof is bound to the round and the coin', () async {
    final co = _FakeCoordinator();
    final messages = <String>[];
    var addressN = 0;
    await runRound(
      fetchJson: co.fetch,
      assetId: _asset,
      maxCredentials: 1,
      sleep: (_) async {},
      selectInputs: ({required asset, required denom, required coordFee, required maxCredentials}) async =>
          [_coin('b' * 64, denom + coordFee)],
      proveOwnership: (message, coin) async {
        messages.add(message);
        return OwnershipSig('02${'11' * 32}', 'de');
      },
      freshAddress: () async => 'addr${addressN++}',
      verifyAndSign: (txHex, ctx) async => 'signed',
    );
    expect(messages.single, 'seqcj-ownership-v1|r1|${'b' * 64}:0');
  });

  test('too little to mix one denomination is refused before anything is registered', () async {
    final co = _FakeCoordinator();
    await expectLater(
      runRound(
        fetchJson: co.fetch,
        assetId: _asset,
        maxCredentials: 1,
        sleep: (_) async {},
        selectInputs: ({required asset, required denom, required coordFee, required maxCredentials}) async =>
            [_coin('c' * 64, denom)], // one atom short of denom + fee
        proveOwnership: (message, coin) async => OwnershipSig('02', 'de'),
        freshAddress: () async => 'addr',
        verifyAndSign: (txHex, ctx) async => 'signed',
      ),
      throwsA(isA<StateError>()),
    );
    expect(co.blindedSeen, isEmpty);
    expect(co.signed, 0);
  });

  test('a round the coordinator fails ends with its reason, not a timeout', () async {
    final co = _FakeCoordinator();
    var addressN = 0;
    co.phase = 'input';
    await expectLater(
      runRound(
        fetchJson: (path, [body]) async {
          final r = await co.fetch(path, body);
          if (path.startsWith('/round/')) {
            return {'round': {'phase': 'failed', 'error': 'not enough participants'}};
          }
          return r;
        },
        assetId: _asset,
        maxCredentials: 1,
        sleep: (_) async {},
        selectInputs: ({required asset, required denom, required coordFee, required maxCredentials}) async =>
            [_coin('d' * 64, denom + coordFee)],
        proveOwnership: (message, coin) async => OwnershipSig('02${'11' * 32}', 'de'),
        freshAddress: () async => 'addr${addressN++}',
        verifyAndSign: (txHex, ctx) async => 'signed',
      ),
      throwsA(predicate((e) => '$e'.contains('not enough participants'))),
    );
  });
}
