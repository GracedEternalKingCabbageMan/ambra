// Unit tests for the MULTI-RECORD trade-store substrate + the shared slot count (trade_slots.dart),
// gap 9 of the DEX parity drive:
//
//   1. ONE-TIME MIGRATION, NEVER-LOSSY — a legacy single-slot record ('ambra.<kind>.active') is ADOPTED
//      into the new list key on first read (id injected, write-first-then-delete), round-trips every
//      field, and is NEVER dropped: a re-run dedupes by id (the crash-mid-adoption case) and an
//      UNDECODABLE legacy blob stays in place untouched.
//   2. PER-RECORD IDS — save() upserts by id, so two concurrent records never clobber each other and a
//      remove() drops exactly one.
//   3. SHARED SLOT COUNT — TradeSlots counts in-flight records ACROSS the rail-crossing kinds
//      (buys + sells + subswaps + bridge + xr; pure-LN records never count) and refuses with the honest
//      message once kMaxConcurrentTrades are in flight; terminal records never eat a slot.
//
//   cd app && flutter test test/trade_slots_test.dart

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/ln_take_service.dart';
import 'package:ambra/src/data/lsp_bridge_service.dart';
import 'package:ambra/src/data/lsp_client.dart' show SubOffer;
import 'package:ambra/src/data/subasset_buy_service.dart';
import 'package:ambra/src/data/subasset_sell_service.dart';
import 'package:ambra/src/data/subswap_service.dart';
import 'package:ambra/src/data/trade_slots.dart';
import 'package:ambra/src/data/xr_swap_service.dart';

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
  }

  static void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  }
}

SubBuyRecord _buy({String? id, SubBuyStep step = SubBuyStep.funding}) => SubBuyRecord(
      id: id,
      step: step,
      asset: 'aa11',
      ticker: 'GOLD',
      preimage: 'b' * 64,
      hashHex: 'a' * 64,
      nodeKey: 'nk',
      redeem: 'cc',
      p2sh: '2NAddr',
      p2shSpk: 'dd',
      tBtc: 100,
      btcSats: BigInt.from(5000),
      assetAtoms: BigInt.from(1000),
      makerClaimPub: '02aa',
      refundPub: '02bb',
      offerId: 'off-1',
      makerPubkey: '02cc',
      fundingTxid: step == SubBuyStep.secretReady ? '' : 'e' * 64,
    );

SubSellRecord _sell({String? id, SubSellStep step = SubSellStep.claiming}) => SubSellRecord(
      id: id,
      step: step,
      asset: 'aa11',
      ticker: 'GOLD',
      expectedBtc: BigInt.from(5000),
      preimage: 'b' * 64,
      hashHex: 'a' * 64,
    );

SubswapRecord _sub({String? id, SubState state = SubState.funding}) => SubswapRecord(
      id: id,
      buy: false,
      state: state,
      asset: 'aa11',
      assetAtoms: BigInt.from(1000),
      btcSats: BigInt.from(5000),
      offerId: 'off-sub',
      makerPubkey: '02dd',
    );

XrSwapRecord _xr({String? id, XrStep step = XrStep.seqFunded}) => XrSwapRecord(
      id: id,
      step: step,
      offerId: 'off-xr',
      makerPubkey: '02ee',
      seqAsset: 'aa11',
      seqAmount: BigInt.from(1000),
      btcAmount: BigInt.from(5000),
      feeBtc: BigInt.zero,
      hashHex: 'a' * 64,
      makerSeqClaimPub: '02aa',
      makerBtcRefundPub: '02bb',
      takerBtcClaimPub: '02cc',
      takerSeqRefundPub: '02dd',
      btcLocktime: 200,
      seqLocktime: 100,
      btcLegTxid: 'f' * 64,
      btcLegVout: 0,
      btcLegAmount: BigInt.from(5000),
      btcLegRedeemScript: 'ee',
      btcP2shSpkHex: 'ff',
      seqFundTxid: 'e' * 64,
    );

LspBridgeRecord _bridge({String? id, BridgeState state = BridgeState.held}) => LspBridgeRecord(
      id: id,
      state: state,
      asset: 'aa11',
      assetAtoms: BigInt.from(1000),
      btcSats: BigInt.from(5000),
      offerId: 'off-br',
      makerPubkey: '02ff',
      hashHex: 'a' * 64,
      preimageHex: 'b' * 64,
      startedMs: 7,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage fake;

  setUp(() async {
    fake = _FakeSecureStorage()..install();
    await SubBuyStore.clear();
    await SubSellStore.clear();
    await SubswapStore.clear();
    await XrSwapStore.clear();
    await LspBridgeStore.clear();
    await LnTakeStore.clear();
    fake.data.clear();
  });

  tearDown(_FakeSecureStorage.uninstall);

  group('one-time migration (legacy adopt, never-lossy)', () {
    test('a legacy BUY record is adopted into the list, round-trips every field, and the legacy key empties', () async {
      // A pre-list record has NO id — the adoption injects one.
      final legacy = _buy().toJson()..remove('id');
      fake.data['ambra.subasset.buy.active'] = jsonEncode(legacy);
      final all = await SubBuyStore.loadAll();
      expect(all, hasLength(1));
      final r = all.single;
      expect(r.id, isNotEmpty, reason: 'the adoption mints a stable per-record id');
      expect(r.step, SubBuyStep.funding);
      expect(r.preimage, 'b' * 64);
      expect(r.btcSats, BigInt.from(5000));
      expect(r.assetAtoms, BigInt.from(1000));
      expect(r.fundingTxid, 'e' * 64);
      expect(fake.data.containsKey('ambra.subasset.buy.active'), isFalse, reason: 'adopted -> legacy slot emptied');
      // ROUND-TRIP: the adopted record persists + reloads identically through the list store.
      await SubBuyStore.save(r);
      final back = await SubBuyStore.load(id: r.id);
      expect(back, isNotNull);
      expect(jsonEncode(back!.toJson()), jsonEncode(r.toJson()));
    });

    test('a crashed half-adoption never duplicates: the legacy id already in the list is deduped', () async {
      // Simulate the crash window AFTER the list write, BEFORE the legacy delete: both keys carry the
      // record under the SAME id.
      final rec = _buy(id: 'crash-adopt-1');
      fake.data['ambra.subasset.buys'] = jsonEncode([rec.toJson()]);
      fake.data['ambra.subasset.buy.active'] = jsonEncode(rec.toJson());
      final all = await SubBuyStore.loadAll();
      expect(all, hasLength(1), reason: 'the re-run dedupes by id — never a duplicate record');
      expect(fake.data.containsKey('ambra.subasset.buy.active'), isFalse, reason: 'the re-run tidies the legacy key');
    });

    test('an UNDECODABLE legacy blob is left in place untouched (never deleted by a read)', () async {
      fake.data['ambra.subasset.buy.active'] = 'not json {{{';
      final all = await SubBuyStore.loadAll();
      expect(all, isEmpty);
      expect(fake.data['ambra.subasset.buy.active'], 'not json {{{',
          reason: 'it may be the only copy of reclaim material — reads never delete it');
    });

    test('every legacy store adopts: sell / subswap / xr / bridge / ln', () async {
      fake.data['ambra.subasset.sell.active'] = jsonEncode(_sell().toJson()..remove('id'));
      fake.data['ambra.subswap.active'] = jsonEncode(_sub().toJson()..remove('id'));
      fake.data['ambra.xrswap.active'] = jsonEncode(_xr().toJson()..remove('id'));
      fake.data['ambra.bridge.active'] = jsonEncode(_bridge().toJson()..remove('id'));
      fake.data['ambra.ln.active'] = jsonEncode(LnTakeRecord(
        state: 'inflight',
        side: 'buy',
        asset: 'aa11',
        assetAtoms: BigInt.one,
        quoteAtoms: BigInt.two,
        startedMs: 1,
      ).toJson()
        ..remove('id'));
      expect((await SubSellStore.loadAll()).single.step, SubSellStep.claiming);
      expect((await SubswapStore.loadAll()).single.state, SubState.funding);
      expect((await XrSwapStore.loadAll()).single.step, XrStep.seqFunded);
      expect((await LspBridgeStore.loadAll()).single.state, BridgeState.held);
      expect((await LnTakeStore.loadAll()).single.side, 'buy');
      for (final k in [
        'ambra.subasset.sell.active',
        'ambra.subswap.active',
        'ambra.xrswap.active',
        'ambra.bridge.active',
        'ambra.ln.active',
      ]) {
        expect(fake.data.containsKey(k), isFalse, reason: '$k adopted');
      }
    });
  });

  group('per-record ids (upsert never clobbers)', () {
    test('two records coexist; saving one leaves the other byte-identical; remove drops exactly one', () async {
      final a = _buy(id: 'rec-a');
      final b = _buy(id: 'rec-b', step: SubBuyStep.funded);
      await SubBuyStore.save(a);
      await SubBuyStore.save(b);
      expect(await SubBuyStore.loadAll(), hasLength(2));
      // Mutate + upsert A: B must be untouched (the structural fund-safety the single slot could not give).
      a.step = SubBuyStep.holding;
      await SubBuyStore.save(a);
      final b2 = await SubBuyStore.load(id: 'rec-b');
      expect(jsonEncode(b2!.toJson()), jsonEncode(b.toJson()));
      expect((await SubBuyStore.load(id: 'rec-a'))!.step, SubBuyStep.holding);
      await SubBuyStore.remove('rec-a');
      expect(await SubBuyStore.load(id: 'rec-a'), isNull);
      expect(await SubBuyStore.load(id: 'rec-b'), isNotNull);
    });
  });

  group('shared slot count (buys + sells + subswaps + bridge + xr < 3)', () {
    test('counts in-flight records across kinds; terminal records never eat a slot', () async {
      expect(await TradeSlots.inFlightCount(), 0);
      expect(await TradeSlots.refusalIfFull(), isNull);
      await SubBuyStore.save(_buy());
      await SubSellStore.save(_sell());
      expect(await TradeSlots.inFlightCount(), 2);
      expect(await TradeSlots.refusalIfFull(), isNull, reason: '2 of 3 slots used — one still free');
      final sub = _sub();
      await SubswapStore.save(sub);
      expect(await TradeSlots.inFlightCount(), 3);
      final msg = await TradeSlots.refusalIfFull();
      expect(msg, isNotNull);
      expect(msg, contains('3 trades in progress'));
      expect(msg, contains('in-flight cards'));
      // Settling the SAME record (upsert by id) frees its slot.
      sub.state = SubState.settled;
      await SubswapStore.save(sub);
      expect(await TradeSlots.inFlightCount(), 2);
      expect(await TradeSlots.refusalIfFull(), isNull);
    });

    test('xr and bridge records count; a pure-LN take never does', () async {
      await XrSwapStore.save(_xr());
      await LspBridgeStore.save(_bridge());
      expect(await TradeSlots.inFlightCount(), 2);
      await LnTakeStore.save(LnTakeRecord(
        state: 'inflight',
        side: 'buy',
        asset: 'aa11',
        assetAtoms: BigInt.one,
        quoteAtoms: BigInt.two,
        startedMs: DateTime.now().millisecondsSinceEpoch,
      ));
      expect(await TradeSlots.inFlightCount(), 2, reason: 'pure-LN commits nothing client-side — no slot');
      // A pre-hold bridge record (nothing committed) does not count; an xr record with no funded
      // evidence does not count either.
      await LspBridgeStore.save(_bridge(state: BridgeState.starting, id: 'br-2'));
      expect(await TradeSlots.inFlightCount(), 2);
    });

    test('the sub-asset BUY begin-gate refuses at 3 in flight with the honest message', () async {
      await SubBuyStore.save(_buy(id: 's1'));
      await SubSellStore.save(_sell(id: 's2'));
      await XrSwapStore.save(_xr(id: 's3'));
      expect(
        () => SubassetBuyService.begin(
          asset: 'aa11',
          offer: SubOffer(
            offerId: 'o',
            makerPubkey: 'm',
            makerClaimPub: '02aa',
            assetAmount: BigInt.from(1000),
            btcSats: BigInt.from(5000),
            onchainCltv: 100,
            raw: const {},
          ),
        ),
        throwsA(predicate((e) => e.toString().contains('trades in progress'))),
      );
    });
  });
}
