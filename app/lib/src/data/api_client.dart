import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

class FaucetResult {
  FaucetResult(this.amount, this.asset, this.txid);
  final String amount;
  final String asset;
  final String txid;
}

/// Thin HTTP client for the box sidecars (faucet now; registry/prices next).
class ApiClient {
  ApiClient._();

  /// Request testnet coins to [address]. Empty/null [asset] = native tSEQ.
  static Future<FaucetResult> faucet(String address, {String? asset}) async {
    final body = (asset == null || asset.isEmpty)
        ? <String, String>{'address': address}
        : <String, String>{'address': address, 'asset': asset};
    final r = await http
        .post(Uri.parse(Backend.faucet),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 30));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) {
      throw Exception(j['error']?.toString() ?? 'HTTP ${r.statusCode}');
    }
    return FaucetResult('${j['amount']}', '${j['asset']}', '${j['txid']}');
  }

  /// The producer fee-acceptance set: {("bitcoin"=tSEQ | ticker | hex): rate}.
  /// rate = atoms-of-asset per reference unit ×1e8.
  static Future<Map<String, num>> feeRates() async {
    final r = await http.get(Uri.parse(Backend.feerates)).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return j.map((k, v) => MapEntry(k, v is num ? v : num.parse('$v')));
  }
}
