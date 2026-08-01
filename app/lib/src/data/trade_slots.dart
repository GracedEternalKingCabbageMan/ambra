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
// ---------------------------------------------------------------------------

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

/// List-backed persistence for ONE trade kind: a JSON array under [listKey] with one-time, never-lossy
/// adoption of the legacy single-slot record under [legacyKey]. All mutations are serialised per store
/// (single-process async lock) so read-modify-write never drops a concurrent update.
class TradeListStore {
  TradeListStore({required this.listKey, required this.legacyKey});
  final String listKey;
  final String legacyKey;
  static const _storage = FlutterSecureStorage();

  Future<void> _chain = Future<void>.value();

  /// Serialise [body] behind every earlier mutation of THIS store (errors do not break the chain).
  Future<T> _locked<T>(Future<T> Function() body) {
    final run = _chain.then((_) => body());
    _chain = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Read every entry, adopting the legacy single-slot record first (crash-safe, see the header).
  /// Storage READ errors propagate as-is (transient — the caller's fail-safe policy applies); a
  /// present-but-undecodable LIST blob throws [TradeListCorruptException] (durable; blob preserved).
  Future<TradeListRead> readAll() => _locked(_readAllInner);

  Future<TradeListRead> _readAllInner() async {
    var legacyUndecodable = false;
    // ADOPT the legacy record whenever the legacy key still holds one (covers both the first read and
    // a crash mid-adoption). Read errors propagate; an undecodable legacy blob is left alone + flagged.
    final legacyRaw = await _storage.read(key: legacyKey);
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
      } else {
        await _adoptInner(legacy, legacyRaw);
      }
    }
    final s = await _storage.read(key: listKey);
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
      await _storage.write(key: listKey, value: jsonEncode(arr)); // (2) write-first…
    }
    await _storage.delete(key: legacyKey); // (3) …then delete
  }

  /// The raw stored array (undecodable entries preserved as-is); empty on absent. An undecodable LIST
  /// blob throws [TradeListCorruptException] so a mutation can never overwrite corrupt material.
  Future<List<dynamic>> _readArrOrEmpty() async {
    final s = await _storage.read(key: listKey);
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
        await _storage.write(key: listKey, value: jsonEncode(arr));
      });

  /// Remove the entry whose id matches; the key is deleted once the list is empty.
  Future<void> removeById(String id) => _locked(() async {
        final arr = await _readArrOrEmpty();
        arr.removeWhere((e) => e is Map && '${e['id'] ?? ''}' == id);
        if (arr.isEmpty) {
          await _storage.delete(key: listKey);
        } else {
          await _storage.write(key: listKey, value: jsonEncode(arr));
        }
      });

  /// Remove entries a predicate marks (used by corrupt-recovery to drop EXACTLY the undecodable /
  /// undrivable material after the user was warned — healthy records survive). Non-object entries are
  /// dropped only when [dropNonObjects] is set (the recovery flow's explicit choice).
  Future<void> removeWhere(bool Function(Map<String, dynamic>) test, {bool dropNonObjects = false}) =>
      _locked(() async {
        List<dynamic> arr;
        try {
          arr = await _readArrOrEmpty();
        } on TradeListCorruptException {
          return; // the whole blob is corrupt; only wipeListBlob may touch it
        }
        arr.removeWhere((e) => e is! Map ? dropNonObjects : test(e.cast<String, dynamic>()));
        if (arr.isEmpty) {
          await _storage.delete(key: listKey);
        } else {
          await _storage.write(key: listKey, value: jsonEncode(arr));
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
  Future<void> deleteLegacyBlob() => _locked(() => _storage.delete(key: legacyKey));

  /// Delete the (whole-blob-corrupt) LIST — corrupt-recovery only, after the user was warned.
  Future<void> wipeListBlob() => _locked(() => _storage.delete(key: listKey));

  /// Full wipe of both keys. TEST/reset use and the guarded corrupt-recovery ONLY — production flows
  /// remove records individually so one trade's clear can never drop another's reclaim material.
  Future<void> wipeAll() => _locked(() async {
        await _storage.delete(key: listKey);
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
