import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

class FaucetResult {
  FaucetResult(this.amount, this.asset, this.txid);
  final String amount;
  final String asset;
  final String txid;
}

/// A restricted asset as described by the OpenAMP enclave (`GET /v1/assets`).
class OpenAmpAsset {
  OpenAmpAsset({
    required this.id,
    required this.ticker,
    required this.name,
    required this.precision,
    this.clawback = false,
  });
  final String id;
  final String ticker;
  final String name;
  final int precision;
  final bool clawback;
}

/// One input the wallet must Schnorr-sign for an OpenAMP transfer. [input] is the
/// opaque key the enclave expects back in the `sigs` map on completion.
class OpenAmpToSign {
  OpenAmpToSign({required this.input, required this.sighash, required this.pubkey});
  final String input;
  final String sighash;
  final String pubkey;
}

/// A drafted OpenAMP transfer awaiting the wallet's signatures.
class OpenAmpTransfer {
  OpenAmpTransfer({required this.id, required this.toSign, this.convertAtoms});
  final String id;
  final List<OpenAmpToSign> toSign;
  final BigInt? convertAtoms; // fee taken by convert (fee_mode: "convert")
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

  // -- OpenAMP restricted-asset enclave ---------------------------------------
  // Same jsonEncode/decode + authHeaders + timeout shape as the calls above.
  // The wallet's x-only key (m/5/0) registers the user; the enclave hands back
  // sighashes the wallet Schnorr-signs (core.openampSignSighash) to move funds.

  static const _openampTimeout = Duration(seconds: 25);

  static Map<String, String> get _jsonHeaders =>
      {'Content-Type': 'application/json', ...Backend.authHeaders};

  static Never _openampErr(http.Response r) {
    String? msg;
    try {
      final j = jsonDecode(r.body);
      if (j is Map && j['error'] != null) msg = j['error'].toString();
    } catch (_) {/* non-JSON body */}
    throw Exception(msg ?? 'HTTP ${r.statusCode}');
  }

  /// Register (idempotent) the wallet's x-only pubkeys and return its account id.
  static Future<String> openampRegister(List<String> pubkeys) async {
    final r = await http
        .post(Uri.parse('${Backend.openamp}/v1/users'),
            headers: _jsonHeaders, body: jsonEncode({'pubkeys': pubkeys}))
        .timeout(_openampTimeout);
    if (r.statusCode != 200) _openampErr(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return '${j['aid']}';
  }

  /// The enclave deposit address for [asset] under account [aid].
  static Future<String> openampAddress(String aid, String asset) async {
    final u = Uri.parse('${Backend.openamp}/v1/users/$aid/address')
        .replace(queryParameters: {'asset': asset});
    final r = await http.get(u, headers: Backend.authHeaders).timeout(_openampTimeout);
    if (r.statusCode != 200) _openampErr(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return '${j['address']}';
  }

  /// The confirmed restricted-asset balance (atoms) for [asset] under [aid].
  static Future<BigInt> openampBalance(String aid, String asset) async {
    final u = Uri.parse('${Backend.openamp}/v1/users/$aid/balance')
        .replace(queryParameters: {'asset': asset});
    final r = await http.get(u, headers: Backend.authHeaders).timeout(_openampTimeout);
    if (r.statusCode != 200) _openampErr(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return BigInt.tryParse('${j['atoms']}') ?? BigInt.zero;
  }

  /// The enclave's restricted-asset catalogue.
  static Future<List<OpenAmpAsset>> openampAssets() async {
    final r = await http
        .get(Uri.parse('${Backend.openamp}/v1/assets'), headers: Backend.authHeaders)
        .timeout(_openampTimeout);
    if (r.statusCode != 200) _openampErr(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final list = j['assets'];
    final out = <OpenAmpAsset>[];
    if (list is List) {
      for (final e in list) {
        if (e is! Map) continue;
        final id = e['id'];
        final ticker = e['ticker'];
        if (id is! String || ticker is! String || ticker.isEmpty) continue;
        final precRaw = e['precision'];
        final prec = precRaw is num ? precRaw.toInt() : int.tryParse('$precRaw') ?? 8;
        out.add(OpenAmpAsset(
          id: id,
          ticker: _clean(ticker, 16),
          name: e['name'] is String ? _clean(e['name'] as String, 48) : ticker,
          precision: (prec < 0 || prec > 8) ? 8 : prec,
          clawback: e['clawback'] == true,
        ));
      }
    }
    return out;
  }

  /// Draft a transfer; the enclave returns the sighashes the wallet must sign.
  static Future<OpenAmpTransfer> openampCreateTransfer({
    required String asset,
    required String senderAid,
    required String recipientAid,
    required BigInt atoms,
  }) async {
    final r = await http
        .post(Uri.parse('${Backend.openamp}/v1/transfers'),
            headers: _jsonHeaders,
            body: jsonEncode({
              'asset': asset,
              'sender_aid': senderAid,
              'recipient_aid': recipientAid,
              'atoms': atoms.toString(),
              'fee_mode': 'convert',
            }))
        .timeout(_openampTimeout);
    if (r.statusCode != 200) _openampErr(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final toSign = <OpenAmpToSign>[];
    final ts = j['to_sign'];
    if (ts is List) {
      for (final e in ts) {
        if (e is! Map) continue;
        toSign.add(OpenAmpToSign(
          input: '${e['input']}',
          sighash: '${e['sighash']}',
          pubkey: '${e['pubkey']}',
        ));
      }
    }
    return OpenAmpTransfer(
      id: '${j['id']}',
      toSign: toSign,
      convertAtoms: BigInt.tryParse('${j['convert_atoms']}'),
    );
  }

  /// Submit the signatures and return the broadcast txid.
  static Future<String> openampCompleteTransfer(String id, Map<String, String> sigs) async {
    final r = await http
        .post(Uri.parse('${Backend.openamp}/v1/transfers/$id/complete'),
            headers: _jsonHeaders, body: jsonEncode({'sigs': sigs}))
        .timeout(_openampTimeout);
    if (r.statusCode != 200) _openampErr(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return '${j['txid']}';
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
