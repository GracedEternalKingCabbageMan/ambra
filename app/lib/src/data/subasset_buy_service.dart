import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import 'config.dart';
import 'lightning_service.dart';
import 'lsp_client.dart';
import 'trade_receipts.dart';
import 'wallet_repository.dart';

/// T_btc safety delta over the current BTC tip (parent-chain blocks), matching the maker's
/// BtcLocktimeDelta so the refund branch matures well after the swap should have settled.
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
    this.fundingTxid = '',
    this.vout = -1,
    this.jobId = '',
    this.poll = '',
    this.refundTxid = '',
    this.detail = '',
  });

  SubBuyStep step;
  final String asset; // the Sequentia asset received over Lightning
  final String ticker;
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

  Map<String, dynamic> toJson() => {
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
        'fundingTxid': fundingTxid,
        'vout': vout,
        'jobId': jobId,
        'poll': poll,
        'refundTxid': refundTxid,
        'detail': detail,
      };

  static SubBuyRecord fromJson(Map<String, dynamic> j) => SubBuyRecord(
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
        fundingTxid: '${j['fundingTxid'] ?? ''}',
        vout: (j['vout'] as int?) ?? -1,
        jobId: '${j['jobId'] ?? ''}',
        poll: '${j['poll'] ?? ''}',
        refundTxid: '${j['refundTxid'] ?? ''}',
        detail: '${j['detail'] ?? ''}',
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

/// Persists the single active sub-asset BUY. It carries P (the only thing that settles the asset +
/// releases the BTC) and the funding outpoint, so it lives in secure storage. A distinct key from the
/// SELL store so the two never clobber.
class SubBuyStore {
  SubBuyStore._();
  static const _key = 'ambra.subasset.buy.active';
  static const _storage = FlutterSecureStorage();

  static Future<SubBuyRecord?> load() async {
    final s = await _storage.read(key: _key);
    if (s == null || s.isEmpty) return null;
    try {
      return SubBuyRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(SubBuyRecord r) => _storage.write(key: _key, value: jsonEncode(r.toJson()));
  static Future<void> clear() => _storage.delete(key: _key);
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

  /// True while a buy has (or may have) locked BTC that is not yet settled/refunded — the guard + the
  /// screen's gating both read this so a second buy can never overwrite the recovery handle.
  static Future<bool> hasInFlight() async {
    final r = await SubBuyStore.load();
    return r != null && r.inFlight;
  }

  /// Build P/H, size this fill (BigInt partial-fill), pick T_btc, build the BTC HTLC, and PERSIST —
  /// all BEFORE any money moves. Refuses to start while another buy's BTC is still committed (that
  /// record is the only recovery handle). Returns the new record (the UI then funds the BTC).
  static Future<SubBuyRecord> begin({
    required String asset,
    required SubOffer offer,
    BigInt? reqBtcSats,
  }) async {
    if (_starting) {
      throw Exception('A sub-asset buy is already starting; wait for it to finish.');
    }
    _starting = true;
    try {
      return await _begin(asset: asset, offer: offer, reqBtcSats: reqBtcSats);
    } finally {
      _starting = false;
    }
  }

  static Future<SubBuyRecord> _begin({
    required String asset,
    required SubOffer offer,
    BigInt? reqBtcSats,
  }) async {
    // FUND-SAFETY self-guard: a second buy would overwrite the persisted P + funding outpoint — the
    // single handle to the locked BTC. Refuse while one is still committed. (A prior secretReady stub,
    // with nothing locked, is safe to overwrite.)
    final existing = await SubBuyStore.load();
    if (existing != null && existing.inFlight) {
      throw Exception('You already have a sub-asset buy in progress (Bitcoin locked). '
          'Finish or refund it first.');
    }
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
    // 2. Size this fill. Default to the whole offer; if the user entered LESS BTC than the offer's full
    // price, take a proportional slice. BigInt, NOT float: btcSats MUST equal the maker's integer
    // ProportionalBtc(ceil) or the maker rejects us AFTER the BTC is locked -> stranded until refund.
    var assetAtoms = offer.assetAmount;
    var btcSats = offer.btcSats;
    if (reqBtcSats != null &&
        reqBtcSats > BigInt.zero &&
        reqBtcSats < offer.btcSats &&
        offer.assetAmount > BigInt.zero &&
        offer.btcSats > BigInt.zero) {
      var a = (offer.assetAmount * reqBtcSats) ~/ offer.btcSats; // floor slice of the entered BTC
      if (a < BigInt.one) a = BigInt.one;
      assetAtoms = a;
      btcSats = _ceilDiv(offer.btcSats * a, offer.assetAmount); // = the maker's ProportionalBtc need
    }
    // 3. Build the BTC HTLC on H: maker claims with P, device refunds after T_btc = max(offer CLTV,
    // tip + delta). The device REFUND key is HD-derivable (recovery-safe); P is not, hence the persist.
    final refundPub = await core.xchainBtcRefundPubkey(mnemonic: m);
    final tip = await _btcTip();
    final tBtc = _max(offer.onchainCltv, tip + kBuyCltvDelta);
    final htlc = await core.xchainBtcHtlc(
      hashHex: h,
      claimPubHex: offer.makerClaimPub, // BTC leg: the maker claims with the secret
      refundPubHex: refundPub, // we refund via CLTV
      locktime: tBtc,
    );
    final rec = SubBuyRecord(
      step: SubBuyStep.secretReady,
      asset: asset,
      ticker: ticker,
      preimage: p,
      hashHex: h,
      nodeKey: nodeKey,
      redeem: htlc.redeemScriptHex,
      p2sh: htlc.p2ShAddress,
      p2shSpk: htlc.p2ShSpkHex,
      tBtc: tBtc,
      btcSats: btcSats,
      assetAtoms: assetAtoms,
      makerClaimPub: offer.makerClaimPub,
      refundPub: refundPub,
      offerId: offer.offerId,
      makerPubkey: offer.makerPubkey,
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
    TradeReceipts.log(id: 'subbuy:${r.hashHex}', title: 'Buying ${r.ticker} with BTC', status: 'BTC locked')
        .ignore();
    return r;
  }

  /// Poll until the BTC HTLC funding confirms (record its vout), then command the maker's pay over LN
  /// (an async LSP job). Returns true once the swap is issued. Never broadcasts.
  static Future<bool> pollFundAndSwap(SubBuyRecord r) async {
    if (r.step != SubBuyStep.funding || r.fundingTxid.isEmpty) return r.step == SubBuyStep.funded;
    final f = await core.xchainFindBtcFunding(t4Api: Backend.testnet4, txid: r.fundingTxid, p2ShSpkHex: r.p2shSpk);
    if (f.confirmations < 1 || f.height < 0) return false;
    r
      ..vout = f.vout
      ..step = SubBuyStep.funded;
    await SubBuyStore.save(r);
    await _issueSwap(r); // ask the maker to pay us the asset over LN
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
    var tip = 0;
    try {
      tip = await _btcTip();
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
    TradeReceipts.log(id: 'subbuy:${r.hashHex}', title: 'Bought ${r.ticker} with BTC', status: 'Asset received')
        .ignore();
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
    final txid = await core.btcBroadcast(t4Api: Backend.testnet4, txHex: hex);
    r
      ..refundTxid = txid
      ..step = SubBuyStep.refunded;
    await SubBuyStore.save(r);
    TradeReceipts.log(
            id: 'subbuy:${r.hashHex}', title: 'Buy refunded (${r.ticker})', status: 'BTC refunded', txid: r.refundTxid)
        .ignore();
    return r;
  }

  /// Whether the BTC refund is spendable yet (parent-chain tip >= T_btc) and the swap is refundable.
  static Future<bool> refundReady(SubBuyRecord r) async {
    if (!r.refundable) return false;
    final tip = await _btcTip();
    return tip > 0 && tip >= r.tBtc;
  }

  /// On wallet load / cold start: if a buy locked its BTC HTLC but never completed, resume it — settle
  /// once the asset is held, or refund the BTC once past T_btc. Fire-and-forget from the shell; loops
  /// the idempotent [drive] step (bounded) so a locked HTLC recovers even if the user never opens the
  /// screen. The fund-recovery path (mirrors the web's resumeBuy).
  static Future<void> resume() async {
    final r0 = await SubBuyStore.load();
    if (r0 == null || !r0.inFlight || r0.preimage.isEmpty) return;
    var r = r0; // non-null past the guard, so the drive loop reassigns cleanly
    for (var i = 0; i < 240; i++) {
      try {
        await drive(r);
      } catch (_) {/* leave persisted; the BTC is still refundable at T_btc */}
      if (r.terminal) return;
      await Future<void>.delayed(const Duration(seconds: 6));
      final fresh = await SubBuyStore.load();
      if (fresh == null || fresh.terminal) return; // cleared / finished (e.g. by the open screen)
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

  static int _max(int a, int b) => a > b ? a : b;

  /// ceil(a / b) for positive BigInts.
  static BigInt _ceilDiv(BigInt a, BigInt b) => (a + b - BigInt.one) ~/ b;
}
