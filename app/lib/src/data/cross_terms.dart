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

/// THE PRE-LOCK FUND-SAFETY GATE. Validate a maker's [terms] against the resting [offer] the taker chose,
/// BEFORE any Bitcoin is locked. A taker must NEVER lock BTC on a mismatch (mirrors the web wallet's
/// runForwardCourier checks, xswap.js). Returns null when it is safe to lock; otherwise a short, honest
/// human message explaining why the swap was refused. Pure — no IO — so it is unit-testable and every
/// caller applies the identical rule.
String? validateCrossTerms({required CrossOffer offer, required CrossTerms terms}) {
  // The maker must quote the offer's advertised amounts, not bait-and-switch after the taker committed.
  if (terms.btcSats != offer.btcSats) {
    return 'The maker quoted a different Bitcoin amount than the offer; not proceeding.';
  }
  if (terms.assetAtoms != offer.assetAtoms) {
    return 'The maker quoted a different asset amount than the offer; not proceeding.';
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
