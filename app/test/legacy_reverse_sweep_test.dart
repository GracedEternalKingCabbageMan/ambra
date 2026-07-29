// The one-shot migration for the RETIRED RFQ reverse rail's orphaned record.
//
// This exists because an earlier version of that migration DESTROYED FUNDS. It
// warned via debugPrint and then deleted the key. But for a record in
// RStep.seqFunding or RStep.seqSubmitted the payload IS the recovery blob — it
// carries seqRedeemScript, seqFundTxid and seqLocktime, everything needed to drive
// the CLTV refund of a FUNDED Sequentia HTLC, and it exists nowhere else. Its only
// trace was a debugPrint, which on a release build reaches logcat at best. A user
// with locked funds would have lost their reclaim material silently.
//
// The claim that this was "covered on both paths" was also false: _legacyReverseSwept
// is a static per-process flag with no reset, so the body ran at most once per test
// process and no test asserted either the warning or the delete. Hence
// debugResetLegacyReverseSweep, used by every case below.
//
//   cd app && flutter test test/legacy_reverse_sweep_test.dart
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/subswap_service.dart';

const MethodChannel _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const String _legacyKey = 'ambra.xchain.reverse.active';
const String _orphanKey = 'ambra.xchain.reverse.orphaned';

class _FakeSecureStorage {
  final Map<String, String> data = {};
  bool failReads = false;
  bool failWrites = false;
  int deletes = 0;

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    switch (call.method) {
      case 'read':
        if (failReads) throw PlatformException(code: 'Locked', message: 'keystore unavailable');
        return data[args['key'] as String];
      case 'write':
        if (failWrites) throw PlatformException(code: 'Locked', message: 'keystore unavailable');
        data[args['key'] as String] = args['value'] as String;
        return null;
      case 'delete':
        deletes++;
        data.remove(args['key'] as String);
        return null;
      case 'containsKey':
        return data.containsKey(args['key'] as String);
      case 'readAll':
        return Map<String, String>.from(data);
      case 'deleteAll':
        data.clear();
        return null;
      default:
        return null;
    }
  }

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null));
  }
}

/// A record describing a FUNDED Sequentia HTLC — the case that must never be lost.
String _fundedReverseRecord() => jsonEncode({
      'step': 'seqFunding',
      'asset': 'aa11bb22',
      'seqAmount': '5000000',
      'btcAmount': '25000',
      'seqRedeemScript': 'a914deadbeefdeadbeefdeadbeefdeadbeefdeadbeef87',
      'seqFundTxid': 'f0'.padRight(64, '0'),
      'seqLocktime': 16740,
      'preimageHex': 'cc' * 32,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(SubswapStore.debugResetLegacyReverseSweep);

  test('a funded orphan is PRESERVED, never deleted', () async {
    final fake = _FakeSecureStorage()..install();
    final raw = _fundedReverseRecord();
    fake.data[_legacyKey] = raw;

    await SubswapStore.sweepLegacyReverseRecord();

    expect(fake.data[_orphanKey], raw,
        reason: 'the payload must survive verbatim — it is the only copy of the reclaim material');
    expect(fake.data.containsKey(_legacyKey), isFalse,
        reason: 'the dead slot is vacated, so the migration does not run forever');
  });

  test('the preserved record is SURFACED, not merely logged', () async {
    final fake = _FakeSecureStorage()..install();
    fake.data[_legacyKey] = _fundedReverseRecord();

    await SubswapStore.sweepLegacyReverseRecord();

    expect(await SubswapStore.hasOrphanedLegacyReverse(), isTrue,
        reason: 'the UI banner keys off this; a debugPrint is not user-visible on a release build');
    final digest = await SubswapStore.orphanedLegacyReverseDigest();
    expect(digest, isNotNull);
    // The fields a human needs to drive the refund by hand.
    expect(digest, contains('16740'), reason: 'the CLTV locktime must be recoverable');
    expect(digest, contains('a914deadbeef'), reason: 'the redeem script must be recoverable');
  });

  test('the digest never carries the swap secret', () async {
    final fake = _FakeSecureStorage()..install();
    fake.data[_legacyKey] = _fundedReverseRecord();

    await SubswapStore.sweepLegacyReverseRecord();

    final digest = await SubswapStore.orphanedLegacyReverseDigest();
    expect(digest, isNotNull);
    expect(digest!.contains('cc' * 32), isFalse,
        reason: 'device logs and support pastes must never carry a preimage');
  });

  test('nothing to sweep is a no-op: no orphan key is invented', () async {
    final fake = _FakeSecureStorage()..install();

    await SubswapStore.sweepLegacyReverseRecord();

    expect(fake.data.containsKey(_orphanKey), isFalse);
    expect(await SubswapStore.hasOrphanedLegacyReverse(), isFalse);
  });

  test('a locked keystore leaves the record untouched and RETRIES on the next cold start', () async {
    final fake = _FakeSecureStorage()..install();
    fake.data[_legacyKey] = _fundedReverseRecord();
    fake.failReads = true;

    await SubswapStore.sweepLegacyReverseRecord();
    expect(fake.data.containsKey(_legacyKey), isTrue, reason: 'an unreadable keystore is not a verdict');
    expect(fake.deletes, 0, reason: 'nothing may be deleted on a path that could not even read');

    // The flag must have been RESET, so the next cold start tries again. Without the
    // reset the sweep would be skipped forever after one transient failure.
    fake.failReads = false;
    await SubswapStore.sweepLegacyReverseRecord();
    expect(fake.data[_orphanKey], isNotNull, reason: 'the retry must actually run');
  });

  test('a failed WRITE never deletes the original', () async {
    final fake = _FakeSecureStorage()..install();
    fake.data[_legacyKey] = _fundedReverseRecord();
    fake.failWrites = true;

    await SubswapStore.sweepLegacyReverseRecord();

    // Write-then-delete ordering: if the write cannot land, the original must still
    // be there. The reverse order would lose the record on exactly this failure.
    expect(fake.data.containsKey(_legacyKey), isTrue);
    expect(fake.deletes, 0);
  });

  test('discarding is explicit and only removes the preserved copy', () async {
    final fake = _FakeSecureStorage()..install();
    fake.data[_legacyKey] = _fundedReverseRecord();
    await SubswapStore.sweepLegacyReverseRecord();
    expect(await SubswapStore.hasOrphanedLegacyReverse(), isTrue);

    await SubswapStore.discardOrphanedLegacyReverse();

    expect(await SubswapStore.hasOrphanedLegacyReverse(), isFalse,
        reason: 'the user asked for this one, having been shown the digest first');
  });
}
