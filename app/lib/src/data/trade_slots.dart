// ---------------------------------------------------------------------------
// trade_slots.dart — the MULTI-RECORD substrate for the per-trade stores + the SHARED concurrent-trade
// slot count, the mobile twin of the web wallet's SUBSWAPS/BUYS/SELLS arrays + MAX_CONCURRENT_TRADES /
// tradeSlotsFree / buySlotsFree (swap.js).
//
// Every rail-crossing trade store used to be SINGLE-SLOT ('ambra.<kind>.active'): starting a second
// trade of the same kind was hard-refused because a second record would have OVERWRITTEN the first's
// recovery material (preimage / HTLC terms — the only handle to locked funds). This substrate keeps a
// bounded LIST of records instead, each with a stable per-record `id`, so:
//
//   • a new record NEVER clobbers a live one (upsert is by id — the structural fund-safety the
//     single-slot guards existed to enforce);
//   • up to [kMaxConcurrentTrades] trades may be in flight ACROSS the rail-crossing kinds
//     (buys + sells + subswaps + bridge + xr), enforced at dispatch with the web's honest message;
//   • resume paths iterate every non-terminal record INDEPENDENTLY, so one stuck counterparty never
//     blocks another trade's settle/refund (the web resumeSubswap lesson).
//
// MIGRATION (one-time, never-lossy): each store's legacy single-slot record is ADOPTED into the list
// on first read. The adoption is crash-safe by ordering: (1) the legacy blob is REWRITTEN in place
// with its new `id` injected, (2) the record is prepended to the list and the list written, (3) the
// legacy key is deleted. A crash between any two steps leaves either a re-adoptable legacy blob or a
// dedupable duplicate (matched by id), never a lost record. An UNDECODABLE legacy blob is LEFT IN
// PLACE untouched (never deleted — it may be the only copy of reclaim material) and reported to the
// owning store, which surfaces its existing corrupt-recovery affordance.
//
// Ambra is a single OS process, so the web's multi-tab merge/tombstone machinery is deliberately NOT
// ported; a simple per-store async serialisation lock makes read-modify-write safe against
// interleaved async callers in this one process.
//
// MIRRORED PERSISTENCE (the keystore-invalidation incident): on Android a keystore invalidation /
// EncryptedSharedPreferences failure makes flutter_secure_storage reads silently return null —
// indistinguishable from "key absent" — so every trade record (each holding the preimage that is the
// ONLY handle to committed funds) can vanish without a trace. Every list write therefore lands in TWO
// independent targets: secure storage first, then a plain JSON file per store under the app documents
// directory (<docs>/trade-mirror/<listKey>.json). A read that finds secure storage EMPTY (or throwing)
// while the mirror still holds records ADOPTS the mirror copy — returning it and writing it back to
// secure storage best-effort — and logs loudly. The mirror is never consulted while secure storage has
// entries. The mirror file is SAME-SANDBOX app-internal storage (the trust boundary the web wallet's
// localStorage already accepts for identical material); it must never move to external storage or into
// logs, and Android auto-backup is disabled app-wide (AndroidManifest allowBackup=false) so it never
// leaves the device.
// ---------------------------------------------------------------------------

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'store_log.dart';

import 'lsp_bridge_service.dart' show LspBridgeStore;
import 'subasset_buy_service.dart' show SubBuyStore;
import 'subasset_sell_service.dart' show SubSellStore;
import 'subswap_service.dart' show SubswapStore;
import 'xr_swap_service.dart' show XrSwapStore;

/// NOT a product limit — a runaway backstop (web swap.js MAX_CONCURRENT_TRADES, same value).
/// Rail-crossing trades are independent per-record state machines and there is no principled
/// ceiling on how many a trader may run; this bound exists only so a bug that spawns trades
/// in a loop cannot lock funds without bound. Set far above any human trading pattern.
const int kMaxConcurrentTrades = 100;

/// A fresh stable per-record id: 16 random bytes, hex. Assigned at record creation (or at legacy
/// adoption for a pre-list record), and the key every upsert/remove matches on.
String newTradeId() {
  final r = Random.secure();
  return List<int>.generate(16, (_) => r.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// The list blob is PRESENT but not a decodable JSON array — durable corruption of the whole store.
/// The blob is always LEFT IN PLACE (it may carry reclaim material); the owning store decides whether
/// to fail safe (SubswapStore) or degrade to an empty read (the stores whose load() already tolerated
/// an undecodable blob by returning null WITHOUT deleting it).
class TradeListCorruptException implements Exception {
  const TradeListCorruptException(this.key);
  final String key;
  @override
  String toString() => 'trade list under "$key" is present but undecodable';
}

/// What a [TradeListStore.readAll] found: the decodable entry maps, plus the corrupt material it
/// deliberately did NOT drop (undecodable list entries stay on disk verbatim; an undecodable legacy
/// blob stays under its own key).
class TradeListRead {
  const TradeListRead({required this.entries, required this.undecodableEntries, required this.legacyUndecodable});
  final List<Map<String, dynamic>> entries;
  final int undecodableEntries; // list entries that are not JSON objects (preserved on rewrite)
  final bool legacyUndecodable; // a legacy single-slot blob exists but cannot be decoded (left in place)
}

/// The MIRROR seam: the second, independent persistence target every [TradeListStore] writes through
/// to. Static + injectable so unit tests swap it for an in-memory fake (the same seam pattern as the
/// method-channel secure-storage fake); production uses [FileTradeMirror].
abstract class TradeMirrorTarget {
  Future<String?> read(String listKey);
  Future<void> write(String listKey, String value);
  Future<void> delete(String listKey);
}

/// The live mirror: one JSON file per store at `<app-docs>/trade-mirror/<listKey>.json` — app-internal,
/// same-sandbox storage that does NOT ride the Android keystore, so a keystore invalidation cannot
/// touch it. Errors propagate; the [TradeListStore] helpers make every mirror touch best-effort.
class FileTradeMirror implements TradeMirrorTarget {
  Future<Directory>? _dirFut;

  /// Resolve (and memoise) the mirror directory. A FAILED resolution is not cached, so one transient
  /// error at startup can never permanently disable the mirror.
  Future<Directory> _dir() {
    final cached = _dirFut;
    if (cached != null) return cached;
    final fut = (() async {
      final docs = await getApplicationDocumentsDirectory();
      final d = Directory('${docs.path}/trade-mirror');
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    })();
    _dirFut = fut;
    fut.catchError((Object _) {
      _dirFut = null; // retry next touch
      return Directory(''); // value unused; the original future still errors for its awaiter
    });
    return fut;
  }

  Future<File> _file(String listKey) async => File('${(await _dir()).path}/$listKey.json');

  @override
  Future<String?> read(String listKey) async {
    final f = await _file(listKey);
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  @override
  Future<void> write(String listKey, String value) async {
    await (await _file(listKey)).writeAsString(value, flush: true);
  }

  @override
  Future<void> delete(String listKey) async {
    final f = await _file(listKey);
    if (await f.exists()) await f.delete();
  }
}

/// List-backed persistence for ONE trade kind: a JSON array under [listKey] with one-time, never-lossy
/// adoption of the legacy single-slot record under [legacyKey]. All mutations are serialised per store
/// (single-process async lock) so read-modify-write never drops a concurrent update. Every write lands
/// in secure storage AND the [mirror] (see the header); a mirror failure never fails the operation.
class TradeListStore {
  TradeListStore({required this.listKey, required this.legacyKey});
  final String listKey;
  final String legacyKey;
  static const _storage = FlutterSecureStorage();

  /// The shared second persistence target (tests inject an in-memory fake).
  static TradeMirrorTarget mirror = FileTradeMirror();

  Future<void> _chain = Future<void>.value();

  /// Serialise [body] behind every earlier mutation of THIS store (errors do not break the chain).
  Future<T> _locked<T>(Future<T> Function() body) {
    final run = _chain.then((_) => body());
    _chain = run.then((_) {}, onError: (_) {});
    return run;
  }

  // ---- mirror plumbing (best-effort on every touch; the mirror never fails an operation) -----------

  Future<String?> _mirrorRead() async {
    try {
      return await TradeListStore.mirror.read(listKey);
    } catch (e) {
      storeLog('mirror read failed for "$listKey": $e');
      return null;
    }
  }

  Future<void> _mirrorWrite(String value) async {
    try {
      await TradeListStore.mirror.write(listKey, value);
    } catch (e) {
      storeLog('mirror write failed for "$listKey" (secure-storage copy is current): $e');
    }
  }

  Future<void> _mirrorDelete() async {
    try {
      await TradeListStore.mirror.delete(listKey);
    } catch (e) {
      storeLog('mirror delete failed for "$listKey": $e');
    }
  }

  /// Write [arr] to BOTH targets: secure storage first (authoritative), then the mirror (best-effort).
  Future<void> _writeList(List<dynamic> arr) async {
    final enc = jsonEncode(arr);
    await _storage.write(key: listKey, value: enc);
    await _mirrorWrite(enc);
  }

  /// Delete the list from BOTH targets (empty-list tidy / explicit wipe).
  Future<void> _deleteList() async {
    await _storage.delete(key: listKey);
    await _mirrorDelete();
  }

  /// How many decodable entries a raw list blob holds; -1 when the blob is not a JSON array.
  static int _entryCount(String raw) {
    try {
      final d = jsonDecode(raw);
      return d is List ? d.length : -1;
    } catch (_) {
      return -1;
    }
  }

  /// The raw list blob, MIRROR-BACKED: secure storage is authoritative whenever it yields ANYTHING
  /// (even an undecodable blob — never adopt over material the corrupt-recovery flow owns). When it
  /// yields NOTHING (null/empty, or the read THROWS — the Android keystore-invalidation signature)
  /// while the mirror still holds records, the mirror copy is ADOPTED: logged loudly, written back to
  /// secure storage best-effort, and returned. With no mirror rescue a secure-storage read error still
  /// propagates (the caller's fail-safe policy applies unchanged).
  Future<String?> _readListRawMirrored() async {
    String? s;
    Object? secureErr;
    try {
      s = await _storage.read(key: listKey);
    } catch (e) {
      secureErr = e;
      storeLog('secure-storage read THREW for "$listKey": $e - consulting the mirror');
    }
    if (s != null && s.isNotEmpty) return s;
    final m = await _mirrorRead();
    if (m == null || m.isEmpty || _entryCount(m) <= 0) {
      if (m != null && m.isNotEmpty && _entryCount(m) < 0) {
        storeLog('mirror blob for "$listKey" is undecodable - not adopted');
      }
      if (secureErr != null) throw secureErr; // no rescue: keep the original fail-safe contract
      return null;
    }
    storeLog('ADOPT-FROM-MIRROR for "$listKey": secure storage yielded '
        '${secureErr != null ? 'a read error' : 'no entries'} but the mirror holds ${_entryCount(m)} '
        'record(s) - serving the mirror copy and writing it back to secure storage');
    try {
      await _storage.write(key: listKey, value: m);
    } catch (e) {
      storeLog('write-back to secure storage failed for "$listKey" (mirror copy still served): $e');
    }
    return m;
  }

  /// Read every entry, adopting the legacy single-slot record first (crash-safe, see the header).
  /// Storage READ errors propagate as-is (transient — the caller's fail-safe policy applies) unless the
  /// mirror rescues the read; a present-but-undecodable LIST blob throws [TradeListCorruptException]
  /// (durable; blob preserved).
  Future<TradeListRead> readAll() => _locked(_readAllInner);

  Future<TradeListRead> _readAllInner() async {
    var legacyUndecodable = false;
    // ADOPT the legacy record whenever the legacy key still holds one (covers both the first read and
    // a crash mid-adoption). A legacy READ error is logged and skipped (adoption simply re-runs on a
    // later read — the legacy blob stays in place, never-lossy) so a broken secure storage cannot block
    // the mirror-backed list read below. An undecodable legacy blob is left alone + flagged.
    String? legacyRaw;
    try {
      legacyRaw = await _storage.read(key: legacyKey);
    } catch (e) {
      storeLog('secure-storage read THREW for legacy "$legacyKey" (adoption deferred to a later read): $e');
    }
    if (legacyRaw != null && legacyRaw.isNotEmpty) {
      Map<String, dynamic>? legacy;
      try {
        final d = jsonDecode(legacyRaw);
        legacy = d is Map ? d.cast<String, dynamic>() : null;
      } catch (_) {
        legacy = null;
      }
      if (legacy == null) {
        legacyUndecodable = true; // preserved in place; the owner surfaces recovery
        storeLog('legacy blob under "$legacyKey" is undecodable - left in place, recovery surfaced');
      } else {
        await _adoptInner(legacy, legacyRaw);
      }
    }
    final s = await _readListRawMirrored();
    if (s == null || s.isEmpty) {
      return TradeListRead(entries: const [], undecodableEntries: 0, legacyUndecodable: legacyUndecodable);
    }
    List<dynamic> arr;
    try {
      final d = jsonDecode(s);
      arr = d is List ? d : (throw const FormatException('not a JSON array'));
    } catch (_) {
      throw TradeListCorruptException(listKey);
    }
    final entries = <Map<String, dynamic>>[];
    var undecodable = 0;
    for (final e in arr) {
      if (e is Map) {
        entries.add(e.cast<String, dynamic>());
      } else {
        undecodable++; // preserved verbatim by every rewrite (see _writeArr callers)
      }
    }
    return TradeListRead(entries: entries, undecodableEntries: undecodable, legacyUndecodable: legacyUndecodable);
  }

  /// Crash-safe adoption of a decoded legacy record: inject the id INTO the legacy blob first (so a
  /// re-run can dedupe by id), then prepend to the list, then delete the legacy key — in that order, so
  /// no crash window loses the record.
  Future<void> _adoptInner(Map<String, dynamic> legacy, String legacyRaw) async {
    var id = '${legacy['id'] ?? ''}';
    if (id.isEmpty) {
      id = newTradeId();
      legacy['id'] = id;
      await _storage.write(key: legacyKey, value: jsonEncode(legacy)); // (1) id survives a crash
    }
    final arr = await _readArrOrEmpty();
    final already = arr.any((e) => e is Map && '${e['id'] ?? ''}' == id);
    if (!already) {
      arr.insert(0, legacy);
      await _writeList(arr); // (2) write-first…
    }
    await _storage.delete(key: legacyKey); // (3) …then delete
    storeLog('legacy adoption "$legacyKey" -> "$listKey": record id=$id ${already ? 'deduped (already in the list)' : 'adopted'}');
  }

  /// The raw stored array (undecodable entries preserved as-is); empty on absent. Mirror-backed like
  /// [readAll] so a mutation on a keystore-nulled store can never clobber the mirror's live records. An
  /// undecodable LIST blob throws [TradeListCorruptException] so a mutation can never overwrite corrupt
  /// material.
  Future<List<dynamic>> _readArrOrEmpty() async {
    final s = await _readListRawMirrored();
    if (s == null || s.isEmpty) return <dynamic>[];
    try {
      final d = jsonDecode(s);
      if (d is List) return d;
    } catch (_) {}
    throw TradeListCorruptException(listKey);
  }

  /// Insert-or-replace by `json['id']` (append when absent). Non-object / foreign-id entries are
  /// preserved verbatim, so an upsert can never drop another record's material.
  Future<void> upsert(Map<String, dynamic> json) => _locked(() async {
        final id = '${json['id'] ?? ''}';
        if (id.isEmpty) throw ArgumentError('trade record has no id');
        final arr = await _readArrOrEmpty();
        final i = arr.indexWhere((e) => e is Map && '${e['id'] ?? ''}' == id);
        if (i >= 0) {
          arr[i] = json;
        } else {
          arr.add(json);
        }
        await _writeList(arr);
      });

  /// Remove the entry whose id matches; the key is deleted (from both targets) once the list is empty.
  /// [reason] is the caller's stated cause, logged loudly — a record removal must never be silent.
  Future<void> removeById(String id, {String reason = 'unspecified'}) => _locked(() async {
        final arr = await _readArrOrEmpty();
        final before = arr.length;
        arr.removeWhere((e) => e is Map && '${e['id'] ?? ''}' == id);
        storeLog('remove from "$listKey": id=$id ${before == arr.length ? '(absent)' : ''} reason: $reason');
        if (arr.isEmpty) {
          await _deleteList();
        } else {
          await _writeList(arr);
        }
      });

  /// Remove entries a predicate marks (used by corrupt-recovery to drop EXACTLY the undecodable /
  /// undrivable material after the user was warned — healthy records survive). Non-object entries are
  /// dropped only when [dropNonObjects] is set (the recovery flow's explicit choice).
  Future<void> removeWhere(bool Function(Map<String, dynamic>) test,
          {bool dropNonObjects = false, String reason = 'corrupt-recovery clear'}) =>
      _locked(() async {
        List<dynamic> arr;
        try {
          arr = await _readArrOrEmpty();
        } on TradeListCorruptException {
          return; // the whole blob is corrupt; only wipeListBlob may touch it
        }
        final before = arr.length;
        arr.removeWhere((e) => e is! Map ? dropNonObjects : test(e.cast<String, dynamic>()));
        if (before != arr.length) {
          storeLog('removeWhere on "$listKey": dropped ${before - arr.length} of $before entries reason: $reason');
        }
        if (arr.isEmpty) {
          await _deleteList();
        } else {
          await _writeList(arr);
        }
      });

  /// The raw legacy blob (for the corrupt-recovery inspect affordance). Best-effort.
  Future<String?> readRawLegacy() async {
    try {
      return await _storage.read(key: legacyKey);
    } catch (_) {
      return null;
    }
  }

  /// The raw list blob (for the corrupt-recovery inspect affordance). Best-effort.
  Future<String?> readRawList() async {
    try {
      return await _storage.read(key: listKey);
    } catch (_) {
      return null;
    }
  }

  /// Delete the undecodable LEGACY blob — corrupt-recovery only, after the user was warned.
  Future<void> deleteLegacyBlob() => _locked(() async {
        storeLog('deleteLegacyBlob "$legacyKey" (corrupt-recovery, user-warned)');
        await _storage.delete(key: legacyKey);
      });

  /// Delete the (whole-blob-corrupt) LIST — corrupt-recovery only, after the user was warned. The
  /// mirror copy is wiped WITH it: the user explicitly chose to destroy this store's material, and a
  /// surviving mirror would silently resurrect it on the next read.
  Future<void> wipeListBlob() => _locked(() async {
        storeLog('wipeListBlob "$listKey" (corrupt-recovery, user-warned) - both targets');
        await _deleteList();
      });

  /// Full wipe of both keys, in BOTH targets. TEST/reset use and the guarded corrupt-recovery ONLY —
  /// production flows remove records individually so one trade's clear can never drop another's
  /// reclaim material.
  Future<void> wipeAll() => _locked(() async {
        storeLog('wipeAll "$listKey" + "$legacyKey" - both targets');
        await _deleteList();
        await _storage.delete(key: legacyKey);
      });
}

/// The SHARED slot count across the rail-crossing trade kinds (web buySlotsFree: activeBuys +
/// activeSells + activeSubswaps + bridge < MAX_CONCURRENT_TRADES, here with the xr reverse-cross records
/// counted too). Pure-LN takes commit nothing client-side, so they do not occupy a slot.
///
/// Counting is a UX bound, not the fund-safety line — with per-record ids a new record can never
/// clobber a live one — so a transiently unreadable store counts 0 here (the per-kind guards, e.g.
/// SubswapStore's fail-safe machinery, still gate their own rail).
class TradeSlots {
  TradeSlots._();

  static Future<int> inFlightCount() async {
    var n = 0;
    try {
      n += (await SubBuyStore.loadAll()).where((r) => r.inFlight).length;
    } catch (_) {}
    try {
      n += (await SubSellStore.loadAll()).where((r) => r.inFlight).length;
    } catch (_) {}
    try {
      n += SubswapStore.primed
          ? SubswapStore.activeCount
          : (await SubswapStore.loadAll()).where((r) => !r.terminal).length;
    } catch (_) {
      // A failing subswap read fails SAFE inside its own store (activeCount holds >=1); mirror that.
      n += SubswapStore.activeCount;
    }
    try {
      n += (await XrSwapStore.inFlightWithFunds()).length;
    } catch (_) {}
    try {
      n += (await LspBridgeStore.inFlightWithFunds()).length;
    } catch (_) {}
    return n;
  }

  /// Null when a slot is free; otherwise the web wallet's honest block message, adapted to the
  /// composer's in-flight cards.
  static Future<String?> refusalIfFull() async {
    final n = await inFlightCount();
    if (n < kMaxConcurrentTrades) return null;
    return 'You already have $n trades in progress · see the in-flight cards above. '
        'Finish or reclaim one before starting another.';
  }
}
