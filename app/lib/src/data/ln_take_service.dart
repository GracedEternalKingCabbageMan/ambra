// ---------------------------------------------------------------------------
// ln_take_service.dart — the COMPOSER-NATIVE pure-LN take (BTC<->asset AND asset<->asset), the mobile
// twin of the web wallet's swap.js requote-ln + reviewLn. One service owns the whole seam so the
// composer and any legacy entry point ([LightningSwapScreen]) build the /swap request the SAME way:
//
//   • PIN the best resting offer from /lnbook BEFORE review, so the sheet prices the EXACT offer the
//     LSP then lifts (offer_id + maker_pubkey travel on the POST) — never a relay-arbitrary one.
//   • SLICE truth: the take lifts min(typed, offer) of the pinned offer ([priceSlice] is the ONE
//     authority for the slice math, mirroring the LSP's Go settlement driver exactly: the counter leg
//     is FLOOR on a buy / CEIL on a sell of offerQuote·take/offerAsset). `take_atoms` carries the
//     slice on the POST; absent/0 = the whole offer (the maker re-rests the remainder of a slice).
//     The review shows the SLICE's amounts as "You pay / You receive" (review == execution); only a
//     typed size AT/ABOVE the offer keeps the whole-offer display, with the loud cap note when it
//     deviates by more than [kLnSizeNoteFractionPct].
//   • PERSIST-BEFORE-POST: a single-slot record ('ambra.ln.active') is written BEFORE the irreversible
//     POST and cleared on success (the receipt is written as before) or marked failed on error. Pure-LN
//     commits nothing client-side — an unsettled take costs nothing — so a stale record resolves by
//     re-checking the local receipt trail, never by inventing recovery machinery.
//
// Amounts are BigInt atoms of each leg's OWN asset (BTC leg = sats — [LnOffer] carries sats, never
// msat, so sats/atoms are the one unit authority end-to-end); display formatting stays with the caller.
// ---------------------------------------------------------------------------

import 'config.dart';
import 'format.dart';
import 'lightning_service.dart';
import 'lsp_client.dart';
import 'trade_receipts.dart';
import 'trade_slots.dart';

/// The LSP's /swap timeout (LspClient.swap posts with a 90s timeout). A persisted in-flight record OLDER
/// than this can no longer be racing a live POST in any process, so restart-resolution may judge it.
const int kLnLspTimeoutMs = 90 * 1000;

/// The offer-vs-typed size deviation (percent) above which the review shows the loud mismatch note
/// (mirror web reviewLn's 0.05 threshold).
const double kLnSizeNoteFractionPct = 5.0;

/// The priced SLICE of a pinned pure-LN offer — what actually moves on the wire. THE one client-side
/// authority for the partial-take math, mirroring the LSP's Go settlement driver EXACTLY (both sides
/// derive the same legs from the signed offer):
///
///   take       = min(requestedAtoms, offer.assetAtoms)          (asset atoms; the base leg)
///   counter    = FLOOR(offer.btcAtoms · take / offer.assetAtoms) when the taker BUYS (gives BTC/quote)
///              = CEIL (offer.btcAtoms · take / offer.assetAtoms) when the taker SELLS (receives BTC/quote)
///
/// Units are exactly what [LnOffer] carries: asset atoms and BTC SATS (or quote-asset atoms for
/// asset<->asset) — the offer model carries no msat, so no ×1000 shadow-unit ever enters the math.
/// A [whole] slice reproduces the offer's OWN legs verbatim (no derived rounding): `take_atoms` then
/// stays OFF the wire and the LSP lifts in full, exactly today's behavior.
class LnSlice {
  const LnSlice({required this.assetAtoms, required this.quoteAtoms, required this.whole});

  /// The base leg that moves (asset atoms). Equals the offer's base leg when [whole].
  final BigInt assetAtoms;

  /// The counter leg that moves (BTC sats, or quote-asset atoms). Equals the offer's counter leg
  /// verbatim when [whole]; floor/ceil-derived otherwise.
  final BigInt quoteAtoms;

  /// True = the whole offer lifts (`take_atoms` stays off the POST; today's wire shape).
  final bool whole;

  /// A partial slice whose counter leg priced to ZERO is dust — nothing can settle a 0-sat leg, so
  /// the caller must refuse honestly BEFORE anything persists or posts.
  bool get dust => !whole && quoteAtoms <= BigInt.zero;
}

/// The single-slot persisted state of one composer-native pure-LN take. Written BEFORE the POST; pure-LN
/// commits nothing client-side, so the record exists only to make an interrupted take VISIBLE (settled
/// via the receipt trail, or honestly "did not settle · funds are safe") — it holds no reclaim material.
class LnTakeRecord {
  LnTakeRecord({
    String? id,
    required this.state,
    required this.side,
    required this.asset,
    this.quoteAsset,
    this.offerId,
    this.makerPubkey,
    required this.assetAtoms,
    required this.quoteAtoms,
    BigInt? takeAtoms,
    required this.startedMs,
    this.detail = '',
  })  : takeAtoms = takeAtoms ?? BigInt.zero,
        id = id ?? newTradeId();

  /// Stable per-record id (multi-record store).
  final String id;
  String state; // 'inflight' | 'failed'
  final String side; // 'buy' (quote -> base) | 'sell' (base -> quote)
  final String asset; // the BASE asset id (hex)
  final String? quoteAsset; // the counter asset for asset<->asset; null = BTC implied
  final String? offerId; // the pinned resting offer
  final String? makerPubkey;
  final BigInt assetAtoms; // the base leg that actually moves (the slice's leg; = the offer's when whole)
  final BigInt quoteAtoms; // the counter leg that actually moves (BTC sats, or quote-asset atoms)
  final BigInt takeAtoms; // the `take_atoms` sent on the POST (zero = whole-offer lift, today's wire)
  final int startedMs; // wall-clock ms at persist (immediately before the POST)
  String detail;

  bool get failed => state == 'failed';

  Map<String, dynamic> toJson() => {
        'id': id,
        'state': state,
        'side': side,
        'asset': asset,
        'quote_asset': quoteAsset,
        'offer_id': offerId,
        'maker_pubkey': makerPubkey,
        'asset_atoms': assetAtoms.toString(),
        'quote_atoms': quoteAtoms.toString(),
        'take_atoms': takeAtoms.toString(),
        'started_ms': startedMs,
        'detail': detail,
      };

  static LnTakeRecord fromJson(Map<String, dynamic> j) => LnTakeRecord(
        id: '${j['id'] ?? ''}'.isEmpty ? null : '${j['id']}',
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
        // Absent on legacy records = zero = a whole-offer lift (exactly what those takes were).
        takeAtoms: BigInt.tryParse('${j['take_atoms'] ?? 0}') ?? BigInt.zero,
        startedMs: (j['started_ms'] as num?)?.toInt() ?? 0,
        detail: '${j['detail'] ?? ''}',
      );
}

/// The multi-record store for pure-LN takes (list under a new key, one-time adoption of the legacy
/// 'ambra.ln.active'), secure storage like its rail siblings. Pure-LN records protect no funds and do
/// NOT count toward the shared trade-slot bound — they exist only to keep interrupted takes VISIBLE.
class LnTakeStore {
  LnTakeStore._();
  static final TradeListStore _list = TradeListStore(listKey: 'ambra.ln.takes', legacyKey: 'ambra.ln.active');

  /// Every persisted take record (undecodable entries skipped; a pure-LN record protects no funds).
  static Future<List<LnTakeRecord>> loadAll() async {
    List<Map<String, dynamic>> entries;
    try {
      entries = (await _list.readAll()).entries;
    } catch (_) {
      return const []; // undecodable blob: nothing recoverable rides on it (deliberately tolerant)
    }
    final out = <LnTakeRecord>[];
    for (final e in entries) {
      try {
        out.add(LnTakeRecord.fromJson(e));
      } catch (_) {/* skip */}
    }
    return out;
  }

  /// Compat single-record read: the most recent record (by [id] when given).
  static Future<LnTakeRecord?> load({String? id}) async {
    final all = await loadAll();
    if (all.isEmpty) return null;
    if (id != null && id.isNotEmpty) {
      for (final r in all) {
        if (r.id == id) return r;
      }
      return null;
    }
    return all.first;
  }

  static Future<void> save(LnTakeRecord r) => _list.upsert(r.toJson());

  /// Remove ONE record by id.
  static Future<void> remove(String id, {String reason = 'unspecified'}) =>
      _list.removeById(id, reason: reason);

  /// TEST-ONLY full wipe.
  static Future<void> clear() => _list.wipeAll();
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

  /// Price the SLICE of [offer] that a request for [requestedAtoms] base-asset atoms lifts — the ONE
  /// authority both the Review sheet and [take] consume (review == execution), mirroring the LSP's Go
  /// settlement driver EXACTLY. PURE, BigInt throughout (no double ever touches the legs):
  ///
  ///   take = min(requestedAtoms, offer.assetAtoms); null / <= 0 / >= the offer lifts WHOLE — the
  ///   offer's OWN legs verbatim, no derived rounding (today's behavior, `take_atoms` off the wire).
  ///   Partial counter leg: [side] 'buy' (taker BUYS the asset, gives BTC/quote) = FLOOR of
  ///   offer.btcAtoms·take/offer.assetAtoms; 'sell' (taker receives BTC/quote) = CEIL.
  ///
  /// Units = what [LnOffer] carries: asset atoms + BTC sats (or quote-asset atoms); never msat.
  /// A partial whose counter leg prices to zero comes back [LnSlice.dust] — refuse it before anything
  /// persists or posts.
  static LnSlice priceSlice({required String side, required LnOffer offer, BigInt? requestedAtoms}) {
    final offerAsset = offer.assetAtoms, offerQuote = offer.btcAtoms;
    if (requestedAtoms == null ||
        requestedAtoms <= BigInt.zero ||
        offerAsset <= BigInt.zero ||
        requestedAtoms >= offerAsset) {
      // WHOLE: the offer's exact legs (the min() cap for an oversized request lands here too).
      return LnSlice(assetAtoms: offerAsset, quoteAtoms: offerQuote, whole: true);
    }
    final take = requestedAtoms; // min(requested, offer) — the >= branch returned above
    final prod = offerQuote * take;
    final quote = side == 'buy'
        ? prod ~/ offerAsset // taker gives BTC/quote: FLOOR
        : (prod + offerAsset - BigInt.one) ~/ offerAsset; // taker receives BTC/quote: CEIL
    return LnSlice(assetAtoms: take, quoteAtoms: quote, whole: false);
  }

  /// PIN the best resting offer for (base [asset], [quoteAsset]) on [side] from the LSP's /lnbook —
  /// the pre-Review read whose offer the POST then lifts in full. Never throws (lnBook is tolerant).
  static Future<LnPinVerdict> pinBest({required String side, required String asset, String? quoteAsset}) async {
    final book = await LightningService.instance.lnBook(asset, quoteAsset: quoteAsset);
    return LnPinVerdict(offer: book.best(side), served: book.raw.isNotEmpty);
  }

  /// Execute the reviewed take: PERSIST the single-slot record, resolve the user's OWN node keys
  /// (self-custody — the LSP drives the swap on THEM), then POST /swap pinning [offer]. Clears the
  /// record + writes the receipt on success; marks it failed on error and rethrows. [requestedAtoms]
  /// is the typed base-asset size: [priceSlice] turns it into the slice that actually moves —
  /// `take_atoms` rides the POST for a partial (the LSP passes it to the settlement driver; the maker
  /// re-rests the remainder) and stays OFF the wire for a whole lift (today's shape). A dust slice
  /// (counter leg priced to zero) throws BEFORE anything persists or posts. [typedAmount] is the
  /// display string the user typed (forwarded to the LSP as before). [offer] is null ONLY on the
  /// legacy fall-through where the LSP's /lnbook is unreachable and the LSP does its own matching
  /// ([LightningSwapScreen]'s no-regression path); the composer always pins.
  static Future<LspSwapResult> take({
    required String side,
    required String asset,
    String? quoteAsset,
    LnOffer? offer,
    BigInt? requestedAtoms,
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

    // THE slice (the one authority — the review sheet showed exactly this). Null offer = the legacy
    // LSP-matches path, which stays whole (no offer to slice against). Dust refuses HERE, before the
    // record persists and before anything posts — an honest client-side stop, nothing moved.
    final slice = offer == null ? null : priceSlice(side: side, offer: offer, requestedAtoms: requestedAtoms);
    if (slice != null && slice.dust) {
      throw Exception('That amount is too small to price against the resting offer · enter a larger amount.');
    }

    // PERSIST BEFORE THE IRREVERSIBLE POST: the record is what makes an interrupted take visible.
    // The persisted legs are the SLICE's (what actually moves); take_atoms zero = a whole lift.
    final rec = LnTakeRecord(
      state: 'inflight',
      side: side,
      asset: asset,
      quoteAsset: quoteAsset,
      offerId: offer?.offerId,
      makerPubkey: offer?.makerPubkey,
      assetAtoms: slice?.assetAtoms ?? BigInt.zero,
      quoteAtoms: slice?.quoteAtoms ?? BigInt.zero,
      takeAtoms: (slice != null && !slice.whole) ? slice.assetAtoms : BigInt.zero,
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
        // The slice on the wire: integer base-asset atoms; absent (null) = whole (today's behavior).
        takeAtoms: rec.takeAtoms > BigInt.zero ? rec.takeAtoms : null,
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
      await LnTakeStore.remove(rec.id, reason: 'pure-LN take settled');
      return r;
    } catch (e) {
      rec
        ..state = 'failed'
        ..detail = e.toString().replaceFirst('Exception: ', '');
      await LnTakeStore.save(rec);
      rethrow;
    }
  }

  /// Resolve EVERY persisted record on entry/restart (multi-record store). A record contributes no
  /// verdict when:
  ///   • it is in-flight and YOUNGER than the LSP's 90s timeout (a live POST in this process may still
  ///     be racing it — its own sheet is the surface);
  ///   • its receipt trail PROVES it settled (cleared silently; the settled verdict is returned so the
  ///     caller may refresh balances).
  /// Every other record yields the "did not settle · funds are safe" banner verdict — honest, because
  /// a pure-LN take commits nothing client-side.
  static Future<List<LnStaleVerdict>> resolveStaleAll({int? nowMs}) async {
    final recs = await LnTakeStore.loadAll();
    final out = <LnStaleVerdict>[];
    for (final rec in recs) {
      final v = await _resolveOne(rec, nowMs: nowMs);
      if (v != null) out.add(v);
    }
    return out;
  }

  /// Compat single-verdict resolve: the first surfaced verdict, if any.
  static Future<LnStaleVerdict?> resolveStale({int? nowMs}) async {
    final all = await resolveStaleAll(nowMs: nowMs);
    return all.isEmpty ? null : all.first;
  }

  static Future<LnStaleVerdict?> _resolveOne(LnTakeRecord rec, {int? nowMs}) async {
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
        await LnTakeStore.remove(rec.id, reason: 'stale check: receipt shows the take settled');
        return LnStaleVerdict(record: rec, settled: true);
      }
    }
    return LnStaleVerdict(record: rec, settled: false);
  }

  /// Dismiss ONE surfaced record (nothing was committed — pure-LN holds no client-side funds).
  static Future<void> dismiss(LnTakeRecord rec) =>
      LnTakeStore.remove(rec.id, reason: 'user dismissed (pure-LN holds no client-side funds)');

  static double _pow10(int n) {
    var v = 1.0;
    for (var i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }
}
