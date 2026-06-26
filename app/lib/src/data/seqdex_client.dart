import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// Read the first present of [names] from a grpc-gateway JSON object (it emits
/// camelCase but accepts either; responses vary), mirroring swap.js `pick`.
dynamic pick(Map? obj, List<String> names) {
  if (obj == null) return null;
  for (final n in names) {
    if (obj.containsKey(n) && obj[n] != null) return obj[n];
  }
  return null;
}

/// seqdex.v1 TradeType.
const Map<String, int> tradeType = {'BUY': 0, 'SELL': 1};

/// A same-chain market (an unordered asset pair the daemon makes).
class Market {
  Market(this.baseAsset, this.quoteAsset);
  final String baseAsset;
  final String quoteAsset;

  static Market fromJson(Map m) {
    final mk = (pick(m, ['market']) as Map?) ?? m;
    return Market(
      '${pick(mk, ['base_asset', 'baseAsset'])}',
      '${pick(mk, ['quote_asset', 'quoteAsset'])}',
    );
  }

  Map<String, String> toJson() => {'base_asset': baseAsset, 'quote_asset': quoteAsset};
}

/// A PreviewTrade result: the counter-leg amount/asset + the computed fee.
class Preview {
  Preview({required this.counterAtoms, required this.counterAsset, required this.feeAsset, required this.feeAmount});
  final BigInt counterAtoms; // atoms of the non-base leg
  final String counterAsset;
  final String feeAsset;
  final BigInt feeAmount;
}

/// The accepted maker half: the PSET to sign + the accept id for CompleteTrade.
class SwapAccept {
  SwapAccept(this.transaction, this.id);
  final String transaction; // base64 PSET
  final String id;
}

/// Thin HTTP client for the SeqDEX daemon (grpc-gateway REST under Backend.dex).
class SeqdexClient {
  SeqdexClient._();

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
      throw Exception('${pick(j, ['message', 'error']) ?? j['_raw'] ?? 'HTTP ${r.statusCode}'}');
    }
    return j;
  }

  /// All same-chain markets the daemon makes.
  static Future<List<Market>> markets() async {
    final j = await _post('/v1/markets', {});
    final list = (j['markets'] as List?) ?? const [];
    return list.map((m) => Market.fromJson(m as Map)).toList();
  }

  /// Spot price for a market (base_price = quote units per 1 base). Used to convert
  /// a quote-leg amount into the base-leg amount PreviewTrade is parameterised by.
  static Future<double> basePrice(Market market, String feeAsset) async {
    final j = await _post('/v1/market/price', {'market': market.toJson(), 'fee_asset': feeAsset});
    final sp = (pick(j, ['spot_price', 'spotPrice']) as Map?) ?? j;
    final bp = double.tryParse('${pick(sp, ['base_price', 'basePrice'])}') ?? 0;
    if (!(bp > 0)) throw Exception('no price for this market yet');
    return bp;
  }

  /// Preview a trade. [side] is 'BUY' or 'SELL'; [baseAtoms] is the BASE-leg amount.
  static Future<Preview> preview(Market market, String side, BigInt baseAtoms, String feeAsset) async {
    final j = await _post('/v1/trade/preview', {
      'market': market.toJson(),
      'type': tradeType[side],
      'amount': baseAtoms.toString(),
      'asset': market.baseAsset,
      'fee_asset': feeAsset,
    });
    final previews = (j['previews'] as List?) ?? const [];
    if (previews.isEmpty) throw Exception('no preview for this market/amount');
    final p = previews.first as Map;
    return Preview(
      counterAtoms: BigInt.tryParse('${pick(p, ['amount'])}') ?? BigInt.zero,
      counterAsset: '${pick(p, ['asset'])}',
      feeAsset: '${pick(p, ['fee_asset', 'feeAsset']) ?? feeAsset}',
      feeAmount: BigInt.tryParse('${pick(p, ['fee_amount', 'feeAmount']) ?? 0}') ?? BigInt.zero,
    );
  }

  /// Propose the taker's SwapRequest; returns the maker's SwapAccept or throws the
  /// daemon's failure message.
  static Future<SwapAccept> propose(
      Market market, String side, Map<String, dynamic> swapRequest, BigInt feeAmount, String feeAsset) async {
    final j = await _post('/v1/trade/propose', {
      'market': market.toJson(),
      'type': tradeType[side],
      'swap_request': swapRequest,
      'fee_amount': feeAmount.toString(),
      'fee_asset': feeAsset,
    });
    final fail = pick(j, ['swap_fail', 'swapFail']) as Map?;
    if (fail != null) {
      throw Exception('Provider rejected the swap: ${pick(fail, ['failure_message', 'failureMessage']) ?? 'unknown reason'}');
    }
    final accept = pick(j, ['swap_accept', 'swapAccept']) as Map?;
    final tx = accept == null ? null : pick(accept, ['transaction']);
    if (tx == null) throw Exception('no SwapAccept returned');
    return SwapAccept('$tx', '${pick(accept, ['id'])}');
  }

  /// Complete the trade with the signed (stripped) PSET; returns the txid, or
  /// throws (the caller may then self-broadcast).
  static Future<String> complete(String id, String acceptId, String strippedPset) async {
    final j = await _post('/v1/trade/complete', {
      'swap_complete': {'id': id, 'accept_id': acceptId, 'transaction': strippedPset},
    });
    final fail = pick(j, ['swap_fail', 'swapFail']) as Map?;
    if (fail != null) {
      throw Exception('${pick(fail, ['failure_message', 'failureMessage']) ?? 'CompleteTrade failed'}');
    }
    final txid = pick(j, ['txid']);
    if (txid == null) throw Exception('CompleteTrade returned no txid');
    return '$txid';
  }
}
