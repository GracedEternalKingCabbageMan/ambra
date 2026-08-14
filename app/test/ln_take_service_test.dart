// Unit tests for the COMPOSER-NATIVE pure-LN take seam (ln_take_service.dart):
//
//   1. REVIEW SIZING — the offer-vs-typed mismatch math the Review sheet keys its loud note on
//      (mirror web reviewLn's 5% threshold): within 5% -> no note; beyond -> note; nothing typed /
//      unparsable -> no note (the review's amounts are already the whole truth).
//   2. SLICE PRICING — priceSlice, the one client-side authority mirroring the LSP's Go settlement
//      driver EXACTLY: take = min(typed, offer); counter leg FLOOR on a buy / CEIL on a sell; BigInt
//      exactness; the whole path reproduces the offer's legs VERBATIM (no derived rounding); a dust
//      partial (counter leg = 0) refuses before anything persists or posts.
//   3. RECORD ROUND-TRIP — the persisted single-slot record ('ambra.ln.active') preserves every field
//      (take_atoms included; absent on legacy records = zero = a whole lift) through JSON and through
//      the real secure-storage store; an unrecognised state decodes as 'inflight' (never silently
//      resolved).
//   4. STALE RESOLUTION — a record younger than the LSP's 90s timeout is left alone (a live POST may
//      still be racing it); an old one with a matching 'ln:' receipt in the trail resolves SETTLED and
//      clears; an old one without a receipt surfaces "did not settle" (honest: pure-LN commits nothing
//      client-side); a failed record surfaces the same banner.
//
//   cd app && flutter test test/ln_take_service_test.dart

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/config.dart';
import 'package:ambra/src/data/ln_take_service.dart';
import 'package:ambra/src/data/lsp_client.dart';
import 'package:ambra/src/data/trade_receipts.dart';

const MethodChannel _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// In-memory flutter_secure_storage backend over the plugin MethodChannel (the shared test idiom).
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

const String kAsset = '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de';

LnTakeRecord _rec({String state = 'inflight', int? startedMs}) => LnTakeRecord(
      state: state,
      side: 'sell',
      asset: kAsset,
      quoteAsset: null,
      offerId: 'off-1',
      makerPubkey: '02aa',
      assetAtoms: BigInt.from(200000),
      quoteAtoms: BigInt.from(1234),
      takeAtoms: BigInt.from(200000),
      startedMs: startedMs ?? DateTime.now().millisecondsSinceEpoch,
      detail: 'd',
    );

LnOffer _offer({required int assetAtoms, required int btcSats}) => LnOffer(
      offerId: 'off-1',
      makerPubkey: '02aa',
      assetAtoms: BigInt.from(assetAtoms),
      btcAtoms: BigInt.from(btcSats),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('review sizing (offer-vs-typed)', () {
    // Offer leg: 200000 atoms at precision 4 = "20" display units.
    final exec = BigInt.from(200000);

    test('typed within 5% of the executed leg -> no note', () {
      expect(LnTakeService.sizeMismatchPct(execAtoms: exec, precision: 4, typed: '19.5'), closeTo(2.5, 0.001));
      expect(LnTakeService.needsSizeNote(execAtoms: exec, precision: 4, typed: '19.5'), isFalse);
      expect(LnTakeService.needsSizeNote(execAtoms: exec, precision: 4, typed: '20'), isFalse);
    });

    test('typed beyond 5% -> loud note (both directions)', () {
      expect(LnTakeService.sizeMismatchPct(execAtoms: exec, precision: 4, typed: '10'), closeTo(50.0, 0.001));
      expect(LnTakeService.needsSizeNote(execAtoms: exec, precision: 4, typed: '10'), isTrue);
      expect(LnTakeService.needsSizeNote(execAtoms: exec, precision: 4, typed: '30'), isTrue);
    });

    test('nothing typed / unparsable / zero exec -> null (no note)', () {
      expect(LnTakeService.sizeMismatchPct(execAtoms: exec, precision: 4, typed: ''), isNull);
      expect(LnTakeService.sizeMismatchPct(execAtoms: exec, precision: 4, typed: 'abc'), isNull);
      expect(LnTakeService.sizeMismatchPct(execAtoms: BigInt.zero, precision: 4, typed: '10'), isNull);
      expect(LnTakeService.needsSizeNote(execAtoms: exec, precision: 4, typed: ''), isFalse);
    });

    test('precision matters: the same typed string judged in the leg\'s OWN units', () {
      // 1234 sats at precision 8 = 0.00001234 BTC; typing exactly that is a 0% mismatch.
      expect(LnTakeService.sizeMismatchPct(execAtoms: BigInt.from(1234), precision: 8, typed: '0.00001234'),
          closeTo(0, 0.0001));
    });
  });

  group('slice pricing (priceSlice — the one authority, mirrors the Go settlement driver)', () {
    test('null / non-positive / at-or-above the offer -> WHOLE: the offer\'s legs VERBATIM, no rounding', () {
      final o = _offer(assetAtoms: 3, btcSats: 10);
      for (final req in <BigInt?>[null, BigInt.zero, -BigInt.one, BigInt.from(3), BigInt.from(999)]) {
        for (final side in const ['buy', 'sell']) {
          final s = LnTakeService.priceSlice(side: side, offer: o, requestedAtoms: req);
          expect(s.whole, isTrue, reason: 'req=$req side=$side');
          expect(s.assetAtoms, BigInt.from(3)); // min(req, offer) caps at the offer
          expect(s.quoteAtoms, BigInt.from(10)); // the offer's OWN counter leg, never re-derived
          expect(s.dust, isFalse);
        }
      }
    });

    test('min(typed, offer): a smaller request takes exactly that base slice', () {
      final s = LnTakeService.priceSlice(
          side: 'sell', offer: _offer(assetAtoms: 200000, btcSats: 1234), requestedAtoms: BigInt.from(50000));
      expect(s.whole, isFalse);
      expect(s.assetAtoms, BigInt.from(50000));
    });

    test('the edge where floor and ceil DIFFER: a BUY floors (taker gives BTC), a SELL ceils (taker receives)', () {
      final o = _offer(assetAtoms: 3, btcSats: 10); // 10*2/3 = 6.66…
      final buy = LnTakeService.priceSlice(side: 'buy', offer: o, requestedAtoms: BigInt.two);
      expect(buy.whole, isFalse);
      expect(buy.assetAtoms, BigInt.two);
      expect(buy.quoteAtoms, BigInt.from(6)); // FLOOR(10·2/3)
      final sell = LnTakeService.priceSlice(side: 'sell', offer: o, requestedAtoms: BigInt.two);
      expect(sell.quoteAtoms, BigInt.from(7)); // CEIL(10·2/3)
    });

    test('exact division: floor == ceil (no rounding artifact on either side)', () {
      final o = _offer(assetAtoms: 4, btcSats: 10); // 10*2/4 = 5 exactly
      for (final side in const ['buy', 'sell']) {
        expect(LnTakeService.priceSlice(side: side, offer: o, requestedAtoms: BigInt.two).quoteAtoms,
            BigInt.from(5));
      }
    });

    test('BigInt exactness beyond double precision (legs past 2^53)', () {
      final offerAsset = BigInt.parse('9007199254740993'); // 2^53 + 1: double math would corrupt this
      final offerQuote = BigInt.parse('9007199254740995');
      final req = BigInt.parse('9007199254740992');
      final o = LnOffer(offerId: 'o', makerPubkey: '02aa', assetAtoms: offerAsset, btcAtoms: offerQuote);
      final expectedFloor = (offerQuote * req) ~/ offerAsset;
      final buy = LnTakeService.priceSlice(side: 'buy', offer: o, requestedAtoms: req);
      expect(buy.assetAtoms, req);
      expect(buy.quoteAtoms, expectedFloor);
      // The division is inexact here, so the sell's CEIL is exactly one more.
      expect((offerQuote * req) % offerAsset, isNot(BigInt.zero));
      final sell = LnTakeService.priceSlice(side: 'sell', offer: o, requestedAtoms: req);
      expect(sell.quoteAtoms, expectedFloor + BigInt.one);
    });

    test('dust: a partial pricing the counter leg to ZERO refuses (buy floors to 0; a sell ceils to 1)', () {
      final o = _offer(assetAtoms: 1000, btcSats: 5);
      final buy = LnTakeService.priceSlice(side: 'buy', offer: o, requestedAtoms: BigInt.one);
      expect(buy.quoteAtoms, BigInt.zero);
      expect(buy.dust, isTrue); // the caller must refuse before anything persists or posts
      final sell = LnTakeService.priceSlice(side: 'sell', offer: o, requestedAtoms: BigInt.one);
      expect(sell.quoteAtoms, BigInt.one); // CEIL of a positive product never dusts
      expect(sell.dust, isFalse);
    });

    test('take() refuses a dust slice BEFORE persisting anything', () async {
      _FakeSecureStorage().install();
      await expectLater(
        LnTakeService.take(
          side: 'buy',
          asset: kAsset,
          offer: _offer(assetAtoms: 1000, btcSats: 5),
          requestedAtoms: BigInt.one,
          typedAmount: '1',
        ),
        throwsA(isA<Exception>()),
      );
      expect(await LnTakeStore.load(), isNull); // nothing persisted, nothing posted
    });
  });

  group('record round-trip', () {
    test('JSON round-trip preserves every field', () {
      final r = _rec(startedMs: 1234567);
      final back = LnTakeRecord.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(back.state, 'inflight');
      expect(back.side, 'sell');
      expect(back.asset, kAsset);
      expect(back.quoteAsset, isNull);
      expect(back.offerId, 'off-1');
      expect(back.makerPubkey, '02aa');
      expect(back.assetAtoms, BigInt.from(200000));
      expect(back.quoteAtoms, BigInt.from(1234));
      expect(back.takeAtoms, BigInt.from(200000));
      expect(back.startedMs, 1234567);
      expect(back.detail, 'd');
    });

    test('a legacy record without take_atoms decodes ZERO (= a whole lift, exactly what it was)', () {
      final j = _rec().toJson()..remove('take_atoms');
      expect(LnTakeRecord.fromJson(j).takeAtoms, BigInt.zero);
    });

    test('an unrecognised persisted state decodes as inflight (never silently resolved)', () {
      final j = _rec().toJson()..['state'] = 'from-the-future';
      expect(LnTakeRecord.fromJson(j).failed, isFalse);
    });

    test('store round-trip through the real secure-storage slot', () async {
      _FakeSecureStorage().install();
      expect(await LnTakeStore.load(), isNull);
      await LnTakeStore.save(_rec(startedMs: 42));
      final back = await LnTakeStore.load();
      expect(back, isNotNull);
      expect(back!.startedMs, 42);
      expect(back.assetAtoms, BigInt.from(200000));
      await LnTakeStore.clear();
      expect(await LnTakeStore.load(), isNull);
    });
  });

  group('stale resolution (restart)', () {
    test('a record younger than the 90s LSP timeout is left alone', () async {
      _FakeSecureStorage().install();
      await LnTakeStore.save(_rec());
      expect(await LnTakeService.resolveStale(), isNull);
      expect(await LnTakeStore.load(), isNotNull); // untouched
    });

    test('old record + a matching ln: receipt in the trail -> settled, record cleared', () async {
      _FakeSecureStorage().install();
      final started = DateTime.now().millisecondsSinceEpoch - kLnLspTimeoutMs - 1000;
      await LnTakeStore.save(_rec(startedMs: started));
      final tk = SeqAssets.labelFor(kAsset).ticker;
      await TradeReceipts.log(id: 'ln:deadbeef', title: 'Sold $tk for BTC (Lightning)', status: 'Settled');
      final v = await LnTakeService.resolveStale();
      expect(v, isNotNull);
      expect(v!.settled, isTrue);
      expect(await LnTakeStore.load(), isNull); // proven settled -> cleared
    });

    test('old record with NO receipt -> "did not settle" verdict; the record stays until dismissed', () async {
      _FakeSecureStorage().install();
      final started = DateTime.now().millisecondsSinceEpoch - kLnLspTimeoutMs - 1000;
      await LnTakeStore.save(_rec(startedMs: started));
      final v = await LnTakeService.resolveStale();
      expect(v, isNotNull);
      expect(v!.settled, isFalse);
      expect(await LnTakeStore.load(), isNotNull);
      await LnTakeService.dismiss((await LnTakeStore.load())!);
      expect(await LnTakeStore.load(), isNull);
    });

    test('a receipt from BEFORE the take never proves this take settled', () async {
      _FakeSecureStorage().install();
      final tk = SeqAssets.labelFor(kAsset).ticker;
      // The receipt predates the take by well over the 2s grace the resolver allows.
      await TradeReceipts.log(id: 'ln:old', title: 'Sold $tk for BTC (Lightning)', status: 'Settled');
      await Future<void>.delayed(const Duration(seconds: 3));
      final started = DateTime.now().millisecondsSinceEpoch;
      await LnTakeStore.save(_rec(startedMs: started));
      final v = await LnTakeService.resolveStale(nowMs: started + kLnLspTimeoutMs + 1000);
      expect(v, isNotNull);
      expect(v!.settled, isFalse);
    });

    test('a failed record surfaces the same honest banner', () async {
      _FakeSecureStorage().install();
      await LnTakeStore.save(_rec(state: 'failed'));
      final v = await LnTakeService.resolveStale();
      expect(v, isNotNull);
      expect(v!.settled, isFalse);
      expect(v.record.failed, isTrue);
    });
  });
}
