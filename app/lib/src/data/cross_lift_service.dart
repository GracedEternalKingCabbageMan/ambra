import '../rust/api.dart' as core;
import 'cross_courier.dart';
import 'cross_terms.dart';
import 'seqob_client.dart' show CrossOffer;
import 'xchain_swap_service.dart';

/// Orchestrates a cross (BTC<->asset) lift over the relay order-book courier — the mobile twin of the web
/// wallet's runForwardCourier. The PRE-LOCK phase (open session -> request + validate the maker's terms)
/// COMMITS NO FUNDS; only after the caller confirms does the BTC leg lock (handed to the HTLC settle).
class CrossLiftService {
  /// Pre-lock: open a courier session for [offer], request the maker's per-lift Terms, and validate them
  /// against the offer. Returns the LIVE session + validated terms — nothing has been spent. On any
  /// mismatch/timeout it tells the maker (fail), closes the session, and throws an honest message. The
  /// caller MUST later [CrossLiftQuote.close] the returned quote (or complete the lift), or the WS leaks.
  ///
  /// PARTIAL FILLS (spec §4, priority C): [requestedAtoms], when smaller than the offer, asks the maker
  /// (seqdex `xlift -amount`) to quote just that slice at the PROPORTIONAL BTC (forward CEIL). The take
  /// amount couriered in `start_lift` becomes the slice, and [validateCrossTerms] binds the maker to
  /// `slice` asset + `CEIL(offerBtc·slice/offerAsset)` sat — so a taker who typed "buy 10 of a 43" locks
  /// BTC for exactly 10, never the whole 43 (invariant §2.4). A null / ≥offer value is a whole fill.
  static Future<CrossLiftQuote> requestAndValidateTerms(CrossOffer offer, {BigInt? requestedAtoms}) async {
    final whole =
        requestedAtoms == null || requestedAtoms <= BigInt.zero || requestedAtoms >= offer.assetAtoms;
    final takeAmount = whole ? offer.assetAtoms : requestedAtoms; // the slice the maker must quote
    final courier = await CrossCourier.open(
      offerId: offer.offerId,
      makerPubHex: offer.makerPubkey,
      takeAmount: takeAmount,
    );
    try {
      await courier.send({'type': XcType.termsRequest});
      final t = await courier.recv(XcType.terms, timeout: const Duration(seconds: 30));
      final terms = _parseTerms(t);
      final err = validateCrossTerms(offer: offer, terms: terms, requestedAtoms: whole ? null : requestedAtoms);
      if (err != null) {
        await courier.fail('terms_mismatch', err); // tell the maker + close; nothing was spent
        throw Exception(err);
      }
      return CrossLiftQuote(courier: courier, terms: terms, offer: offer);
    } catch (e) {
      await courier.close();
      rethrow;
    }
  }

  /// After the user confirms [quote], lock the BTC leg and drive the swap to settlement over the courier.
  /// Fund-safety (all reused from the /dex HTLC path): the taker's BTC is ALWAYS refundable after T_btc;
  /// the secret is revealed only once the maker's SEQ leg passes verifyLeg (value + script byte-match) +
  /// the anchor gate + the T_seq refund-race guard. On any post-lock failure the BTC is recoverable.
  /// Progress via [onStep].
  static Future<XchainSwapRecord> lockAndSettle(CrossLiftQuote quote, {void Function(String)? onStep}) async {
    final courier = quote.courier;
    void step(String s) => onStep?.call(s);
    try {
      // 1. Build the record (secret + BTC HTLC) from the validated terms — nothing spent yet.
      step('Preparing the swap…');
      var rec = await XchainSwapService.beginFromCourierTerms(quote.offer, quote.terms);

      // 2. Lock the BTC leg (fund the HTLC; persist-before-broadcast) — the first + only fund commitment.
      step('Locking your Bitcoin…');
      rec = await XchainSwapService.fundBtc(rec);

      // 2b. Wait for >=1 confirmation before telling the maker (never send an unconfirmed leg).
      step('Waiting for your Bitcoin lock to confirm (about one block)…');
      var confirmed = false;
      for (var i = 0; i < 240 && !confirmed; i++) {
        // Guard each poll: pollBtcLock hits esplora, which throws on a transient network/500 blip.
        // An unguarded throw here aborted the WHOLE settlement mid-wait even though the BTC is funded
        // and refundable — swallow the transient and keep polling until the timeout.
        try {
          confirmed = await XchainSwapService.pollBtcLock(rec);
        } catch (_) {/* transient; retry next tick */}
        if (!confirmed) await Future<void>.delayed(const Duration(seconds: 15));
      }
      if (!confirmed) {
        throw Exception('Your Bitcoin lock has not confirmed yet; it is refundable after block ${rec.btcLocktime}.');
      }

      // 3. Courier the BTC leg to the maker.
      step('Sending the Bitcoin leg to the maker…');
      await courier.send({
        'type': XcType.btcLegFunded,
        'hash_h': rec.hashHex,
        'taker_seq_claim_pub': rec.seqClaimPub,
        'taker_btc_refund_pub': rec.btcRefundPub,
        'leg': {
          'txid': rec.btcFundingTxid,
          'vout': rec.btcVout,
          'amount': rec.btcAmount.toInt(),
          'redeem_script': rec.btcRedeemScript,
          'locktime': rec.btcLocktime,
          'height': rec.btcHp,
        },
      });

      // 4. Receive the maker's Sequentia HTLC leg (bound to the same hash).
      step('Maker is locking the asset on Sequentia…');
      final locked = await courier.recv('seq_leg_locked', timeout: const Duration(minutes: 15));
      final legJson = (locked['leg'] as Map?)?.cast<String, dynamic>();
      if (legJson == null) throw Exception('The maker sent no Sequentia leg.');
      rec = await XchainSwapService.setCourierSeqLeg(rec, legJson);

      // 5. Verify the leg + anchor + T_seq race, THEN claim (reveals the secret). Never reveal on a bad leg.
      step('Verifying the asset leg is anchored to Bitcoin…');
      await XchainSwapService.verifyLeg(rec);
      // LOOP the anchor gate (mirror the web awaitAnchor) instead of a single shot: a transient esplora
      // lag, or a leg block a beat from confirming, should WAIT rather than abort the whole lift.
      // checkAnchor throws while the leg is unconfirmed/unbindable and returns ok:false until the anchor
      // is deep enough — keep waiting, but bail to the refund the moment claiming would start racing the
      // maker's SEQ refund window (seqRefundRaceSafe). The secret is never revealed while waiting. ~40 min
      // budget at 20s/tick; past that the record stays resumable from the in-flight banner.
      core.AnchorEvidence? ev;
      for (var i = 0; i < 120 && (ev == null || !ev.ok); i++) {
        if (!await XchainSwapService.seqRefundRaceSafe(rec)) {
          await courier.fail('anchor_unsafe', 'too close to the maker SEQ refund window');
          throw Exception(
              'The asset leg did not become claimable before the maker\'s refund window; your secret was NOT revealed and your Bitcoin is refundable after block ${rec.btcLocktime}.');
        }
        try {
          ev = await XchainSwapService.checkAnchor(rec);
        } catch (_) {
          ev = null; // transient / not-yet-confirmed — wait and retry
        }
        if (ev != null && ev.ok) break;
        step('Waiting for the asset block to confirm and anchor to Bitcoin…');
        await Future<void>.delayed(const Duration(seconds: 20));
      }
      if (ev == null || !ev.ok) {
        await courier.fail('anchor_unsafe', 'asset leg not anchor-safe');
        throw Exception(
            'The asset leg is not anchored safely yet; your secret was NOT revealed and your Bitcoin is refundable after block ${rec.btcLocktime}.');
      }
      step('Claiming your asset…');
      rec = await XchainSwapService.claimSeq(rec); // T_seq refund-race guarded; reveals the secret
      step('Swap complete.');
      await courier.close();
      return rec;
    } catch (e) {
      await courier.close();
      rethrow;
    }
  }

  static CrossTerms _parseTerms(Map<String, dynamic> t) {
    Object? p(String a, String b) => t[a] ?? t[b];
    BigInt big(Object? v) => BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
    int i(Object? v) => v is int ? v : int.tryParse('${v ?? 0}') ?? 0;
    return CrossTerms(
      makerBtcClaimPub: '${p('maker_btc_claim_pub', 'makerBtcClaimPub') ?? ''}',
      makerSeqRefundPub: '${p('maker_refund_pub', 'makerRefundPub') ?? ''}',
      btcLocktime: i(p('btc_locktime', 'btcLocktime')),
      seqLocktime: i(p('seq_locktime', 'seqLocktime')),
      feeBtcSats: big(p('fee_btc', 'feeBtc')),
      btcSats: big(p('btc_amount', 'btcAmount')),
      assetAtoms: big(p('seq_amount', 'seqAmount')),
    );
  }
}

/// A validated cross-lift quote: the LIVE courier session + the maker's validated terms + the offer. The
/// caller shows the terms to the user; on confirm the BTC leg is locked + the HTLC settled over [courier].
class CrossLiftQuote {
  CrossLiftQuote({required this.courier, required this.terms, required this.offer});
  final CrossCourier courier;
  final CrossTerms terms;
  final CrossOffer offer;

  Future<void> close() => courier.close();
}
