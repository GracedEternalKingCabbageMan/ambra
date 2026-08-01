import 'dart:convert';

import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import 'api_client.dart';
import 'config.dart';
import 'lightning_service.dart';
import 'lsp_client.dart';
import 'trade_receipts.dart';
import 'trade_slots.dart';
import 'wallet_repository.dart';

/// T safety delta over the funding chain's current tip (parent-chain blocks for the BTC shape,
/// Sequentia blocks for the mixed same-chain shape), matching the maker's BtcLocktimeDelta so the
/// refund branch matures well after the swap should have settled.
const int kBuyCltvDelta = 100;

/// A conservative fee (sats) for the legacy-P2SH BTC HTLC refund spend (~200 vB at ~2 sat/vB).
final BigInt _kRefundFeeSats = BigInt.from(440);

/// Local, taker-centric state of an in-flight sub-asset BUY (fund a BTC on-chain HTLC, receive a
/// Sequentia asset over Lightning). The MIRROR of the SELL, roles flipped: here the DEVICE generates
/// P/H, registers a HODL invoice on H at its own hosted asset node (the maker pays H BY HASH), FUNDS a
/// BTC HTLC on H (the maker claims with P, the device refunds after T_btc), then commands the LSP to
/// drive the maker's pay. Once the asset payment is HELD at the device's node, the device SETTLES with
/// P — releasing the asset to itself AND revealing P so the maker claims the BTC.
///
/// FUND DISCIPLINE: P (the preimage) and the funding outpoint are the only non-derivable recovery
/// data. Both are persisted to secure storage BEFORE any broadcast (P at [secretReady]; the funding
/// txid at [funding], before the BTC broadcast). P is revealed ONLY via nodeSettle, ONLY after the
/// invoice reports `held` — never before (that would give the maker the BTC for free). A T_btc CLTV
/// refund is the loss-avoiding off-ramp if the maker never pays.
enum SubBuyStep {
  secretReady, // P/H + the BTC HTLC built; nothing broadcast yet
  funding, // BTC HTLC funding tx broadcast (txid persisted before broadcast)
  funded, // BTC funding confirmed; the LSP swap issued (maker asked to pay)
  holding, // the maker's asset payment arrived HELD (about to device-settle with P)
  settled, // device-settled with P: asset received + P revealed for the maker to claim the BTC
  refunded, // BTC refunded via CLTV (the maker never paid in time)
  failed,
}

class SubBuyRecord {
  SubBuyRecord({
    String? id,
    required this.step,
    required this.asset,
    required this.ticker,
    required this.preimage,
    required this.hashHex,
    required this.nodeKey,
    required this.redeem,
    required this.p2sh,
    required this.p2shSpk,
    required this.tBtc,
    required this.btcSats,
    required this.assetAtoms,
    required this.makerClaimPub,
    required this.refundPub,
    required this.offerId,
    required this.makerPubkey,
    this.quoteAsset,
    this.fundingTxid = '',
    this.vout = -1,
    this.jobId = '',
    this.poll = '',
    this.refundTxid = '',
    this.detail = '',
    this.emptyScans = 0,
  }) : id = id ?? newTradeId();

  /// Stable per-record id (multi-record store) — every save upserts on it, so a second buy can never
  /// clobber this record's P + funding outpoint (the recovery handle).
  final String id;
  SubBuyStep step;
  final String asset; // the Sequentia asset received over Lightning
  final String ticker;

  /// MIXED same-chain: the on-chain leg's REAL asset — an HTLC on this Sequentia asset instead of
  /// Bitcoin, with [btcSats]/[tBtc] carrying QUOTE ATOMS / a SEQUENTIA height (the LSP contract labels
  /// them btc_sats/cltv regardless). Null = the BTC shape (the on-chain leg is Bitcoin, unchanged).
  final String? quoteAsset;
  final String preimage; // P — NOT HD-derivable; only the device holds it until it settles
  final String hashHex; // H = sha256(P)
  String nodeKey; // our OWN hosted asset node that receives + settles the HODL invoice
  final String redeem; // the BTC HTLC redeemScript
  final String p2sh; // the BTC HTLC P2SH address (funded with btcSats)
  final String p2shSpk; // its scriptPubKey (locate the funded vout)
  final int tBtc; // the BTC HTLC CLTV refund height
  final BigInt btcSats; // the BTC locked (this fill's proportional price)
  final BigInt assetAtoms; // the asset received (this fill's slice)
  final String makerClaimPub; // the maker's on-chain claim key (claims the BTC with P)
  final String refundPub; // our device refund key (refunds the BTC after T_btc)
  final String offerId;
  final String makerPubkey;
  String fundingTxid;
  int vout;
  String jobId;
  String poll;
  String refundTxid;
  String detail;

  /// Consecutive DEFINITIVE empty scans of the quote-HTLC P2SH while at [SubBuyStep.funding] with no
  /// txid (the Sequentia funding txid is only known after broadcast, unlike btcPrepare's). Bounds the
  /// lost-broadcast recovery: found -> adopt; several definitive empties -> nothing was ever locked.
  int emptyScans;

  Map<String, dynamic> toJson() => {
        'id': id,
        'step': step.name,
        'asset': asset,
        'ticker': ticker,
        'preimage': preimage,
        'hashHex': hashHex,
        'nodeKey': nodeKey,
        'redeem': redeem,
        'p2sh': p2sh,
        'p2shSpk': p2shSpk,
        'tBtc': tBtc,
        'btcSats': btcSats.toString(),
        'assetAtoms': assetAtoms.toString(),
        'makerClaimPub': makerClaimPub,
        'refundPub': refundPub,
        'offerId': offerId,
        'makerPubkey': makerPubkey,
        'quoteAsset': quoteAsset,
        'fundingTxid': fundingTxid,
        'vout': vout,
        'jobId': jobId,
        'poll': poll,
        'refundTxid': refundTxid,
        'detail': detail,
        'emptyScans': emptyScans,
      };

  static SubBuyRecord fromJson(Map<String, dynamic> j) => SubBuyRecord(
        id: '${j['id'] ?? ''}'.isEmpty ? null : '${j['id']}',
        step: SubBuyStep.values.firstWhere((s) => s.name == j['step'], orElse: () => SubBuyStep.failed),
        asset: '${j['asset']}',
        ticker: '${j['ticker']}',
        preimage: '${j['preimage']}',
        hashHex: '${j['hashHex']}',
        nodeKey: '${j['nodeKey']}',
        redeem: '${j['redeem']}',
        p2sh: '${j['p2sh']}',
        p2shSpk: '${j['p2shSpk']}',
        tBtc: (j['tBtc'] as int?) ?? 0,
        btcSats: BigInt.tryParse('${j['btcSats'] ?? 0}') ?? BigInt.zero,
        assetAtoms: BigInt.tryParse('${j['assetAtoms'] ?? 0}') ?? BigInt.zero,
        makerClaimPub: '${j['makerClaimPub'] ?? ''}',
        refundPub: '${j['refundPub'] ?? ''}',
        offerId: '${j['offerId'] ?? ''}',
        makerPubkey: '${j['makerPubkey'] ?? ''}',
        quoteAsset: (j['quoteAsset'] is String && (j['quoteAsset'] as String).isNotEmpty)
            ? j['quoteAsset'] as String
            : null,
        fundingTxid: '${j['fundingTxid'] ?? ''}',
        vout: (j['vout'] as int?) ?? -1,
        jobId: '${j['jobId'] ?? ''}',
        poll: '${j['poll'] ?? ''}',
        refundTxid: '${j['refundTxid'] ?? ''}',
        detail: '${j['detail'] ?? ''}',
        emptyScans: (j['emptyScans'] as int?) ?? 0,
      );

  /// The `btc_htlc` object handed to the LSP swap (the maker claims this with P). Mirrors the web's
  /// btc_htlc shape. Only valid once [vout] is known (post-funding).
  Map<String, dynamic> btcHtlcJson() => {
        'txid': fundingTxid,
        'vout': vout,
        'amount': btcSats.toInt(),
        'redeem_script': redeem,
        'cltv': tBtc,
        'maker_claim_pub': makerClaimPub,
        'taker_refund_pub': refundPub,
      };

  /// True once the BTC is (or may be) locked and not yet settled/refunded — the window where the
  /// record is the ONLY recovery handle (single-active guard + shell resume both read this).
  bool get inFlight => step == SubBuyStep.funding || step == SubBuyStep.funded || step == SubBuyStep.holding;

  /// True while the BTC is committed and can still be reclaimed via the CLTV refund branch.
  bool get refundable => fundingTxid.isNotEmpty && inFlight;

  bool get terminal => step == SubBuyStep.settled || step == SubBuyStep.refunded || step == SubBuyStep.failed;
}

/// Persists the active sub-asset BUYs — a MULTI-RECORD list (web BUYS array) under a NEW key, with
/// one-time never-lossy adoption of the legacy single-slot record ('ambra.subasset.buy.active'). Each
/// record carries P (the only thing that settles the asset + releases the BTC) and the funding
/// outpoint, so it lives in secure storage; every save upserts by [SubBuyRecord.id] so records never
/// clobber each other. A distinct key from the SELL store so the two never mix.
class SubBuyStore {
  SubBuyStore._();
  static final TradeListStore _list =
      TradeListStore(listKey: 'ambra.subasset.buys', legacyKey: 'ambra.subasset.buy.active');

  /// Every persisted buy record (terminal ones included, until pruned at the next begin). Undecodable
  /// entries are skipped here but PRESERVED on disk (never dropped by a read).
  static Future<List<SubBuyRecord>> loadAll() async {
    final read = await _list.readAll();
    final out = <SubBuyRecord>[];
    for (final e in read.entries) {
      try {
        out.add(SubBuyRecord.fromJson(e));
      } catch (_) {/* preserved on disk; not drivable by this build */}
    }
    return out;
  }

  /// The buys whose BTC is (or may be) locked — what the guard, the composer cards and resume iterate.
  static Future<List<SubBuyRecord>> activeAll() async =>
      (await loadAll()).where((r) => r.inFlight).toList();

  /// Compat single-record read: the record with [id] when given, else the first in-flight record,
  /// else the most recent record of any state (so a just-settled buy still renders its done view).
  static Future<SubBuyRecord?> load({String? id}) async {
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

  static Future<void> save(SubBuyRecord r) => _list.upsert(r.toJson());

  /// Remove ONE record by id (a finished/abandoned buy) — never the whole store.
  static Future<void> remove(String id) => _list.removeById(id);

  /// Drop terminal records + never-funded secretReady stubs before starting a new buy (the bounded-list
  /// hygiene the single slot got for free). A record that is (or may be) holding funds is NEVER pruned.
  static Future<void> pruneSettled() =>
      _list.removeWhere((e) {
        try {
          final r = SubBuyRecord.fromJson(e);
          return r.terminal || (r.step == SubBuyStep.secretReady && r.fundingTxid.isEmpty);
        } catch (_) {
          return false; // undecodable: keep — it may represent a live trade
        }
      });

  /// TEST-ONLY full wipe.
  static Future<void> clear() => _list.wipeAll();
}

/// The sized fill of a sub-asset BUY against one resting offer. PURE (unit-tested). `offerBtc` /
/// `reqBtcSats` carry the offer's quote-leg atoms: sats for the BTC shape, QUOTE ATOMS for the mixed
/// same-chain shape (the LSP labels them btc_sats regardless) — the math is precision-blind. Default =
/// the whole offer; a smaller request takes a floor slice of the asset priced at the maker's EXACT
/// integer ProportionalBtc(ceil), or the maker rejects the lift AFTER the on-chain leg is locked.
class SubBuyFill {
  const SubBuyFill({required this.assetAtoms, required this.btcSats});
  final BigInt assetAtoms;
  final BigInt btcSats;
}

SubBuyFill sizeSubBuyFill({required BigInt offerAtoms, required BigInt offerBtc, BigInt? reqBtcSats}) {
  var assetAtoms = offerAtoms;
  var btcSats = offerBtc;
  if (reqBtcSats != null &&
      reqBtcSats > BigInt.zero &&
      reqBtcSats < offerBtc &&
      offerAtoms > BigInt.zero &&
      offerBtc > BigInt.zero) {
    var a = (offerAtoms * reqBtcSats) ~/ offerBtc; // floor slice of the entered quote amount
    if (a < BigInt.one) a = BigInt.one;
    assetAtoms = a;
    btcSats = (offerBtc * a + offerAtoms - BigInt.one) ~/ offerAtoms; // = the maker's ceil need
  }
  return SubBuyFill(assetAtoms: assetAtoms, btcSats: btcSats);
}

/// Drives the sub-asset BUY from LOCAL state: build P/H + the BTC HTLC, register the HODL invoice,
/// FUND the BTC HTLC, command the maker's pay, then device-settle with P once the asset is held (or
/// refund the BTC after T_btc). All money-moving spends are built by the audited core FFI. Each method
/// advances one step and persists; [drive] is a single idempotent reconcile step and [resume] loops it.
class SubassetBuyService {
  SubassetBuyService._();

  /// Synchronous in-flight sentinel (mirror of the web's `_buyStarting`): checked-and-set atomically
  /// at the top of [begin] so a concurrent begin can't overwrite the just-built secretReady record
  /// (its preimage) before it is persisted. The funds-committed guard ([SubBuyRecord.inFlight]) covers
  /// the post-fund window.
  static bool _starting = false;

  static Future<String> _mnemonic() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw Exception('wallet unavailable');
    return m;
  }

  /// True while any buy has (or may have) locked BTC that is not yet settled/refunded. With the
  /// multi-record store this no longer hard-blocks a second buy (records upsert by id, so nothing can
  /// be overwritten); the shared [TradeSlots] bound is what gates new dispatches.
  static Future<bool> hasInFlight() async => (await SubBuyStore.activeAll()).isNotEmpty;

  /// Build P/H, size this fill (BigInt partial-fill), pick T_btc, build the BTC HTLC, and PERSIST —
  /// all BEFORE any money moves. Refuses to start while another buy's BTC is still committed (that
  /// record is the only recovery handle). Returns the new record (the UI then funds the BTC).
  static Future<SubBuyRecord> begin({
    required String asset,
    required SubOffer offer,
    BigInt? reqBtcSats,
    String? quoteAsset,
  }) async {
    if (_starting) {
      throw Exception('A sub-asset buy is already starting; wait for it to finish.');
    }
    _starting = true;
    try {
      return await _begin(asset: asset, offer: offer, reqBtcSats: reqBtcSats, quoteAsset: quoteAsset);
    } finally {
      _starting = false;
    }
  }

  static Future<SubBuyRecord> _begin({
    required String asset,
    required SubOffer offer,
    BigInt? reqBtcSats,
    String? quoteAsset,
  }) async {
    // SHARED SLOT GATE (web buySlotsFree): records upsert by id so a second buy can never overwrite
    // another's persisted P + funding outpoint — the old single-slot hard refusal is replaced by the
    // bounded concurrent-trade count across all rail-crossing kinds. Prune finished/never-funded
    // records first so a done trade never eats a slot.
    await SubBuyStore.pruneSettled();
    final refusal = await TradeSlots.refusalIfFull();
    if (refusal != null) throw Exception(refusal);
    if (offer.makerClaimPub.isEmpty) {
      throw Exception('No resting ${SeqAssets.labelFor(asset).ticker} buy offer right now; try again shortly.');
    }
    final m = await _mnemonic();
    final ticker = SeqAssets.labelFor(asset).ticker;
    // 1. The DEVICE generates the secret. Only we ever hold P until WE settle.
    final sec = await core.xchainNewSecret();
    final h = sec.hashHex, p = sec.secretHex;
    // Our OWN hosted asset node RECEIVES the asset over LN (the deterministic key; fund() connects it).
    final nodeKey = LightningService.instance.ownNodeKey(m, asset: asset);
    // 2. Size this fill (pure BigInt math, [sizeSubBuyFill]): default the whole offer; a smaller
    // request takes a floor slice priced at the maker's EXACT integer ProportionalBtc(ceil), or the
    // maker rejects us AFTER the on-chain leg is locked -> stranded until refund.
    final fill = sizeSubBuyFill(
        offerAtoms: offer.assetAmount, offerBtc: offer.btcSats, reqBtcSats: reqBtcSats);
    final assetAtoms = fill.assetAtoms;
    final btcSats = fill.btcSats;
    // 3. Build the on-chain HTLC on H: maker claims with P, device refunds after T = max(offer CLTV,
    // tip + delta), the tip and the HTLC's chain chosen by the shape. MIXED same-chain: a Sequentia
    // HTLC ON THE QUOTE ASSET, T off the SEQUENTIA tip (mirror web startBuy's `qh ? seqLeg : btcLeg`
    // seam); xchainSeqHtlcReverse embeds the wallet's canonical SEQ key as the refund side. BTC shape:
    // the legacy-P2SH Bitcoin HTLC, unchanged. Both refund keys are HD-derivable; P is not, hence the
    // persist below.
    final String refundPub, redeem, p2sh, p2shSpk;
    final int tBtc;
    if (quoteAsset != null && quoteAsset.isNotEmpty) {
      final tip = await _seqTip();
      if (tip < 0) throw Exception('The Sequentia tip is unreadable; try again shortly.');
      tBtc = _max(offer.onchainCltv, tip + kBuyCltvDelta);
      refundPub = await core.xchainSeqClaimPubkey(mnemonic: m);
      final htlc = await core.xchainSeqHtlcReverse(
        mnemonic: m,
        hashHex: h,
        makerSeqClaimPubHex: offer.makerClaimPub, // the maker claims with the secret
        seqLocktime: tBtc, // we refund via CLTV (a Sequentia height)
      );
      redeem = htlc.redeemScriptHex;
      p2sh = htlc.p2ShAddress;
      p2shSpk = htlc.p2ShSpkHex;
    } else {
      final tip = await _btcTip();
      tBtc = _max(offer.onchainCltv, tip + kBuyCltvDelta);
      refundPub = await core.xchainBtcRefundPubkey(mnemonic: m);
      final htlc = await core.xchainBtcHtlc(
        hashHex: h,
        claimPubHex: offer.makerClaimPub, // BTC leg: the maker claims with the secret
        refundPubHex: refundPub, // we refund via CLTV
        locktime: tBtc,
      );
      redeem = htlc.redeemScriptHex;
      p2sh = htlc.p2ShAddress;
      p2shSpk = htlc.p2ShSpkHex;
    }
    final rec = SubBuyRecord(
      step: SubBuyStep.secretReady,
      asset: asset,
      ticker: ticker,
      preimage: p,
      hashHex: h,
      nodeKey: nodeKey,
      redeem: redeem,
      p2sh: p2sh,
      p2shSpk: p2shSpk,
      tBtc: tBtc,
      btcSats: btcSats,
      assetAtoms: assetAtoms,
      makerClaimPub: offer.makerClaimPub,
      refundPub: refundPub,
      offerId: offer.offerId,
      makerPubkey: offer.makerPubkey,
      quoteAsset: (quoteAsset != null && quoteAsset.isNotEmpty) ? quoteAsset : null,
    );
    await SubBuyStore.save(rec); // PERSIST before any broadcast (P is the recovery-critical secret)
    return rec;
  }

  /// FUND the BTC HTLC. Requires payment auth (fail-closed) FIRST, then brings the asset node online,
  /// registers the HODL invoice on H (so the maker can pay by hash), and funds the P2SH.
  /// FUND-SAFETY: btcPrepare returns a fully-signed tx whose txid is final (segwit inputs), so the
  /// funding txid + step are persisted BEFORE btcBroadcast — if the app dies mid-broadcast, the outpoint
  /// is already saved so drive/resume can settle or refund the locked BTC. A broadcast that then throws
  /// does NOT roll the step back (re-funding could double-lock); recovery is the drive/refund off-ramp.
  static Future<SubBuyRecord> fund(SubBuyRecord r) async {
    if (r.step != SubBuyStep.secretReady) return r; // already funded (idempotent)
    // Funding spends real (testnet4) Bitcoin. Require payment auth (fail-closed) BEFORE anything moves.
    final ok = await WalletRepository.instance.requirePaymentAuth();
    if (!ok) throw Exception('Authentication failed or cancelled; BTC not locked.');
    final m = await _mnemonic();
    // Bring our asset node's device signer online so it can register + later settle the HODL invoice.
    r.nodeKey = await LightningService.instance.connectNode(m, asset: r.asset);
    await SubBuyStore.save(r);
    // Best-effort JIT inbound liquidity so the maker can pay us over LN (idempotent; a funded channel
    // may already have inbound room).
    try {
      await LspClient.channelInbound(nodeKey: r.nodeKey, asset: r.asset, amount: r.assetAtoms.toInt());
    } catch (_) {/* best-effort */}
    // Register the HODL invoice on H at our OWN node (NO bolt11; the maker pays H BY HASH). Device keeps P.
    final inv = await LspClient.nodeInvoice(
        nodeKey: r.nodeKey, asset: r.asset, amount: r.assetAtoms.toInt(), paymentHash: r.hashHex);
    if (!(inv.hodl || (inv.paymentHash != null && inv.paymentHash!.isNotEmpty))) {
      throw Exception('Could not register the Lightning invoice on your node.');
    }
    if (r.quoteAsset != null) {
      // MIXED same-chain: fund the QUOTE-asset HTLC on Sequentia via the wallet's own tx builder.
      // Unlike btcPrepare, the PSET's txid is only known AFTER broadcast, so the 'funding' step is
      // persisted BEFORE the irreversible broadcast and a lost txid is recovered by the P2SH scan in
      // [pollFundAndSwap] (mirror web startBuy's seqLeg.fund + findFundingByAddress).
      final pset = await core.buildSendTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        recipients: [core.Recipient(address: r.p2sh, assetId: r.quoteAsset!, satoshi: r.btcSats)],
        feeRateSatKvb: null,
        feeAsset: null,
      );
      final signed = await core.signPset(mnemonic: m, pset: pset);
      r.step = SubBuyStep.funding;
      await SubBuyStore.save(r);
      final txid = await core.finalizeAndBroadcast(mnemonic: m, esploraUrl: Backend.esplora, pset: signed);
      r.fundingTxid = txid;
      await SubBuyStore.save(r);
    } else {
      // Build the funding tx (signed; txid is final for segwit inputs).
      final tx = await core.btcPrepare(
        mnemonic: m,
        t4Api: Backend.testnet4,
        address: r.p2sh,
        amountSats: r.btcSats,
        feeRate: 0,
      );
      // FUND-SAFETY: persist the txid + advance the step BEFORE broadcasting.
      r
        ..fundingTxid = tx.txid
        ..step = SubBuyStep.funding;
      await SubBuyStore.save(r);
      await core.btcBroadcast(t4Api: Backend.testnet4, txHex: tx.hex);
    }
    final qtk = _quoteTicker(r);
    TradeReceipts.log(id: 'subbuy:${r.hashHex}', title: 'Buying ${r.ticker} with $qtk', status: '$qtk locked')
        .ignore();
    return r;
  }

  /// Poll until the on-chain HTLC funding is located (record its vout), then command the maker's pay
  /// over LN (an async LSP job). Returns true once the swap is issued. Never broadcasts. BTC shape:
  /// waits for 1 confirmation. MIXED same-chain: a 0-conf hand-off (mirror web) — the vout is adopted
  /// the moment the funding is visible (mempool included); the maker carries its own 0-conf policy and
  /// the CLTV refund path is unchanged.
  static Future<bool> pollFundAndSwap(SubBuyRecord r) async {
    if (r.step != SubBuyStep.funding) return r.step == SubBuyStep.funded;
    if (r.quoteAsset != null) {
      if (r.fundingTxid.isEmpty && !await _recoverSeqFundingTxid(r)) return false;
      final v = await _findSeqVout(r.fundingTxid, r.p2shSpk);
      if (v < 0) return false;
      r
        ..vout = v
        ..step = SubBuyStep.funded;
    } else {
      if (r.fundingTxid.isEmpty) return false;
      final f =
          await core.xchainFindBtcFunding(t4Api: Backend.testnet4, txid: r.fundingTxid, p2ShSpkHex: r.p2shSpk);
      if (f.confirmations < 1 || f.height < 0) return false;
      r
        ..vout = f.vout
        ..step = SubBuyStep.funded;
    }
    await SubBuyStore.save(r);
    await _issueSwap(r); // ask the maker to pay us the asset over LN
    return true;
  }

  /// Recover a quote-HTLC funding whose txid never persisted (a crash between broadcast and the save):
  /// scan the P2SH via esplora `/address/<addr>/utxo` (confirmed + mempool). Found -> adopt the txid
  /// (true). A transient read error keeps the record resumable (false). Several consecutive DEFINITIVE
  /// empties prove the broadcast never went out (the step is persisted BEFORE broadcasting), so nothing
  /// was locked -> terminal `failed`, releasing the single slot (false).
  static Future<bool> _recoverSeqFundingTxid(SubBuyRecord r) async {
    final utxos = await _seqAddressUtxos(r.p2sh);
    if (utxos == null) return false; // transient: never a false drop of a possibly-funded HTLC
    if (utxos.isEmpty) {
      r.emptyScans++;
      if (r.emptyScans >= 3) {
        r
          ..step = SubBuyStep.failed
          ..detail = 'The lock was never broadcast; nothing was locked.';
      }
      await SubBuyStore.save(r);
      return false;
    }
    final txid = '${(utxos.first as Map)['txid'] ?? ''}';
    if (txid.isEmpty) return false;
    r
      ..fundingTxid = txid
      ..emptyScans = 0;
    await SubBuyStore.save(r);
    return true;
  }

  /// (Re-)command the maker's pay-by-hash over LN. Idempotent: the hosted node's hold invoice on H can
  /// only be paid once, so a duplicate command is harmless. Best-effort — a failure leaves jobId empty
  /// so [drive] retries; the CLTV refund guard protects the funds regardless.
  static Future<void> _issueSwap(SubBuyRecord r) async {
    if (r.vout < 0) return;
    final m = await _mnemonic();
    try {
      r.nodeKey = await LightningService.instance.connectNode(m, asset: r.asset); // node up for pay/settle
      final resp = await LightningService.instance.swapSub(
        side: 'buy',
        asset: r.asset,
        nodeKey: r.nodeKey,
        hodl: true,
        paymentHash: r.hashHex,
        assetAmount: r.assetAtoms,
        payRail: 'chain',
        recvRail: 'ln',
        btcHtlc: r.btcHtlcJson(),
        offerId: r.offerId.isEmpty ? null : r.offerId,
        makerPubkey: r.makerPubkey.isEmpty ? null : r.makerPubkey,
        quoteAsset: r.quoteAsset, // mixed same-chain: the on-chain leg's REAL asset (absent = BTC)
      );
      r
        ..jobId = resp.job.jobId ?? ''
        ..poll = resp.job.poll ?? '';
      await SubBuyStore.save(r);
    } catch (_) {
      await SubBuyStore.save(r); // persist any nodeKey update; leave jobId empty so drive() re-issues
    }
  }

  /// ONE idempotent reconcile step (shared by the screen's timer + [resume]'s loop): reconcile a
  /// dropped LSP job, then either device-settle once the asset is HELD, or refund the BTC once the CLTV
  /// matures. Reveals P (via nodeSettle) ONLY after the invoice reports `held` — never before.
  static Future<SubBuyRecord> drive(SubBuyRecord r) async {
    if (r.terminal) return r;
    // Advance a just-funded record: confirm the BTC funding + issue the swap.
    if (r.step == SubBuyStep.funding) {
      try {
        await pollFundAndSwap(r);
      } catch (_) {/* not confirmed yet / offline; the refund guard below still applies */}
    } else if (r.step == SubBuyStep.funded || r.step == SubBuyStep.holding) {
      await _reconcileJob(r);
    }
    if (r.step != SubBuyStep.funded && r.step != SubBuyStep.holding) return r;
    // The refund guard is judged on the HTLC's OWN chain: the Sequentia tip for a quote-asset leg
    // (tBtc is a Sequentia height there), the Bitcoin tip otherwise.
    var tip = 0;
    try {
      tip = r.quoteAsset != null ? await _seqTip() : await _btcTip();
    } catch (_) {}
    HodlInvoiceStatus? status;
    try {
      status = await LightningService.instance.invoiceStatus(nodeKey: r.nodeKey, paymentHash: r.hashHex);
    } catch (_) {/* keep waiting */}
    if (status != null && status.settled) {
      r.step = SubBuyStep.settled;
      await SubBuyStore.save(r);
      return r;
    }
    if (status != null && status.held) {
      await _settle(r); // device-settle with P (asset in + P revealed); THE reveal, only once held
      return r;
    }
    if (tip > 0 && r.tBtc > 0 && tip >= r.tBtc) {
      await refund(r); // the maker didn't pay in time; reclaim the BTC (the only loss-avoiding path)
      return r;
    }
    return r;
  }

  /// Drop a dead/interrupted/gone LSP job + re-issue the swap (idempotent). Mirrors the web driver's
  /// job reconcile so a restarted LSP no longer strands the maker's pay-by-hash.
  static Future<void> _reconcileJob(SubBuyRecord r) async {
    if (r.jobId.isNotEmpty) {
      final j = await LightningService.instance.jobStatus(r.poll.isNotEmpty ? r.poll : '/swap/${r.jobId}');
      if (!j.alive) {
        r
          ..jobId = ''
          ..poll = '';
        await SubBuyStore.save(r);
      }
    }
    if (r.jobId.isEmpty) await _issueSwap(r);
  }

  /// Device-settle the HELD HODL invoice with P: releases the held asset payment to us AND reveals P so
  /// the maker claims the BTC, atomically. THE point of no return — called ONLY once held.
  static Future<void> _settle(SubBuyRecord r) async {
    r.step = SubBuyStep.holding;
    await SubBuyStore.save(r);
    final m = await _mnemonic();
    // The settle changes the channel commitment, so the device signer must be online to co-sign it.
    await LightningService.instance.connectNode(m, asset: r.asset);
    await LspClient.nodeSettle(nodeKey: r.nodeKey, paymentHash: r.hashHex, preimage: r.preimage);
    r.step = SubBuyStep.settled;
    await SubBuyStore.save(r);
    final qtk = _quoteTicker(r);
    TradeReceipts.log(
      id: 'subbuy:${r.hashHex}',
      title: 'Bought ${r.ticker} with $qtk',
      status: 'Asset received',
      pair: '${r.ticker}/$qtk',
      side: 'buy',
      price: _fillPrice(r),
    ).ignore();
    // Best-effort: record the maker-claim job status for display. Non-fatal.
    if (r.poll.isNotEmpty || r.jobId.isNotEmpty) {
      try {
        final j = await LightningService.instance.jobStatus(r.poll.isNotEmpty ? r.poll : '/swap/${r.jobId}');
        if (j.status.isNotEmpty) {
          r.detail = j.status;
          await SubBuyStore.save(r);
        }
      } catch (_) {}
    }
  }

  /// Refund the funded BTC HTLC via its CLTV branch after T_btc (a real on-chain reclaim). Terminal.
  static Future<SubBuyRecord> refund(SubBuyRecord r) async {
    if (!r.refundable) throw Exception('this buy is not refundable (nothing is locked, or it already settled)');
    final m = await _mnemonic();
    final dest = await core.receiveAddress(mnemonic: m); // our own tb1
    final String txid;
    if (r.quoteAsset != null) {
      // MIXED same-chain: reclaim the quote-asset HTLC on Sequentia via its CLTV branch, the fee sized
      // per-asset from the published rate (the HTLC holds no native tSEQ). Mirror web refundBuy's
      // `qh ? seqLeg.refund : btcLeg.refund` seam.
      final hex = await core.xchainSeqRefund(
        mnemonic: m,
        seqTxid: r.fundingTxid,
        seqVout: r.vout,
        seqAmount: r.btcSats,
        seqAssetId: r.quoteAsset!,
        destAddress: dest,
        feeAtoms: await _seqAssetFee(r.quoteAsset!, r.btcSats),
        redeemScriptHex: r.redeem,
        seqLocktime: r.tBtc,
      );
      txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: hex);
    } else {
      final hex = await core.xchainBtcRefund(
        mnemonic: m,
        btcTxid: r.fundingTxid,
        btcVout: r.vout,
        btcAmountSats: r.btcSats,
        destAddress: dest,
        feeSats: _kRefundFeeSats,
        redeemScriptHex: r.redeem,
        locktime: r.tBtc,
      );
      txid = await core.btcBroadcast(t4Api: Backend.testnet4, txHex: hex);
    }
    r
      ..refundTxid = txid
      ..step = SubBuyStep.refunded;
    await SubBuyStore.save(r);
    final qtk = _quoteTicker(r);
    TradeReceipts.log(
            id: 'subbuy:${r.hashHex}', title: 'Buy refunded (${r.ticker})', status: '$qtk refunded', txid: r.refundTxid)
        .ignore();
    return r;
  }

  /// Whether the on-chain refund is spendable yet (the HTLC chain's tip >= T) and the swap is refundable.
  static Future<bool> refundReady(SubBuyRecord r) async {
    if (!r.refundable) return false;
    final tip = r.quoteAsset != null ? await _seqTip() : await _btcTip();
    return tip > 0 && tip >= r.tBtc;
  }

  /// On wallet load / cold start: resume EVERY buy that locked its BTC HTLC but never completed —
  /// settle once the asset is held, or refund the BTC once past T_btc. Fire-and-forget from the shell;
  /// each record is driven INDEPENDENTLY (concurrently) so one stuck counterparty never blocks
  /// another's settle/refund (the web resumeBuy over activeBuys, Promise.all).
  static Future<void> resume() async {
    List<SubBuyRecord> recs;
    try {
      recs = await SubBuyStore.activeAll();
    } catch (_) {
      return; // unreadable store: nothing to drive now; records stay persisted
    }
    await Future.wait([
      for (final r in recs)
        if (r.inFlight && r.preimage.isNotEmpty) _resumeOne(r).catchError((Object _) {}),
    ]);
  }

  /// Drive ONE persisted buy (bounded idempotent loop, mirrors the old single-record resume body).
  static Future<void> _resumeOne(SubBuyRecord r0) async {
    var r = r0;
    for (var i = 0; i < 240; i++) {
      try {
        await drive(r);
      } catch (_) {/* leave persisted; the BTC is still refundable at T_btc */}
      if (r.terminal) return;
      await Future<void>.delayed(const Duration(seconds: 6));
      final fresh = await SubBuyStore.load(id: r.id);
      if (fresh == null || fresh.terminal) return; // removed / finished (e.g. by the open screen)
      r = fresh;
    }
  }

  // -- helpers ----------------------------------------------------------------

  /// The current Bitcoin (testnet4) tip height, used for T_btc + the refund maturity gate.
  static Future<int> _btcTip() async {
    final resp =
        await http.get(Uri.parse('${Backend.testnet4}/blocks/tip/height')).timeout(const Duration(seconds: 20));
    return int.tryParse(resp.body.trim()) ?? -1;
  }

  /// The current Sequentia tip height — T + the refund maturity gate for a quote-asset HTLC.
  static Future<int> _seqTip() async {
    final resp = await http
        .get(Uri.parse('${Backend.esplora}/blocks/tip/height'), headers: Backend.authHeaders)
        .timeout(const Duration(seconds: 20));
    return int.tryParse(resp.body.trim()) ?? -1;
  }

  /// The quote-HTLC vout of [txid]: the output paying [p2shSpk] (mempool visible — the 0-conf
  /// hand-off). -1 while the tx is not yet visible / no output matches.
  static Future<int> _findSeqVout(String txid, String p2shSpk) async {
    try {
      final resp = await http
          .get(Uri.parse('${Backend.esplora}/tx/$txid'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return -1;
      final tx = jsonDecode(resp.body) as Map<String, dynamic>;
      final vouts = (tx['vout'] as List?) ?? const [];
      final want = p2shSpk.toLowerCase();
      for (var i = 0; i < vouts.length; i++) {
        final o = vouts[i] as Map?;
        if ('${o?['scriptpubkey'] ?? ''}'.toLowerCase() == want) return i;
      }
      return -1;
    } catch (_) {
      return -1;
    }
  }

  /// The confirmed + mempool UTXOs at [address] via esplora `/address/<addr>/utxo`. A DEFINITIVE read
  /// returns the list (empty = genuinely unfunded); a transient error returns null so the caller never
  /// drops a possibly-funded leg on an unreadable state (mirror subswap's `_seqAddressUtxos`).
  static Future<List<dynamic>?> _seqAddressUtxos(String address) async {
    try {
      final resp = await http
          .get(Uri.parse('${Backend.esplora}/address/$address/utxo'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body);
      return j is List ? j : null;
    } catch (_) {
      return null;
    }
  }

  /// A Sequentia spend fee in atoms of [assetHex] (the HTLC holds no native tSEQ): the native policy
  /// fee converted at the asset's published rate, min 1 atom, capped at half the output. Best-effort
  /// feed; falls back to the reference scale when the feed omits the asset — a refund must stay
  /// broadcastable (same sizing as subswap's `_seqRefundFee`).
  static Future<BigInt> _seqAssetFee(String assetHex, BigInt amount) async {
    final ticker = SeqAssets.labelFor(assetHex).ticker;
    Map<String, BigInt> rates;
    try {
      rates = await ApiClient.feeRates();
    } catch (_) {
      rates = const {};
    }
    final scale = BigInt.from(100000000);
    final rate = rates[ticker] ?? rates[assetHex] ?? scale;
    final native = BigInt.from(400); // ~vbytes at 1 sat/vB, matching the cross-swap sizing
    var fee = (native * scale + rate - BigInt.one) ~/ rate; // ceil(native * scale / rate)
    if (fee < BigInt.one) fee = BigInt.one;
    final half = amount ~/ BigInt.two;
    if (fee > half) fee = half < BigInt.one ? BigInt.one : half;
    return fee;
  }

  /// The quote leg's display name: the quote asset's ticker on the mixed same-chain shape, else 'BTC'.
  static String _quoteTicker(SubBuyRecord r) =>
      r.quoteAsset != null ? SeqAssets.labelFor(r.quoteAsset!).ticker : 'BTC';

  /// The fill price in quote UNITS per base UNIT (receipt display). Null when a side is zero.
  static double? _fillPrice(SubBuyRecord r) {
    final qprec = r.quoteAsset != null ? SeqAssets.labelFor(r.quoteAsset!).precision : 8;
    final aprec = SeqAssets.labelFor(r.asset).precision;
    final q = r.btcSats.toDouble() / _pow10(qprec);
    final a = r.assetAtoms.toDouble() / _pow10(aprec);
    return (q > 0 && a > 0) ? q / a : null;
  }

  static double _pow10(int p) {
    var v = 1.0;
    for (var i = 0; i < p; i++) {
      v *= 10;
    }
    return v;
  }

  static int _max(int a, int b) => a > b ? a : b;
}
