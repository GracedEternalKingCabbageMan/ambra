// Unit tests for the REVERSE cross-chain (asset -> on-chain BTC) driver (xr_swap_service.dart) — the
// fund-safety spine of the mobile SELL taker, ported from the web wallet's xrswap.js. Covered:
//
//   1. Pure terms math: proportionalBtcFloor (whole take EXACT, partial FLOOR) + the min-slice dust
//      guards (byte-for-byte xminslice.go mirrors).
//   2. Persist/restore: the record JSON round-trip + the single-slot store over a method-channel-faked
//      flutter_secure_storage (the subswap test idiom); a corrupt blob loads null but is NOT deleted.
//   3. The state machine over mocked chain/courier seams:
//        - happy path, asserting the WIRE messages (terms_request with seq_amount as a JSON number;
//          seq_leg_funded with the leg's REAL anchor height) and the persist-before-broadcast ordering
//          (seqRedeem persisted before the broadcast; the intent flag at sign time; the txid at
//          broadcast) — plus a BOGUS courier secret_revealed hint being rejected by the hash check.
//        - the ANCHOR-GATE refusal: anchor < lockHeight+1 must WAIT (never fund) and fund only once the
//          anchor catches up; a closing fund window is the ONLY automatic way out of that wait.
//        - the fund-window-closed abort (nothing funded, honest courier fail).
//        - a terms mismatch (maker locks less than the proportional BTC) aborting pre-fund.
//   4. Pre-funding-abandon safety: a record with NO broadcast evidence clears cleanly; any record that
//      might hold a locked asset (intent flag / txid / leg) refuses to clear.
//   5. Strand recovery: broadcast intent recorded but no txid -> resume() adopts the txid found by the
//      HTLC-address scan and settles through to the BTC claim.
//
//   cd app && flutter test test/xr_swap_service_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/xr_swap_service.dart';
import 'package:ambra/src/rust/api.dart' as core;

const MethodChannel _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const String _storeKey = 'ambra.xrswap.active';

/// In-memory flutter_secure_storage backend over the plugin MethodChannel (the subswap test idiom).
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

/// A scripted courier: canned responses per XcMsg type; records everything sent/failed.
class _FakeCourier implements XrCourier {
  final Map<String, Map<String, dynamic>> responses = {};
  final sent = <Map<String, dynamic>>[];
  final fails = <List<String>>[];
  bool closed = false;

  @override
  Future<void> send(Map<String, dynamic> xcmsg) async => sent.add(xcmsg);

  @override
  Future<Map<String, dynamic>> recv(String wantType, {Duration timeout = const Duration(seconds: 30)}) async {
    final r = responses[wantType];
    if (r == null) throw TimeoutException('no scripted $wantType');
    return r;
  }

  @override
  Future<void> fail(String code, String message) async => fails.add([code, message]);

  @override
  Future<void> close() async => closed = true;
}

/// A scripted chain: fixed HTLC scripts/keys, adjustable tips/anchor/funding; records fund calls and
/// asserts the persist-before-broadcast discipline from INSIDE fundSeqHtlc (where the ordering is real).
class _FakeChain implements XrChain {
  _FakeChain();

  // Knobs.
  int seqTip = 1000;
  int seqTipReads = 0;
  int? seqTipAfterFirstRead; // later reads return this (verify passes once, then the window can close)
  int btcTip = 90;
  int anchorHeight = 99; // the LIVE anchor view
  bool anchorOk = true;
  int anchorAdvanceAfterReads = 0; // reads after which the anchor jumps to [anchorAfter]
  int anchorAfter = 0;
  int anchorReads = 0;
  XrBtcFunding? btcFunding; // the maker's lock as our view sees it
  XrSeqFunding? seqFunding; // our asset funding once "confirmed"
  ({int anchor, bool onActiveChain}) legAnchorEv = (anchor: -1, onActiveChain: false);
  String? preimageOnChain;
  String? addressScanTxid;
  BigInt? rate;

  // Recorders.
  int fundCalls = 0;
  final storeSnapshotsAtHook = <Map<String, dynamic>?>[];
  bool throwAfterBroadcastHook = false; // simulate fund() dying AFTER the node may have accepted the tx
  String fundTxid = 'seqfund01';
  String claimTxid = 'btcclaim01';
  String refundTxid = 'seqrefund01';
  final claimCalls = <Map<String, Object?>>[];

  static const btcRedeem = 'b1b1b1'; // the byte-matched BTC-leg script both sides agree on
  static const btcSpk = 'a914b1';
  static const seqRedeem = 's2s2s2';
  static const seqAddr = 'XHtlcAddr';
  static const seqSpk = 'a914s2';

  @override
  Future<String> takerBtcClaimPub() async => '02taker_btc_claim';
  @override
  Future<String> takerSeqRefundPub() async => '02taker_seq_refund';

  @override
  Future<core.BtcHtlcInfo> btcHtlc(
          {required String hashHex,
          required String claimPubHex,
          required String refundPubHex,
          required int locktime}) async =>
      const core.BtcHtlcInfo(redeemScriptHex: btcRedeem, p2ShAddress: 'btcP2sh', p2ShSpkHex: btcSpk);

  @override
  Future<core.SeqHtlcInfo> seqHtlcReverse(
          {required String hashHex, required String makerSeqClaimPubHex, required int seqLocktime}) async =>
      const core.SeqHtlcInfo(redeemScriptHex: seqRedeem, p2ShAddress: seqAddr, p2ShSpkHex: seqSpk);

  @override
  Future<XrBtcFunding?> findBtcFunding({required String txid, required String p2shSpkHex}) async => btcFunding;

  @override
  Future<int> seqTipHeight() async {
    seqTipReads++;
    if (seqTipAfterFirstRead != null && seqTipReads > 1) return seqTipAfterFirstRead!;
    return seqTip;
  }
  @override
  Future<int> btcTipHeight() async => btcTip;

  @override
  Future<({int height, bool ok})?> anchorTip() async {
    anchorReads++;
    if (anchorAdvanceAfterReads > 0 && anchorReads > anchorAdvanceAfterReads) anchorHeight = anchorAfter;
    return (height: anchorHeight, ok: anchorOk);
  }

  @override
  Future<({int anchor, bool onActiveChain})> legAnchor(String txid) async => legAnchorEv;

  @override
  Future<String> fundSeqHtlc(
      {required String address,
      required String assetId,
      required BigInt amountAtoms,
      required Future<void> Function() onAboutToBroadcast}) async {
    fundCalls++;
    // PERSIST-BEFORE-BROADCAST, observed where it matters: snapshot the persisted record BEFORE the
    // pre-broadcast hook (redeem must already be saved, txid must not be, intent must be unset) …
    storeSnapshotsAtHook.add(await _loadRaw());
    await onAboutToBroadcast();
    // … and immediately AFTER (intent set, txid still unset — it persists only once we return).
    storeSnapshotsAtHook.add(await _loadRaw());
    if (throwAfterBroadcastHook) throw Exception('lost response after broadcast');
    return fundTxid;
  }

  Future<Map<String, dynamic>?> _loadRaw() async {
    final r = await XrSwapStore.load();
    return r?.toJson();
  }

  @override
  Future<XrSeqFunding?> findSeqFunding({required String txid, required String p2shSpkHex}) async => seqFunding;

  @override
  Future<String?> findSeqFundingTxidByAddress({required String p2shAddress, required String p2shSpkHex}) async =>
      addressScanTxid;

  @override
  Future<String?> readSeqPreimage(
          {required String seqLegTxid, required int vout, required String hashHex}) async =>
      preimageOnChain;

  @override
  Future<String> claimBtc(
      {required String btcTxid,
      required int btcVout,
      required BigInt amountSats,
      required String redeemScriptHex,
      required String preimageHex}) async {
    claimCalls.add({
      'btcTxid': btcTxid,
      'btcVout': btcVout,
      'amountSats': amountSats,
      'redeemScriptHex': redeemScriptHex,
      'preimageHex': preimageHex,
    });
    return claimTxid;
  }

  @override
  Future<String> refundSeq(
          {required String seqTxid,
          required int seqVout,
          required BigInt amountAtoms,
          required String assetId,
          required String redeemScriptHex,
          required int seqLocktime}) async =>
      refundTxid;

  @override
  Future<BigInt?> assetRate(String assetHex) async => rate;
}

/// The maker's btc_leg_locked for a [wantBtc]-sat / [takeSeq]-atom slice against [_FakeChain]'s scripts.
Map<String, dynamic> _btcLegLocked({
  required BigInt wantBtc,
  required BigInt takeSeq,
  int tBtc = 5000,
  int tSeq = 2000,
  BigInt? legAmount,
}) =>
    {
      'type': 'btc_leg_locked',
      'hash_h': kHashH,
      'maker_seq_claim_pub': '03maker_seq_claim',
      'maker_refund_pub': '03maker_btc_refund',
      'btc_locktime': tBtc,
      'seq_locktime': tSeq,
      'btc_amount': wantBtc.toInt(),
      'seq_amount': takeSeq.toInt(),
      'fee_btc': 0,
      'leg': {
        'txid': 'makerbtclock01',
        'vout': 0,
        'amount': (legAmount ?? wantBtc).toInt(),
        'redeem_script': _FakeChain.btcRedeem,
        'locktime': tBtc,
      },
    };

XrTiming _fastTiming({int btcConfMaxTries = 5, int seqConfMaxTries = 5, int settleMaxTries = 5}) => XrTiming(
      anchorPoll: Duration.zero,
      btcConfPoll: Duration.zero,
      btcConfMaxTries: btcConfMaxTries,
      seqConfPoll: Duration.zero,
      seqConfMaxTries: seqConfMaxTries,
      settlePoll: Duration.zero,
      settleMaxTries: settleMaxTries,
      revealHintTimeout: Duration.zero,
      btcLockedTimeout: Duration.zero,
    );

XrSwapRecord _fundedRecord({XrStep step = XrStep.seqFunded}) => XrSwapRecord(
      step: step,
      offerId: 'off1',
      makerPubkey: '02maker',
      seqAsset: 'assetX',
      seqAmount: BigInt.from(5000),
      btcAmount: BigInt.from(10000),
      feeBtc: BigInt.zero,
      hashHex: kHashH,
      makerSeqClaimPub: '03maker_seq_claim',
      makerBtcRefundPub: '03maker_btc_refund',
      takerBtcClaimPub: '02taker_btc_claim',
      takerSeqRefundPub: '02taker_seq_refund',
      btcLocktime: 5000,
      seqLocktime: 2000,
      btcLegTxid: 'makerbtclock01',
      btcLegVout: 0,
      btcLegAmount: BigInt.from(10000),
      btcLegRedeemScript: _FakeChain.btcRedeem,
      btcP2shSpkHex: _FakeChain.btcSpk,
      btcLegHeight: 100,
      seqRedeem: _FakeChain.seqRedeem,
      seqP2shAddress: _FakeChain.seqAddr,
      seqP2shSpkHex: _FakeChain.seqSpk,
      broadcastAttempted: true,
      seqFundTxid: 'seqfund01',
      seqLeg: XrSeqLeg(txid: 'seqfund01', vout: 1, blockHash: 'bh1'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage store;
  late _FakeChain chain;
  final defaultChain = XrSwapService.chain;
  const defaultTiming = XrTiming();

  setUp(() {
    store = _FakeSecureStorage()..install();
    chain = _FakeChain();
    XrSwapService.chain = chain;
    XrSwapService.timing = _fastTiming();
    addTearDown(() {
      XrSwapService.chain = defaultChain;
      XrSwapService.timing = defaultTiming;
    });
  });

  Future<XrSwapRecord> runDriver(_FakeCourier courier,
      {BigInt? takeSeq, BigInt? offerAtoms, BigInt? offerBtc}) {
    return XrSwapService.runWithCourier(
      courier,
      offerId: 'off1',
      makerPubkey: '02maker',
      seqAsset: 'assetX',
      offerAssetAtoms: offerAtoms ?? BigInt.from(5000),
      offerBtcSats: offerBtc ?? BigInt.from(10000),
      takeSeq: takeSeq ?? BigInt.from(5000),
    );
  }

  group('pure terms math', () {
    test('proportionalBtcFloor: whole take returns wholeBtc exactly; partial floors', () {
      final whole = BigInt.from(43), wholeBtc = BigInt.from(100000);
      expect(XrSwapService.proportionalBtcFloor(wholeBtc, whole, whole), wholeBtc);
      expect(XrSwapService.proportionalBtcFloor(wholeBtc, BigInt.from(50), whole), wholeBtc); // over-take clamps
      // 100000 * 10 / 43 = 23255.8… -> FLOOR 23255 (the maker's favour: the maker GIVES the BTC).
      expect(XrSwapService.proportionalBtcFloor(wholeBtc, BigInt.from(10), whole), BigInt.from(23255));
      expect(XrSwapService.proportionalBtcFloor(wholeBtc, BigInt.one, BigInt.zero), wholeBtc);
    });

    test('min-slice dust guards mirror xminslice.go', () {
      // MinSafeBtcLegSats at the 1000-sat default = 546 + 2000 = 2546.
      expect(XrSwapService.minSafeBtcLegSats(BigInt.from(1000)), BigInt.from(2546));
      expect(XrSwapService.minSafeBtcLegSats(BigInt.from(10)), BigInt.from(2546)); // fee floors up
      // A partial pricing to a sub-minimum BTC leg is refused; a whole take never is.
      expect(
          XrSwapService.minSafeBtcReason(
              BigInt.from(10), BigInt.from(100), BigInt.from(2545), BigInt.from(1000)),
          isNotNull);
      expect(
          XrSwapService.minSafeBtcReason(
              BigInt.from(100), BigInt.from(100), BigInt.one, BigInt.from(1000)),
          isNull);
      // No published rate -> flat native fallback: 1 + 2*1000 = 2001 atoms.
      expect(XrSwapService.minSafeAssetLeg(null, BigInt.from(1000)), BigInt.from(2001));
      // rate = 2e8 (asset worth 2x native): fee = ceil(1000*1e8/2e8) = 500 -> 1 + 1000 = 1001.
      expect(XrSwapService.minSafeAssetLeg(BigInt.from(200000000), BigInt.from(1000)), BigInt.from(1001));
    });
  });

  group('persist/restore', () {
    test('record JSON round-trip preserves every field', () {
      final r = _fundedRecord()..preimageHex = kPreimage;
      final back = XrSwapRecord.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(back.step, r.step);
      expect(back.seqAmount, r.seqAmount);
      expect(back.btcAmount, r.btcAmount);
      expect(back.hashHex, r.hashHex);
      expect(back.btcLocktime, r.btcLocktime);
      expect(back.seqLocktime, r.seqLocktime);
      expect(back.btcLegTxid, r.btcLegTxid);
      expect(back.btcLegAmount, r.btcLegAmount);
      expect(back.btcLegHeight, r.btcLegHeight);
      expect(back.seqRedeem, r.seqRedeem);
      expect(back.seqP2shAddress, r.seqP2shAddress);
      expect(back.broadcastAttempted, isTrue);
      expect(back.seqFundTxid, r.seqFundTxid);
      expect(back.seqLeg!.txid, r.seqLeg!.txid);
      expect(back.seqLeg!.vout, r.seqLeg!.vout);
      expect(back.seqLeg!.blockHash, r.seqLeg!.blockHash);
      expect(back.preimageHex, kPreimage);
    });

    test('store round-trip; an unknown step decodes NON-terminal; corrupt blob is not deleted', () async {
      final r = _fundedRecord();
      await XrSwapStore.save(r);
      final loaded = await XrSwapStore.load();
      expect(loaded, isNotNull);
      expect(loaded!.seqLeg!.vout, 1);
      expect((await XrSwapStore.inFlightWithFunds()), isNotNull);

      // Unknown persisted step -> XrStep.failed (non-terminal), never a silent "done". Seeded under
      // the LEGACY key with its OWN id so the one-time adoption carries it into the list.
      final j = r.toJson()
        ..['step'] = 'no_such_step'
        ..['id'] = 'legacy-unknown-step';
      store.data[_storeKey] = jsonEncode(j);
      final unk = await XrSwapStore.load(id: 'legacy-unknown-step');
      expect(unk!.step, XrStep.failed);
      expect(unk.terminal, isFalse);
      expect(unk.holdsOrMightHoldAsset, isTrue); // the funded evidence still guards it
      expect(store.data.containsKey(_storeKey), isFalse, reason: 'adopted into the list, legacy slot emptied');

      // Corrupt LEGACY blob: reads skip it, but the blob survives (never deleted by a read).
      store.data[_storeKey] = 'not json';
      expect(await XrSwapStore.load(id: 'no-such-record'), isNull);
      expect(store.data.containsKey(_storeKey), isTrue);
      await XrSwapStore.clear();
      expect(store.data.containsKey(_storeKey), isFalse);
    });
  });

  group('state machine (mocked chain + courier)', () {
    test('happy path: verify -> conf -> anchor gate -> fund (persist-before-broadcast) -> announce -> claim',
        () async {
      final wantBtc = BigInt.from(10000), takeSeq = BigInt.from(5000);
      final courier = _FakeCourier()
        ..responses['btc_leg_locked'] = _btcLegLocked(wantBtc: wantBtc, takeSeq: takeSeq)
        // A BOGUS reveal hint: must be REJECTED by the sha256 check (the chain read is authoritative).
        ..responses['secret_revealed'] = {'type': 'secret_revealed', 'preimage': 'bb' * 32};
      chain
        ..btcFunding = XrBtcFunding(vout: 0, valueSats: wantBtc, height: 100, confirmed: true)
        ..anchorHeight = 101 // >= lock height + 1
        ..seqFunding = XrSeqFunding(vout: 1, blockHash: 'bh1')
        ..legAnchorEv = (anchor: 101, onActiveChain: true)
        ..preimageOnChain = kPreimage;

      final rec = await runDriver(courier);
      expect(rec.step, XrStep.btcClaimed);
      expect(rec.btcClaimTxid, 'btcclaim01');
      expect(rec.preimageHex, kPreimage); // the bogus hint was rejected; the chain read won
      expect(courier.closed, isTrue);

      // Wire shape: terms_request carries seq_amount as a JSON NUMBER + both taker pubkeys.
      final tr = courier.sent.firstWhere((m) => m['type'] == 'terms_request');
      expect(tr['seq_amount'], takeSeq.toInt());
      expect(tr['seq_amount'], isA<int>());
      expect(tr['taker_seq_refund_pub'], '02taker_seq_refund');
      expect(tr['taker_btc_claim_pub'], '02taker_btc_claim');
      // seq_leg_funded carries the leg with its REAL Bitcoin-anchor height + block hash.
      final slf = courier.sent.firstWhere((m) => m['type'] == 'seq_leg_funded');
      final leg = slf['leg'] as Map;
      expect(leg['txid'], 'seqfund01');
      expect(leg['vout'], 1);
      expect(leg['anchor_height'], 101);
      expect(leg['block_hash'], 'bh1');
      expect(leg['redeem_script'], _FakeChain.seqRedeem);

      // PERSIST-BEFORE-BROADCAST: at the moment fundSeqHtlc ran, the redeem was already persisted with
      // no txid and no intent; after the pre-broadcast hook the intent was persisted, txid still unset.
      expect(chain.fundCalls, 1);
      final before = chain.storeSnapshotsAtHook[0]!;
      expect(before['seqRedeem'], _FakeChain.seqRedeem);
      expect(before['seqFundTxid'], '');
      expect(before['broadcastAttempted'], false);
      final after = chain.storeSnapshotsAtHook[1]!;
      expect(after['broadcastAttempted'], true);
      expect(after['seqFundTxid'], '');

      // The BTC claim spent the maker's leg with the on-chain preimage.
      expect(chain.claimCalls.single['preimageHex'], kPreimage);
      expect(chain.claimCalls.single['btcTxid'], 'makerbtclock01');
    });

    test('anchor gate: anchor < lockHeight+1 WAITS (never funds), then funds once caught up', () async {
      final courier = _FakeCourier()
        ..responses['btc_leg_locked'] = _btcLegLocked(wantBtc: BigInt.from(10000), takeSeq: BigInt.from(5000));
      chain
        ..btcFunding = XrBtcFunding(vout: 0, valueSats: BigInt.from(10000), height: 100, confirmed: true)
        ..anchorHeight = 100 // == lock height: BELOW the +1 target -> must wait
        ..anchorAdvanceAfterReads = 4
        ..anchorAfter = 101
        ..seqFunding = XrSeqFunding(vout: 1, blockHash: 'bh1')
        ..legAnchorEv = (anchor: 101, onActiveChain: true)
        ..preimageOnChain = kPreimage;

      final rec = await runDriver(courier);
      expect(rec.step, XrStep.btcClaimed);
      expect(chain.anchorReads, greaterThan(4)); // it polled through the refusal window
      expect(chain.fundCalls, 1); // and funded exactly once, only after the anchor caught up
    });

    test('anchor gate refusal is escaped ONLY by the fund window closing: aborts with nothing funded',
        () async {
      final courier = _FakeCourier()
        ..responses['btc_leg_locked'] =
            _btcLegLocked(wantBtc: BigInt.from(10000), takeSeq: BigInt.from(5000), tSeq: 2000);
      chain
        ..btcFunding = XrBtcFunding(vout: 0, valueSats: BigInt.from(10000), height: 100, confirmed: true)
        ..anchorHeight = 100 // stuck below the target forever
        ..seqTip = 1500 // the verify-time T_seq floor passes (2000 >= 1500+120)…
        ..seqTipAfterFirstRead = 1900; // …then the chain moves inside the claim window at the gate
      await expectLater(runDriver(courier), throwsA(isA<Exception>()));
      expect(chain.fundCalls, 0); // NOTHING was funded
      expect(courier.fails, isNotEmpty);
      expect(courier.fails.last[0], 'anchor_not_caught_up');
      final rec = await XrSwapStore.load();
      expect(rec!.step, XrStep.failed);
      expect(rec.holdsOrMightHoldAsset, isFalse); // abandonable: nothing of ours moved
    });

    test('fund-window-closed during the BTC-conf wait aborts with nothing funded', () async {
      final courier = _FakeCourier()
        ..responses['btc_leg_locked'] =
            _btcLegLocked(wantBtc: BigInt.from(10000), takeSeq: BigInt.from(5000), tBtc: 200, tSeq: 150);
      chain
        ..seqTip = 10 // the verify-time T_seq floor passes (150 >= 10+120)
        ..btcFunding = null // the maker's lock never confirms…
        ..btcTip = 195; // …and Bitcoin is within kXrMinBtcClaimWindow of T_btc=200
      await expectLater(runDriver(courier), throwsA(isA<Exception>()));
      expect(chain.fundCalls, 0);
      expect(courier.fails.last[0], 'fund_window_closed');
      expect((await XrSwapStore.load())!.step, XrStep.failed);
    });

    test('terms mismatch (maker locks less than the proportional BTC) aborts pre-fund', () async {
      final courier = _FakeCourier()
        ..responses['btc_leg_locked'] = _btcLegLocked(
            wantBtc: BigInt.from(10000), takeSeq: BigInt.from(5000), legAmount: BigInt.from(9999));
      await expectLater(runDriver(courier), throwsA(isA<Exception>()));
      expect(chain.fundCalls, 0);
      expect(courier.fails.last[0], 'terms_mismatch');
    });

    test('no maker response is retriable (XrNoMakerException), nothing persisted', () async {
      final courier = _FakeCourier(); // no scripted btc_leg_locked -> recv times out
      await expectLater(runDriver(courier), throwsA(isA<XrNoMakerException>()));
      expect(await XrSwapStore.load(), isNull);
      expect(courier.closed, isTrue);
    });
  });

  group('abandon safety', () {
    test('pre-funding record (no broadcast evidence) clears cleanly', () async {
      final r = _fundedRecord(step: XrStep.btcLocked)
        ..seqLeg = null
        ..seqFundTxid = ''
        ..broadcastAttempted = false;
      await XrSwapStore.save(r);
      expect(XrSwapService.canAbandon(r), isTrue);
      expect(await XrSwapService.abandon(r), isTrue);
      expect(await XrSwapStore.load(), isNull);
    });

    test('any record that might hold a locked asset refuses to clear', () async {
      for (final mutate in <void Function(XrSwapRecord)>[
        (r) {}, // seqLeg set
        (r) => r
          ..seqLeg = null
          ..broadcastAttempted = false, // txid persisted (broadcast happened)
        (r) => r..seqFundTxid = '', // intent recorded, txid lost: the strand-recovery case
      ]) {
        final r = _fundedRecord();
        mutate(r);
        await XrSwapStore.save(r);
        expect(XrSwapService.canAbandon(r), isFalse);
        expect(await XrSwapService.abandon(r), isFalse);
        expect(await XrSwapStore.load(), isNotNull); // the reclaim material survives
        await XrSwapStore.clear();
      }
    });

    test('terminal records clear', () async {
      final done = _fundedRecord(step: XrStep.btcClaimed)..btcClaimTxid = 'btcclaim01';
      await XrSwapStore.save(done);
      expect(XrSwapService.canAbandon(done), isTrue);
      expect(await XrSwapService.abandon(done), isTrue);
    });
  });

  group('resume', () {
    test('strand recovery: intent recorded, txid lost -> adopt from the address scan and settle', () async {
      final r = _fundedRecord()
        ..seqLeg = null
        ..seqFundTxid = ''; // fund() threw after the node may have accepted the tx
      await XrSwapStore.save(r);
      chain
        ..addressScanTxid = 'seqfund01'
        ..seqFunding = XrSeqFunding(vout: 1, blockHash: 'bh1')
        ..preimageOnChain = kPreimage;
      final out = await XrSwapService.resume();
      expect(out!.seqFundTxid, 'seqfund01'); // adopted, never re-funded
      expect(out.seqLeg!.vout, 1);
      expect(out.step, XrStep.btcClaimed);
      expect(chain.fundCalls, 0); // resume NEVER funds
      expect(chain.claimCalls, hasLength(1));
    });

    test('strand recovery with an empty scan leaves the record intact (a lagging backend is not proof)',
        () async {
      final r = _fundedRecord()
        ..seqLeg = null
        ..seqFundTxid = '';
      await XrSwapStore.save(r);
      chain.addressScanTxid = null;
      final out = await XrSwapService.resume();
      expect(out!.seqFundTxid, '');
      expect(await XrSwapStore.load(), isNotNull);
      expect(XrSwapService.canAbandon(out), isFalse); // still guarded
    });

    test('resumeSeqLeg adopts the confirmed leg from a persisted txid and never funds', () async {
      final r = _fundedRecord()..seqLeg = null;
      await XrSwapStore.save(r);
      chain.seqFunding = XrSeqFunding(vout: 2, blockHash: 'bh2');
      final out = await XrSwapService.resumeSeqLeg(r);
      expect(out.seqLeg!.vout, 2);
      expect(out.step, XrStep.seqFunded);
      expect(chain.fundCalls, 0);
    });
  });

  group('refund off-ramp', () {
    test('refund is gated on the CLTV maturity and hidden once the secret is out', () async {
      final r = _fundedRecord();
      chain.seqTip = 1999; // below T_seq=2000
      expect(await XrSwapService.refundSeqReady(r), isFalse);
      await expectLater(XrSwapService.refundSeq(r), throwsA(isA<Exception>()));
      chain.seqTip = 2000;
      expect(await XrSwapService.refundSeqReady(r), isTrue);
      r.preimageHex = kPreimage; // the maker already claimed: claim the BTC instead
      expect(await XrSwapService.refundSeqReady(r), isFalse);
    });

    test('refund executes once mature and persists the terminal state', () async {
      final r = _fundedRecord();
      await XrSwapStore.save(r);
      chain.seqTip = 2001;
      final out = await XrSwapService.refundSeq(r);
      expect(out.step, XrStep.refunded);
      expect(out.seqRefundTxid, 'seqrefund01');
      expect((await XrSwapStore.load())!.step, XrStep.refunded);
      expect(XrSwapService.canAbandon(out), isTrue); // terminal: clearable
    });
  });
}
