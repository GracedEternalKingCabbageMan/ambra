// Unit tests for the SUBMARINE store + guard machinery (subswap_service.dart) — the fund-safety spine of the
// rail-crossing taker. These cover the two fund-loss edge holes closed in round 6 plus the surrounding guard:
//
//   1. UNKNOWN STATE -> NON-TERMINAL: an unrecognised persisted 'state' decodes to SubState.unknown (never a
//      terminal state), so a live record NEVER reads as done + gets clobbered. load() routes it to the
//      corrupt/recovery affordance (blocks + surfaces a guarded clear), never a silent drop.
//   2. broadcastAttempted — the INTENT-BEFORE-BROADCAST wedge fix (round 7). The intent is now set by the
//      authorizeBuildBroadcast onAboutToBroadcast hook, which fires ONLY after auth+build+sign succeed and
//      immediately before the on-chain broadcast: (2a) exercises the REAL authorizeBuildBroadcast and proves a
//      pre-broadcast throw (auth-cancel / build error) leaves the hook UNFIRED; (2b) round-trips the record and
//      asserts the D0 pre-commitment precondition (seqFundTxid empty AND !broadcastAttempted) so a never-funded
//      SELL stays clearable (rail not wedged) while a hook-fired / belt-and-suspenders-reset record behaves right.
//   3. The store guard: load() transient-read fail-safe vs durable-decode corrupt split, primeInFlight /
//      hasInFlight, primeErrored self-heal, save/clear keeping the synchronous guard current, and the
//      SubswapService._driving one-at-a-time guard.
//
//   cd app && flutter test test/subswap_store_test.dart
//
// The store reads/writes flutter_secure_storage's `const FlutterSecureStorage()`. We back it with an in-memory
// fake over the plugin's own MethodChannel (no native plugin, full control incl. a throwing READ) so the
// transient-vs-durable split is exercised for real.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ambra/src/data/subswap_service.dart';
import 'package:ambra/src/data/tx_flow.dart';

const MethodChannel _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const MethodChannel _authChannel = MethodChannel('plugins.flutter.io/local_auth');
const String _storeKey = 'ambra.subswap.active';
const String _mnemonicKey = 'ambra.mnemonic';

/// Mock the local_auth plugin channel so [WalletRepository.requirePaymentAuth] resolves deterministically:
/// [deviceSupported]=false takes the bare-emulator allow-through (true); otherwise the result is [authenticate].
/// Registered per-test via addTearDown, so it never leaks. Lets the [authorizeBuildBroadcast] ordering tests
/// drive the REAL auth->build->sign->broadcast path up to (but not through) the rust-FFI sign/broadcast.
void _installLocalAuth({required bool deviceSupported, required bool authenticate}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_authChannel, (call) async {
    switch (call.method) {
      case 'isDeviceSupported':
        return deviceSupported;
      case 'authenticate':
        return authenticate;
      case 'getAvailableBiometrics':
        return <String>[];
      case 'stopAuthentication':
        return true;
      default:
        return null;
    }
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_authChannel, null));
}

/// An in-memory flutter_secure_storage backend over the plugin MethodChannel. [failReads] makes every `read`
/// throw a PlatformException (a transient locked/busy keystore), so load()'s transient-vs-durable split is real.
class _FakeSecureStorage {
  final Map<String, String> data = {};
  bool failReads = false;
  int reads = 0;
  int writes = 0;
  int deletes = 0;

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    switch (call.method) {
      case 'read':
        reads++;
        if (failReads) {
          throw PlatformException(code: 'Locked', message: 'the keystore is transiently unavailable');
        }
        return data[args['key'] as String];
      case 'write':
        writes++;
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, _handle);
  }

  static void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  }
}

SubswapRecord _rec({
  bool buy = false,
  SubState state = SubState.funding,
  String asset = 'aa11bb22',
  BigInt? assetAtoms,
  BigInt? btcSats,
  String offerId = 'offer-1',
  String hashHex = '',
  String preimageHex = '',
  String legTxid = '',
  String legP2shAddr = '',
  int legVout = -1,
  int seqLocktime = 0,
  bool broadcastAttempted = false,
  int broadcastAt = 0,
  int broadcastSeqHeight = 0,
  String seqFundTxid = '',
}) =>
    SubswapRecord(
      buy: buy,
      state: state,
      asset: asset,
      assetAtoms: assetAtoms ?? BigInt.from(1000),
      btcSats: btcSats ?? BigInt.from(50000),
      offerId: offerId,
      makerPubkey: '02deadbeef',
      hashHex: hashHex,
      preimageHex: preimageHex,
      legTxid: legTxid,
      legP2shAddr: legP2shAddr,
      legVout: legVout,
      seqLocktime: seqLocktime,
      broadcastAttempted: broadcastAttempted,
      broadcastAt: broadcastAt,
      broadcastSeqHeight: broadcastSeqHeight,
      seqFundTxid: seqFundTxid,
    );

/// A ms-since-epoch stamp [d] in the past — a plausible past broadcast-time stamp for [SubswapRecord.broadcastAt].
/// Round 12: broadcastAt is DISPLAY ONLY and no longer gates the abandon, so this just populates the field
/// realistically; the abandon decision is fully clock-free and does not read it.
int _agoMs(Duration d) => DateTime.now().subtract(d).millisecondsSinceEpoch;

/// The terminal set per the state machine (BUY/SELL). Everything else — including [SubState.unknown] — is
/// deliberately non-terminal so the guard stays closed.
const Set<SubState> _terminalStates = {SubState.settled, SubState.failed, SubState.refunded};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage fake;

  setUp(() async {
    fake = _FakeSecureStorage()..install();
    await SubswapStore.clear(); // reset the synchronous guard flags + empty the store to a known baseline
    fake.reads = 0;
    fake.writes = 0;
    fake.deletes = 0;
  });

  tearDown(() {
    SubswapService.debugDriving = false; // never leak the forced guard into another test
    SubswapService.debugRescanForAbandon = null; // never leak the round-13 re-scan seam into another test
    _FakeSecureStorage.uninstall();
  });

  // -- (1) fromJson round-trip incl. the unknown-state fund-loss ------------------------------------------

  group('SubswapRecord.fromJson', () {
    test('round-trips every persisted field through toJson/jsonEncode', () {
      final rec = _rec(
        buy: true,
        state: SubState.claiming,
        asset: 'ff00ff00',
        assetAtoms: BigInt.parse('123456789012345'),
        btcSats: BigInt.from(987654),
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
        legTxid: 'c' * 64,
        legVout: 3,
        seqLocktime: 44321,
        broadcastAttempted: true,
        broadcastAt: 1699999999999,
        broadcastSeqHeight: 44290,
        seqFundTxid: 'd' * 64,
      );
      final back = SubswapRecord.fromJson(jsonDecode(jsonEncode(rec.toJson())) as Map<String, dynamic>);
      expect(back.buy, true);
      expect(back.state, SubState.claiming);
      expect(back.asset, 'ff00ff00');
      expect(back.assetAtoms, BigInt.parse('123456789012345'));
      expect(back.btcSats, BigInt.from(987654));
      expect(back.hashHex, 'a' * 64);
      expect(back.preimageHex, 'b' * 64);
      expect(back.legTxid, 'c' * 64);
      expect(back.legVout, 3);
      expect(back.seqLocktime, 44321);
      expect(back.broadcastAttempted, true);
      expect(back.broadcastAt, 1699999999999);
      expect(back.broadcastSeqHeight, 44290, reason: 'round 11: the clock-free broadcast-height stamp round-trips');
      expect(back.seqFundTxid, 'd' * 64);
    });

    test('an UNRECOGNISED state decodes to SubState.unknown, which is NON-TERMINAL (the fund-loss)', () {
      // A record written by a future build / a foreign writer carries a state string this build cannot map.
      final foreign = {
        'buy': false,
        'state': 'some_future_state',
        'asset': 'aa',
        'assetAtoms': '5000',
        'btcSats': '9000',
        'offerId': 'o',
        'makerPubkey': 'm',
        'preimageHex': 'e' * 64, // a live, committed swap
        'legTxid': 'f' * 64,
      };
      final rec = SubswapRecord.fromJson(foreign);
      expect(rec.state, SubState.unknown, reason: 'must NOT fall back to SubState.failed');
      expect(rec.terminal, isFalse, reason: 'unknown is non-terminal so the in-flight guard stays CLOSED');
    });

    test('broadcastAttempted/broadcastAt/broadcastSeqHeight default to false/0/0 when absent (older / pre-r11 record)', () {
      final old = {
        'buy': false,
        'state': 'funding',
        'asset': 'aa',
        'assetAtoms': '5',
        'btcSats': '7',
        'offerId': 'o',
        'makerPubkey': 'm',
      };
      expect(SubswapRecord.fromJson(old).broadcastAttempted, isFalse);
      expect(SubswapRecord.fromJson(old).broadcastAt, 0);
      // Round 11: a pre-r11 record has no height stamp -> 0, which fails the height proof closed (not abandonable).
      expect(SubswapRecord.fromJson(old).broadcastSeqHeight, 0);
    });
  });

  // -- (2a) authorizeBuildBroadcast: the pre-broadcast intent hook fires ONLY after auth+build+sign ------
  //
  // The wedge fix (round 7): broadcastAttempted must be set by onAboutToBroadcast (after auth+build+sign,
  // immediately before the on-chain broadcast), NEVER before the biometric. A pre-broadcast throw (auth-cancel /
  // insufficient funds / sign error) must leave the hook UNFIRED so the never-funded SELL stays D0-clearable and
  // the rail is not falsely wedged 'swap in progress'. These drive the REAL authorizeBuildBroadcast; the
  // rust-FFI sign/broadcast is never reached because auth fails or the build throws first.
  group('authorizeBuildBroadcast pre-broadcast intent ordering (the wedge fix)', () {
    test('an auth CANCEL throws BEFORE building and BEFORE the pre-broadcast hook', () async {
      _installLocalAuth(deviceSupported: true, authenticate: false); // requirePaymentAuth -> false (fail closed)
      fake.data[_mnemonicKey] = 'abandon abandon abandon';
      var buildCalled = false;
      var hookFired = false;
      await expectLater(
        authorizeBuildBroadcast(
          (m) async {
            buildCalled = true;
            return 'pset';
          },
          onAboutToBroadcast: () async => hookFired = true,
        ),
        throwsA(anything),
      );
      expect(buildCalled, isFalse, reason: 'auth fails closed before any build');
      expect(hookFired, isFalse, reason: 'NO broadcast intent is set on an auth-cancel (nothing funded -> stays clearable)');
    });

    test('a build / insufficient-funds error throws AFTER auth but BEFORE the pre-broadcast hook', () async {
      _installLocalAuth(deviceSupported: true, authenticate: true); // requirePaymentAuth -> true
      fake.data[_mnemonicKey] = 'abandon abandon abandon';
      var buildCalled = false;
      var hookFired = false;
      await expectLater(
        authorizeBuildBroadcast(
          (m) async {
            buildCalled = true;
            throw Exception('insufficient funds');
          },
          onAboutToBroadcast: () async => hookFired = true,
        ),
        throwsA(predicate((e) => e.toString().contains('insufficient funds'))),
      );
      expect(buildCalled, isTrue, reason: 'auth passed, so the build ran');
      expect(hookFired, isFalse, reason: 'the pre-broadcast intent must NOT be set on a pre-broadcast (build) throw');
    });
  });

  // -- (2b) SELL broadcastAttempted D0 pre-commitment vs resumable (round-tripped through the real store) --
  //
  // The D0 SELL-resume drops a record as pre-commitment ONLY when the asset was never funded:
  // seqFundTxid empty AND !broadcastAttempted (subswap_service.dart (D0)). The full resume drive needs the
  // wallet/LSP/network; these assert the store-side invariant the fix relies on, via the real save/load.
  group('SELL broadcastAttempted — D0 pre-commitment vs resumable (the wedge fix)', () {
    bool d0PreCommitment(SubswapRecord r) => r.seqFundTxid.isEmpty && !r.broadcastAttempted;

    test('a SELL that threw pre-broadcast (hook never fired) persists broadcastAttempted=false and stays D0-CLEARABLE', () async {
      // Mirror _runSubmarineSell after a pre-broadcast throw: state funding, P/H persisted, NO fund txid,
      // broadcastAttempted left false — the rail must NOT be wedged (the record is droppable as pre-commitment).
      final rec = _rec(state: SubState.funding, hashHex: 'a' * 64, preimageHex: 'b' * 64, broadcastAttempted: false);
      await SubswapStore.save(rec);
      final back = await SubswapStore.load();
      expect(back!.broadcastAttempted, isFalse);
      expect(back.seqFundTxid, isEmpty);
      expect(d0PreCommitment(back), isTrue, reason: 'never funded -> the D0 pre-commitment drop is REACHABLE (rail not wedged)');
    });

    test('once the pre-broadcast hook fires (broadcastAttempted=true, txid not yet persisted) the SELL is RESUMABLE, never D0-cleared', () async {
      // The onAboutToBroadcast hook effect: broadcastAttempted=true with seqFundTxid still empty (a crash between
      // the broadcast and the post-broadcast txid save) must be treated as "a broadcast may have gone out".
      final rec = _rec(state: SubState.funding, hashHex: 'a' * 64, preimageHex: 'b' * 64, broadcastAttempted: true);
      await SubswapStore.save(rec);
      final back = await SubswapStore.load();
      expect(back!.broadcastAttempted, isTrue);
      expect(back.seqFundTxid, isEmpty);
      expect(d0PreCommitment(back), isFalse, reason: 'a broadcast may have gone out -> NEVER dropped as pre-commitment');
      expect(back.terminal, isFalse);
      expect(SubswapStore.hasInFlight, isTrue, reason: 'a funding record holds the guard closed');
    });

    test('the belt-and-suspenders reset (flip broadcastAttempted back to false on a pre-broadcast throw) restores D0 clearability', () async {
      // Had the intent set true, then a pre-broadcast throw forced it back to false + saved (the catch in _runSubmarineSell).
      final rec = _rec(state: SubState.funding, hashHex: 'a' * 64, preimageHex: 'b' * 64, broadcastAttempted: true);
      await SubswapStore.save(rec);
      rec.broadcastAttempted = false; // belt-and-suspenders reset before rethrow
      await SubswapStore.save(rec);
      final back = await SubswapStore.load();
      expect(back!.broadcastAttempted, isFalse);
      expect(d0PreCommitment(back), isTrue, reason: 'reset restores the pre-commitment drop (never-funded record is clearable again)');
    });
  });

  // -- (2) terminal getter for each state ----------------------------------------------------------------

  test('terminal getter matches the terminal set for EVERY state (unknown => false)', () {
    for (final s in SubState.values) {
      expect(_rec(state: s).terminal, _terminalStates.contains(s), reason: 'state $s');
    }
    expect(_rec(state: SubState.unknown).terminal, isFalse);
  });

  // -- (3) load() transient-read (fail-safe) vs durable-decode (corrupt) split ---------------------------

  group('SubswapStore.load transient vs durable split', () {
    test('a definitive empty store sets NOT-in-flight (the only path that opens the guard)', () async {
      final rec = await SubswapStore.load();
      expect(rec, isNull);
      expect(SubswapStore.hasInFlight, isFalse);
      expect(SubswapStore.primed, isTrue);
      expect(SubswapStore.primeErrored, isFalse);
      expect(SubswapStore.corrupt, isFalse);
    });

    test('a valid NON-terminal record loads and holds the guard closed', () async {
      await SubswapStore.save(_rec(state: SubState.settling, legTxid: 'a' * 64));
      final rec = await SubswapStore.load();
      expect(rec, isNotNull);
      expect(rec!.state, SubState.settling);
      expect(SubswapStore.hasInFlight, isTrue);
      expect(SubswapStore.corrupt, isFalse);
    });

    test('a valid TERMINAL record loads and opens the guard', () async {
      fake.data[_storeKey] = jsonEncode(_rec(state: SubState.settled).toJson());
      final rec = await SubswapStore.load();
      expect(rec, isNotNull);
      expect(rec!.state, SubState.settled);
      expect(SubswapStore.hasInFlight, isFalse);
    });

    test('a TRANSIENT read error fails SAFE (in-flight) + marks primeErrored, NOT corrupt', () async {
      fake.data[_storeKey] = jsonEncode(_rec(state: SubState.funding).toJson());
      fake.failReads = true;
      await expectLater(SubswapStore.load(), throwsA(isA<PlatformException>()));
      expect(SubswapStore.hasInFlight, isTrue, reason: 'block rather than clobber a possibly-live record');
      expect(SubswapStore.primed, isTrue);
      expect(SubswapStore.primeErrored, isTrue, reason: 'healable at the next choke point');
      expect(SubswapStore.corrupt, isFalse, reason: 'a retry may succeed — not durable corruption');
    });

    test('a DURABLE undecodable value fails SAFE + flags corrupt (never self-heals)', () async {
      fake.data[_storeKey] = 'this is not json {{{';
      await expectLater(SubswapStore.load(), throwsA(isA<SubswapCorruptRecordException>()));
      expect(SubswapStore.hasInFlight, isTrue);
      expect(SubswapStore.corrupt, isTrue);
      expect(SubswapStore.primeErrored, isTrue);
    });

    test('an UNKNOWN-STATE record is BLOCKED + routed to recovery, NEVER cleared (Task 1 fund-loss)', () async {
      // A decodable record whose state this build does not recognise: it may be a LIVE funded swap.
      fake.data[_storeKey] = jsonEncode({
        'buy': false,
        'state': 'a_state_from_a_newer_build',
        'asset': 'aa',
        'assetAtoms': '5000',
        'btcSats': '9000',
        'offerId': 'o',
        'makerPubkey': 'm',
        'preimageHex': 'e' * 64,
        'legTxid': 'f' * 64,
      });
      await expectLater(SubswapStore.load(), throwsA(isA<SubswapCorruptRecordException>()));
      expect(SubswapStore.hasInFlight, isTrue, reason: 'guard stays closed — never start a second swap over it');
      expect(SubswapStore.corrupt, isTrue, reason: 'surfaced via the guarded RECOVER affordance');
      // Fund-safety: the raw record is still on disk (never dropped by the failing load).
      expect(fake.data.containsKey(_storeKey), isTrue);
      expect(fake.deletes, 0);
    });
  });

  // -- (3) primeInFlight / hasInFlight -------------------------------------------------------------------

  group('SubswapStore.primeInFlight', () {
    test('primes hasInFlight=true from a live record, never throwing into startup', () async {
      await SubswapStore.save(_rec(state: SubState.paying, legTxid: 'a' * 64));
      // reset the volatile guard as a cold start would see it, then prime from disk
      SubswapStore.markInFlight(false);
      await SubswapStore.primeInFlight();
      expect(SubswapStore.hasInFlight, isTrue);
      expect(SubswapStore.primed, isTrue);
    });

    test('primes hasInFlight=false from an empty store', () async {
      SubswapStore.markInFlight(true);
      await SubswapStore.primeInFlight();
      expect(SubswapStore.hasInFlight, isFalse);
    });

    test('a transient read at cold start fails SAFE (in-flight) and is SWALLOWED (no throw)', () async {
      fake.data[_storeKey] = jsonEncode(_rec(state: SubState.funding).toJson());
      fake.failReads = true;
      await SubswapStore.primeInFlight(); // must not throw
      expect(SubswapStore.hasInFlight, isTrue);
      expect(SubswapStore.primeErrored, isTrue);
    });
  });

  // -- (3) primeErrored self-heal ------------------------------------------------------------------------

  test('primeErrored HEALS on the next successful load (idle wallet becomes startable again)', () async {
    // A transient read error at cold start leaves the guard closed + errored (would block an idle wallet).
    fake.failReads = true;
    await expectLater(SubswapStore.load(), throwsA(isA<PlatformException>()));
    expect(SubswapStore.primeErrored, isTrue);
    expect(SubswapStore.hasInFlight, isTrue);
    // The keystore recovers and the store is genuinely empty: a now-succeeding load HEALS the guard.
    fake.failReads = false;
    final rec = await SubswapStore.load();
    expect(rec, isNull);
    expect(SubswapStore.primeErrored, isFalse, reason: 'a definitive success clears the errored flag');
    expect(SubswapStore.hasInFlight, isFalse, reason: 'idle wallet is startable again');
  });

  // -- (3) save / clear keep the synchronous guard current -----------------------------------------------

  group('save/clear keep the guard current', () {
    test('save(non-terminal) closes the guard + clears corrupt/errored', () async {
      await SubswapStore.save(_rec(state: SubState.funding, broadcastAttempted: true));
      expect(SubswapStore.hasInFlight, isTrue);
      expect(SubswapStore.corrupt, isFalse);
      expect(SubswapStore.primeErrored, isFalse);
      expect(fake.data.containsKey(_storeKey), isTrue);
    });

    test('save(terminal) opens the guard', () async {
      await SubswapStore.save(_rec(state: SubState.refunded));
      expect(SubswapStore.hasInFlight, isFalse);
    });

    test('clear opens the guard, empties the store, and resets corrupt', () async {
      fake.data[_storeKey] = 'garbage';
      await expectLater(SubswapStore.load(), throwsA(isA<SubswapCorruptRecordException>()));
      expect(SubswapStore.corrupt, isTrue);
      await SubswapStore.clear();
      expect(SubswapStore.hasInFlight, isFalse);
      expect(SubswapStore.corrupt, isFalse);
      expect(fake.data.containsKey(_storeKey), isFalse);
    });
  });

  // -- (3) the _driving one-at-a-time guard --------------------------------------------------------------

  group('SubswapService._driving one-at-a-time guard', () {
    test('runReverseBuy / runSubmarineSell throw while a drive is in flight', () async {
      SubswapService.debugDriving = true;
      expect(SubswapService.driving, isTrue);
      await expectLater(
        SubswapService.runReverseBuy(_rec(buy: true, state: SubState.starting)),
        throwsA(predicate((e) => e.toString().contains('already being driven'))),
      );
      await expectLater(
        SubswapService.runSubmarineSell(_rec(state: SubState.starting)),
        throwsA(predicate((e) => e.toString().contains('already being driven'))),
      );
      SubswapService.debugDriving = false;
    });

    test('resume() short-circuits while driving and NEVER touches (clears) the record', () async {
      // A pre-commitment record that a real resume WOULD drop — the guard must protect it from a concurrent drive.
      fake.data[_storeKey] = jsonEncode(_rec(state: SubState.starting).toJson());
      SubswapService.debugDriving = true;
      await SubswapService.resume(); // returns immediately; no storage access
      expect(fake.data.containsKey(_storeKey), isTrue, reason: 'the concurrent drive must not clear it');
      expect(fake.reads, 0, reason: 'the guard short-circuits before any load');
      SubswapService.debugDriving = false;
    });
  });

  // -- (4) ROUND 8/9/10/11/12/13: the manual FUND-SAFE, FULLY CLOCK-FREE ABANDON escape for a stuck SELL record --
  //
  // The liveness residual: a SELL that reached the broadcast INTENT (broadcastAttempted=true) but never landed a
  // funding tx (a hard-kill in the ms gap before finalizeAndBroadcast, or a definitive broadcast rejection) can
  // never be D0-auto-cleared (that path needs broadcastAttempted==false) and, being non-terminal + non-corrupt,
  // has no other escape -> the rail wedges 'in progress' forever. The manual escape clears the record ONLY when
  // ALL gates hold: NOT-DRIVING (no resume advancing it), FRESH RELOAD + SEQ-FUND-TXID GUARD (the on-disk record,
  // same swap, still an eligible 'funding' record with NO recorded seqFundTxid — a concurrent resume that found
  // OR recorded the funding WINS), IDENTITY (same offer + HTLC address), an empty PRE-DIALOG scan (offer evidence),
  // AND — round 13 — a RE-SCAN BEFORE CLEAR: the authoritative scan is RE-RUN on the fresh record immediately
  // before the clear, so the stale pre-dialog result is never trusted at clear time (a funding that (re)confirmed
  // while the user lingered on the warning is caught). That scan's ONLY staleness/reorg margin is the round-11
  // CLOCK-FREE height proof: an empty /utxo list is EMPTY only when the backend's tip HEIGHT is >=
  // broadcastSeqHeight + kAbandonMinConfDepth (~240 blocks ≈ 2h) — a stalled-but-serving backend's false [] is
  // UNREADABLE; heights are monotonic so device-clock skew (a slow/fast clock, or a forward jump) can never defeat
  // it. ROUND 12 removed the wall-clock AGE GATE (broadcastAgedForAbandon / kAbandonMinBroadcastAge) entirely, so
  // NO DateTime.now() sits on the abandon path; broadcastAt persists for display only. A funded/unreadable scan
  // (pre-dialog OR re-scan), a recorded seqFundTxid, an advanced record, a different swap in the slot, or an
  // in-flight drive all stay resumable (fund-safe). These cover the pure classifier + the clock-free height proof
  // + eligibility, the clock-INDEPENDENCE of the decision, and the safe-by-construction clear gate (fresh reload,
  // seqFundTxid guard, not-driving, identity, empty pre-scan, re-scan-before-clear) via the real store. The re-scan
  // is driven through the [SubswapService.debugRescanForAbandon] test seam (production runs the real esplora scan).
  group('round 8-13 — manual ABANDON escape (fully clock-free, re-scan-before-clear, safe-by-construction clear of an unfunded SELL funding record)', () {
    test('classifyHtlcScan maps null->unreadable, [utxo]->funded, and []->empty ONLY when the tip HEIGHT proves it', () {
      // A read error is unreadable regardless of the tip-height proof.
      expect(SubswapService.classifyHtlcScan(null), HtlcScanResult.unreadable, reason: 'a read error is NOT empty');
      expect(SubswapService.classifyHtlcScan(null, tipProvesEmpty: true), HtlcScanResult.unreadable);
      // An output at the HTLC P2SH is funded regardless of the tip-height proof.
      final funded = <dynamic>[
        {'txid': 'a' * 64, 'vout': 0, 'value': 1000}
      ];
      expect(SubswapService.classifyHtlcScan(funded), HtlcScanResult.funded, reason: 'an output at the HTLC P2SH means funded');
      expect(SubswapService.classifyHtlcScan(funded, tipProvesEmpty: false), HtlcScanResult.funded);
      // ROUND 11 TIP-HEIGHT PROOF: an empty list is DEFINITIVELY EMPTY only when the backend's tip HEIGHT proves it
      // is past the funding window; against an unproven tip an empty list is UNREADABLE (a stalled backend's false []).
      expect(SubswapService.classifyHtlcScan(const <dynamic>[], tipProvesEmpty: true), HtlcScanResult.empty,
          reason: 'height-proven tip + esplora /utxo (covers mempool) -> [] is definitive');
      expect(SubswapService.classifyHtlcScan(const <dynamic>[], tipProvesEmpty: false), HtlcScanResult.unreadable,
          reason: 'a not-advanced (stalled) backend can return a false empty on a funded HTLC -> UNREADABLE, never EMPTY');
      // Default tipProvesEmpty is false — an empty list is UNREADABLE unless the height proof is explicitly satisfied.
      expect(SubswapService.classifyHtlcScan(const <dynamic>[]), HtlcScanResult.unreadable,
          reason: 'fail closed: an empty list is not trusted without a height proof');
    });

    test('tipHeightProvesEmptyScan (round 11, CLOCK-FREE): trusts an empty scan ONLY when tip >= broadcastHeight + depth', () {
      const depth = SubswapService.kAbandonMinConfDepth;
      const bh = 44000;
      // Tip well past broadcastHeight + depth -> the empty scan can be trusted.
      expect(SubswapService.tipHeightProvesEmptyScan(tipHeight: bh + depth + 5, broadcastSeqHeight: bh), isTrue,
          reason: 'the backend advanced well past the funding-confirmation window');
      // Tip EXACTLY at broadcastHeight + depth -> boundary is inclusive (trusted).
      expect(SubswapService.tipHeightProvesEmptyScan(tipHeight: bh + depth, broadcastSeqHeight: bh), isTrue);
      // Tip just SHORT of the window -> UNREADABLE (fail closed): a funding could still be within the unburied window.
      expect(SubswapService.tipHeightProvesEmptyScan(tipHeight: bh + depth - 1, broadcastSeqHeight: bh), isFalse,
          reason: 'the backend has not advanced past the funding window -> not trustable');
      // A backend whose tip is AT / BELOW the broadcast height (a frozen/stalled index) -> fail closed.
      expect(SubswapService.tipHeightProvesEmptyScan(tipHeight: bh, broadcastSeqHeight: bh), isFalse);
      expect(SubswapService.tipHeightProvesEmptyScan(tipHeight: bh - 100, broadcastSeqHeight: bh), isFalse,
          reason: 'a stalled backend behind the broadcast height can never certify an empty scan');
      // ABSENT/zero broadcast height (a pre-r11 record, or an unreadable tip at broadcast time) FAILS CLOSED even
      // against an arbitrarily high current tip — there is nothing to prove burial against.
      expect(SubswapService.tipHeightProvesEmptyScan(tipHeight: 999999, broadcastSeqHeight: 0), isFalse,
          reason: 'no broadcast-height stamp -> never abandonable');
      // An UNREADABLE current tip (-1 from _seqTipHeight on a read error) FAILS CLOSED.
      expect(SubswapService.tipHeightProvesEmptyScan(tipHeight: -1, broadcastSeqHeight: bh), isFalse,
          reason: 'an unreadable current tip cannot certify an empty scan');
    });

    test('tipHeightProvesEmptyScan is CLOCK-FREE: the decision does not depend on any wall clock / device time', () {
      // The height proof takes NO DateTime. The same inputs give the same verdict irrespective of a slow/fast device
      // clock — the exact defect round 11 fixes (a slow device clock made a stale tip read as fresh under the old
      // block-TIME path). Heights are monotonic + wall-clock-independent; there is no clock input to skew.
      const depth = SubswapService.kAbandonMinConfDepth;
      const bh = 50000;
      // A tip below the window is NOT trusted no matter what the device clock reads (there is no clock parameter).
      expect(SubswapService.tipHeightProvesEmptyScan(tipHeight: bh + depth - 1, broadcastSeqHeight: bh), isFalse);
      // A tip past the window IS trusted regardless of any clock — the same verdict every call.
      expect(SubswapService.tipHeightProvesEmptyScan(tipHeight: bh + depth, broadcastSeqHeight: bh), isTrue);
      expect(SubswapService.tipHeightProvesEmptyScan(tipHeight: bh + depth, broadcastSeqHeight: bh), isTrue);
    });

    test('canAbandonFunding: only a SELL in funding with an empty legTxid AND empty seqFundTxid is a candidate', () {
      expect(SubswapService.canAbandonFunding(_rec(state: SubState.funding, legTxid: '')), isTrue);
      // A funded/settling SELL (legTxid set) must NEVER be abandonable — its asset is on-chain.
      expect(SubswapService.canAbandonFunding(_rec(state: SubState.funding, legTxid: 'a' * 64)), isFalse);
      expect(SubswapService.canAbandonFunding(_rec(state: SubState.settling, legTxid: 'a' * 64)), isFalse);
      // ROUND 10 SEQ-FUND-TXID GUARD: a persisted seqFundTxid is DIRECT proof the funding tx was recorded — the
      // record is FUNDED and must NEVER be abandonable, even in 'funding' with an empty legTxid and any scan.
      expect(SubswapService.canAbandonFunding(_rec(state: SubState.funding, legTxid: '', seqFundTxid: 'd' * 64)), isFalse,
          reason: 'a recorded fund txid is direct proof of funding — never abandonable regardless of the scan');
      // A BUY is never in the SELL 'funding' phase; a terminal record is never a candidate.
      expect(SubswapService.canAbandonFunding(_rec(buy: true, state: SubState.funding)), isFalse);
      expect(SubswapService.canAbandonFunding(_rec(state: SubState.settled)), isFalse);
    });

    test('a not-driving, not-advanced SELL funding record with a (height-proven) empty scan IS abandonable and CLEARS (rail freed)', () async {
      // The exact wedge: broadcast intent set, nothing funded, an authoritative empty scan (the scan's own
      // clock-free height proof is exercised in scanHtlcForAbandon; here we pass the already-classified empty) -> clear.
      // Round 13: the clear gate RE-SCANS the fresh record before clearing (the pre-dialog scan is not trusted at
      // clear time). Drive that re-scan to STILL-EMPTY via the seam so the fund-safe clear proceeds.
      SubswapService.debugRescanForAbandon = (_) async => HtlcScanResult.empty;
      final rec = _rec(
        state: SubState.funding,
        legTxid: '',
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)), // display-only stamp; NOT a gate (round 12)
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
      );
      await SubswapStore.save(rec);
      expect(SubswapStore.hasInFlight, isTrue, reason: 'the funding record holds the guard closed (rail wedged)');

      final cleared = await SubswapService.abandonUnfundedSell(rec, HtlcScanResult.empty);
      expect(cleared, isTrue, reason: 'empty pre-scan + fresh-reload-unchanged + not-driving + identity + STILL-empty re-scan -> the fund-safe clear proceeds');
      expect(fake.data.containsKey(_storeKey), isFalse, reason: 'the never-funded record is dropped');
      expect(SubswapStore.hasInFlight, isFalse, reason: 'the guard resets — the rail is freed');
      expect(SubswapService.driving, isFalse, reason: 'the one-at-a-time guard is released after the decision');
      expect(fake.deletes, 1);
    });

    test('a record that becomes FUNDED between the pre-dialog scan and the clear is NOT cleared (round 13 RE-SCAN BEFORE CLEAR)', () async {
      // The exact hole this closes: the pre-dialog scan read EMPTY and the user was shown the warning, but while
      // they lingered on it a (re)broadcast funding tx confirmed. The pre-dialog scan result must NOT be trusted at
      // clear time — the clear gate RE-RUNS the authoritative scan on the FRESH record and FAILS CLOSED because it
      // now sees the funding. All the earlier gates pass (not-driving, fresh reload unchanged + still eligible,
      // identity, empty pre-scan); only the re-scan-before-clear catches it.
      SubswapService.debugRescanForAbandon = (_) async => HtlcScanResult.funded; // the funding landed during the dialog
      final rec = _rec(
        state: SubState.funding,
        legTxid: '',
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
      );
      await SubswapStore.save(rec);

      final cleared = await SubswapService.abandonUnfundedSell(rec, HtlcScanResult.empty); // pre-dialog scan was empty
      expect(cleared, isFalse, reason: 're-scan-before-clear now finds the funding — the stale empty pre-scan is NOT trusted');
      expect(fake.data.containsKey(_storeKey), isTrue, reason: 'the now-funded record is preserved (resumable)');
      expect(SubswapStore.hasInFlight, isTrue, reason: 'the guard stays closed — the swap can still settle/refund');
      expect(fake.deletes, 0, reason: 'nothing was cleared');
      expect(SubswapService.driving, isFalse, reason: 'the one-at-a-time guard is released after refusing');
    });

    test('a re-scan that returns UNREADABLE at clear time is NOT cleared even though the pre-dialog scan was empty (round 13, fund-safe)', () async {
      // A transient backend stall between the pre-dialog scan and the clear makes the authoritative re-scan
      // UNREADABLE. Fail closed: the stale empty pre-scan cannot carry the clear — keep it resumable.
      SubswapService.debugRescanForAbandon = (_) async => HtlcScanResult.unreadable;
      final rec = _rec(
        state: SubState.funding,
        legTxid: '',
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
      );
      await SubswapStore.save(rec);

      final cleared = await SubswapService.abandonUnfundedSell(rec, HtlcScanResult.empty);
      expect(cleared, isFalse, reason: 'an unreadable re-scan fails closed — never clear on a stale pre-dialog empty');
      expect(fake.data.containsKey(_storeKey), isTrue, reason: 'the record is preserved (resumable)');
      expect(fake.deletes, 0);
      expect(SubswapService.driving, isFalse);
    });

    test('the abandon decision is FULLY CLOCK-FREE: a device-clock jump (broadcastAt in the future, or unstamped) does not change abandonability (round 12)', () async {
      // ROUND 12: broadcastAgedForAbandon (the DateTime.now()-vs-broadcastAt wall-clock gate) is REMOVED. The
      // decision reads no wall clock — only the empty scan (whose margin is the clock-free height proof), the fresh
      // reload, identity, seqFundTxid, and not-driving. So broadcastAt is irrelevant: records that the OLD age gate
      // would have refused (a future broadcastAt from a forward clock jump, or an unstamped broadcastAt==0) now
      // clear identically. Each call clears the store, so we save fresh before each.
      // Round 13: drive the clear gate's re-scan to STILL-EMPTY so it is the clock-free decision under test, not I/O.
      SubswapService.debugRescanForAbandon = (_) async => HtlcScanResult.empty;
      SubswapRecord funding({required int broadcastAt}) => _rec(
            state: SubState.funding,
            legTxid: '',
            broadcastAttempted: true,
            broadcastAt: broadcastAt,
            hashHex: 'a' * 64,
            preimageHex: 'b' * 64,
          );
      // (a) broadcastAt FAR IN THE FUTURE (a forward device-clock jump would have made the old age gate read it as
      // "not yet aged" and refuse). Clock-free: it clears.
      await SubswapStore.save(funding(broadcastAt: DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch));
      final futureRec = (await SubswapStore.load())!;
      expect(await SubswapService.abandonUnfundedSell(futureRec, HtlcScanResult.empty), isTrue,
          reason: 'a future broadcastAt (forward clock jump) no longer blocks the clear — no wall clock is consulted');
      // (b) broadcastAt == 0 (unstamped — the old age gate FAILED CLOSED on this and refused). Clock-free: it clears.
      await SubswapStore.save(funding(broadcastAt: 0));
      final unstampedRec = (await SubswapStore.load())!;
      expect(await SubswapService.abandonUnfundedSell(unstampedRec, HtlcScanResult.empty), isTrue,
          reason: 'an unstamped broadcastAt no longer blocks the clear — abandonability does not depend on the clock');
    });

    test('a record ADVANCED to settling on disk is NOT abandonable even from a stale funding rec (FRESH RELOAD wins)', () async {
      // A concurrent cold-start resume found the funding and advanced the on-disk record to settling+legTxid,
      // while the UI still holds a STALE funding rec. The abandon must RELOAD FRESH and refuse — the resume wins.
      await SubswapStore.save(_rec(
        state: SubState.settling,
        legTxid: 'c' * 64,
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
      ));
      final stale = _rec(
        state: SubState.funding, // stale: the UI thinks it is still funding + empty legTxid
        legTxid: '',
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
      );
      final cleared = await SubswapService.abandonUnfundedSell(stale, HtlcScanResult.empty);
      expect(cleared, isFalse, reason: 'the FRESH on-disk record advanced to settling (funded HTLC) — never clobber it');
      expect(fake.data.containsKey(_storeKey), isTrue, reason: 'the funded record is preserved (resumable)');
      expect(SubswapStore.hasInFlight, isTrue);
      expect(fake.deletes, 0);
    });

    test('a FRESH record with a persisted seqFundTxid is NOT abandonable even with an empty scan (round 10 SEQ-FUND-TXID GUARD)', () async {
      // The funding tx WAS recorded (seqFundTxid persisted right after broadcast, before legTxid resolves) — a
      // recorded fund txid is direct proof of funding. Even a well-aged, empty scan against the persisted HTLC
      // must NOT clear it: a backend transiently/stalely returning [] can never override a recorded funding.
      await SubswapStore.save(_rec(
        state: SubState.funding,
        legTxid: '', // vout not yet resolved from the fund tx
        seqFundTxid: 'd' * 64, // but the funding broadcast WAS recorded
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
      ));
      // The stale UI rec has no seqFundTxid (the concurrent resume/broadcast recorded it after this snapshot).
      final stale = _rec(
        state: SubState.funding,
        legTxid: '',
        seqFundTxid: '',
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
      );
      final cleared = await SubswapService.abandonUnfundedSell(stale, HtlcScanResult.empty);
      expect(cleared, isFalse, reason: 'a persisted seqFundTxid is direct proof of funding — never abandonable, regardless of the scan');
      expect(fake.data.containsKey(_storeKey), isTrue, reason: 'the funded record is preserved (resumable)');
      expect(SubswapStore.hasInFlight, isTrue);
      expect(fake.deletes, 0);
    });

    test('a DRIVING record is NOT abandonable (a resume/drive is advancing it; let it win)', () async {
      final rec = _rec(
        state: SubState.funding,
        legTxid: '',
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
      );
      await SubswapStore.save(rec);
      SubswapService.debugDriving = true; // a drive holds the one-at-a-time guard
      final cleared = await SubswapService.abandonUnfundedSell(rec, HtlcScanResult.empty);
      expect(cleared, isFalse, reason: 'never abandon a record a drive is actively settling');
      expect(fake.data.containsKey(_storeKey), isTrue, reason: 'the record is preserved (resumable)');
      expect(fake.deletes, 0);
      SubswapService.debugDriving = false;
    });

    test('a DIFFERENT swap now in the slot is NOT abandonable from a stale rec (identity guard — the scan does not apply)', () async {
      // Disk now holds swap B (a different offer). The stale rec (swap A) was scanned empty, but B was NOT.
      await SubswapStore.save(_rec(
        offerId: 'offer-B',
        state: SubState.funding,
        legTxid: '',
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
      ));
      final staleA = _rec(
        offerId: 'offer-A',
        state: SubState.funding,
        legTxid: '',
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
      );
      final cleared = await SubswapService.abandonUnfundedSell(staleA, HtlcScanResult.empty);
      expect(cleared, isFalse, reason: 'the on-disk swap is a different offer than the one scanned — never clear it on a foreign scan');
      expect(fake.data.containsKey(_storeKey), isTrue);
      expect(fake.deletes, 0);
    });

    test('a SELL funding record whose scan finds a UTXO (FUNDED) is NOT abandonable — stays resumable', () async {
      final rec = _rec(
        state: SubState.funding,
        legTxid: '',
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
      );
      await SubswapStore.save(rec);

      final cleared = await SubswapService.abandonUnfundedSell(rec, HtlcScanResult.funded);
      expect(cleared, isFalse, reason: 'never clear while an output may sit at the HTLC address (fund-safe)');
      expect(fake.data.containsKey(_storeKey), isTrue, reason: 'the record is preserved (resumable)');
      expect(SubswapStore.hasInFlight, isTrue, reason: 'the guard stays closed — the swap can still settle/refund');
      expect(fake.deletes, 0);
    });

    test('a SELL funding record whose scan ERRORS (unreadable) is NOT abandonable — stays resumable', () async {
      final rec = _rec(
        state: SubState.funding,
        legTxid: '',
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
        hashHex: 'a' * 64,
        preimageHex: 'b' * 64,
      );
      await SubswapStore.save(rec);

      final cleared = await SubswapService.abandonUnfundedSell(rec, HtlcScanResult.unreadable);
      expect(cleared, isFalse, reason: 'a transient/unreadable scan must NEVER enable the abandon (fund-safe)');
      expect(fake.data.containsKey(_storeKey), isTrue, reason: 'the record is preserved (resumable)');
      expect(SubswapStore.hasInFlight, isTrue);
      expect(fake.deletes, 0);
    });

    test('abandonUnfundedSell refuses an INELIGIBLE record even with an empty scan (a settling SELL keeps its funded HTLC)', () async {
      // A 'settling' SELL has a funded on-chain HTLC (legTxid set) — even a fresh reload of it must NOT clear.
      final rec = _rec(state: SubState.settling, legTxid: 'c' * 64, hashHex: 'a' * 64, preimageHex: 'b' * 64);
      await SubswapStore.save(rec);

      final cleared = await SubswapService.abandonUnfundedSell(rec, HtlcScanResult.empty);
      expect(cleared, isFalse, reason: 'the fresh-reloaded record is settling (funded HTLC) — never abandonable');
      expect(fake.data.containsKey(_storeKey), isTrue);
      expect(SubswapStore.hasInFlight, isTrue);
      expect(fake.deletes, 0);
    });

    test('abandonUnfundedSell refuses a BUY record even with an empty scan', () async {
      final rec = _rec(buy: true, state: SubState.funding, legTxid: '');
      await SubswapStore.save(rec);
      expect(await SubswapService.abandonUnfundedSell(rec, HtlcScanResult.empty), isFalse);
      expect(fake.data.containsKey(_storeKey), isTrue);
    });

    test('abandonUnfundedSell on an already-cleared store (fresh reload null) returns false and clears nothing', () async {
      // Disk is empty (nothing to clear); a stale, otherwise-abandonable rec is passed.
      final stale = _rec(
        state: SubState.funding,
        legTxid: '',
        broadcastAttempted: true,
        broadcastAt: _agoMs(const Duration(hours: 3)),
      );
      final cleared = await SubswapService.abandonUnfundedSell(stale, HtlcScanResult.empty);
      expect(cleared, isFalse, reason: 'a null fresh reload means the record is already gone — nothing to clear');
      expect(fake.deletes, 0);
      expect(SubswapService.driving, isFalse);
    });
  });
}
