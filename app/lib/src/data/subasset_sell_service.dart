import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import 'api_client.dart';
import 'config.dart';
import 'lightning_service.dart';
import 'lsp_client.dart';
import 'trade_receipts.dart';
import 'store_log.dart';
import 'trade_slots.dart';
import 'wallet_repository.dart';

/// A conservative fee (sats) for the legacy-P2SH BTC HTLC claim spend (~200 vB at ~2 sat/vB),
/// matching the reverse cross-chain claim. The claim pays `amount - fee` to a fresh wallet address.
final BigInt _kClaimFeeSats = BigInt.from(440);

/// Local, taker-centric state of an in-flight sub-asset SELL (pay a Sequentia asset over Lightning,
/// receive Bitcoin on-chain). The wallet is the source of truth (the maker/LSP state is in-memory and
/// dies on restart), so this is persisted after every transition.
///
/// FUND DISCIPLINE: the asset is paid FIRST over Lightning (claim-or-lose — there is NO BTC refund
/// path in this direction; once the maker reveals the preimage the BTC HTLC is ours to claim). So the
/// preimage + the maker's BTC HTLC terms are persisted at [SubSellStep.claiming] BEFORE the first
/// on-chain claim, and [SubassetSellService.resume] re-attempts the claim idempotently on reload.
enum SubSellStep {
  paying, // about to pay / paying the asset over Lightning; PERSISTED with a swap_nonce BEFORE the pay
  // so a lost response (asset possibly paid) is recoverable by re-calling the swap with the same nonce
  claiming, // asset paid + preimage known; claiming the BTC HTLC on-chain (the recovery window)
  done, // BTC claimed; swap complete
  failed,
}

class SubSellRecord {
  SubSellRecord({
    String? id,
    required this.step,
    required this.asset,
    required this.ticker,
    required this.expectedBtc,
    this.quoteAsset,
    this.preimage = '',
    this.hashHex = '',
    this.btcLeg,
    this.swapNonce,
    this.amount,
    this.btcClaimPub,
    this.offerId,
    this.makerPubkey,
    this.startedMs,
    this.claimTxid = '',
    this.shortfall = false,
  }) : id = id ?? newTradeId();

  /// Stable per-record id (multi-record store): every save upserts on it, so a second sell can never
  /// overwrite this record's preimage/HTLC terms (the recovery handle).
  final String id;
  SubSellStep step;
  final String asset; // the Sequentia asset paid over Lightning
  final String ticker;

  /// MIXED same-chain: the claim leg's REAL asset — the maker's HTLC is on this Sequentia asset instead
  /// of Bitcoin, with [expectedBtc] / [SubBtcHtlc.amount] carrying QUOTE ATOMS and [SubBtcHtlc.tBtc] a
  /// SEQUENTIA height (the LSP contract labels them btc_* regardless). Null = the BTC shape, unchanged.
  final String? quoteAsset;
  final String preimage; // NOT HD-derivable — the recovery-critical secret (claims the BTC); '' at 'paying'
  final String hashHex; // '' until the maker returns it (known from 'claiming' on)
  final SubBtcHtlc? btcLeg; // the maker's BTC HTLC the taker claims with [preimage]; null at 'paying'
  final BigInt expectedBtc; // the BTC the offer quoted (economic gate); 0 when no offer was attached
  // Recovery fields for the 'paying' step (asset possibly paid, response lost): everything needed to
  // RE-CALL swapSub with the SAME [swapNonce] so the LSP returns the settle idempotently, without
  // re-paying the asset. All null on records written before this recovery mechanism existed.
  final String? swapNonce; // the idempotency key sent to the LSP
  final num? amount; // the sell amount, to re-issue the swap
  final String? btcClaimPub; // our device claim pubkey (also re-derivable from the mnemonic)
  final String? offerId;
  final String? makerPubkey;
  final int? startedMs; // wall-clock ms when 'paying' began (bounds the recovery TTL)
  String claimTxid;
  bool shortfall; // the on-chain HTLC value came in below [expectedBtc] (claimed anyway, flagged)

  /// The BTC value actually locked in the maker's HTLC (what the claim recovers). Zero until known.
  BigInt get gotBtc => btcLeg?.amount ?? BigInt.zero;

  Map<String, dynamic> toJson() => {
        'id': id,
        'step': step.name,
        'asset': asset,
        'ticker': ticker,
        'quoteAsset': quoteAsset,
        'preimage': preimage,
        'hashHex': hashHex,
        'btcLeg': btcLeg?.toJson(),
        'expectedBtc': expectedBtc.toString(),
        'claimTxid': claimTxid,
        'shortfall': shortfall,
        'swapNonce': swapNonce,
        'amount': amount,
        'btcClaimPub': btcClaimPub,
        'offerId': offerId,
        'makerPubkey': makerPubkey,
        'startedMs': startedMs,
      };

  static SubSellRecord fromJson(Map<String, dynamic> j) => SubSellRecord(
        id: '${j['id'] ?? ''}'.isEmpty ? null : '${j['id']}',
        step: SubSellStep.values.firstWhere((s) => s.name == j['step'], orElse: () => SubSellStep.failed),
        asset: '${j['asset']}',
        ticker: '${j['ticker']}',
        quoteAsset: (j['quoteAsset'] is String && (j['quoteAsset'] as String).isNotEmpty)
            ? j['quoteAsset'] as String
            : null,
        preimage: '${j['preimage'] ?? ''}',
        hashHex: '${j['hashHex'] ?? ''}',
        btcLeg: j['btcLeg'] is Map ? SubBtcHtlc.fromJson(j['btcLeg'] as Map) : null,
        expectedBtc: BigInt.tryParse('${j['expectedBtc'] ?? 0}') ?? BigInt.zero,
        claimTxid: '${j['claimTxid'] ?? ''}',
        shortfall: j['shortfall'] == true,
        swapNonce: (j['swapNonce'] is String && (j['swapNonce'] as String).isNotEmpty) ? j['swapNonce'] as String : null,
        amount: j['amount'] is num ? j['amount'] as num : null,
        btcClaimPub: j['btcClaimPub'] is String ? j['btcClaimPub'] as String : null,
        offerId: j['offerId'] is String ? j['offerId'] as String : null,
        makerPubkey: j['makerPubkey'] is String ? j['makerPubkey'] as String : null,
        startedMs: j['startedMs'] is num ? (j['startedMs'] as num).toInt() : null,
      );

  /// True while a sell is in flight and its recovery handle must be protected: either the asset has
  /// been paid and the BTC claim has not confirmed ('claiming'), or the asset MAY have been paid but
  /// the swap response was lost ('paying'). [SubassetSellService.resume] advances/recovers both.
  bool get inFlight => step == SubSellStep.claiming || step == SubSellStep.paying;
}

/// Persists the active sub-asset SELLs — a MULTI-RECORD list (web SELLS array) under a NEW key, with
/// one-time never-lossy adoption of the legacy single-slot record ('ambra.subasset.sell.active'). Each
/// record carries the preimage (the only thing that claims the BTC), so it lives in secure storage;
/// every save upserts by [SubSellRecord.id]. A distinct key from the BUY store so the two never mix.
class SubSellStore {
  SubSellStore._();
  static final TradeListStore _list =
      TradeListStore(listKey: 'ambra.subasset.sells', legacyKey: 'ambra.subasset.sell.active');

  /// Every persisted sell record. Undecodable entries are skipped here but PRESERVED on disk.
  static Future<List<SubSellRecord>> loadAll() async {
    final read = await _list.readAll();
    final out = <SubSellRecord>[];
    for (final e in read.entries) {
      try {
        out.add(SubSellRecord.fromJson(e));
      } catch (_) {/* preserved on disk; not drivable by this build */}
    }
    return out;
  }

  /// The sells still protecting a recovery handle (paying/claiming) — guard + cards + resume iterate these.
  static Future<List<SubSellRecord>> activeAll() async =>
      (await loadAll()).where((r) => r.inFlight).toList();

  /// Compat single-record read: by [id] when given, else the first in-flight, else the most recent.
  static Future<SubSellRecord?> load({String? id}) async {
    final all = await loadAll();
    if (all.isEmpty) return null;
    if (id != null && id.isNotEmpty) {
      for (final r in all) {
        if (r.id == id) return r;
      }
      return null;
    }
    for (final r in all) {
      if (r.inFlight) return r;
    }
    return all.first;
  }

  static Future<void> save(SubSellRecord r) => _list.upsert(r.toJson());

  /// Remove ONE record by id (a finished sell, or a definitively-dead 'paying' stub). [reason] is
  /// logged loudly by the substrate — a sell-record removal must never be silent.
  static Future<void> remove(String id, {String reason = 'unspecified'}) =>
      _list.removeById(id, reason: reason);

  /// Drop terminal records before starting a new sell (bounded-list hygiene). A record still in
  /// flight — even 'paying' (asset possibly paid) — is NEVER pruned.
  static Future<void> pruneSettled() => _list.removeWhere(reason: 'pruneSettled: finished sell', (e) {
        try {
          return !SubSellRecord.fromJson(e).inFlight;
        } catch (_) {
          return false; // undecodable: keep — it may represent a live trade
        }
      });

  /// TEST-ONLY full wipe.
  static Future<void> clear() => _list.wipeAll();
}

/// Drives the sub-asset SELL from LOCAL state: pay the asset over Lightning, then CLAIM the maker's
/// BTC HTLC on-chain with the revealed preimage. The on-chain claim is built by the audited core FFI
/// ([core.xchainBtcClaim] — the proven legacy-P2SH spend), never hand-rolled. Each method advances one
/// step and persists; [resume] re-runs the claim idempotently after a reload.
class SubassetSellService {
  SubassetSellService._();

  /// Synchronous in-flight sentinel closing the TOCTOU window the async [hasInFlight] leaves open:
  /// the asset is paid INSIDE [begin]'s swapSub, so a second [begin] slipping in before the record is
  /// persisted would pay a SECOND time and overwrite the single preimage handle. Checked-and-set
  /// atomically at the top of [begin] (no await between), cleared in its finally. Mirrors the web's
  /// `_sellStarting`.
  static bool _starting = false;

  /// After this long a still-'paying' record can't complete (any unsettled Lightning payment has
  /// auto-returned past its own timeout), so [resume] clears it rather than re-attempting forever.
  static const int _kPayingTtlMs = 24 * 60 * 60 * 1000;

  static Future<String> _mnemonic() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw Exception('wallet unavailable');
    return m;
  }

  /// A fresh 32-byte random hex idempotency key for a sub-asset sell (CSPRNG). Persisted in the
  /// 'paying' record BEFORE the asset-paying swapSub and re-sent on recovery so the LSP returns the
  /// already-settled result without re-paying the asset. Mirrors the web wallet's `newSwapNonce`.
  static String _newSwapNonce() {
    final r = Random.secure();
    final b = List<int>.generate(32, (_) => r.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Heuristic: did the swap call fail in a way that means the request MAY have completed server-side
  /// (a LOST RESPONSE — network / timeout / connection error) rather than a DEFINITIVE LSP rejection
  /// (a decoded ok:false body, thrown as a bare Exception by [LspClient])? Fund-safety leans KEEP: the
  /// 'paying' record is discarded only when we are confident no asset was paid.
  static bool _payMayHaveCompleted(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('socketexception') ||
        s.contains('clientexception') ||
        s.contains('httpexception') ||
        s.contains('timeout') ||
        s.contains('timed out') ||
        s.contains('connection') ||
        s.contains('failed host lookup') ||
        s.contains('network') ||
        s.contains('handshake') ||
        s.contains('broken pipe') ||
        s.contains('reset by peer') ||
        s.contains('connection refused');
  }

  /// True while any sell is persisted with its BTC claim not yet confirmed. With the multi-record
  /// store this no longer hard-blocks a second sell (records upsert by id); the shared [TradeSlots]
  /// bound gates new dispatches.
  static Future<bool> hasInFlight() async => (await SubSellStore.activeAll()).isNotEmpty;

  /// Pay the asset over Lightning, learn the preimage + the maker's BTC HTLC terms, PERSIST them, then
  /// claim the BTC on-chain. FUND-SAFETY: the asset is paid inside [LightningService.swapSub]; the
  /// moment it settles we hold the only recovery handle (the preimage), so we persist BEFORE the first
  /// claim and [resume] re-attempts it. Refuses to start while another sell's BTC claim is unconfirmed.
  static Future<SubSellRecord> begin(
      {required String asset, required num amount, SubOffer? offer, String? quoteAsset}) async {
    // FUND-SAFETY self-guard: a second sell would pay the asset again + overwrite the persisted
    // preimage/HTLC — the single handle to the claimable BTC. The sync sentinel is checked-and-set
    // atomically (no await between) so a concurrent begin can't slip through before the persist below.
    if (_starting) {
      throw Exception('A sub-asset sell is already starting; wait for it to finish.');
    }
    _starting = true;
    try {
      // SHARED SLOT GATE (web buySlotsFree): a second sell can no longer overwrite the persisted
      // preimage/HTLC (records upsert by id), so the single-slot hard refusal is replaced by the
      // bounded concurrent-trade count. Prune finished records first so they never eat a slot.
      await SubSellStore.pruneSettled();
      final refusal = await TradeSlots.refusalIfFull();
      if (refusal != null) throw Exception(refusal);
      final m = await _mnemonic();
      final ticker = SeqAssets.labelFor(asset).ticker;
      final qh = (quoteAsset != null && quoteAsset.isNotEmpty) ? quoteAsset : null;
      // The device CLAIM key — only we can claim the maker's on-chain HTLC. The maker embeds it as the
      // IF/claim key so the LSP (keyless) can never take the funds. MIXED same-chain: the claim leg is
      // the QUOTE asset on Sequentia, so the key is the wallet's canonical SEQ claim key (mirror web
      // startSell's `qh ? seqLeg.claimKey() : btcLeg.claimKey()`).
      final btcClaimPub = qh != null
          ? await core.xchainSeqClaimPubkey(mnemonic: m)
          : await core.xchainBtcClaimPubkey(mnemonic: m);
      // Bring our OWN hosted asset node's device signer online so the LSP can command the LN pay.
      final nodeKey = await LightningService.instance.connectNode(m, asset: asset);
      // FUND-SAFETY: the asset is paid INSIDE swapSub. Persist a PENDING ('paying') record carrying a
      // fresh nonce + everything needed to RE-CALL swapSub, BEFORE that call. If its response is lost
      // after the LSP already paid the asset, resume() re-calls with this SAME nonce and the LSP
      // returns the settled result idempotently (it never re-pays for a stored nonce).
      final swapNonce = _newSwapNonce();
      final paying = SubSellRecord(
        step: SubSellStep.paying,
        asset: asset,
        ticker: ticker,
        expectedBtc: offer?.btcSats ?? BigInt.zero,
        quoteAsset: qh,
        swapNonce: swapNonce,
        amount: amount,
        btcClaimPub: btcClaimPub,
        offerId: offer?.offerId,
        makerPubkey: offer?.makerPubkey,
        startedMs: DateTime.now().millisecondsSinceEpoch,
      );
      await SubSellStore.save(paying);
      var paidCallStarted = false;
      try {
        // Pay the asset over Lightning; on settle the maker reveals the preimage, returned WITH the BTC
        // HTLC terms. The LSP never claims (no claim key) — we claim on-chain ourselves.
        paidCallStarted = true; // from here a lost response means the asset MAY be paid -> keep for recovery
        final resp = await LightningService.instance.swapSub(
          side: 'sell',
          asset: asset,
          nodeKey: nodeKey,
          amount: amount,
          // State the rails EXPLICITLY (asset over LN, BTC on-chain) so the LSP routes this to the
          // sub-asset SELL, not the pure-LN default.
          payRail: 'ln',
          recvRail: 'chain',
          btcClaimPub: btcClaimPub,
          offerId: offer?.offerId,
          makerPubkey: offer?.makerPubkey,
          swapNonce: swapNonce,
          quoteAsset: qh, // mixed same-chain: the claim leg's REAL asset (absent = BTC)
        );
        final s = resp.settle;
        if (!(s.settled && s.preimage.isNotEmpty && s.btcHtlc != null)) {
          throw Exception('The sell did not settle over Lightning.');
        }
        // PERSIST BEFORE the on-chain claim: the asset is now paid, so the BTC claim is the fund step and
        // MUST survive a reload — resume() re-attempts it from here. SAME id as the 'paying' record, so
        // the upsert REPLACES it in place (never a second record for the same trade).
        final rec = SubSellRecord(
          id: paying.id,
          step: SubSellStep.claiming,
          asset: asset,
          ticker: ticker,
          preimage: s.preimage,
          hashHex: s.hashHex.isNotEmpty ? s.hashHex : s.btcHtlc!.raw['hash_h']?.toString() ?? '',
          btcLeg: s.btcHtlc!,
          expectedBtc: offer?.btcSats ?? BigInt.zero,
          quoteAsset: qh,
          swapNonce: swapNonce,
        );
        await SubSellStore.save(rec);
        await claim(rec); // verify + claim; mutates + persists rec
        return rec;
      } catch (e) {
        // A LOST RESPONSE (network error after we may have paid) KEEPS the 'paying' record so resume()
        // recovers via the nonce; a DEFINITIVE rejection (LSP ok:false — the sell never settled) means
        // NO asset was paid, so discard THIS record by id (never the whole store — other sells' records
        // are their own trades' recovery handles).
        if (paidCallStarted && !_payMayHaveCompleted(e)) {
          final cur = await SubSellStore.load(id: paying.id);
          if (cur != null && cur.step == SubSellStep.paying) {
            await SubSellStore.remove(paying.id,
                reason: 'begin: pay call failed before the asset could have been paid');
          }
        }
        rethrow;
      }
    } finally {
      _starting = false;
    }
  }

  /// Independently VERIFY the maker's BTC HTLC binds OUR claim key + H before trusting it: rebuild the
  /// redeemScript from (H, our claim key, the maker refund key, T_btc) and byte-compare it to the
  /// reported script, confirm our preimage hashes to H, and confirm the funding output exists on-chain
  /// with the expected vout + value. Throws on any mismatch — never claim into a leg we can't spend.
  static Future<void> verifyClaimable(SubSellRecord rec) async {
    final m = await _mnemonic();
    final h = rec.btcLeg;
    if (h == null) throw Exception('No BTC HTLC to verify (the sell has not settled yet).');
    // The preimage must hash to H on BOTH shapes — never claim with a secret that can't spend the leg.
    final digest = sha256.convert(_hexBytes(rec.preimage)).toString();
    if (digest.toLowerCase() != rec.hashHex.toLowerCase()) {
      throw Exception('The revealed preimage does not hash to H.');
    }
    if (rec.quoteAsset != null) {
      // MIXED same-chain: the claim leg is the QUOTE asset on Sequentia (mirror web claimSell's qh
      // branch). Rebuild the forward HTLC from OUR inputs (claim = our canonical SEQ key), then bind
      // the reported outpoint to a REAL on-chain output: script + asset + amount, from OUR esplora.
      final ours = (await core.xchainSeqClaimPubkey(mnemonic: m)).toLowerCase();
      if (h.takerClaimPubkey.toLowerCase() != ours) {
        throw Exception('The on-chain lock is not bound to this wallet\'s claim key.');
      }
      final rebuilt = await core.xchainSeqHtlcForward(
        mnemonic: m,
        hashHex: rec.hashHex,
        makerSeqRefundPubHex: h.makerRefundPubkey,
        seqLocktime: h.tBtc,
      );
      if (rebuilt.redeemScriptHex.toLowerCase() != h.redeemScript.toLowerCase()) {
        throw Exception('The on-chain lock\'s redeem script does not match H + the claim/refund keys.');
      }
      // A READ FAILURE IS NOT A MISMATCH: an unindexed tx is transient (the claim retries), a real
      // disagreement is fatal. The read is explicit-only, so a blinded/absent output fails closed.
      final out = await _seqOutput(h.txid, h.vout);
      if (out == null) {
        throw Exception('Could not read the counterparty\'s on-chain lock yet; retrying automatically.');
      }
      if ('${out['scriptpubkey'] ?? ''}'.toLowerCase() != rebuilt.p2ShSpkHex.toLowerCase()) {
        throw Exception('The counterparty\'s on-chain lock does not match this trade; not claiming.');
      }
      if ('${out['asset'] ?? ''}'.toLowerCase() != rec.quoteAsset!.toLowerCase()) {
        throw Exception('The counterparty\'s on-chain lock is in the wrong asset; not claiming.');
      }
      final value = BigInt.tryParse('${out['value'] ?? ''}');
      if (value == null || value != h.amount) {
        throw Exception('The counterparty\'s on-chain lock has the wrong amount; not claiming.');
      }
      return;
    }
    final ours = (await core.xchainBtcClaimPubkey(mnemonic: m)).toLowerCase();
    if (h.takerClaimPubkey.toLowerCase() != ours) {
      throw Exception('The BTC HTLC is not locked to this wallet\'s claim key.');
    }
    final rebuilt = await core.xchainBtcHtlc(
      hashHex: rec.hashHex,
      claimPubHex: h.takerClaimPubkey,
      refundPubHex: h.makerRefundPubkey,
      locktime: h.tBtc,
    );
    if (rebuilt.redeemScriptHex.toLowerCase() != h.redeemScript.toLowerCase()) {
      throw Exception('The BTC HTLC redeem script does not match H + the claim/refund keys.');
    }
    final f = await core.xchainFindBtcFunding(t4Api: Backend.testnet4, txid: h.txid, p2ShSpkHex: rebuilt.p2ShSpkHex);
    if (f.vout != h.vout) {
      throw Exception('The BTC HTLC funding output was not found on-chain.');
    }
    final onchain = BigInt.tryParse(f.valueSats);
    if (onchain != null && onchain != h.amount) {
      throw Exception('The BTC HTLC on-chain amount does not match the reported value.');
    }
  }

  /// CLAIM the maker's BTC HTLC with the preimage, to a fresh wallet address. Economic gate: if the
  /// on-chain HTLC is worth LESS than the quote ([SubSellRecord.expectedBtc]), we flag the shortfall
  /// but STILL claim — recovering the dust beats letting the maker refund it. Idempotent-ish: a
  /// duplicate claim of an already-spent HTLC just errors, which the caller surfaces.
  static Future<SubSellRecord> claim(SubSellRecord rec) async {
    // ECONOMIC gate (best-effort; only when an offer's quote was attached). verifyClaimable only
    // checks the HTLC's on-chain value equals what the LSP reported, NOT that it meets the quote, so a
    // shortchanging counterparty could hand back a dust HTLC after we already paid the asset over LN.
    if (rec.expectedBtc > BigInt.zero && rec.gotBtc < rec.expectedBtc && !rec.shortfall) {
      rec.shortfall = true;
      await SubSellStore.save(rec);
    }
    await verifyClaimable(rec);
    final m = await _mnemonic();
    final h = rec.btcLeg;
    if (h == null) throw Exception('No BTC HTLC to claim (the sell has not settled yet).');
    final dest = await core.receiveAddress(mnemonic: m); // our own tb1
    final String txid;
    if (rec.quoteAsset != null) {
      // MIXED same-chain: claim the QUOTE-asset HTLC on Sequentia with the preimage, the fee sized
      // per-asset from the published rate and paid in the claimed asset (the HTLC holds no native
      // tSEQ). Fail-closed fee sizing: an unmineable claim would linger while the maker's refund
      // matures — the throw keeps the record 'claiming' and the claim retries.
      final fee = await _seqClaimFee(rec.quoteAsset!, h.amount);
      final hex = await core.xchainSeqClaim(
        mnemonic: m,
        seqTxid: h.txid,
        seqVout: h.vout,
        seqAmount: h.amount,
        seqAssetId: rec.quoteAsset!,
        destAddress: dest,
        hashHex: rec.hashHex,
        makerSeqRefundPubHex: h.makerRefundPubkey,
        seqLocktime: h.tBtc,
        fee: fee,
        preimageHex: rec.preimage,
      );
      txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: hex);
    } else {
      final hex = await core.xchainBtcClaim(
        mnemonic: m,
        btcTxid: h.txid,
        btcVout: h.vout,
        btcAmountSats: h.amount,
        destAddress: dest,
        feeSats: _kClaimFeeSats,
        redeemScriptHex: h.redeemScript,
        preimageHex: rec.preimage,
      );
      txid = await core.btcBroadcast(t4Api: Backend.testnet4, txHex: hex);
    }
    rec
      ..claimTxid = txid
      ..step = SubSellStep.done;
    await SubSellStore.save(rec);
    final qtk = rec.quoteAsset != null ? SeqAssets.labelFor(rec.quoteAsset!).ticker : 'BTC';
    TradeReceipts.log(
      id: 'subsell:${rec.hashHex}',
      title: 'Sold ${rec.ticker} for $qtk',
      status: rec.shortfall ? '$qtk claimed (below quote)' : '$qtk claimed',
      txid: rec.claimTxid,
      pair: '${rec.ticker}/$qtk',
      side: 'sell',
      price: _fillPrice(rec),
    ).ignore();
    return rec;
  }

  /// The fill price in quote UNITS per base UNIT (receipt display). Null when a side is unknown.
  static double? _fillPrice(SubSellRecord rec) {
    final qprec = rec.quoteAsset != null ? SeqAssets.labelFor(rec.quoteAsset!).precision : 8;
    var q = 1.0;
    for (var i = 0; i < qprec; i++) {
      q *= 10;
    }
    final got = rec.gotBtc.toDouble() / q;
    final amt = (rec.amount ?? 0).toDouble();
    return (got > 0 && amt > 0) ? got / amt : null;
  }

  /// On wallet load / cold start: for EVERY persisted in-flight sell, re-attempt the claim (asset paid,
  /// preimage known) or the nonce-recovery (asset possibly paid, response lost). The fund-recovery
  /// path. Records are driven INDEPENDENTLY (concurrently) so one stuck counterparty never blocks
  /// another's claim (the web resumeSell over activeSells).
  static Future<void> resume() async {
    List<SubSellRecord> recs;
    try {
      recs = await SubSellStore.activeAll();
    } catch (e) {
      storeLog('sub-asset SELL resume: store UNREADABLE ($e) - nothing driven, records stay persisted');
      return; // unreadable store: records stay persisted for the next resume
    }
    storeLog('sub-asset SELL resume: ${recs.length} active record(s)'
        '${recs.isEmpty ? '' : ' [${recs.map((r) => '${r.id}:${r.step.name}').join(', ')}]'}');
    await Future.wait([for (final r in recs) _resumeOne(r).catchError((Object _) {})]);
  }

  /// Resume ONE persisted sell (the old single-record resume body, per record).
  static Future<void> _resumeOne(SubSellRecord rec) async {
    // (A) Asset paid + response received: preimage + HTLC persisted -> re-attempt the on-chain claim.
    if (rec.step == SubSellStep.claiming && rec.preimage.isNotEmpty) {
      try {
        await claim(rec);
      } catch (_) {
        // Leave persisted; the HTLC may already be claimed, or the claim needs a retry — surfaced when
        // the user re-enters the sub-asset SELL screen.
      }
      return;
    }
    // (B) Asset MAY have been paid but the swapSub response was LOST (a network blip after the LSP
    //     settled): 'paying' with a nonce, no preimage. RE-CALL swapSub with the SAME nonce — the LSP
    //     returns the already-settled result idempotently (never re-paying), then claim. This is the
    //     window that would otherwise LOSE the asset (paid, but with no preimage/HTLC to claim the BTC).
    if (rec.step == SubSellStep.paying && (rec.swapNonce?.isNotEmpty ?? false) && rec.preimage.isEmpty) {
      // Bounded: past the Lightning leg's own timeout any unsettled asset payment has auto-returned, so a
      // still-'paying' record this old can't complete — clear it rather than re-attempt (or re-run) forever.
      final startedMs = rec.startedMs ?? 0;
      if (startedMs > 0 && DateTime.now().millisecondsSinceEpoch - startedMs > _kPayingTtlMs) {
        // only THIS dead record; others keep their handles
        await SubSellStore.remove(rec.id,
            reason: 'resume: stale paying record past the Lightning-leg TTL - cannot complete');
        return;
      }
      try {
        final m = await _mnemonic();
        final asset = rec.asset;
        // Re-derive our claim key + bring our node online the SAME way begin does (deterministic):
        // the SEQ claim key for a mixed same-chain sell, the BTC claim key otherwise.
        final btcClaimPub = (rec.btcClaimPub != null && rec.btcClaimPub!.isNotEmpty)
            ? rec.btcClaimPub!
            : (rec.quoteAsset != null
                ? await core.xchainSeqClaimPubkey(mnemonic: m)
                : await core.xchainBtcClaimPubkey(mnemonic: m));
        final nodeKey = await LightningService.instance.connectNode(m, asset: asset);
        final resp = await LightningService.instance.swapSub(
          side: 'sell',
          asset: asset,
          nodeKey: nodeKey,
          amount: rec.amount,
          payRail: 'ln',
          recvRail: 'chain',
          btcClaimPub: btcClaimPub,
          offerId: rec.offerId,
          makerPubkey: rec.makerPubkey,
          swapNonce: rec.swapNonce,
          quoteAsset: rec.quoteAsset,
        );
        final s = resp.settle;
        if (!(s.settled && s.preimage.isNotEmpty && s.btcHtlc != null)) return; // not settled yet; keep for a later retry
        final claiming = SubSellRecord(
          id: rec.id, // upsert REPLACES the 'paying' record in place
          step: SubSellStep.claiming,
          asset: asset,
          ticker: rec.ticker,
          preimage: s.preimage,
          hashHex: s.hashHex.isNotEmpty ? s.hashHex : s.btcHtlc!.raw['hash_h']?.toString() ?? '',
          btcLeg: s.btcHtlc!,
          expectedBtc: rec.expectedBtc,
          quoteAsset: rec.quoteAsset,
          swapNonce: rec.swapNonce,
        );
        await SubSellStore.save(claiming);
        await claim(claiming);
      } catch (_) {
        // Leave the 'paying' record; its nonce keeps recovery idempotent on the next resume.
      }
      return;
    }
  }

  // -- Sequentia-side helpers (mixed same-chain claim leg) --------------------

  /// Output [vout] of Sequentia tx [txid] from OUR OWN esplora: `{scriptpubkey, asset, value}`.
  /// Null while the tx is unindexed / unreadable (transient — the caller retries), so a lagging
  /// backend is never reported as a mismatch.
  static Future<Map<String, dynamic>?> _seqOutput(String txid, int vout) async {
    try {
      final resp = await http
          .get(Uri.parse('${Backend.esplora}/tx/$txid'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final tx = jsonDecode(resp.body) as Map<String, dynamic>;
      final vouts = (tx['vout'] as List?) ?? const [];
      if (vout < 0 || vout >= vouts.length) return null;
      final o = vouts[vout];
      return o is Map ? Map<String, dynamic>.from(o) : null;
    } catch (_) {
      return null;
    }
  }

  /// The claim fee in atoms of the CLAIMED quote asset: the native policy fee converted at the asset's
  /// published rate, min 1 atom, capped at half the output. FAIL-CLOSED on a missing rate — an
  /// under-fee'd claim sits unmined while the maker's refund matures; the throw keeps the record
  /// 'claiming' and the claim retries (mirror XchainSwapService._seqClaimFee).
  static Future<BigInt> _seqClaimFee(String assetHex, BigInt amount) async {
    final ticker = SeqAssets.labelFor(assetHex).ticker;
    final rates = await ApiClient.feeRates();
    final scale = BigInt.from(100000000);
    final rate = rates[ticker] ?? rates[assetHex];
    if (rate == null || rate <= BigInt.zero) {
      throw Exception('No Sequentia fee rate for $ticker, so the claim fee cannot be sized safely; retrying.');
    }
    final native = BigInt.from(400); // ~vbytes at 1 sat/vB, matching the cross-swap sizing
    var fee = (native * scale + rate - BigInt.one) ~/ rate; // ceil(native * scale / rate)
    if (fee < BigInt.one) fee = BigInt.one;
    final half = amount ~/ BigInt.two;
    if (half >= BigInt.one && fee > half) fee = half;
    return fee;
  }
}

/// hex string -> bytes (for the sha256(preimage) == H check).
List<int> _hexBytes(String hex) {
  final s = hex.startsWith('0x') ? hex.substring(2) : hex;
  if (s.length.isOdd) throw const FormatException('odd-length hex');
  final out = List<int>.filled(s.length ~/ 2, 0);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
