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

  /// Request testnet coins to [address]. Empty/null [asset] = tSEQ.
  static Future<FaucetResult> faucet(String address, {String? asset}) async {
    final body = (asset == null || asset.isEmpty)
        ? <String, String>{'address': address}
        : <String, String>{'address': address, 'asset': asset};
    final r = await http
        .post(Uri.parse(Backend.faucet),
            headers: {'Content-Type': 'application/json', ...Backend.authHeaders}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 30));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) {
      throw Exception(j['error']?.toString() ?? 'HTTP ${r.statusCode}');
    }
    return FaucetResult('${j['amount']}', '${j['asset']}', '${j['txid']}');
  }

  /// The producer fee-acceptance set: {("bitcoin"=tSEQ | ticker | hex): rate}.
  /// rate = atoms-of-asset per reference unit ×1e8 (an integer, consensus-exact).
  /// Parsed losslessly as BigInt; non-integer/garbage rates are dropped.
  static Future<Map<String, BigInt>> feeRates() async {
    final r = await http.get(Uri.parse(Backend.feerates), headers: Backend.authHeaders).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final out = <String, BigInt>{};
    j.forEach((k, v) {
      final b = BigInt.tryParse('$v');
      if (b != null && b > BigInt.zero) out[k] = b;
    });
    return out;
  }

  /// The public asset registry, as display labels keyed by asset id (hex).
  /// index.minimal.json is `{ id: [domain, ticker, name, precision, verified] }`.
  static Future<Map<String, AssetLabel>> registry() async {
    final r =
        await http.get(Uri.parse(Backend.registry), headers: Backend.authHeaders).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final out = <String, AssetLabel>{};
    j.forEach((id, v) {
      if (v is! List || v.length < 4) return;
      final ticker = v[1];
      final name = v[2];
      final precRaw = v[3];
      final prec = precRaw is num ? precRaw.toInt() : int.tryParse('$precRaw');
      if (ticker is! String || ticker.isEmpty || prec == null || prec < 0 || prec > 8) return;
      out[id] = AssetLabel(
        _clean(ticker, 16),
        prec,
        subtitle: (name is String && name.isNotEmpty) ? _clean(name, 48) : null,
      );
    });
    return out;
  }

  /// Defence-in-depth for registry display strings: strip angle brackets and cap
  /// the length (these render as text, but keep them tidy and non-injectable).
  static String _clean(String s, int max) {
    final t = s.replaceAll(RegExp(r'[<>]'), '');
    return t.length > max ? t.substring(0, max) : t;
  }

  /// Per-asset USD prices for reference-currency display (DISPLAY only).
  /// /prices = {TICKER: {price, market_cap, …}} (or a flat number).
  static Future<Map<String, double>> prices() async {
    final r = await http.get(Uri.parse(Backend.prices), headers: Backend.authHeaders).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final out = <String, double>{};
    j.forEach((k, v) {
      double? p;
      if (v is Map && v['price'] is num) {
        p = (v['price'] as num).toDouble();
      } else if (v is num) {
        p = v.toDouble();
      }
      if (p != null && p > 0) out[k.toUpperCase()] = p;
    });
    return out;
  }
}
