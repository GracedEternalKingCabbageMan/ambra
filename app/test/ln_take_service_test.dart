// Unit tests for the COMPOSER-NATIVE pure-LN take seam (ln_take_service.dart):
//
//   1. REVIEW SIZING — the offer-vs-typed mismatch math the Review sheet keys its loud note on
//      (mirror web reviewLn's 5% threshold): within 5% -> no note; beyond -> note; nothing typed /
//      unparsable -> no note (the review's amounts are already the whole truth).
//   2. RECORD ROUND-TRIP — the persisted single-slot record ('ambra.ln.active') preserves every field
//      through JSON and through the real secure-storage store; an unrecognised state decodes as
//      'inflight' (never silently resolved).
//   3. STALE RESOLUTION — a record younger than the LSP's 90s timeout is left alone (a live POST may
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
      startedMs: startedMs ?? DateTime.now().millisecondsSinceEpoch,
      detail: 'd',
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
      expect(back.startedMs, 1234567);
      expect(back.detail, 'd');
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
      await LnTakeService.dismiss();
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
