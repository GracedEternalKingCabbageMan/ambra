// The checksums here are the node's: `sequentia-cli getdescriptorinfo <descriptor>`
// reports the same eight characters, so a descriptor Ambra shows is one the node
// accepts verbatim — and the same string the web wallet shows for the same key.
import 'package:flutter_test/flutter_test.dart';
import 'package:ambra/src/data/descriptor.dart';

const ko =
    '[73c5da0a/84h/1h/0h]tpubDC8msFGeGuwnKG9Upg7DM2b4DaRqg3CUZa5g8v2SRQ6K4NSkxUgd7HsL2XVWbVm39yBA4LAxysQAm397zwQSQoQgewGiYZqrA9DsP4zbQ1M';

void main() {
  test('the checksums the node reports', () {
    expect(accountDescriptors(ko), [
      'wpkh($ko/0/*)#evh9fu0w',
      'wpkh($ko/1/*)#gcjy5flk',
    ]);
    expect(accountDescriptors(ko, kind: 'pkh'), [
      'pkh($ko/0/*)#mzfssff9',
      'pkh($ko/1/*)#2kv3duea',
    ]);
  });

  test('a second descriptor the node checksums the same way', () {
    expect(
      descriptorChecksum(
          'wpkh(tprv8ZgxMBicQKsPd7Uf69XL1XwhmjHopUGep8GuEiJDZmbQz6o58LninorQAfcKZWARbtRtfnLcJ5MQ2AtHcQJCCRUcMRvmDUjyEmNUWwx8UbK/1/2/*)'),
      'vuyep999',
    );
  });

  test('an empty key origin yields no descriptor, and a bad character none', () {
    expect(accountDescriptors(''), isEmpty);
    expect(descriptorChecksum('wpkh(tpub…/0/*)'), isNull);
    expect(withChecksum('wpkh(tpub…/0/*)'), 'wpkh(tpub…/0/*)');
  });
}
