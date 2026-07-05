// Host-side proof that the new device-transport-key FFI bridges to Dart and
// derives a valid, deterministic Noise static key from the mnemonic (the mobile
// twin of the web wallet's lnDeviceTransportPriv: standard BIP39 seed -> BIP32
// m/1017'/0'/0').
//
//   cd app && flutter test test/seqln_device_key_test.dart
//
// (Requires the host cdylib: `cargo build` in ../ambra_core first.)

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/rust/api/signer.dart';
import 'package:ambra/src/rust/frb_generated.dart';

const _hostLib = '/home/aejkohl/ambra/ambra_core/target/debug/libambra_core.so';

// A fixed BIP39 test mnemonic (the all-"abandon" vector); testnet only.
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

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
}
