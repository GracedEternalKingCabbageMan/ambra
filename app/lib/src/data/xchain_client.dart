import 'seqdex_client.dart' show pick;

/// Cross-chain wire TYPES used by the relay ORDER-BOOK courier path.
///
/// The retired /dex RFQ client that used to live here (XchainService:
/// /v1/xchain/markets|quote|propose|swap|reverse/quote|reverse/open|reverse/submit)
/// and its RFQ-only DTOs are GONE. These two data classes survive because the LIVE
/// order-book path builds and parses them; see the note on each.

// protojson encodes uint64/int64 as STRINGS and uint32 as NUMBERS; field names
// arrive camelCase (snake also accepted). These parse either, robustly.
BigInt _big(dynamic v) => BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
int _int(dynamic v) => int.tryParse('${v ?? 0}') ?? 0;
String _str(dynamic v) => v == null ? '' : '$v';

/// A cross-chain (BTC <-> Sequentia asset) market. LIVE: the composer CONSTRUCTS these itself
/// from `SeqObClient.crossMarketAssets()` (the relay order book) to source its BTC pairs. There is
/// no `fromJson` any more: the only producer of the wire form was the retired RFQ /v1/xchain/markets
/// endpoint, so the type is now BUILT locally and never parsed.
class XchainMarket {
  XchainMarket({required this.btcAsset, required this.seqAsset, required this.name, required this.priceSeqPerBtc});
  final String btcAsset;
  final String seqAsset;
  final String name;
  final double priceSeqPerBtc;
}

/// The maker's SEQ HTLC leg. LIVE: parsed by `XchainSwapService.setCourierSeqLeg` from the
/// courier maker's seq_leg_locked message on every order-book cross lift.
class XSeqLeg {
  XSeqLeg({
    required this.txid,
    required this.vout,
    required this.blockHash,
    required this.anchorHeight,
    required this.redeemScript,
    required this.amount,
    required this.assetId,
  });
  final String txid;
  final int vout;
  final String blockHash;
  final int anchorHeight; // maker-reported; the wallet re-verifies independently
  final String redeemScript;
  final BigInt amount;
  final String assetId;
  static XSeqLeg fromJson(Map m) => XSeqLeg(
        txid: _str(pick(m, ['txid'])),
        vout: _int(pick(m, ['vout'])),
        blockHash: _str(pick(m, ['block_hash', 'blockHash'])),
        anchorHeight: _int(pick(m, ['anchor_height', 'anchorHeight'])),
        redeemScript: _str(pick(m, ['redeem_script', 'redeemScript'])),
        amount: _big(pick(m, ['amount'])),
        // The courier maker (Go XcLeg) sends the SEQ leg's asset under 'asset';
        // the /dex daemon used 'asset_id'. Read BOTH, or verifyLeg throws "wrong
        // asset" on EVERY courier cross lift (assetId would parse empty).
        assetId: _str(pick(m, ['asset', 'asset_id', 'assetId'])),
      );
  Map<String, dynamic> toJson() => {
        'txid': txid,
        'vout': vout,
        'block_hash': blockHash,
        'anchor_height': anchorHeight,
        'redeem_script': redeemScript,
        'amount': amount.toString(),
        'asset_id': assetId,
      };
}
