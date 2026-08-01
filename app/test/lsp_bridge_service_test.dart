// Unit tests for the LSP PAYER LEG-BRIDGE taker (lsp_bridge_service.dart) — the fund-safety spine of
// the bridged BTC-LN -> asset-on-chain buy:
//
//   1. RECORD ROUND-TRIP — every field survives JSON + the real secure-storage slot; an unrecognised
//      persisted state decodes NON-terminal (never silently "done"); the single-slot guard keys on the
//      hold evidence (holdsOrMightHoldValue), not the step label.
//   2. PURE GATES — claimWindowOpen (fail closed on an unreadable tip; refuse a window under the
//      margin), the skew-immune holdCltvCap, and the CLTV-gated canAbandon.
//   3. DRIVER FAIL-CLOSED (mocked seam) — a hold not bound to OUR H / an overpaying hold / a hold with
//      no CLTV floor all refuse BEFORE the bare-hash pay (zero exposure, record fails terminal); the
//      happy path runs hold -> leg -> verify -> anchor -> window -> claim in order.
//   4. CLAIM-WINDOW GATE REFUSAL — the driver refuses to claim (never reveals P) when the window has
//      closed after the hold was paid (record stays resumable, NEVER dropped), and the resume re-claim
//      is gated the same way (the web claimWindowGate:true twin).
//
//   cd app && flutter test test/lsp_bridge_service_test.dart

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/lsp_bridge_service.dart';
import 'package:ambra/src/data/lsp_client.dart';
import 'package:ambra/src/data/seqob_client.dart' show CrossOffer;
import 'package:ambra/src/rust/api.dart' as core;

const MethodChannel _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

class _FakeSecureStorage {
  final Map<String, String> data = {};

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    switch (call.method) {
      case 'read':
        return data[args['key'] as String];
      case 'write':
        data[args['key'] as String] = args['value'] as String;
        return null;
      case 'delete':
        data.remove(args['key'] as String);
        return null;
      case 'readAll':
        return Map<String, String>.from(data);
      case 'deleteAll':
        data.clear();
        return null;
      case 'containsKey':
        return data.containsKey(args['key'] as String);
      default:
        return null;
    }
  }

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, _handle);
    addTearDown(() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
  }
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
List<int> _bytes(String hex) =>
    [for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

final String kPreimage = 'aa' * 32;
final String kHashH = _hex(sha256.convert(_bytes(kPreimage)).bytes);
const String kAsset = '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de';
const String kRedeem = 'aabbcc';
const String kSpk = 'a914001122334455667788990011223344556677889987';
final String kLegTxid = 'ab' * 32;

CrossOffer _offer() => CrossOffer(
      offerId: 'off-1',
      seqAsset: kAsset,
      makerSellsAsset: true,
      assetAtoms: BigInt.from(1000),
      btcSats: BigInt.from(5000),
      makerPubkey: '02${'cc' * 32}',
    );

/// A scripted BridgeChain: canned LSP/chain responses + call recording, so the driver's fail-closed
/// ordering is exercised for real (nothing is stubbed inside the service under test).
class _FakeChain implements BridgeChain {
  // Knobs.
  Map<String, dynamic> statusBody = {}; // returned by every lspBridgeStatus poll
  Map<String, dynamic> holdBody = {};
  List<int> tips = [1000]; // successive seqTipHeight reads (last value repeats)
  bool anchored = true;
  Map<String, dynamic>? tx; // /tx/<txid> body

  // Recorders.
  int payHashCalls = 0;
  int claimCalls = 0;
  final List<String> order = [];

  @override
  Future<({String secretHex, String hashHex})> newSecret() async => (secretHex: kPreimage, hashHex: kHashH);

  @override
  Future<String> takerSeqClaimPub() async => '02${'dd' * 32}';

  @override
  Future<core.SeqHtlcInfo> seqHtlcForward(
          {required String hashHex, required String makerRefundPub, required int seqLocktime}) async =>
      const core.SeqHtlcInfo(redeemScriptHex: kRedeem, p2ShAddress: 'addr', p2ShSpkHex: kSpk);

  @override
  Future<Map<String, dynamic>?> seqTx(String txid) async => tx;

  @override
  Future<int> seqTipHeight() async {
    final v = tips.length > 1 ? tips.removeAt(0) : tips.first;
    order.add('tip:$v');
    return v;
  }

  @override
  Future<bool> waitAnchorBuried({required String txid, required int minDepth, void Function()? onWait}) async {
    order.add('anchor');
    return anchored;
  }

  @override
  Future<String> claimSeq({
    required String seqTxid,
    required int seqVout,
    required BigInt amountAtoms,
    required String assetId,
    required String redeemScriptHex,
    required int seqLocktime,
    required String makerRefundPub,
    required String hashHex,
    required String preimageHex,
  }) async {
    claimCalls++;
    order.add('claim');
    return 'claimtxid';
  }

  @override
  Future<SubSwapJob> lspSwapBridge(Map<String, dynamic> p) async {
    order.add('swap');
    return SubSwapJob.fromJson({'job_id': 'job-1', 'poll': '/swap/job-1'});
  }

  @override
  Future<BridgeJobStatus?> lspBridgeStatus(String pollPathOrId) async =>
      BridgeJobStatus.fromJson(Map<String, dynamic>.from(statusBody));

  @override
  Future<BridgeHold> lspBridgeHold(String jobId) async {
    order.add('hold');
    return BridgeHold.fromJson(Map<String, dynamic>.from(holdBody));
  }

  @override
  Future<Map<String, dynamic>> lspNodePayHash({
    required String nodeKey,
    required String nodeId,
    required String hash,
    required BigInt amountMsat,
    int? minFinalCltv,
    List<dynamic>? connectHints,
  }) async {
    payHashCalls++;
    order.add('pay');
    return {'committed': true};
  }

  @override
  Future<String> btcNodeKey() async => 'btc-node-key';
}

/// A full happy-path scripted world: terms + leg on every poll, a visible bound funding output, an
/// anchored block, and a wide claim window (T_seq 5000 vs tip 1000).
_FakeChain _happyChain() {
  final c = _FakeChain();
  c.statusBody = {
    'ok': true,
    'status': 'working',
    'bridge_terms': {'hash_h': kHashH, 'seq_locktime': 5000, 'maker_seq_refund_pub': '02${'ee' * 32}'},
    'maker_seq_leg': {
      'txid': kLegTxid,
      'vout': 0,
      'amount': '1000',
      'asset': kAsset,
      'redeem_script': kRedeem,
      'locktime': 5000,
      'block_hash': 'cd' * 32,
    },
  };
  c.holdBody = {'node_id': '03${'ff' * 32}', 'payment_hash': kHashH, 'amount_msat': 5000000, 'hold_min_final_cltv': 144};
  c.tx = {
    'vout': [
      {'scriptpubkey': kSpk, 'value': 1000, 'asset': kAsset}
    ]
  };
  c.tips = [1000];
  return c;
}

LspBridgeRecord _record({BridgeState state = BridgeState.held}) => LspBridgeRecord(
      state: state,
      asset: kAsset,
      assetAtoms: BigInt.from(1000),
      btcSats: BigInt.from(5000),
      offerId: 'off-1',
      makerPubkey: '02aa',
      hashHex: kHashH,
      preimageHex: kPreimage,
      jobId: 'job-1',
      poll: '/swap/job-1',
      seqLocktime: 5000,
      makerRefundPub: '02${'ee' * 32}',
      startedMs: 7,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LspBridgeService.timing = const BridgeTiming(
      poll: Duration(milliseconds: 1),
      handshakeWait: Duration(seconds: 2),
      legWait: Duration(seconds: 2),
    );
    addTearDown(() {
      LspBridgeService.timing = const BridgeTiming();
      LspBridgeService.chain = BridgeChainLive();
    });
  });

  group('record + store', () {
    test('JSON round-trip preserves every field', () {
      final r = _record()
        ..legTxid = kLegTxid
        ..legVout = 0
        ..legRedeem = kRedeem
        ..legBlockHash = 'cd' * 32
        ..btcNodeKey = 'nk'
        ..holdMinFinalCltv = 144
        ..detail = 'x';
      final back = LspBridgeRecord.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(back.state, BridgeState.held);
      expect(back.asset, kAsset);
      expect(back.assetAtoms, BigInt.from(1000));
      expect(back.btcSats, BigInt.from(5000));
      expect(back.offerId, 'off-1');
      expect(back.hashHex, kHashH);
      expect(back.preimageHex, kPreimage);
      expect(back.jobId, 'job-1');
      expect(back.poll, '/swap/job-1');
      expect(back.seqLocktime, 5000);
      expect(back.makerRefundPub, '02${'ee' * 32}');
      expect(back.legTxid, kLegTxid);
      expect(back.legVout, 0);
      expect(back.legRedeem, kRedeem);
      expect(back.legBlockHash, 'cd' * 32);
      expect(back.btcNodeKey, 'nk');
      expect(back.holdMinFinalCltv, 144);
      expect(back.startedMs, 7);
      expect(back.detail, 'x');
    });

    test('an unrecognised persisted state decodes NON-terminal and still guards the slot', () {
      final j = _record().toJson()..['state'] = 'a-future-state';
      final back = LspBridgeRecord.fromJson(j);
      expect(back.state, BridgeState.unknown);
      expect(back.terminal, isFalse);
      expect(back.holdsOrMightHoldValue, isTrue); // fail SAFE: an unknown state might hold the payment
    });

    test('store round-trip; inFlightWithFunds keys on the hold evidence, not the label', () async {
      _FakeSecureStorage().install();
      expect(await LspBridgeStore.load(), isNull);
      await LspBridgeStore.save(_record(state: BridgeState.confirming));
      // confirming = job posted, hold NOT paid -> nothing committed -> the slot is not "with funds".
      expect(await LspBridgeStore.inFlightWithFunds(), isNull);
      await LspBridgeStore.save(_record(state: BridgeState.held));
      expect(await LspBridgeStore.inFlightWithFunds(), isNotNull);
      await LspBridgeStore.clear();
      expect(await LspBridgeStore.load(), isNull);
    });
  });

  group('pure gates', () {
    test('claimWindowOpen: fail closed on an unreadable tip; refuse a window under the margin', () {
      expect(LspBridgeService.claimWindowOpen(seqTip: -1, seqLocktime: 5000), isFalse); // unreadable
      expect(LspBridgeService.claimWindowOpen(seqTip: 1000, seqLocktime: 0), isFalse); // no T_seq
      expect(LspBridgeService.claimWindowOpen(seqTip: 4880, seqLocktime: 5000), isFalse); // exactly margin
      expect(LspBridgeService.claimWindowOpen(seqTip: 4879, seqLocktime: 5000), isTrue); // margin + 1
      expect(LspBridgeService.claimWindowOpen(seqTip: 1000, seqLocktime: 5000), isTrue);
    });

    test('holdCltvCap: the skew-immune honest maximum (< the node routing ceiling)', () {
      // 480 blocks * 90s + 2h reorg + 30m settle = 52200s; /150s-per-BTC-block = 348; +6 margin = 354.
      expect(LspBridgeService.holdCltvCap(), 354);
      expect(LspBridgeService.holdCltvCap() <= kBridgeNodeMaxCltv, isTrue);
    });

    test('canAbandon: pre-hold and terminal clear freely; a held record only past T_seq', () {
      expect(LspBridgeService.canAbandon(_record(state: BridgeState.starting), seqTip: 0), isTrue);
      expect(LspBridgeService.canAbandon(_record(state: BridgeState.confirming), seqTip: 0), isTrue);
      expect(LspBridgeService.canAbandon(_record(state: BridgeState.settled), seqTip: 0), isTrue);
      final held = _record(state: BridgeState.held);
      expect(LspBridgeService.canAbandon(held, seqTip: 4999), isFalse); // window still live
      expect(LspBridgeService.canAbandon(held, seqTip: -1), isFalse); // unreadable tip: fail closed
      expect(LspBridgeService.canAbandon(held, seqTip: 5000), isTrue); // past T_seq: hold has expired back
    });
  });

  group('driver fail-closed (before the bare-hash pay: zero exposure)', () {
    test('a hold whose payment_hash is not OUR H refuses before paying', () async {
      _FakeSecureStorage().install();
      final c = _happyChain();
      c.holdBody['payment_hash'] = 'ee' * 32;
      LspBridgeService.chain = c;
      await expectLater(LspBridgeService.buy(_offer()), throwsA(isA<Exception>()));
      expect(c.payHashCalls, 0);
      final rec = await LspBridgeStore.load();
      expect(rec!.state, BridgeState.failed); // nothing committed -> terminal, the slot frees
    });

    test('an overpaying hold refuses before paying', () async {
      _FakeSecureStorage().install();
      final c = _happyChain();
      c.holdBody['amount_msat'] = 5000001; // 1 msat over the offer's 5000 sats
      LspBridgeService.chain = c;
      await expectLater(LspBridgeService.buy(_offer()), throwsA(isA<Exception>()));
      expect(c.payHashCalls, 0);
    });

    test('a hold with no min-final-CLTV floor refuses; one above the honest cap refuses', () async {
      _FakeSecureStorage().install();
      final c = _happyChain();
      c.holdBody.remove('hold_min_final_cltv');
      LspBridgeService.chain = c;
      await expectLater(LspBridgeService.buy(_offer()), throwsA(isA<Exception>()));
      expect(c.payHashCalls, 0);

      final c2 = _happyChain();
      c2.holdBody['hold_min_final_cltv'] = LspBridgeService.holdCltvCap() + 1;
      LspBridgeService.chain = c2;
      await expectLater(LspBridgeService.buy(_offer()), throwsA(isA<Exception>()));
      expect(c2.payHashCalls, 0);
    });

    test('happy path: swap -> hold -> pay -> anchor -> claim, in order, settled', () async {
      _FakeSecureStorage().install();
      final c = _happyChain();
      LspBridgeService.chain = c;
      final rec = await LspBridgeService.buy(_offer());
      expect(rec.state, BridgeState.settled);
      expect(rec.seqClaimTxid, 'claimtxid');
      expect(c.payHashCalls, 1);
      expect(c.claimCalls, 1);
      // The fund-safety ordering, as actually executed.
      expect(c.order.indexOf('swap'), lessThan(c.order.indexOf('hold')));
      expect(c.order.indexOf('hold'), lessThan(c.order.indexOf('pay')));
      expect(c.order.indexOf('pay'), lessThan(c.order.indexOf('anchor')));
      expect(c.order.indexOf('anchor'), lessThan(c.order.indexOf('claim')));
    });
  });

  group('claim-window gate (never reveal P into a closed window)', () {
    test('driver: a window closed after the hold refuses to claim; the record stays resumable', () async {
      _FakeSecureStorage().install();
      final c = _happyChain();
      c.tips = [4950]; // T_seq 5000: only 50 blocks left, under the 120 margin
      LspBridgeService.chain = c;
      await expectLater(LspBridgeService.buy(_offer()), throwsA(isA<Exception>()));
      expect(c.claimCalls, 0); // P was NOT revealed
      final rec = await LspBridgeStore.load();
      expect(rec, isNotNull);
      expect(rec!.state, BridgeState.held); // post-hold: NEVER dropped, resume keeps watching
      expect(rec.terminal, isFalse);
    });

    test('resume re-claim (branch A) is gated the same way — the claimWindowGate twin', () async {
      _FakeSecureStorage().install();
      final c = _happyChain();
      c.tips = [4950];
      LspBridgeService.chain = c;
      final r = _record(state: BridgeState.claiming)
        ..legTxid = kLegTxid
        ..legVout = 0
        ..legRedeem = kRedeem;
      await LspBridgeStore.save(r);
      final out = await LspBridgeService.resume();
      expect(c.claimCalls, 0); // refusal: P is not revealed into a closed window
      expect(out, isNotNull);
      expect(out!.state, BridgeState.claiming); // kept, not cleared
      expect(out.detail, contains('window'));
    });

    test('resume re-claim succeeds while the window is open', () async {
      _FakeSecureStorage().install();
      final c = _happyChain();
      c.tips = [1000];
      LspBridgeService.chain = c;
      final r = _record(state: BridgeState.claiming)
        ..legTxid = kLegTxid
        ..legVout = 0
        ..legRedeem = kRedeem;
      await LspBridgeStore.save(r);
      final out = await LspBridgeService.resume();
      expect(c.claimCalls, 1);
      expect(out!.state, BridgeState.settled);
    });

    test('resume of a held record re-enters the full verify->claim ladder', () async {
      _FakeSecureStorage().install();
      final c = _happyChain();
      LspBridgeService.chain = c;
      await LspBridgeStore.save(_record(state: BridgeState.held));
      final out = await LspBridgeService.resume();
      expect(out!.state, BridgeState.settled);
      expect(c.claimCalls, 1);
      expect(c.order.indexOf('anchor'), lessThan(c.order.indexOf('claim')));
    });

    test('resume drops only a provably-uncommitted record (starting, no job)', () async {
      _FakeSecureStorage().install();
      LspBridgeService.chain = _happyChain();
      final r = _record(state: BridgeState.starting)
        ..jobId = ''
        ..poll = '';
      await LspBridgeStore.save(r);
      final out = await LspBridgeService.resume();
      expect(out, isNull);
      expect(await LspBridgeStore.load(), isNull);
    });
  });
}
