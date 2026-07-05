import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'seqdex_client.dart' show pick;

// protojson encodes uint64/int64 as STRINGS and uint32 as NUMBERS; field names
// arrive camelCase (snake also accepted). These parse either, robustly.
BigInt _big(dynamic v) => BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
int _int(dynamic v) => int.tryParse('${v ?? 0}') ?? 0;
double _dbl(dynamic v) => double.tryParse('${v ?? 0}') ?? 0;
String _str(dynamic v) => v == null ? '' : '$v';

/// A cross-chain (BTC <-> SEQ asset) market.
class XchainMarket {
  XchainMarket({required this.btcAsset, required this.seqAsset, required this.name, required this.priceSeqPerBtc});
  final String btcAsset;
  final String seqAsset;
  final String name;
  final double priceSeqPerBtc;
  static XchainMarket fromJson(Map m) => XchainMarket(
        btcAsset: _str(pick(m, ['btc_asset', 'btcAsset'])),
        seqAsset: _str(pick(m, ['seq_asset', 'seqAsset'])),
        name: _str(pick(m, ['name'])),
        priceSeqPerBtc: _dbl(pick(m, ['price_seq_per_btc', 'priceSeqPerBtc'])),
      );
}

/// A cross-chain quote: how much BTC Alice locks to receive `seqAmount` of the
/// SEQ asset, plus the maker's pubkeys + the two CLTV timeouts.
class XQuote {
  XQuote({
    required this.quoteId,
    required this.seqAmount,
    required this.btcAmount,
    required this.priceSeqPerBtc,
    required this.feeBtc,
    required this.makerBtcClaimPub,
    required this.makerSeqRefundPub,
    required this.btcLocktime,
    required this.seqLocktime,
    required this.expiresAtUnix,
  });
  final String quoteId;
  final BigInt seqAmount;
  final BigInt btcAmount;
  final double priceSeqPerBtc;
  final BigInt feeBtc;
  final String makerBtcClaimPub;
  final String makerSeqRefundPub;
  final int btcLocktime;
  final int seqLocktime;
  final int expiresAtUnix;
  static XQuote fromJson(Map j) => XQuote(
        quoteId: _str(pick(j, ['quote_id', 'quoteId'])),
        seqAmount: _big(pick(j, ['seq_amount', 'seqAmount'])),
        btcAmount: _big(pick(j, ['btc_amount', 'btcAmount'])),
        priceSeqPerBtc: _dbl(pick(j, ['price_seq_per_btc', 'priceSeqPerBtc'])),
        feeBtc: _big(pick(j, ['fee_btc', 'feeBtc'])),
        makerBtcClaimPub: _str(pick(j, ['maker_btc_claim_pub', 'makerBtcClaimPub'])),
        makerSeqRefundPub: _str(pick(j, ['maker_seq_refund_pub', 'makerSeqRefundPub'])),
        btcLocktime: _int(pick(j, ['btc_locktime', 'btcLocktime'])),
        seqLocktime: _int(pick(j, ['seq_locktime', 'seqLocktime'])),
        expiresAtUnix: _int(pick(j, ['expires_at_unix', 'expiresAtUnix'])),
      );
}

/// The maker's SEQ HTLC leg, as reported by the daemon on propose-accept / status.
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
        assetId: _str(pick(m, ['asset_id', 'assetId'])),
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

/// Live swap status from the daemon (its state is in-memory; tolerate 404).
class XSwapStatus {
  XSwapStatus({
    required this.swapId,
    required this.state,
    required this.seqClaimTxid,
    required this.btcClaimTxid,
    required this.preimage,
    required this.detail,
  });
  final String swapId;
  final String state; // XCHAIN_SWAP_STATE_* enum name
  final String seqClaimTxid;
  final String btcClaimTxid;
  final String preimage;
  final String detail;
  static XSwapStatus fromJson(Map j) => XSwapStatus(
        swapId: _str(pick(j, ['swap_id', 'swapId'])),
        state: _str(pick(j, ['state'])),
        seqClaimTxid: _str(pick(j, ['seq_claim_txid', 'seqClaimTxid'])),
        btcClaimTxid: _str(pick(j, ['btc_claim_txid', 'btcClaimTxid'])),
        preimage: _str(pick(j, ['preimage'])),
        detail: _str(pick(j, ['detail'])),
      );
}

/// The daemon rejected the swap in-band ({fail:{code,message}}, HTTP 200) — retry
/// (e.g. BTC_LEG_UNCONFIRMED) or abort to refund.
class XchainFail implements Exception {
  XchainFail(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'XchainFail($code): $message';
}

/// HTTP client for the daemon's cross-chain service (XchainService, REST under
/// Backend.dex). All POST with the whole message as the JSON body.
class XchainClient {
  XchainClient._();

  static Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final r = await http
        .post(Uri.parse('${Backend.dex}$path'),
            headers: {'Content-Type': 'application/json', ...Backend.authHeaders}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 30));
    Map<String, dynamic> j;
    try {
      j = r.body.isNotEmpty ? jsonDecode(r.body) as Map<String, dynamic> : <String, dynamic>{};
    } catch (_) {
      j = {'_raw': r.body};
    }
    if (r.statusCode != 200) {
      // e.g. NotFound for an expired quote / restarted daemon -> caller re-quotes.
      throw Exception('${pick(j, ['message', 'error']) ?? j['_raw'] ?? 'HTTP ${r.statusCode}'}');
    }
    return j;
  }

  static Future<List<XchainMarket>> markets() async {
    final j = await _post('/v1/xchain/markets', {});
    final list = (j['markets'] as List?) ?? const [];
    return list.map((m) => XchainMarket.fromJson(m as Map)).toList();
  }

  static Future<XQuote> quote(String seqAsset, BigInt seqAmount) async {
    final j = await _post('/v1/xchain/quote', {'seq_asset': seqAsset, 'seq_amount': seqAmount.toString()});
    return XQuote.fromJson(j);
  }

  /// Propose the funded BTC leg; returns the accepted swap (id + SEQ leg) or
  /// throws [XchainFail] on an in-band rejection.
  static Future<({String swapId, XSeqLeg seqLeg})> propose({
    required String quoteId,
    required String hashHex,
    required String btcTxid,
    required int btcVout,
    required int btcHeight,
    required String btcRedeemScript,
    required BigInt btcAmount,
    required String takerSeqClaimPub,
    required String takerBtcRefundPub,
  }) async {
    final j = await _post('/v1/xchain/propose', {
      'quote_id': quoteId,
      'hash': hashHex,
      'btc_leg': {
        'txid': btcTxid,
        'vout': btcVout,
        'height': btcHeight.toString(),
        'redeem_script': btcRedeemScript,
        'amount': btcAmount.toString(),
        'asset_id': '',
      },
      'taker_seq_claim_pub': takerSeqClaimPub,
      'taker_btc_refund_pub': takerBtcRefundPub,
    });
    final fail = pick(j, ['fail']) as Map?;
    if (fail != null) {
      throw XchainFail('${pick(fail, ['code']) ?? 'FAIL'}', '${pick(fail, ['message']) ?? 'rejected'}');
    }
    final accepted = pick(j, ['accepted']) as Map?;
    if (accepted == null) throw Exception('propose returned neither accepted nor fail');
    final leg = pick(accepted, ['seq_leg', 'seqLeg']) as Map?;
    if (leg == null) throw Exception('propose accepted without a Sequentia leg');
    return (swapId: _str(pick(accepted, ['swap_id', 'swapId'])), seqLeg: XSeqLeg.fromJson(leg));
  }

  static Future<XSwapStatus> swap(String swapId) async {
    final j = await _post('/v1/xchain/swap', {'swap_id': swapId});
    return XSwapStatus.fromJson(j);
  }
}
