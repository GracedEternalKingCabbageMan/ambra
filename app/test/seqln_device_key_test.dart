// Host-side proof that the new device-transport-key FFI bridges to Dart and
// derives a valid, deterministic Noise static key from the mnemonic (the mobile
// twin of the web wallet's lnDeviceTransportPriv: standard BIP39 seed -> BIP32
// m/1017'/0'/0').
//
//   cd app && flutter test test/seqln_device_key_test.dart
//
// (Requires the host cdylib: `cargo build` in ../ambra_core first.)

import 'dart:io' show Platform;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/rust/api/signer.dart';
import 'package:ambra/src/rust/frb_generated.dart';

// Flutter runs tests with the package dir (app/) as the working directory;
// override with AMBRA_CORE_LIB for out-of-tree builds.
final _hostLib = Platform.environment['AMBRA_CORE_LIB'] ??
    '../ambra_core/target/debug/libambra_core.so';

// A fixed BIP39 test mnemonic (the all-"abandon" vector); testnet only.
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

// The live GOLD asset id — a per-asset provisioned-node identity vector.
const _goldId = '3a0f9192219db59f8d7f87d93ac6311095dfe1255d149727b87baaa7d2cc71a1';

// EXPECTED derivations, computed by running the web wallet's ACTUAL seqln-keys.js
// (lnDeriveNode / lnDeriveAsset) in Node for _mnemonic — the source of truth the LSP keys
// nodes by. If these ever diverge, the mobile device signer would derive a DIFFERENT node
// id/transport pubkey than the browser and the LSP could not pin one identity per wallet.
const _expected = {
  'asset_transport': 'd02e7f53b719e2921f972f3e54f5d37d04f17cda0889b0909042ccb93d80180d',
  'asset_signing': '05f8a46113d05e5f7ccccd1af1e590201d6e221d63cfd53ba55022a4a47f2fcf',
  'btc_transport': '5f9aadde083ea59312db0ca55f5f419859602be95ccb8a8e0be4bb58c48e2188',
  'btc_signing': '273c358c8a38a19a80b793b276c61bf9badd3db75c5e75ef55eb96aa4311d2d0',
  'perasset_transport': 'fba50a5529cc98ae4ea314014b60cb3c49a2478593cbf3a98dd0affc96f6b9a6',
  'perasset_signing': '5904adc2c68229ae6907a481dfc4b8b9ad45612b2ef09253480e43b387959084',
};

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(_hostLib));
  });

  test('derives a 32-byte device transport key, deterministically', () {
    final k1 = seqlnDeviceTransportPrivkey(mnemonic: _mnemonic);
    final k2 = seqlnDeviceTransportPrivkey(mnemonic: '  $_mnemonic  '); // trimmed
    expect(k1.length, 32);
    expect(k2, k1, reason: 'deterministic + trims whitespace like the web client');
  });

  test('a different seed yields a different key', () {
    final k1 = seqlnDeviceTransportPrivkey(mnemonic: _mnemonic);
    final k2 = seqlnDeviceTransportPrivkey(
      mnemonic: 'legal winner thank year wave sausage worth useful legal winner thank yellow',
    );
    expect(k2, isNot(equals(k1)));
  });

  test('the derived key is a valid Noise static key (yields a 33-byte pubkey)', () {
    final k = seqlnDeviceTransportPrivkey(mnemonic: _mnemonic);
    final pub = devicePubkey(staticPrivkey: k);
    expect(pub.length, 66, reason: '33-byte compressed pubkey as hex');
    expect(RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(pub), true);
  });

  group('web-wallet parity (byte-match seqln-keys.js)', () {
    test("asset node: transport m/1017'/0'/0' + signing m/1017'/1'/0'", () {
      final k = seqlnDeriveNode(mnemonic: _mnemonic, node: 'asset');
      expect(_hex(k.transportPrivkey), _expected['asset_transport']);
      expect(k.signingSeed, _expected['asset_signing']);
    });

    test("btc node: transport m/1017'/0'/1' + signing m/1017'/1'/1'", () {
      final k = seqlnDeriveNode(mnemonic: _mnemonic, node: 'btc');
      expect(_hex(k.transportPrivkey), _expected['btc_transport']);
      expect(k.signingSeed, _expected['btc_signing']);
    });

    test("per-asset node: FNV-1a index -> m/1017'/2'|3'/<idx>'", () {
      final k = seqlnDeriveAsset(mnemonic: _mnemonic, assetId: _goldId);
      expect(_hex(k.transportPrivkey), _expected['perasset_transport']);
      expect(k.signingSeed, _expected['perasset_signing']);
    });

    test('the legacy transport fn equals the asset node transport (back-compat)', () {
      final legacy = seqlnDeviceTransportPrivkey(mnemonic: _mnemonic);
      final node = seqlnDeriveNode(mnemonic: _mnemonic, node: 'asset');
      expect(_hex(node.transportPrivkey), _hex(legacy));
    });

    test('every derived transport key is a valid Noise static key + distinct per node', () {
      final pubs = <String>{};
      for (final node in ['asset', 'btc']) {
        final k = seqlnDeriveNode(mnemonic: _mnemonic, node: node);
        final pub = devicePubkey(staticPrivkey: k.transportPrivkey);
        expect(RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(pub), true, reason: '$node transport pubkey');
        pubs.add(pub);
      }
      final assetPub = devicePubkey(
          staticPrivkey: seqlnDeriveAsset(mnemonic: _mnemonic, assetId: _goldId).transportPrivkey);
      pubs.add(assetPub);
      expect(pubs.length, 3, reason: 'asset, btc, and the per-asset node have distinct device identities');
    });

    test('an invalid asset id is rejected', () {
      expect(() => seqlnDeriveAsset(mnemonic: _mnemonic, assetId: 'not-hex'), throwsA(anything));
    });
  });
}
