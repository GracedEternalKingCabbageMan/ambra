// Host-side proof that the Flutter/Dart layer reaches the Sequentia Rust core
// (ambra_core) over flutter_rust_bridge. Loads the natively-built debug cdylib
// directly, so it runs on the host without an Android device.
//
//   cd app && flutter test
//
// (Requires the host cdylib: `cargo build` in ../ambra_core first.)

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/rust/api.dart';
import 'package:ambra/src/rust/frb_generated.dart';

const _hostLib =
    '/home/aejkohl/ambra/ambra_core/target/debug/libambra_core.so';

void main() {
  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(_hostLib));
  });

  test('ambra_core bridges to Dart and derives a Sequentia wallet', () async {
    expect(networkName(), 'sequentia-testnet');

    final mnemonic = await generateMnemonic();
    expect(mnemonic.split(' ').length, 12,
        reason: 'expected a 12-word BIP39 phrase');

    final address = await receiveAddress(mnemonic: mnemonic);
    expect(address.startsWith('tb1'), isTrue,
        reason:
            'default receive must be a non-confidential tb1 address: $address');

    final confidential = await confidentialReceiveAddress(mnemonic: mnemonic);
    expect(confidential.startsWith('tsqb1'), isTrue,
        reason: 'confidential receive must be a tsqb1 address: $confidential');

    // ignore: avoid_print
    print('bridge OK — receive=$address');
  });
}
