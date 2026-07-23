import 'seqob_client.dart' show CrossOffer;

/// The maker's per-lift HTLC Terms for a cross (BTC<->asset) swap, returned over the relay courier in
/// response to a TermsRequest. The resting [CrossOffer] is advisory; these Terms carry the load-bearing
/// keys and CLTV locktimes that bind the actual swap.
class CrossTerms {
  const CrossTerms({
    required this.makerBtcClaimPub,
    required this.makerSeqRefundPub,
    required this.btcLocktime,
    required this.seqLocktime,
    required this.feeBtcSats,
    required this.btcSats,
    required this.assetAtoms,
  });

  final String makerBtcClaimPub;
  final String makerSeqRefundPub;
  final int btcLocktime; // T_btc: the taker's BTC HTLC refund height
  final int seqLocktime; // T_seq: the maker's asset HTLC refund height
  final BigInt feeBtcSats; // maker fee taken on the BTC leg
  final BigInt btcSats; // BTC the swap moves
  final BigInt assetAtoms; // asset the swap moves
}

/// The forward (BUY) proportional BTC for taking [slice] of an offer that advertises [offerAsset] for
/// [offerBtc]: CEIL(offerBtc · slice / offerAsset). Forward CEIL (the taker overpays by at most one sat)
/// protects the MAKER, matching the deployed seqdex `xlift -amount` math (P2.3). Pure + exact so the
/// taker's validation and the maker's quote agree to the sat.
BigInt proportionalBtcForwardCeil(BigInt offerBtc, BigInt offerAsset, BigInt slice) {
  if (offerAsset <= BigInt.zero) return BigInt.zero;
  final num = offerBtc * slice;
  return (num + offerAsset - BigInt.one) ~/ offerAsset; // CEIL
}

/// THE PRE-LOCK FUND-SAFETY GATE. Validate a maker's [terms] against the resting [offer] the taker chose,
/// BEFORE any Bitcoin is locked. A taker must NEVER lock BTC on a mismatch (mirrors the web wallet's
/// runForwardCourier checks, xswap.js). Returns null when it is safe to lock; otherwise a short, honest
/// human message explaining why the swap was refused. Pure — no IO — so it is unit-testable and every
/// caller applies the identical rule.
///
/// PARTIAL FILLS (spec §4, priority C): when [requestedAtoms] is a slice SMALLER than the offer, the
/// taker asked for a partial fill and the maker (seqdex `xlift -amount`) must quote exactly that slice at
/// the PROPORTIONAL BTC (forward CEIL). The gate then binds the maker to `assetAtoms == slice` and
/// `btcSats == CEIL(offerBtc·slice/offerAsset)` instead of the whole-offer amounts — so a taker who typed
/// "buy 10 of a 43" locks BTC for exactly 10, never the whole 43 (invariant §2.4). [minFill], when known,
/// refuses a slice below the offer's minimum fillable lot before any BTC is locked (the maker also
/// enforces its own min and would `fail` the courier, but rejecting locally is faster + clearer). A null
/// or ≥offer [requestedAtoms] keeps the exact whole-offer behaviour unchanged.
String? validateCrossTerms({
  required CrossOffer offer,
  required CrossTerms terms,
  BigInt? requestedAtoms,
  BigInt? minFill,
}) {
  // Resolve the expected fill. A partial is a slice strictly inside (0, offer.assetAtoms); anything ≥ the
  // offer (or unset) is a whole fill and keeps the strict amount checks.
  final whole = requestedAtoms == null ||
      requestedAtoms <= BigInt.zero ||
      requestedAtoms >= offer.assetAtoms;
  final expectAsset = whole ? offer.assetAtoms : requestedAtoms;
  final expectBtc =
      whole ? offer.btcSats : proportionalBtcForwardCeil(offer.btcSats, offer.assetAtoms, requestedAtoms);
  if (!whole && minFill != null && requestedAtoms < minFill) {
    return 'That amount is below this offer\'s minimum fillable size; enter a larger amount.';
  }
  // The maker must quote the EXPECTED amounts (whole or the proportional slice), not bait-and-switch after
  // the taker committed. For a partial, the taker must never be charged MORE than the forward-CEIL BTC.
  if (terms.assetAtoms != expectAsset) {
    return 'The maker quoted a different asset amount than requested; not proceeding.';
  }
  if (terms.btcSats != expectBtc) {
    return 'The maker quoted a different Bitcoin amount than the requested size; not proceeding.';
  }
  // Both HTLC keys are load-bearing; a missing one means we could build a leg we cannot claim/refund.
  if (terms.makerBtcClaimPub.isEmpty || terms.makerSeqRefundPub.isEmpty) {
    return 'The maker\'s terms were missing a key; not proceeding.';
  }
  // Safe locktime ordering: the taker's BTC (the FIRST leg locked) must refund LATER than the maker's
  // asset leg, so the taker is never forced to reveal into a window where only its own refund has matured.
  if (terms.btcLocktime <= terms.seqLocktime) {
    return 'Bad locktime ordering (the Bitcoin refund must mature after the asset refund); not proceeding.';
  }
  // Fee sanity: refuse a punitive maker fee (> ~1% of the trade + 1000 sats slack), matching the web
  // wallet (xswap.js: tFee > atBtc/100 + 1000). Defends against a maker quoting a punitive fee once the
  // session is open.
  if (terms.feeBtcSats < BigInt.zero ||
      terms.feeBtcSats > terms.btcSats ~/ BigInt.from(100) + BigInt.from(1000)) {
    return 'The maker fee is too high (over ~1% of the trade); not proceeding.';
  }
  return null; // safe to lock the BTC leg
}
