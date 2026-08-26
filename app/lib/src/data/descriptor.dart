/// Output descriptors for the wallet's account key, in the form another wallet
/// can import. The web wallet's `descriptor.js`, kept in step with it: both
/// produce the same strings for the same key, because both are checked against
/// what `getdescriptorinfo` reports.
///
/// A descriptor without its checksum is refused by the RPCs that matter, so
/// these carry it. Both chains derive from one m/84'/1'/0' account, so one key
/// yields both forms: wpkh() describes the tb1 addresses this wallet hands out,
/// pkh() the legacy form of the same key — the address a node's verifymessage
/// takes, and so what someone imports to check a signature from the Sign screen.
library;

const _inputCharset =
    "0123456789()[],'/*abcdefgh@:\$%{}IJKLMNOPQRSTUVWXYZ&+-.;<=>?!^_|~ijklmnopqrstuvwxyzABCDEFGH`#\"\\ ";
const _checksumCharset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
final List<BigInt> _generator = [
  BigInt.parse('f5dee51989', radix: 16),
  BigInt.parse('a9fdca3312', radix: 16),
  BigInt.parse('1bab10e32d', radix: 16),
  BigInt.parse('3706b1677a', radix: 16),
  BigInt.parse('644d626ffd', radix: 16),
];
final BigInt _low35 = BigInt.parse('7ffffffff', radix: 16);

BigInt _polymod(BigInt c, int val) {
  final c0 = c >> 35;
  c = ((c & _low35) << 5) ^ BigInt.from(val);
  for (var i = 0; i < 5; i++) {
    if (((c0 >> i) & BigInt.one) == BigInt.one) c ^= _generator[i];
  }
  return c;
}

/// The eight-character BIP380 checksum for [desc], or null if it holds a
/// character no descriptor may.
String? descriptorChecksum(String desc) {
  var c = BigInt.one;
  var cls = 0, clscount = 0;
  for (final ch in desc.split('')) {
    final pos = _inputCharset.indexOf(ch);
    if (pos < 0) return null;
    c = _polymod(c, pos & 31);
    cls = cls * 3 + (pos >> 5);
    if (++clscount == 3) {
      c = _polymod(c, cls);
      cls = 0;
      clscount = 0;
    }
  }
  if (clscount > 0) c = _polymod(c, cls);
  for (var i = 0; i < 8; i++) {
    c = _polymod(c, 0);
  }
  c ^= BigInt.one;
  final out = StringBuffer();
  for (var i = 0; i < 8; i++) {
    out.write(_checksumCharset[((c >> (5 * (7 - i))) & BigInt.from(31)).toInt()]);
  }
  return out.toString();
}

String withChecksum(String desc) {
  final sum = descriptorChecksum(desc);
  return sum == null ? desc : '$desc#$sum';
}

/// The PAIR a wallet imports — receive at /0/* then change at /1/* — rather
/// than one multipath `<0;1>` descriptor: sequentiad answers "Key path value
/// '<0;1>' is not a valid uint32", so the shorter form would be a string this
/// network's own node refuses. [keyorigin] is the
/// "[fingerprint/84h/1h/0h]tpub..." string the signer reports.
List<String> accountDescriptors(String keyorigin, {String kind = 'wpkh'}) {
  if (keyorigin.isEmpty) return const [];
  return [0, 1].map((b) => withChecksum('$kind($keyorigin/$b/*)')).toList();
}
