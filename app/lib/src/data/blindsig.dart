/// RSA blind signatures (Chaum), the credential primitive that makes a CoinJoin round
/// unlinkable. A Dart port of the seqcj client half that the browser wallet vendors
/// (`blindsig.js`, whose source of truth is seqcj/blindsig.mjs), and checked against it:
/// the vectors in the test are what that code produces, so a credential minted here is
/// one the coordinator accepts.
///
/// In a round the coordinator must be convinced of two things it must NOT be able to
/// connect: that a participant registered inputs worth k denominations, and that some
/// output is owed one denomination. So the first is paid for in blind signatures — the
/// participant sends a BLINDED random nonce, the coordinator signs without seeing it, and
/// later, on a separate connection in a separate phase, presents the unblinded pair as an
/// anonymous bearer credential.
///
/// Textbook RSA-FDH:
///   client       m = FDH(nonce);  r random, gcd(r,n)=1;  blinded = m * r^e mod n
///   coordinator  s_blinded = blinded^d mod n
///   client       s = s_blinded * r^-1 mod n
///   verifier     s^e == FDH(nonce) mod n
///
/// FDH is MGF1-SHA256 truncated to (keylen - 1) bytes, so the image is uniform below n.
/// A plain "hash into the low 32 bytes" would be forgeable; full-domain hashing is what
/// the security proof needs. The private exponent never appears here.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

final _rand = Random.secure();

/// Every value drawn here is security-critical — a nonce an adversary can predict is a
/// credential they can recognise — so this is the secure generator, with no fallback.
Uint8List randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rand.nextInt(256)));

BigInt bytesToBig(List<int> b) {
  var x = BigInt.zero;
  for (final v in b) {
    x = (x << 8) | BigInt.from(v);
  }
  return x;
}

Uint8List bigToBytes(BigInt x, int len) {
  final out = Uint8List(len);
  var v = x;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  if (v != BigInt.zero) throw ArgumentError('integer does not fit in $len bytes');
  return out;
}

String toHex(List<int> b) => b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHex(String h) {
  final s = h.startsWith('0x') ? h.substring(2) : h;
  if (s.length.isOdd) throw ArgumentError('odd-length hex');
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List _sha256(List<int> b) => Uint8List.fromList(c.sha256.convert(b).bytes);

/// PKCS#1's mask generation function, MGF1-SHA256.
Uint8List mgf1(List<int> seed, int outLen) {
  final out = Uint8List(outLen);
  var off = 0;
  for (var counter = 0; off < outLen; counter++) {
    final input = Uint8List(seed.length + 4)
      ..setAll(0, seed)
      ..[seed.length] = (counter >> 24) & 0xff
      ..[seed.length + 1] = (counter >> 16) & 0xff
      ..[seed.length + 2] = (counter >> 8) & 0xff
      ..[seed.length + 3] = counter & 0xff;
    final h = _sha256(input);
    final take = h.length < outLen - off ? h.length : outLen - off;
    out.setRange(off, off + take, h.sublist(0, take));
    off += take;
  }
  return out;
}

const _domain = 'seqcj-credential-v1|';

/// The message the signature actually covers, domain-separated so a signature issued by a
/// seqcj coordinator can never be reinterpreted as a signature over something else.
BigInt fdh(List<int> nonce, int klen) {
  final tag = utf8.encode(_domain);
  final seed = Uint8List(tag.length + nonce.length)
    ..setAll(0, tag)
    ..setAll(tag.length, nonce);
  return bytesToBig(mgf1(seed, klen - 1));
}

/// The coordinator's per-(round, lane) RSA public key. One keypair per lane means a
/// credential cannot be replayed into another round, or moved to a lane with a larger
/// denomination — the binding is the key itself, not a field anyone could forge.
class BlindKey {
  const BlindKey(this.n, this.e);
  final String n;
  final String e;
  BigInt get modulus => BigInt.parse(n, radix: 16);
  BigInt get exponent => BigInt.parse(e, radix: 16);
  int get klen => fromHex(n).length;
}

/// What to send (`blinded`) and what to keep. The kept half is what turns the
/// coordinator's answer into a credential, and it must never leave the client before the
/// output-registration phase.
class Blinded {
  const Blinded({required this.nonce, required this.factor, required this.blinded, required this.klen});
  final Uint8List nonce;
  final BigInt factor;
  final String blinded;
  final int klen;
}

Blinded blind(BlindKey pub, {Uint8List? nonce, BigInt? fixedFactor}) {
  final use = nonce ?? randomBytes(32);
  final n = pub.modulus, e = pub.exponent, klen = pub.klen;
  final m = fdh(use, klen);
  for (var attempt = 0; attempt < 8; attempt++) {
    BigInt r;
    if (fixedFactor != null) {
      r = fixedFactor % n;
    } else {
      final rb = randomBytes(klen);
      rb[0] &= 0x7f; // keep r < n without a rejection loop biased at the top
      r = bytesToBig(rb) % n;
    }
    if (r < BigInt.two) continue;
    BigInt rinv;
    try {
      rinv = r.modInverse(n);
    } catch (_) {
      if (fixedFactor != null) rethrow;
      continue; // a random r sharing a factor with n means we hit one — draw again
    }
    final blinded = (m * r.modPow(e, n)) % n;
    return Blinded(nonce: use, factor: rinv, blinded: toHex(bigToBytes(blinded, klen)), klen: klen);
  }
  throw StateError('could not draw a usable blinding factor');
}

class Credential {
  const Credential(this.nonce, this.sig);
  final String nonce;
  final String sig;
  Map<String, String> toJson() => {'nonce': nonce, 'sig': sig};
}

/// Turn the coordinator's blinded signature into the real one, and CHECK it before
/// trusting it — a coordinator that returns garbage must be caught now, while the failure
/// is still a failed registration rather than an output we cannot claim later.
Credential unblind(BlindKey pub, String blindedSigHex, Blinded kept) {
  final n = pub.modulus, e = pub.exponent, klen = pub.klen;
  final sb = bytesToBig(fromHex(blindedSigHex));
  final s = (sb * kept.factor) % n;
  final m = fdh(kept.nonce, klen);
  if (s.modPow(e, n) != m) throw StateError('coordinator returned an invalid blind signature');
  return Credential(toHex(kept.nonce), toHex(bigToBytes(s, klen)));
}

bool verifyCredential(BlindKey pub, Credential cred) {
  try {
    final n = pub.modulus, e = pub.exponent, klen = pub.klen;
    final s = bytesToBig(fromHex(cred.sig));
    if (s <= BigInt.one || s >= n) return false;
    return s.modPow(e, n) == fdh(fromHex(cred.nonce), klen);
  } catch (_) {
    return false;
  }
}
