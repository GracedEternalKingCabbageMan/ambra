// Host-side proof that classic message signing bridges to Dart AND agrees, byte
// for byte, with the web wallet — which in turn agrees with the node: every
// vector here is what `sequentia-cli signmessagewithprivkey` produces and what
// `verifymessage` accepts. One phrase, one signature, either wallet.
//
//   cd app && flutter test test/classic_signing_test.dart
//
// (Requires the host cdylib: `cargo build` in ../ambra_core first.)

import 'dart:io' show Platform;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/descriptor.dart';
import 'package:ambra/src/rust/api.dart' as core;
import 'package:ambra/src/rust/frb_generated.dart';

final _hostLib = Platform.environment['AMBRA_CORE_LIB'] ??
    '../ambra_core/target/debug/libambra_core.so';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

void main() {
  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(_hostLib));
  });

  test('signs what the web wallet and the node do', () async {
    final out = await core.signMessageClassic(
      mnemonic: _mnemonic,
      index: 0,
      message: 'sequentia web wallet classic signing',
    );
    expect(out.signature,
        'IPqYE4yB1g2PC2I9Yflw3yWl7Y8uJ83t/9TmuLwsRe1DV1zOey2HU8AVAeSMI8IT5VCP2gCMn8z8eMFk3WyWNVo=');
    expect(out.verifyAddress, 'mzYpQmSAGYWWyTLiLGbGaG8T3rHdjNcV11');
    expect(out.address, 'tb1q6rz28mcfaxtmd6v789l9rrlrusdprr9pqcpvkl');
  });

  test('signs with the key behind the address the wallet hands out', () async {
    for (final index in [0, 1, 7]) {
      final out = await core.signMessageClassic(mnemonic: _mnemonic, index: index, message: 'x');
      final shown = await core.receiveAddressAt(mnemonic: _mnemonic, index: index, confidential: false);
      expect(out.address, shown.address, reason: 'index $index');
    }
  });

  test('the account key, and the descriptors built from it, match the web wallet', () async {
    final ko = await core.accountXpub(mnemonic: _mnemonic);
    expect(ko,
        '[73c5da0a/84h/1h/0h]tpubDC8msFGeGuwnKG9Upg7DM2b4DaRqg3CUZa5g8v2SRQ6K4NSkxUgd7HsL2XVWbVm39yBA4LAxysQAm397zwQSQoQgewGiYZqrA9DsP4zbQ1M');
    // The checksums the node reports for these exact strings.
    expect(accountDescriptors(ko).first.endsWith('#evh9fu0w'), isTrue);
    expect(accountDescriptors(ko, kind: 'pkh').first.endsWith('#mzfssff9'), isTrue);
  });
}
