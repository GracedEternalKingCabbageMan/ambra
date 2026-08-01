// ---------------------------------------------------------------------------
// ln_take_service.dart — the COMPOSER-NATIVE pure-LN take (BTC<->asset AND asset<->asset), the mobile
// twin of the web wallet's swap.js requote-ln + reviewLn. One service owns the whole seam so the
// composer and any legacy entry point ([LightningSwapScreen]) build the /swap request the SAME way:
//
//   • PIN the best resting offer from /lnbook BEFORE review, so the sheet prices the EXACT offer the
//     LSP then lifts (offer_id + maker_pubkey travel on the POST) — never a relay-arbitrary one.
//   • WHOLE-FILL truth: the LSP runs xpln, which lifts the pinned offer IN FULL. The review therefore
//     shows the OFFER's amounts as "You pay / You receive" (never the typed amount), with a loud note
//     when the executed size differs from the typed size by more than [kLnSizeNoteFractionPct].
//   • PERSIST-BEFORE-POST: a single-slot record ('ambra.ln.active') is written BEFORE the irreversible
//     POST and cleared on success (the receipt is written as before) or marked failed on error. Pure-LN
//     commits nothing client-side — an unsettled take costs nothing — so a stale record resolves by
//     re-checking the local receipt trail, never by inventing recovery machinery.
//
// Amounts are BigInt atoms of each leg's OWN asset; display formatting stays with the caller.
// ---------------------------------------------------------------------------

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'config.dart';
import 'format.dart';
import 'lightning_service.dart';
import 'lsp_client.dart';
import 'trade_receipts.dart';

/// The LSP's /swap timeout (LspClient.swap posts with a 90s timeout). A persisted in-flight record OLDER
/// than this can no longer be racing a live POST in any process, so restart-resolution may judge it.
const int kLnLspTimeoutMs = 90 * 1000;

/// The offer-vs-typed size deviation (percent) above which the review shows the loud mismatch note
/// (mirror web reviewLn's 0.05 threshold).
const double kLnSizeNoteFractionPct = 5.0;

/// The single-slot persisted state of one composer-native pure-LN take. Written BEFORE the POST; pure-LN
/// commits nothing client-side, so the record exists only to make an interrupted take VISIBLE (settled
/// via the receipt trail, or honestly "did not settle · funds are safe") — it holds no reclaim material.
class LnTakeRecord {
  LnTakeRecord({
    required this.state,
    required this.side,
    required this.asset,
    this.quoteAsset,
    this.offerId,
    this.makerPubkey,
    required this.assetAtoms,
    required this.quoteAtoms,
    required this.startedMs,
    this.detail = '',
  });

  String state; // 'inflight' | 'failed'
  final String side; // 'buy' (quote -> base) | 'sell' (base -> quote)
  final String asset; // the BASE asset id (hex)
  final String? quoteAsset; // the counter asset for asset<->asset; null = BTC implied
  final String? offerId; // the pinned resting offer
  final String? makerPubkey;
  final BigInt assetAtoms; // the pinned offer's base leg (what actually moves — whole-fill)
  final BigInt quoteAtoms; // the pinned offer's counter leg (BTC sats, or quote-asset atoms)
  final int startedMs; // wall-clock ms at persist (immediately before the POST)
  String detail;

  bool get failed => state == 'failed';

  Map<String, dynamic> toJson() => {
        'state': state,
        'side': side,
        'asset': asset,
        'quote_asset': quoteAsset,
        'offer_id': offerId,
        'maker_pubkey': makerPubkey,
        'asset_atoms': assetAtoms.toString(),
        'quote_atoms': quoteAtoms.toString(),
        'started_ms': startedMs,
        'detail': detail,
      };

  static LnTakeRecord fromJson(Map<String, dynamic> j) => LnTakeRecord(
        // An unrecognised persisted state decodes as 'inflight' (never silently resolved): the stale
        // resolver then judges it honestly off its age + the receipt trail.
        state: j['state'] == 'failed' ? 'failed' : 'inflight',
        side: '${j['side'] ?? 'buy'}',
        asset: '${j['asset'] ?? ''}',
        quoteAsset: (j['quote_asset'] as String?)?.isEmpty ?? true ? null : j['quote_asset'] as String?,
        offerId: (j['offer_id'] as String?)?.isEmpty ?? true ? null : j['offer_id'] as String?,
        makerPubkey: (j['maker_pubkey'] as String?)?.isEmpty ?? true ? null : j['maker_pubkey'] as String?,
        assetAtoms: BigInt.tryParse('${j['asset_atoms'] ?? 0}') ?? BigInt.zero,
        quoteAtoms: BigInt.tryParse('${j['quote_atoms'] ?? 0}') ?? BigInt.zero,
        startedMs: (j['started_ms'] as num?)?.toInt() ?? 0,
        detail: '${j['detail'] ?? ''}',
      );
}

/// The single-slot store for the active pure-LN take. Secure storage like its rail siblings
/// (XrSwapStore / SubswapStore), under its own key so it never clobbers another rail's record.
class LnTakeStore {
  LnTakeStore._();
  static const _key = 'ambra.ln.active';
  static const _storage = FlutterSecureStorage();

  static Future<LnTakeRecord?> load() async {
    final s = await _storage.read(key: _key);
    if (s == null || s.isEmpty) return null;
    try {
      return LnTakeRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      // Undecodable: a pure-LN record protects no funds, so an unreadable blob is dropped rather than
      // wedging the rail (deliberately unlike the on-chain stores, whose records carry reclaim material).
      return null;
    }
  }

  static Future<void> save(LnTakeRecord r) => _storage.write(key: _key, value: jsonEncode(r.toJson()));
  static Future<void> clear() => _storage.delete(key: _key);
}

/// The /lnbook pre-check verdict: the pinned best offer (or null), and whether the book was SERVED at
/// all — an unreachable / older LSP returns an un-served (raw-empty) book, which is a different honest
/// message than "the book is served but this side is empty".
class LnPinVerdict {
  const LnPinVerdict({required this.offer, required this.served});
  final LnOffer? offer;
  final bool served;
}

/// A stale persisted take, resolved for the composer banner: [settled] = the receipt trail proves the
/// swap actually settled (the record was cleared); otherwise the take did not settle — pure-LN commits
/// nothing client-side, so the honest message is "did not settle · funds are safe".
class LnStaleVerdict {
  const LnStaleVerdict({required this.record, required this.settled});
  final LnTakeRecord record;
  final bool settled;
}

class LnTakeService {
  LnTakeService._();

  /// The typed size's deviation from the leg that actually executes, in PERCENT of the executed leg
  /// (mirror web reviewLn's offer-vs-typed warning math). Null when nothing was typed / unparsable —
  /// no note then, the review's amounts are already the whole truth. PURE.
  static double? sizeMismatchPct({required BigInt execAtoms, required int precision, required String typed}) {
    final t = typed.trim();
    if (t.isEmpty || execAtoms <= BigInt.zero) return null;
    final typedAtoms = parseAtoms(t, precision);
    if (typedAtoms == null || typedAtoms <= BigInt.zero) return null;
    final diff = (execAtoms - typedAtoms).abs();
    return diff.toDouble() / execAtoms.toDouble() * 100.0;
  }

  /// Whether the review must carry the loud offer-vs-typed note (> [kLnSizeNoteFractionPct]). PURE.
  static bool needsSizeNote({required BigInt execAtoms, required int precision, required String typed}) {
    final pct = sizeMismatchPct(execAtoms: execAtoms, precision: precision, typed: typed);
    return pct != null && pct > kLnSizeNoteFractionPct;
  }

  /// PIN the best resting offer for (base [asset], [quoteAsset]) on [side] from the LSP's /lnbook —
  /// the pre-Review read whose offer the POST then lifts in full. Never throws (lnBook is tolerant).
  static Future<LnPinVerdict> pinBest({required String side, required String asset, String? quoteAsset}) async {
    final book = await LightningService.instance.lnBook(asset, quoteAsset: quoteAsset);
    return LnPinVerdict(offer: book.best(side), served: book.raw.isNotEmpty);
  }

  /// Execute the reviewed take: PERSIST the single-slot record, resolve the user's OWN node keys
  /// (self-custody — the LSP drives the swap on THEM), then POST /swap pinning [offer]. Clears the
  /// record + writes the receipt on success; marks it failed on error and rethrows. [typedAmount] is
  /// the display string the user typed (forwarded to the LSP as before; the lift is whole-offer
  /// regardless, so the pinned offer's legs are what actually move). [offer] is null ONLY on the
  /// legacy fall-through where the LSP's /lnbook is unreachable and the LSP does its own matching
  /// ([LightningSwapScreen]'s no-regression path); the composer always pins.
  static Future<LspSwapResult> take({
    required String side,
    required String asset,
    String? quoteAsset,
    LnOffer? offer,
    String? typedAmount,
  }) async {
    final ln = LightningService.instance;
    final aprec = SeqAssets.labelFor(asset).precision;
    final qprec = quoteAsset == null ? 8 : SeqAssets.labelFor(quoteAsset).precision;
    // The LSP's `amount` field: the typed number when present (the wire shape LightningSwapScreen has
    // always sent), else the pinned offer's own pay-leg size in display units — never a fabricated size.
    final typed = double.tryParse((typedAmount ?? '').trim());
    final amount = (typed != null && typed > 0)
        ? typed
        : offer == null
            ? (throw Exception('Enter an amount'))
            : (side == 'buy'
                ? offer.btcAtoms.toDouble() / _pow10(qprec)
                : offer.assetAtoms.toDouble() / _pow10(aprec));

    // PERSIST BEFORE THE IRREVERSIBLE POST: the record is what makes an interrupted take visible.
    final rec = LnTakeRecord(
      state: 'inflight',
      side: side,
      asset: asset,
      quoteAsset: quoteAsset,
      offerId: offer?.offerId,
      makerPubkey: offer?.makerPubkey,
      assetAtoms: offer?.assetAtoms ?? BigInt.zero,
      quoteAtoms: offer?.btcAtoms ?? BigInt.zero,
      startedMs: DateTime.now().millisecondsSinceEpoch,
    );
    await LnTakeStore.save(rec);

    try {
      // SELF-CUSTODY (mirror web reviewLn): the swap runs on the user's OWN per-asset nodes; the device
      // co-signs the commitment updates over the wss link during the call. baseNodeKey = the base asset
      // node; counterNodeKey = the counter-asset node (asset<->asset) or the user's BTC node (asset<->BTC).
      final baseNodeKey = await ln.assetNodeKey(asset);
      final counterNodeKey = quoteAsset != null ? await ln.assetNodeKey(quoteAsset) : await ln.btcNodeKey();
      final r = await ln.swap(
        side: side,
        asset: asset,
        amount: amount,
        nodeKey: baseNodeKey,
        counterNodeKey: counterNodeKey,
        quoteAsset: quoteAsset,
        offerId: offer?.offerId,
        makerPubkey: offer?.makerPubkey,
      );
      // Receipt as before (keyed by the settle's preimage so it is recorded exactly once). The quote
      // ticker comes from the wallet's OWN asset metadata, never a server label (an LSP that does not
      // know a ticker echoes the raw hex id, which must never reach the UI).
      final tk = SeqAssets.labelFor(asset).ticker;
      final qtk = quoteAsset == null ? 'BTC' : SeqAssets.labelFor(quoteAsset).ticker;
      if (r.preimage.isNotEmpty) {
        await TradeReceipts.log(
          id: 'ln:${r.preimage}',
          title: r.direction == 'sold' ? 'Sold $tk for $qtk (Lightning)' : 'Bought $tk with $qtk (Lightning)',
          status: 'Settled',
        );
      }
      await LnTakeStore.clear();
      return r;
    } catch (e) {
      rec
        ..state = 'failed'
        ..detail = e.toString().replaceFirst('Exception: ', '');
      await LnTakeStore.save(rec);
      rethrow;
    }
  }

  /// Resolve a persisted record on entry/restart. Returns null when there is nothing to surface:
  ///   • no record, OR an in-flight record YOUNGER than the LSP's 90s timeout (a live POST in this
  ///     process may still be racing it — its own sheet is the surface);
  ///   • an old in-flight record whose receipt trail PROVES it settled (cleared silently, verdict
  ///     [LnStaleVerdict.settled] so the caller may refresh balances).
  /// Otherwise the verdict carries the record for the "did not settle · funds are safe" banner —
  /// honest, because a pure-LN take commits nothing client-side.
  static Future<LnStaleVerdict?> resolveStale({int? nowMs}) async {
    final rec = await LnTakeStore.load();
    if (rec == null) return null;
    if (!rec.failed) {
      final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      if (now - rec.startedMs < kLnLspTimeoutMs) return null; // may still be live in-process
      // RECEIPT TRAIL: a settled take logged an 'ln:<preimage>' receipt at settle time. Match by the
      // id prefix + a timestamp at/after the take started + the base ticker in the title.
      final tk = SeqAssets.labelFor(rec.asset).ticker;
      final startedS = rec.startedMs ~/ 1000;
      List<TradeReceipt> receipts;
      try {
        receipts = await TradeReceipts.list();
      } catch (_) {
        receipts = const [];
      }
      final settled = receipts.any((r) => r.id.startsWith('ln:') && r.ts >= startedS - 2 && r.title.contains(tk));
      if (settled) {
        await LnTakeStore.clear();
        return LnStaleVerdict(record: rec, settled: true);
      }
    }
    return LnStaleVerdict(record: rec, settled: false);
  }

  /// Dismiss the surfaced record (nothing was committed — pure-LN holds no client-side funds).
  static Future<void> dismiss() => LnTakeStore.clear();

  static double _pow10(int n) {
    var v = 1.0;
    for (var i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }
}
