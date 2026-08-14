// ---------------------------------------------------------------------------
// lsp_bridge_service.dart — the LSP PAYER LEG-BRIDGE taker (a BUY paying BTC over Lightning against an
// on-chain-only / passive maker), the mobile twin of the web wallet's subswap.js runLspPayerBridge +
// swap.js driveLspPayerBridge / resumeSubswap branch (C). FAITHFUL port of the verified driver: do NOT
// re-derive the checks.
//
//   0. Mint P SELF-CUSTODY (H = sha256(P)); PERSIST the record ('ambra.bridge.active') BEFORE anything
//      leaves the device — persist-P-early is what makes every later step resumable.
//   1. POST /swap {bridge:true, hash_h, taker_seq_claim_pub, ...} -> job; poll for bridge_terms and
//      assert the handshake bound OUR H.
//   2. POST /bridge/hold -> the LSP issues a BTC-LN HOLD on H at its node; validate (payment_hash == H,
//      never an overpay, min-final-CLTV floored AND capped) then PAY IT BY BARE HASH from the user's
//      OWN hosted BTC node. HELD, never captured: it settles only when the LSP recoups with P.
//   3. The LSP fronts the maker's on-chain BTC HTLC; the maker locks the ASSET to OUR key on H; the LSP
//      relays the leg -> poll for maker_seq_leg (re-reading the leg's refund key WITH the leg: a
//      fronted leg is refundable by the LSP, not the maker).
//   4. VERIFY the leg binds MY claim key + asset + amount + T_seq (rebuild the redeem, byte-compare,
//      bind the funding output) -> WAIT anchor-buried -> gate the SEQ CLAIM WINDOW (re-checked with a
//      FRESH tip immediately before the claim) -> claim with P. Claiming reveals P — the LSP recoups —
//      so P is NEVER revealed until the verified, anchor-buried asset is ours to claim strictly before
//      T_seq (else the maker could refund while the LSP still captures our Bitcoin).
//
// The taker has NO on-chain leg of its own: its exposure is the HELD BTC-LN payment, which fails back
// at its CLTV expiry (no-loss). So the off-ramps are: resume (re-poll -> verify -> claim), and a
// CLTV-gated abandon — a held record may be cleared only once the Sequentia tip has PASSED T_seq
// (claiming is then forbidden anyway and the hold, whose CLTV was validated to cover T_seq, has
// expired back). Pre-hold records committed nothing and clear freely.
//
// Pure gates (bolt11 decode, redeem/leg/funding binding, hold-CLTV) are REUSED from subswap_service.
// ---------------------------------------------------------------------------

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import 'api_client.dart';
import 'config.dart';
import 'lightning_service.dart';
import 'lsp_client.dart';
import 'seqob_client.dart' show CrossOffer;
import 'store_log.dart';
import 'trade_slots.dart';
import 'subswap_service.dart'
    show
        bolt11AmountMsat,
        bolt11PaymentHash,
        checkFundingOutput,
        checkLegBinding,
        checkRedeemMatches,
        kSubClaimMargin,
        kSubMinAnchorDepth;
import 'trade_receipts.dart';
import 'wallet_repository.dart';

/// CLN's default --max-cltv-expiry (blocks): our OWN hosted BTC node cannot route an HTLC whose total
/// CLTV exceeds this, so it is the hard ceiling on any hold we could pay (web DEFAULT_NODE_MAX_CLTV).
const int kBridgeNodeMaxCltv = 2016;

/// The bridge hold-life model (web leg-bridge.mjs HOLD_LIFE_DEFAULTS), used ONLY to derive the
/// SKEW-IMMUNE cap on the hold's demanded min-final-CLTV: the largest value any HONEST in-bound swap
/// could require, at the max admissible T_seq window — independent of our live tip, so an LSP that read
/// a slightly-earlier tip is never wrongly rejected while an absurd demand still is.
const int kBridgeMaxTseqBlocks = 480; // max (T_seq - tip) the LSP/taker admits
const int kBridgeSeqSecsPerBlock = 90; // conservative-SLOW Sequentia block time
const int kBridgeFastBtcSecsPerBlock = 150; // conservative-FAST Bitcoin block time
const int kBridgeReorgMarginSecs = 2 * 3600;
const int kBridgeSettleMarginSecs = 30 * 60;
const int kBridgeCltvMarginBlocks = 6;

final BigInt _kScale = BigInt.from(100000000);
final RegExp _kHex64 = RegExp(r'^[0-9a-fA-F]{64}$');

/// The bridge state machine (web SUBSWAP kind 'lsp-payer-buy'). starting -> confirming (job posted) ->
/// held (the BTC-LN hold is PAID) -> claiming (leg verified; P about to be / being revealed) ->
/// settled. `failed` is terminal ONLY pre-hold; a post-hold failure keeps its live state so resume
/// keeps polling (the hold may be HELD — only a verified asset-in-our-key claim reveals P).
/// [unknown] decodes any unrecognised persisted state NON-terminal (the subswap lesson).
enum BridgeState { starting, confirming, held, claiming, settled, failed, unknown }

/// The persisted single-slot payer-bridge record. P lives ONLY here (self-custody) — persisted at mint
/// time (persist-P-early), before any wire act, so a crash at any later point can still claim.
class LspBridgeRecord {
  LspBridgeRecord({
    String? id,
    required this.state,
    required this.asset,
    required this.assetAtoms,
    required this.btcSats,
    required this.offerId,
    required this.makerPubkey,
    required this.hashHex,
    required this.preimageHex,
    this.jobId = '',
    this.poll = '',
    this.seqLocktime = 0,
    this.makerRefundPub = '',
    this.legTxid = '',
    this.legVout = -1,
    this.legRedeem = '',
    this.legBlockHash = '',
    this.seqClaimTxid = '',
    this.btcNodeKey = '',
    this.holdMinFinalCltv = 0,
    required this.startedMs,
    this.detail = '',
  }) : id = id ?? newTradeId();

  /// Stable per-record id (multi-record store): saves upsert on it, so records never clobber.
  final String id;
  BridgeState state;
  final String asset;
  final BigInt assetAtoms; // the exact amounts the maker binds on (whole-offer)
  final BigInt btcSats;
  final String offerId;
  final String makerPubkey;
  final String hashHex; // H = sha256(P)
  final String preimageHex; // P — SELF-CUSTODY, persisted before anything leaves the device
  String jobId;
  String poll;
  int seqLocktime; // T_seq from bridge_terms (0 until the terms arrive)
  String makerRefundPub; // the leg's refund key — re-read WITH the leg (a fronted leg is LSP-refundable)
  String legTxid; // the maker's verified asset leg (set only after verification)
  int legVout;
  String legRedeem; // OUR rebuilt redeem (never the relayed bytes)
  String legBlockHash;
  String seqClaimTxid;
  String btcNodeKey;
  int holdMinFinalCltv; // the validated hold CLTV (informational; the hold refunds itself)
  final int startedMs;
  String detail;

  /// The swap resolved (asset claimed) or died before ANY value moved.
  bool get terminal => state == BridgeState.settled || state == BridgeState.failed;

  /// The taker's Bitcoin is (or might be) committed in a HELD payment whose only key to value — P —
  /// lives in this record. True from the hold on; such a record must NEVER be silently cleared.
  bool get holdsOrMightHoldValue =>
      !terminal &&
      (state == BridgeState.held || state == BridgeState.claiming || state == BridgeState.unknown);

  Map<String, dynamic> toJson() => {
        'id': id,
        'state': state.name,
        'asset': asset,
        'asset_atoms': assetAtoms.toString(),
        'btc_sats': btcSats.toString(),
        'offer_id': offerId,
        'maker_pubkey': makerPubkey,
        'hash_h': hashHex,
        'preimage': preimageHex,
        'job_id': jobId,
        'poll': poll,
        'seq_locktime': seqLocktime,
        'maker_refund_pub': makerRefundPub,
        'leg_txid': legTxid,
        'leg_vout': legVout,
        'leg_redeem': legRedeem,
        'leg_block_hash': legBlockHash,
        'seq_claim_txid': seqClaimTxid,
        'btc_node_key': btcNodeKey,
        'hold_min_final_cltv': holdMinFinalCltv,
        'started_ms': startedMs,
        'detail': detail,
      };

  static LspBridgeRecord fromJson(Map<String, dynamic> j) => LspBridgeRecord(
        id: '${j['id'] ?? ''}'.isEmpty ? null : '${j['id']}',
        // Unrecognised persisted state -> NON-terminal [BridgeState.unknown]: a live record must never
        // read as done and get clobbered (mirror SubswapRecord.fromJson).
        state: BridgeState.values.firstWhere((s) => s.name == j['state'], orElse: () => BridgeState.unknown),
        asset: '${j['asset'] ?? ''}',
        assetAtoms: BigInt.tryParse('${j['asset_atoms'] ?? 0}') ?? BigInt.zero,
        btcSats: BigInt.tryParse('${j['btc_sats'] ?? 0}') ?? BigInt.zero,
        offerId: '${j['offer_id'] ?? ''}',
        makerPubkey: '${j['maker_pubkey'] ?? ''}',
        hashHex: '${j['hash_h'] ?? ''}',
        preimageHex: '${j['preimage'] ?? ''}',
        jobId: '${j['job_id'] ?? ''}',
        poll: '${j['poll'] ?? ''}',
        seqLocktime: (j['seq_locktime'] as num?)?.toInt() ?? 0,
        makerRefundPub: '${j['maker_refund_pub'] ?? ''}',
        legTxid: '${j['leg_txid'] ?? ''}',
        legVout: (j['leg_vout'] as num?)?.toInt() ?? -1,
        legRedeem: '${j['leg_redeem'] ?? ''}',
        legBlockHash: '${j['leg_block_hash'] ?? ''}',
        seqClaimTxid: '${j['seq_claim_txid'] ?? ''}',
        btcNodeKey: '${j['btc_node_key'] ?? ''}',
        holdMinFinalCltv: (j['hold_min_final_cltv'] as num?)?.toInt() ?? 0,
        startedMs: (j['started_ms'] as num?)?.toInt() ?? 0,
        detail: '${j['detail'] ?? ''}',
      );
}

/// Multi-record secure-storage store for the active payer-bridges (the XrSwapStore twin under its own
/// keys), with one-time never-lossy adoption of the legacy single-slot record ('ambra.bridge.active').
/// A read never deletes stored material; only an explicit per-record [remove] does.
class LspBridgeStore {
  LspBridgeStore._();
  static final TradeListStore _list =
      TradeListStore(listKey: 'ambra.bridges', legacyKey: 'ambra.bridge.active');

  /// Every persisted bridge record. Undecodable entries are skipped but PRESERVED on disk.
  static Future<List<LspBridgeRecord>> loadAll() async {
    final read = await _list.readAll();
    final out = <LspBridgeRecord>[];
    for (final e in read.entries) {
      try {
        out.add(LspBridgeRecord.fromJson(e));
      } catch (_) {/* preserved on disk; not drivable by this build */}
    }
    return out;
  }

  /// Compat single-record read: by [id] when given, else the first holding value, else the most recent.
  static Future<LspBridgeRecord?> load({String? id}) async {
    final all = await loadAll();
    if (all.isEmpty) return null;
    if (id != null && id.isNotEmpty) {
      for (final r in all) {
        if (r.id == id) return r;
      }
      return null;
    }
    for (final r in all) {
      if (r.holdsOrMightHoldValue) return r;
    }
    return all.first;
  }

  static Future<void> save(LspBridgeRecord r) => _list.upsert(r.toJson());

  /// Remove ONE record by id (after the CLTV-gated abandon / pre-commitment cleanup). [reason] is
  /// logged loudly by the substrate — a bridge record removal must never be silent.
  static Future<void> remove(String id, {String reason = 'unspecified'}) =>
      _list.removeById(id, reason: reason);

  /// The records the store must protect: non-terminal AND holding (or possibly holding) a committed
  /// HELD payment keyed by that record's P. Slot count + cards + resume iterate these.
  static Future<List<LspBridgeRecord>> inFlightWithFunds() async =>
      (await loadAll()).where((r) => r.holdsOrMightHoldValue).toList();

  /// TEST-ONLY full wipe.
  static Future<void> clear() => _list.wipeAll();
}

/// The chain + LSP seam every network/FFI touch goes through, so tests can mock the world. The live
/// implementation reuses the SAME primitives as the P2P submarine (core xchain FFIs + esplora).
abstract class BridgeChain {
  /// Mint the swap secret P + H = sha256(P) (core xchainNewSecret; P never leaves the device).
  Future<({String secretHex, String hashHex})> newSecret();
  Future<String> takerSeqClaimPub();
  Future<core.SeqHtlcInfo> seqHtlcForward({required String hashHex, required String makerRefundPub, required int seqLocktime});
  Future<Map<String, dynamic>?> seqTx(String txid);
  Future<int> seqTipHeight(); // -1 when unreadable (a failed read is not a verdict)
  Future<bool> waitAnchorBuried({required String txid, required int minDepth, void Function()? onWait});
  Future<String> claimSeq({
    required String seqTxid,
    required int seqVout,
    required BigInt amountAtoms,
    required String assetId,
    required String redeemScriptHex,
    required int seqLocktime,
    required String makerRefundPub,
    required String hashHex,
    required String preimageHex,
  });
  Future<SubSwapJob> lspSwapBridge(Map<String, dynamic> p);
  Future<BridgeJobStatus?> lspBridgeStatus(String pollPathOrId);
  Future<BridgeHold> lspBridgeHold(String jobId);
  Future<Map<String, dynamic>> lspNodePayHash({
    required String nodeKey,
    required String nodeId,
    required String hash,
    required BigInt amountMsat,
    int? minFinalCltv,
    List<dynamic>? connectHints,
  });
  Future<String> btcNodeKey();
}

/// Poll cadences / deadlines, swappable for tests (mirror the web driver's defaults).
class BridgeTiming {
  const BridgeTiming({
    this.poll = const Duration(seconds: 4),
    this.handshakeWait = const Duration(minutes: 10),
    this.legWait = const Duration(minutes: 45),
  });
  final Duration poll;
  final Duration handshakeWait;
  final Duration legWait;
}

class LspBridgeService {
  LspBridgeService._();

  static BridgeChain chain = BridgeChainLive();
  static BridgeTiming timing = const BridgeTiming();

  // ---- pure gates ------------------------------------------------------------------------------------

  /// The SEQ CLAIM WINDOW gate (fund-loss, critical): claiming reveals P, which lets the LSP settle its
  /// HELD BTC-LN — so P may be revealed ONLY while the asset is still ours to claim strictly before
  /// T_seq. An unreadable tip (< 0) fails CLOSED. PURE; the driver AND resume both call it, and it is
  /// re-checked with a FRESH tip immediately before the irreversible claim.
  static bool claimWindowOpen({required int seqTip, required int seqLocktime, int claimMargin = kSubClaimMargin}) {
    if (seqTip < 0 || seqLocktime <= 0) return false;
    return seqLocktime > seqTip + claimMargin;
  }

  /// The SKEW-IMMUNE cap on the hold's demanded min-final-CLTV: the largest value any HONEST in-bound
  /// swap could require (requiredTakerHold at the max T_seq window), floored by our node's routing
  /// ceiling. Constant, so an LSP that read a slightly-earlier tip than us is never wrongly rejected —
  /// while a masqueraded hold demanding an absurd CLTV (locking our Bitcoin far past T_seq) still is.
  static int holdCltvCap() {
    final requiredSecs =
        kBridgeMaxTseqBlocks * kBridgeSeqSecsPerBlock + kBridgeReorgMarginSecs + kBridgeSettleMarginSecs;
    final tseqDerived = (requiredSecs / kBridgeFastBtcSecsPerBlock).ceil() + kBridgeCltvMarginBlocks;
    return tseqDerived < kBridgeNodeMaxCltv ? tseqDerived : kBridgeNodeMaxCltv;
  }

  /// Whether the persisted record may be cleared without stranding value. Terminal and pre-hold records
  /// clear freely (nothing committed). A record that holds (or might hold) a HELD payment clears ONLY
  /// once the Sequentia tip has PASSED T_seq: claiming is then forbidden anyway (revealing P would race
  /// the maker's refund) and the hold — whose CLTV was validated to cover T_seq — has failed back. PURE
  /// given [seqTip]; pass a FRESH read.
  static bool canAbandon(LspBridgeRecord rec, {required int seqTip}) {
    if (rec.terminal) return true;
    if (!rec.holdsOrMightHoldValue) return true; // starting/confirming: the hold was never paid
    return seqTip >= 0 && rec.seqLocktime > 0 && seqTip >= rec.seqLocktime;
  }

  /// Clear ONE record, refused (false) while [canAbandon] says it still protects value. Judged on the
  /// FRESH on-disk record by id; removes exactly that record.
  static Future<bool> abandon(LspBridgeRecord record) async {
    final rec = await LspBridgeStore.load(id: record.id);
    if (rec == null) return true; // already gone
    final tip = await chain.seqTipHeight();
    if (!canAbandon(rec, seqTip: tip)) return false;
    await LspBridgeStore.remove(rec.id,
        reason: 'user clear, CLTV-gated abandon allowed (state=${rec.state.name}, T_seq=${rec.seqLocktime}, tip=$tip)');
    return true;
  }

  // ---- the driver ------------------------------------------------------------------------------------

  /// Run a bridged BUY of [offer] (whole-offer: the maker binds exact amounts) to completion. ONE
  /// consent is taken by the CALLER before this runs; every fail-closed path before the hold pays
  /// commits nothing. Throws on failure with the persisted record carrying the state.
  static Future<LspBridgeRecord> buy(CrossOffer offer, {void Function(String)? onStep}) async {
    void step(String s) => onStep?.call(s);

    // SHARED SLOT GATE (web tradeSlotsFree): records upsert by id so a second bridge can never
    // overwrite one protecting a HELD payment — the single-slot hard refusal is replaced by the
    // bounded concurrent-trade count across all rail-crossing kinds.
    final refusal = await TradeSlots.refusalIfFull();
    if (refusal != null) throw Exception(refusal);
    if (offer.assetAtoms <= BigInt.zero || offer.btcSats <= BigInt.zero) {
      throw Exception('This offer has no amounts to bind - nothing was placed.');
    }

    // 0. Mint P SELF-CUSTODY; H = sha256(P). PERSIST-P-EARLY: the record exists before any wire act.
    step('Preparing the swap…');
    final secret = await chain.newSecret();
    final preimage = secret.secretHex.toLowerCase();
    final hashH = secret.hashHex.toLowerCase();
    if (!_kHex64.hasMatch(preimage) || !_kHex64.hasMatch(hashH) || _sha256Hex(preimage) != hashH) {
      throw Exception('The swap secret could not be minted - nothing was placed.');
    }
    final claimPub = await chain.takerSeqClaimPub();
    final rec = LspBridgeRecord(
      state: BridgeState.starting,
      asset: offer.seqAsset,
      assetAtoms: offer.assetAtoms,
      btcSats: offer.btcSats,
      offerId: offer.offerId,
      makerPubkey: offer.makerPubkey,
      hashHex: hashH,
      preimageHex: preimage,
      startedMs: DateTime.now().millisecondsSinceEpoch,
    );
    await LspBridgeStore.save(rec);

    try {
      // 1. POST the bridged swap; poll for the forward-maker terms (bridge_terms) bound to OUR H.
      step('Asking the service to secure a maker…');
      final job = await chain.lspSwapBridge({
        'asset': offer.seqAsset,
        'asset_atoms': offer.assetAtoms,
        'btc_sats': offer.btcSats,
        'offer_id': offer.offerId,
        'maker_pubkey': offer.makerPubkey,
        'hash_h': hashH,
        'taker_seq_claim_pub': claimPub,
      });
      final poll = job.poll ?? job.jobId;
      if (poll == null || poll.isEmpty) {
        throw Exception('The service returned no job handle - nothing was committed.');
      }
      rec
        ..jobId = job.jobId ?? ''
        ..poll = poll
        ..state = BridgeState.confirming;
      await LspBridgeStore.save(rec);

      step('Waiting for the maker terms…');
      BridgeJobStatus? terms;
      final hsDeadline = DateTime.now().add(timing.handshakeWait);
      for (;;) {
        final j = await chain.lspBridgeStatus(poll);
        if (j != null && j.hasTerms) {
          if (j.termsHashH != hashH) {
            throw Exception('The service handshake bound a different secret - nothing was committed.');
          }
          terms = j;
          break;
        }
        if (j != null && j.failed) {
          throw Exception('The maker handshake failed: ${j.error ?? 'unknown'} - nothing was committed.');
        }
        if (DateTime.now().isAfter(hsDeadline)) {
          throw Exception('The maker terms never arrived - nothing was committed.');
        }
        await Future<void>.delayed(timing.poll);
      }
      rec
        ..seqLocktime = terms.seqLocktime ?? 0
        ..makerRefundPub = terms.makerSeqRefundPub ?? '';
      await LspBridgeStore.save(rec);

      // 2. The BTC-LN hold on H — validate EVERYTHING before the single irreversible act (paying it).
      step('Setting up your Bitcoin payment…');
      final hold = await chain.lspBridgeHold(rec.jobId.isNotEmpty ? rec.jobId : poll);
      // FAIL CLOSED with zero exposure when the LSP returns NO usable target.
      if ((hold.nodeId == null || hold.nodeId!.isEmpty) && (hold.bolt11 == null || hold.bolt11!.isEmpty)) {
        throw Exception('This trade could not be placed right now - try again shortly.');
      }
      // PAYMENT-HASH assert: the hold MUST be on OUR H (we pay by our own H regardless; this rejects a
      // confused LSP up front rather than committing an HTLC that could only stall).
      if (hold.paymentHash != null && hold.paymentHash!.toLowerCase() != hashH) {
        throw Exception('The service hold is not bound to your swap secret - NOT paying (nothing committed).');
      }
      if (hold.bolt11 != null && hold.bolt11!.isNotEmpty) {
        final hh = bolt11PaymentHash(hold.bolt11);
        if (hh == null || hh != hashH) {
          throw Exception('The hold invoice is not bound to your swap secret - NOT paying (nothing committed).');
        }
      }
      // OVERPAY guard: never hold-pay more than the offer's price. amount_msat is authoritative when
      // present, else the decoded invoice amount, else exactly the offer amount (an amountless hold).
      final maxMsat = offer.btcSats * BigInt.from(1000);
      final holdMsat = hold.amountMsat ?? (hold.bolt11 != null ? bolt11AmountMsat(hold.bolt11) : null) ?? maxMsat;
      if (holdMsat > maxMsat) {
        throw Exception('The hold demands $holdMsat msat, more than the offer\'s $maxMsat - NOT paying (nothing committed).');
      }
      // CLTV FLOOR + CAP: a zero/absent min-final-CLTV would commit an HTLC that lapses before the
      // asset can be delivered; one above the skew-immune honest cap would lock our Bitcoin far past
      // T_seq. Mirror the web payMaxCltv discipline (the pay itself is bounded by the node's ceiling).
      final minFinalCltv = hold.holdMinFinalCltv ?? 0;
      if (minFinalCltv <= 0) {
        throw Exception('The hold has no timeout covering the asset delivery - NOT paying (nothing committed).');
      }
      final cap = holdCltvCap();
      if (minFinalCltv > cap) {
        throw Exception('The hold demands a $minFinalCltv-block timeout, above the safe maximum $cap - '
            'NOT paying (it would lock your Bitcoin far past the asset timeout; nothing committed).');
      }
      // PAY BY BARE HASH from the user's OWN hosted BTC node. IRREVERSIBLE (the payment lands HELD).
      step('Paying the Bitcoin hold over Lightning…');
      final nodeKey = await chain.btcNodeKey();
      rec.btcNodeKey = nodeKey;
      rec.holdMinFinalCltv = minFinalCltv;
      await LspBridgeStore.save(rec);
      final pay = await chain.lspNodePayHash(
        nodeKey: nodeKey,
        nodeId: hold.nodeId ?? '',
        hash: hashH,
        amountMsat: holdMsat,
        minFinalCltv: minFinalCltv,
        connectHints: hold.connectHints,
      );
      final committed = pay['committed'] == true || pay['status'] == 'pending' || pay['status'] == 'complete';
      if (!committed) {
        throw Exception('This trade could not be completed - your funds are safe.');
      }
      rec.state = BridgeState.held;
      await LspBridgeStore.save(rec);

      // 3.–4. Wait for the maker's asset leg, verify, anchor-gate, window-gate, claim. Shared with
      // resume so a crash anywhere after the hold lands re-enters the exact same ladder.
      return await _awaitLegVerifyAndClaim(rec, onStep: onStep);
    } catch (e) {
      // A post-hold failure keeps its live state (held/claiming) so resume keeps polling — the HELD
      // payment may still settle or fail back on its own CLTV. Pre-hold, nothing moved: fail terminal.
      if (!rec.holdsOrMightHoldValue) {
        rec
          ..state = BridgeState.failed
          ..detail = e.toString().replaceFirst('Exception: ', '');
        await LspBridgeStore.save(rec);
      } else {
        rec.detail = e.toString().replaceFirst('Exception: ', '');
        await LspBridgeStore.save(rec);
      }
      rethrow;
    }
  }

  /// Poll for the maker's asset leg, VERIFY it binds our key/asset/amount, wait for the Bitcoin-anchor
  /// burial, gate the claim window, and claim with P. Entered by the live driver (post-hold) and by
  /// [resume] (branch C) — the ordering is identical in both.
  static Future<LspBridgeRecord> _awaitLegVerifyAndClaim(LspBridgeRecord rec, {void Function(String)? onStep}) async {
    void step(String s) => onStep?.call(s);

    // 3. Wait for the relayed leg. THE REFUND KEY IS A PROPERTY OF THE LEG WE ARE HANDED, not of the
    // handshake: the LSP may front the asset from its own inventory, and a fronted leg is refundable by
    // the LSP — so re-read maker_seq_refund_pub from the SAME response that carried the leg.
    step('Waiting for the asset to lock to your key… this waits on Bitcoin confirmations, typically '
        '10-60+ minutes on testnet4. Safe to leave the app · the trade resumes from its in-flight card '
        'on the Swap tab, and if it cannot complete every leg refunds on its own timeout.');
    BridgeLeg? leg;
    var legRefundPub = rec.makerRefundPub;
    var seqLt = rec.seqLocktime;
    // HONEST DRIVE-TIME COPY (step strings only — the gates/ordering below are untouched): when the job
    // reports the LSP is FRONTING the asset from its own inventory (front_mode 'inventory'), say the
    // fast variant instead of leaving the 10-60+ minute line standing. Absent front_mode = maker-first
    // (slow) — the default copy above stays.
    var saidFronted = false;
    final legDeadline = DateTime.now().add(timing.legWait);
    for (;;) {
      final j = await chain.lspBridgeStatus(rec.poll.isNotEmpty ? rec.poll : rec.jobId);
      final ml = j?.makerSeqLeg;
      if (ml != null) {
        leg = ml;
        if (j!.makerSeqRefundPub != null && j.makerSeqRefundPub!.isNotEmpty) legRefundPub = j.makerSeqRefundPub!;
        if ((j.seqLocktime ?? 0) > 0) seqLt = j.seqLocktime!;
        break;
      }
      if (!saidFronted && j != null && j.frontedFromInventory) {
        saidFronted = true;
        step('The service is fronting your asset from its own inventory — no waiting on the maker\'s '
            'Bitcoin confirmations · typically ${j.expectedWait ?? 'about a minute'}.');
      }
      if (j != null && j.status == 'failed') {
        throw Exception('The swap failed before the asset locked: ${j.error ?? 'unknown'} · your Bitcoin '
            'hold expires back on its own - no loss.');
      }
      if (DateTime.now().isAfter(legDeadline)) {
        throw Exception('The maker never locked the asset · your Bitcoin hold expires back on its own - no loss.');
      }
      await Future<void>.delayed(timing.poll);
    }
    if (seqLt <= 0) seqLt = leg.locktime;
    rec
      ..seqLocktime = seqLt
      ..makerRefundPub = legRefundPub;
    await LspBridgeStore.save(rec);

    // 4a. VERIFY: rebuild the redeem from OUR key + H (never the relayed bytes), byte-compare, bind the
    // leg to the agreed amounts, and bind the on-chain funding output to the HTLC P2SH. A leg we cannot
    // SEE yet is not a leg that is WRONG: the LSP fronts at 0-conf, so a funding output still in the
    // mempool is POLLED (bounded by the leg deadline); every other mismatch fails closed on first look.
    step('Verifying the asset is locked to your key…');
    final htlc = await chain.seqHtlcForward(hashHex: rec.hashHex, makerRefundPub: legRefundPub, seqLocktime: seqLt);
    final vr = checkRedeemMatches(rebuilt: htlc.redeemScriptHex, provided: leg.redeemScript);
    if (!vr.ok) {
      throw Exception('The asset leg failed verification (NOT claiming; the hold expires no-loss): ${vr.reason}');
    }
    final vb = checkLegBinding(
      legAmount: leg.amount,
      legAsset: leg.asset,
      legLocktime: leg.locktime,
      legTxid: leg.txid,
      legVout: leg.vout,
      expectAsset: rec.asset,
      expectAtoms: rec.assetAtoms,
      expectLocktime: seqLt,
    );
    if (!vb.ok) {
      throw Exception('The asset leg failed verification (NOT claiming; the hold expires no-loss): ${vb.reason}');
    }
    final verifyDeadline = DateTime.now().add(timing.legWait);
    for (;;) {
      final tx = await chain.seqTx(leg.txid);
      final vouts = (tx?['vout'] as List?) ?? const [];
      final o = (leg.vout >= 0 && leg.vout < vouts.length) ? vouts[leg.vout] as Map? : null;
      if (o != null) {
        final vf = checkFundingOutput(
          outputSpk: '${o['scriptpubkey'] ?? ''}',
          outputValue: BigInt.tryParse('${o['value'] ?? 0}'),
          outputAsset: '${o['asset'] ?? ''}',
          expectSpkHex: htlc.p2ShSpkHex,
          expectAtoms: rec.assetAtoms,
          expectAsset: rec.asset,
        );
        if (!vf.ok) {
          throw Exception('The asset leg failed verification (NOT claiming; the hold expires no-loss): ${vf.reason}');
        }
        break; // funding output seen and bound
      }
      if (DateTime.now().isAfter(verifyDeadline)) {
        throw Exception('The asset funding never became visible on-chain (NOT claiming; the hold expires no-loss).');
      }
      await Future<void>.delayed(timing.poll);
    }

    // 4b. ANCHOR GATE: wait until the funding block is Bitcoin-anchor-buried — never reveal P against a
    // reorg-able asset HTLC. Fails closed on timeout (the hold refunds no-loss).
    // A FRONTED leg arrived without the maker's confirmation wait, so the honest timescale here is the
    // anchor burial alone — don't re-promise 10-60+ minutes the fast variant does not spend.
    final anchorWait = saidFronted
        ? 'usually quick for a fronted leg'
        : 'typically 10-60+ minutes on testnet4';
    step('Waiting for the asset to anchor to Bitcoin… $anchorWait. Safe to '
        'leave the app · the trade resumes from its in-flight card.');
    final anchored = await chain.waitAnchorBuried(
      txid: leg.txid,
      minDepth: kSubMinAnchorDepth,
      onWait: () => step('Waiting for the asset block to confirm and anchor to Bitcoin… $anchorWait. '
          'Safe to leave the app · the trade resumes from its in-flight card.'),
    );
    if (!anchored) {
      throw Exception('The asset did not anchor to Bitcoin in time (NOT claiming; the hold expires no-loss).');
    }

    // 4c. CLAIM-WINDOW GATE (fund-loss, critical): never reveal P unless the asset is still ours to
    // claim strictly before T_seq (else the maker refunds while the LSP captures our Bitcoin).
    final tip1 = await chain.seqTipHeight();
    if (!claimWindowOpen(seqTip: tip1, seqLocktime: seqLt)) {
      throw Exception('The claim window is too small (T_seq $seqLt vs tip $tip1) - NOT claiming '
          '(revealing the secret now risks a refund-race loss).');
    }
    rec
      ..legTxid = leg.txid
      ..legVout = leg.vout
      ..legRedeem = htlc.redeemScriptHex
      ..legBlockHash = leg.blockHash
      ..state = BridgeState.claiming;
    await LspBridgeStore.save(rec);

    // RE-CHECK with a FRESH tip immediately before the irreversible claim (the tip may have advanced
    // during the anchor poll / persist; never reveal P into a window that has since closed).
    final tip2 = await chain.seqTipHeight();
    if (!claimWindowOpen(seqTip: tip2, seqLocktime: seqLt)) {
      throw Exception('The claim window closed before the claim (T_seq $seqLt vs tip $tip2) - NOT revealing the secret.');
    }

    step('Claiming your asset…');
    final txid = await chain.claimSeq(
      seqTxid: leg.txid,
      seqVout: leg.vout,
      amountAtoms: rec.assetAtoms,
      assetId: rec.asset,
      redeemScriptHex: htlc.redeemScriptHex,
      seqLocktime: seqLt,
      makerRefundPub: legRefundPub,
      hashHex: rec.hashHex,
      preimageHex: rec.preimageHex,
    );
    rec
      ..seqClaimTxid = txid
      ..state = BridgeState.settled
      ..detail = '';
    await LspBridgeStore.save(rec);
    TradeReceipts.log(
      id: 'bridge:${rec.hashHex}',
      title: 'Bought ${SeqAssets.labelFor(rec.asset).ticker} with BTC (Lightning, bridged)',
      status: 'Settled',
      txid: txid,
    ).ignore();
    step('Swap complete - the asset is yours.');
    return rec;
  }

  // ---- resume ----------------------------------------------------------------------------------------

  /// Resume a persisted bridge after a restart — the mobile twin of the web resumeSubswap branches (A)
  /// and (C), with the SAME ordering (verify -> window-gated claim):
  ///   claiming (leg verified, P possibly revealed) -> re-claim idempotently, STILL window-gated: for
  ///     the payer bridge, claiming is what FIRST reveals P, so a claim that never landed must not
  ///     reveal it into a closed window.
  ///   held / confirming (the hold may be HELD)     -> re-poll the job for the relayed leg, then the
  ///     full verify -> anchor -> window -> claim ladder. NEVER dropped.
  ///   starting (no job posted, no hold)            -> nothing committed; cleared.
  /// Returns the record (possibly advanced), or null when nothing is persisted. With the multi-record
  /// store, EVERY non-terminal record is resumed INDEPENDENTLY (one stuck job never blocks another
  /// record's claim); [record] targets a specific one (the resume sheet). The return value is the
  /// targeted record when given, else the first record touched (compat).
  static Future<LspBridgeRecord?> resume({void Function(String)? onStep, LspBridgeRecord? record}) async {
    if (record != null) {
      final fresh = await LspBridgeStore.load(id: record.id);
      storeLog('bridge resume (targeted): id=${record.id} '
          '${fresh == null ? 'NOT FOUND on disk (driving the caller\'s copy)' : 'found, state=${fresh.state.name}'}');
      return _resumeOne(fresh ?? record, onStep: onStep);
    }
    List<LspBridgeRecord> recs;
    try {
      recs = await LspBridgeStore.loadAll();
    } catch (e) {
      storeLog('bridge resume: store UNREADABLE ($e) - nothing driven, records stay persisted');
      return null;
    }
    storeLog('bridge resume: ${recs.length} record(s)'
        '${recs.isEmpty ? '' : ' [${recs.map((r) => '${r.id}:${r.state.name}').join(', ')}]'}');
    LspBridgeRecord? first;
    await Future.wait([
      for (final r in recs)
        if (!r.terminal)
          _resumeOne(r, onStep: onStep).then((v) => first ??= v).catchError((Object _) => null),
    ]);
    return first;
  }

  static Future<LspBridgeRecord?> _resumeOne(LspBridgeRecord rec, {void Function(String)? onStep}) async {
    if (rec.terminal) {
      storeLog('bridge resume: id=${rec.id} terminal (state=${rec.state.name}) - nothing to drive');
      return rec;
    }
    if (rec.state == BridgeState.claiming && rec.legTxid.isNotEmpty && rec.legRedeem.isNotEmpty) {
      storeLog('bridge resume: id=${rec.id} state=claiming - re-claim (window-gated)');
      // (A) Re-claim idempotently (a crash between the window re-check and the claim must never strand
      // the asset — we hold P). CLAIM-WINDOW GATE stays active (claimWindowGate:true in the web twin).
      final tip = await chain.seqTipHeight();
      if (!claimWindowOpen(seqTip: tip, seqLocktime: rec.seqLocktime)) {
        rec.detail = 'The claim window has closed; your Bitcoin hold expires back on its own.';
        await LspBridgeStore.save(rec);
        return rec;
      }
      try {
        final txid = await chain.claimSeq(
          seqTxid: rec.legTxid,
          seqVout: rec.legVout,
          amountAtoms: rec.assetAtoms,
          assetId: rec.asset,
          redeemScriptHex: rec.legRedeem,
          seqLocktime: rec.seqLocktime,
          makerRefundPub: rec.makerRefundPub,
          hashHex: rec.hashHex,
          preimageHex: rec.preimageHex,
        );
        rec
          ..seqClaimTxid = txid
          ..state = BridgeState.settled
          ..detail = '';
        await LspBridgeStore.save(rec);
      } catch (e) {
        // Leave RESUMABLE; a retry re-claims (an already-spent HTLC just fails harmlessly here).
        rec.detail = 'Completing your trade - your funds are safe.';
        await LspBridgeStore.save(rec);
      }
      return rec;
    }
    if ((rec.state == BridgeState.held || rec.state == BridgeState.confirming || rec.state == BridgeState.unknown) &&
        (rec.jobId.isNotEmpty || rec.poll.isNotEmpty)) {
      // (C) The hold may be HELD: re-poll for the leg and run the identical verify->claim ladder.
      storeLog('bridge resume: id=${rec.id} state=${rec.state.name} - re-polling the job (hold may be HELD)');
      try {
        return await _awaitLegVerifyAndClaim(rec, onStep: onStep);
      } catch (e) {
        rec.detail = e.toString().replaceFirst('Exception: ', '');
        await LspBridgeStore.save(rec);
        storeLog('bridge resume: id=${rec.id} ladder paused (kept persisted): ${rec.detail}');
        return rec; // NEVER dropped — only a verified asset-in-our-key claim reveals P
      }
    }
    // Pre-commitment (no job posted, hold never paid): the session is gone and nothing moved — remove
    // exactly THIS record (never the whole store).
    if (!rec.holdsOrMightHoldValue) {
      await LspBridgeStore.remove(rec.id,
          reason: 'resume: pre-commitment record (state=${rec.state.name}, no job/hold) - nothing was committed');
      return null;
    }
    storeLog('bridge resume: id=${rec.id} state=${rec.state.name} holds value but has no job handle - kept persisted');
    return rec;
  }

  static String _sha256Hex(String hexStr) {
    final bytes = <int>[];
    for (var i = 0; i + 1 < hexStr.length; i += 2) {
      bytes.add(int.parse(hexStr.substring(i, i + 2), radix: 16));
    }
    return sha256.convert(bytes).toString();
  }
}

/// The live seam: the SAME ambra_core FFIs + esplora/LSP endpoints the P2P submarine uses.
class BridgeChainLive implements BridgeChain {
  Future<String> _mnemonic() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw Exception('wallet unavailable');
    return m;
  }

  @override
  Future<({String secretHex, String hashHex})> newSecret() async {
    final s = await core.xchainNewSecret();
    return (secretHex: s.secretHex, hashHex: s.hashHex);
  }

  @override
  Future<String> takerSeqClaimPub() async =>
      (await core.xchainSeqClaimPubkey(mnemonic: await _mnemonic())).toLowerCase();

  @override
  Future<core.SeqHtlcInfo> seqHtlcForward(
          {required String hashHex, required String makerRefundPub, required int seqLocktime}) async =>
      core.xchainSeqHtlcForward(
        mnemonic: await _mnemonic(),
        hashHex: hashHex,
        makerSeqRefundPubHex: makerRefundPub,
        seqLocktime: seqLocktime,
      );

  @override
  Future<Map<String, dynamic>?> seqTx(String txid) async {
    try {
      final resp = await http
          .get(Uri.parse('${Backend.esplora}/tx/$txid'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int> seqTipHeight() async {
    try {
      final resp = await http
          .get(Uri.parse('${Backend.esplora}/blocks/tip/height'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 20));
      return int.tryParse(resp.body.trim()) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<bool> waitAnchorBuried({required String txid, required int minDepth, void Function()? onWait}) async {
    // The funding block is derived from the txid's OWN confirmed status (never a relayed block hash);
    // a still-mempool funding is WAITED OUT. Mirrors SubswapService._waitAnchorBuried.
    final until = DateTime.now().add(const Duration(minutes: 20));
    while (true) {
      final tx = await seqTx(txid);
      final status = tx?['status'] as Map?;
      final confirmed = status != null && status['confirmed'] == true;
      final blockHash = '${status?['block_hash'] ?? ''}';
      if (confirmed && blockHash.isNotEmpty) {
        try {
          final ev = await core.xchainVerifySeqLegSafe(
            seqEsplora: Backend.esplora,
            seqBlockHash: blockHash,
            btcLegHeight: 0, // no BTC on-chain leg on the bridge path; the anchor-depth gate governs
            t4Api: Backend.testnet4,
            minDepth: minDepth,
          );
          if (ev.ok) return true;
        } catch (_) {/* transient / not-yet-anchored — wait and retry */}
      }
      if (DateTime.now().isAfter(until)) return false;
      onWait?.call();
      await Future<void>.delayed(const Duration(seconds: 20));
    }
  }

  @override
  Future<String> claimSeq({
    required String seqTxid,
    required int seqVout,
    required BigInt amountAtoms,
    required String assetId,
    required String redeemScriptHex,
    required int seqLocktime,
    required String makerRefundPub,
    required String hashHex,
    required String preimageHex,
  }) async {
    final m = await _mnemonic();
    final dest = await core.receiveAddress(mnemonic: m);
    final fee = await _seqClaimFee(assetId, amountAtoms);
    final hex = await core.xchainSeqClaim(
      mnemonic: m,
      seqTxid: seqTxid,
      seqVout: seqVout,
      seqAmount: amountAtoms,
      seqAssetId: assetId,
      destAddress: dest,
      hashHex: hashHex,
      makerSeqRefundPubHex: makerRefundPub,
      seqLocktime: seqLocktime,
      fee: fee,
      preimageHex: preimageHex,
    );
    return core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: hex);
  }

  /// The SEQ-claim fee in atoms of the CLAIMED asset from the published rate (min 1 atom, capped at
  /// half the output). Fails CLOSED when the feed has no rate for the asset — an unmineable claim
  /// leaves P public while the leg sits unmined (mirror SubswapService._seqClaimFee).
  Future<BigInt> _seqClaimFee(String assetHex, BigInt amount) async {
    final ticker = SeqAssets.labelFor(assetHex).ticker;
    final rates = await ApiClient.feeRates();
    final rate = rates[ticker] ?? rates[assetHex];
    if (rate == null || rate <= BigInt.zero) {
      throw Exception('No Sequentia fee rate for $ticker, so the claim fee cannot be sized safely; your secret was NOT revealed.');
    }
    final native = BigInt.from(400);
    var fee = (native * _kScale + rate - BigInt.one) ~/ rate;
    if (fee < BigInt.one) fee = BigInt.one;
    final half = amount ~/ BigInt.two;
    if (half >= BigInt.one && fee > half) fee = half;
    return fee;
  }

  @override
  Future<SubSwapJob> lspSwapBridge(Map<String, dynamic> p) => LspClient.swapBridge(
        asset: p['asset'] as String,
        assetAtoms: p['asset_atoms'] as BigInt,
        btcSats: p['btc_sats'] as BigInt,
        offerId: p['offer_id'] as String,
        makerPubkey: p['maker_pubkey'] as String,
        hashH: p['hash_h'] as String,
        takerSeqClaimPub: p['taker_seq_claim_pub'] as String,
      );

  @override
  Future<BridgeJobStatus?> lspBridgeStatus(String pollPathOrId) => LspClient.bridgeStatus(pollPathOrId);

  @override
  Future<BridgeHold> lspBridgeHold(String jobId) => LspClient.bridgeHold(jobId: jobId);

  @override
  Future<Map<String, dynamic>> lspNodePayHash({
    required String nodeKey,
    required String nodeId,
    required String hash,
    required BigInt amountMsat,
    int? minFinalCltv,
    List<dynamic>? connectHints,
  }) =>
      LspClient.nodePayHash(
        nodeKey: nodeKey,
        nodeId: nodeId,
        hash: hash,
        amountMsat: amountMsat,
        minFinalCltv: minFinalCltv,
        connectHints: connectHints,
      );

  @override
  Future<String> btcNodeKey() async =>
      LightningService.instance.connectNode(await _mnemonic(), chain: 'btc');
}
