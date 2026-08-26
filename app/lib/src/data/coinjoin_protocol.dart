/// The participant half of the seqcj protocol — a Dart port of the module the browser
/// wallet vendors from the seqcj repository (`coinjoin-protocol.js`, source of truth
/// seqcj/client.mjs). Kept faithful to it, phase for phase and message for message, so a
/// round proven end to end against a real coordinator is the round this wallet performs.
///
/// It is deliberately WALLET-AGNOSTIC: the round protocol and nothing else — no key
/// handling, no coin selection, no transaction building. Everything that needs a wallet
/// arrives as a hook, which is what lets the phone, the browser and the regtest harness
/// run the same protocol.
///
/// THE RULE THAT MATTERS. `verifyAndSign` is the last gate before a signature exists, and
/// it is the participant's ONLY protection against a dishonest coordinator. It must check,
/// against the wallet's own view and not against anything this module says, that the
/// transaction pays the participant what the round promised. This module cannot check it
/// for you: it never sees a key, a blinding factor or a balance.
library;

import 'dart:math';

import 'blindsig.dart';

typedef FetchJson = Future<Map<String, dynamic>> Function(String path, [Map<String, dynamic>? body]);
typedef SelectInputs = Future<List<CoinjoinCoin>> Function(
    {required String asset, required BigInt denom, required BigInt coordFee, required int maxCredentials});
typedef ProveOwnership = Future<OwnershipSig> Function(String message, CoinjoinCoin coin);
typedef FreshAddress = Future<String> Function();
typedef VerifyAndSign = Future<String> Function(String txHex, RoundContext context);
typedef OnStatus = void Function(String phase, Map<String, dynamic> detail);

/// A transparent coin of ours, as the round needs to see it.
class CoinjoinCoin {
  const CoinjoinCoin({
    required this.txid,
    required this.vout,
    required this.atoms,
    required this.asset,
    required this.spkHex,
    required this.chain,
    required this.index,
  });
  final String txid;
  final int vout;
  final BigInt atoms;
  final String asset;
  final String spkHex;
  final int chain;
  final int index;
}

class OwnershipSig {
  const OwnershipSig(this.pubkey, this.sig);
  final String pubkey;
  final String sig;
}

/// What the wallet must check the coordinator's transaction against.
class RoundContext {
  const RoundContext({
    required this.lane,
    required this.inputs,
    required this.denom,
    required this.k,
    required this.mixAddresses,
    required this.changeAddress,
    required this.change,
  });
  final Map<String, dynamic> lane;
  final List<CoinjoinCoin> inputs;
  final BigInt denom;
  final int k;
  final List<String> mixAddresses;
  final String? changeAddress;
  final BigInt change;
  BigInt get expectedCredit => denom * BigInt.from(k) + change;
}

class RoundResult {
  const RoundResult({
    required this.txid,
    required this.denominations,
    required this.denomAtoms,
    required this.changeAtoms,
    required this.mixAddresses,
    required this.changeAddress,
  });
  final String txid;
  final int denominations;
  final BigInt denomAtoms;
  final BigInt changeAtoms;
  final List<String> mixAddresses;
  final String? changeAddress;
}

/// An output of the round transaction that the wallet could unblind.
class MineOutput {
  const MineOutput({required this.scriptPubkey, required this.asset, required this.value});
  final String scriptPubkey;
  final String asset;
  final BigInt value;
}

final _rand = Random.secure();

/// Pick the round and lane to join. `assetId` is required — a mix is per asset, and
/// guessing one for the user would be picking which of their holdings to move.
Future<Map<String, dynamic>?> chooseRound(FetchJson fetchJson, String assetId) async {
  final res = await fetchJson('/rounds');
  final rounds = (res['rounds'] as List?) ?? const [];
  for (final r in rounds) {
    if (r['phase'] != 'input') continue;
    for (final lane in (r['lanes'] as List? ?? const [])) {
      if (lane['asset'] == assetId) return {'round': r, 'lane': lane};
    }
  }
  return null;
}

/// One full round, from registration to broadcast.
Future<RoundResult> runRound({
  required FetchJson fetchJson,
  required SelectInputs selectInputs,
  required ProveOwnership proveOwnership,
  required FreshAddress freshAddress,
  required VerifyAndSign verifyAndSign,
  required String assetId,
  int? maxCredentials,
  OnStatus? onStatus,
  Future<void> Function(int ms)? sleep,
}) async {
  final status = onStatus ?? (String _, Map<String, dynamic> _) {};
  final nap = sleep ?? ((ms) => Future<void>.delayed(Duration(milliseconds: ms)));

  final found = await chooseRound(fetchJson, assetId);
  if (found == null) throw StateError('no open round is mixing that asset right now');
  final round = found['round'] as Map<String, dynamic>;
  final lane = found['lane'] as Map<String, dynamic>;
  final denom = BigInt.parse('${lane['denom_atoms']}');
  final coordFee = BigInt.parse('${lane['coord_fee_atoms'] ?? '0'}');
  final roundMax = (round['max_credentials'] as num).toInt();
  final cap = min(maxCredentials ?? roundMax, roundMax);
  status('selecting', {'round': round['round_id'], 'lane': lane['label']});

  // ---- 1. coins ------------------------------------------------------------
  final inputs = await selectInputs(asset: assetId, denom: denom, coordFee: coordFee, maxCredentials: cap);
  if (inputs.isEmpty) throw StateError('no transparent coins of that asset to mix');
  final total = inputs.fold<BigInt>(BigInt.zero, (s, i) => s + i.atoms);
  final per = denom + coordFee;
  final whole = (total ~/ per).toInt();
  final k = whole > cap ? cap : whole;
  if (k < 1) {
    throw StateError('need at least $per atoms to mix one denomination; have $total');
  }
  final change = total - BigInt.from(k) * per;

  // ---- 2. blind k nonces ---------------------------------------------------
  // Kept material never leaves this scope until phase two. If the app dies here the round
  // simply fails: no coins have moved, and none can — nothing has been signed.
  final blindKey = BlindKey('${lane['blind_key']['n']}', '${lane['blind_key']['e']}');
  final kept = [for (var i = 0; i < k; i++) blind(blindKey)];

  // ---- 3. input registration (identified) ----------------------------------
  final proofs = <Map<String, dynamic>>[];
  for (final i in inputs) {
    final msg = 'seqcj-ownership-v1|${round['round_id']}|${i.txid}:${i.vout}';
    final p = await proveOwnership(msg, i);
    proofs.add({'txid': i.txid, 'vout': i.vout, 'pubkey': p.pubkey, 'sig': p.sig});
  }
  final changeAddress = change > BigInt.zero ? await freshAddress() : null;
  status('registering-inputs',
      {'inputs': inputs.length, 'denominations': k, 'change': change.toString()});
  final reg = await fetchJson('/register-input', {
    'round_id': round['round_id'],
    'lane': lane['index'],
    'inputs': proofs,
    'credentials': [for (final x in kept) x.blinded],
    'change_address': ?changeAddress,
  });
  final blindSigs = (reg['blind_sigs'] as List).cast<String>();
  final credentials = [for (var i = 0; i < kept.length; i++) unblind(blindKey, blindSigs[i], kept[i])];

  // ---- 4. output registration (anonymous) ----------------------------------
  // The addresses are drawn ONLY now, so nothing about them existed during input
  // registration, and the registrations are spaced by a random delay: submitting k outputs
  // back to back in one instant is itself a correlation the coordinator could read.
  // Network-level unlinkability is the CLIENT's job, not this module's — and a phone on one
  // connection cannot arrange it, which the screen says plainly.
  await waitForPhase(fetchJson, '${round['round_id']}', 'output', nap, status);
  final mixAddresses = <String>[];
  for (final cred in _shuffled(credentials)) {
    final address = await freshAddress();
    mixAddresses.add(address);
    await fetchJson('/register-output',
        {'round_id': round['round_id'], 'credential': cred.toJson(), 'address': address});
    status('registering-outputs', {'registered': mixAddresses.length, 'of': k});
    if (mixAddresses.length < credentials.length) await nap(200 + _rand.nextInt(800));
  }

  // ---- 5. verify + sign ----------------------------------------------------
  final signing = await waitForPhase(fetchJson, '${round['round_id']}', 'signing', nap, status);
  status('verifying', {'vsize': signing['vsize']});
  final signed = await verifyAndSign(
    '${signing['tx_hex']}',
    RoundContext(
      lane: lane,
      inputs: inputs,
      denom: denom,
      k: k,
      mixAddresses: mixAddresses,
      changeAddress: changeAddress,
      change: change,
    ),
  );
  await fetchJson('/sign', {
    'round_id': round['round_id'],
    'registration_id': reg['registration_id'],
    'tx_hex': signed,
  });
  status('signed', {});

  // ---- 6. outcome ----------------------------------------------------------
  final done = await waitForPhase(fetchJson, '${round['round_id']}', 'done', nap, status);
  return RoundResult(
    txid: '${done['txid']}',
    denominations: k,
    denomAtoms: denom,
    changeAtoms: change,
    mixAddresses: mixAddresses,
    changeAddress: changeAddress,
  );
}

/// THE GATE.
///
/// Given the outputs a wallet could unblind of the round transaction, decide whether it
/// pays what the round owed. The single function whose failure costs real money, so it is
/// a faithful port of the one both other wallets vendor, rule for rule:
///   1. every mix address registered must be present, for EXACTLY the denomination;
///   2. the change output, if one was registered, must be present for exactly the change;
///   3. nothing else of ours may appear — an extra output of ours is not free money, it is
///      a sign the round is not the one we agreed to (and very likely a de-anonymising
///      marker);
///   4. the totals must agree.
BigInt verifyRoundOutputs({
  required List<MineOutput> mine,
  required List<String> mixScripts,
  required String? changeScript,
  required BigInt denom,
  required BigInt change,
  required String asset,
}) {
  final byScript = <String, MineOutput>{};
  for (final o in mine) {
    final s = o.scriptPubkey.toLowerCase();
    if (byScript.containsKey(s)) {
      throw StateError('the round pays the same address of mine twice; refusing to sign');
    }
    byScript[s] = o;
  }
  var credited = BigInt.zero;
  for (final s in mixScripts) {
    final o = byScript[s.toLowerCase()];
    if (o == null) throw StateError('one of my mixed outputs is missing from the round; refusing to sign');
    if (o.asset != asset) throw StateError('a mixed output of mine is in the wrong asset; refusing to sign');
    if (o.value != denom) {
      throw StateError('a mixed output of mine is ${o.value} atoms, not the $denom the round promised; refusing to sign');
    }
    credited += o.value;
    byScript.remove(s.toLowerCase());
  }
  if (changeScript != null) {
    final o = byScript[changeScript.toLowerCase()];
    if (o == null) throw StateError('my change output is missing from the round; refusing to sign');
    if (o.asset != asset) throw StateError('my change is in the wrong asset; refusing to sign');
    if (o.value != change) {
      throw StateError('my change is ${o.value} atoms, not the $change I registered; refusing to sign');
    }
    credited += o.value;
    byScript.remove(changeScript.toLowerCase());
  } else if (change != BigInt.zero) {
    throw StateError('the round owes me change but no change address was registered; refusing to sign');
  }
  if (byScript.isNotEmpty) {
    throw StateError('the round contains an output of mine I did not register; refusing to sign');
  }
  final owed = denom * BigInt.from(mixScripts.length) + change;
  if (credited != owed) {
    throw StateError('the round credits me $credited atoms, not the $owed it owes; refusing to sign');
  }
  return credited;
}

/// Order is metadata. Presenting credentials in the order they were issued would tell the
/// coordinator which output belongs to which registration — the one thing the blinding
/// exists to prevent — so the shuffle uses the same secure randomness as everything else.
List<Credential> _shuffled(List<Credential> a) {
  final out = [...a];
  for (var i = out.length - 1; i > 0; i--) {
    final j = _rand.nextInt(i + 1);
    final t = out[i];
    out[i] = out[j];
    out[j] = t;
  }
  return out;
}

/// Poll until the round reaches `phase`. A round that fails, or vanishes because the
/// coordinator retired it, ends the wait with the coordinator's own reason rather than a
/// timeout the user cannot act on.
Future<Map<String, dynamic>> waitForPhase(
  FetchJson fetchJson,
  String roundId,
  String phase,
  Future<void> Function(int ms) sleep,
  OnStatus status, {
  int timeoutMs = 600000,
}) async {
  const order = ['input', 'output', 'signing', 'broadcasting', 'done'];
  final target = order.indexOf(phase);
  final until = DateTime.now().millisecondsSinceEpoch + timeoutMs;
  String? last;
  while (DateTime.now().millisecondsSinceEpoch < until) {
    Map<String, dynamic> r;
    try {
      r = ((await fetchJson('/round/$roundId'))['round'] as Map).cast<String, dynamic>();
    } catch (e) {
      throw StateError('round $roundId is no longer available: $e');
    }
    if (r['phase'] == 'failed') {
      throw StateError('round failed: ${r['error'] ?? 'no reason given'}');
    }
    if (r['phase'] != last) {
      status('waiting', {'phase': r['phase']});
      last = '${r['phase']}';
    }
    if (order.indexOf('${r['phase']}') >= target) return r;
    await sleep(1000);
  }
  throw StateError('timed out waiting for the round to reach $phase');
}
