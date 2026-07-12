import 'dart:convert';

import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import 'config.dart';

class FaucetResult {
  FaucetResult(this.amount, this.asset, this.txid);
  final String amount;
  final String asset;
  final String txid;
}

/// A restricted asset as described by the OpenAMP enclave (`GET /v1/assets`).
/// Carries the disclosure the wallet must surface (spec 0.6/1.5(d)): clawback,
/// the eligibility rules, a lock-in height, and the issuance terms hash. No
/// privileged framing — a restricted asset is one row among equals.
class OpenAmpAsset {
  OpenAmpAsset({
    required this.id,
    required this.ticker,
    required this.name,
    required this.precision,
    this.clawback = false,
    this.allowedCategories = const [],
    this.lockinUntilHeight = 0,
    this.termsHash = '',
  });
  final String id;
  final String ticker;
  final String name;
  final int precision;
  final bool clawback;

  /// If non-empty, only holders in one of these categories may receive it.
  final List<String> allowedCategories;

  /// If > 0, the asset is locked until this Sequentia block height.
  final int lockinUntilHeight;

  /// The issuance-contract terms hash (64-hex), if disclosed.
  final String termsHash;
}

/// A restricted-asset holder's enclave account record (`GET /v1/users/{aid}`).
/// `categories`/`frozen` are omitempty on the wire, so both default to
/// empty/false — absence is never an error (spec 1.5(c)).
class OpenAmpUser {
  OpenAmpUser({this.categories = const [], this.frozen = false});
  final List<String> categories;
  final bool frozen;
}

/// One input the wallet must Schnorr-sign for an OpenAMP transfer. [input] is the
/// opaque key the enclave expects back in the `sigs` map on completion.
class OpenAmpToSign {
  OpenAmpToSign({required this.input, required this.sighash, required this.pubkey});
  final String input;
  final String sighash;
  final String pubkey;
}

/// A drafted OpenAMP transfer awaiting the wallet's signatures. [tx] is the full
/// unsigned transaction (hex): the wallet uses it to recompute every enclave
/// sighash locally and decode the effects, never trusting the server's `to_sign`.
class OpenAmpTransfer {
  OpenAmpTransfer({
    required this.id,
    required this.tx,
    required this.toSign,
    this.convertAtoms,
    this.feeSats,
  });
  final String id;
  final String tx;
  final List<OpenAmpToSign> toSign;
  final BigInt? convertAtoms; // fee taken by convert (fee_mode: "convert")
  final BigInt? feeSats; // the equivalent network fee in sats
}

/// A per-asset enclave deposit address plus the taproot spend material the wallet
/// needs to recompute an enclave sighash: the shared scriptPubKey, and the
/// transfer leaf + control block of my enclave inputs for this asset.
class EnclaveAddressInfo {
  EnclaveAddressInfo({
    required this.address,
    required this.scriptPubkey,
    required this.transferLeaf,
    required this.transferControl,
    required this.userPubkey,
  });
  final String address;
  final String scriptPubkey;
  final String transferLeaf;
  final String transferControl;
  final String userPubkey;
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

  /// The full enclave address record for [asset] under [aid]: the deposit
  /// address plus the scriptPubKey and the transfer leaf + control block the
  /// wallet needs to recompute the enclave sighash locally (spec 0.4(3)).
  static Future<EnclaveAddressInfo> openampAddressInfo(String aid, String asset) async {
    final u = Uri.parse('${Backend.openamp}/v1/users/$aid/address')
        .replace(queryParameters: {'asset': asset});
    final r = await http.get(u, headers: Backend.authHeaders).timeout(_openampTimeout);
    if (r.statusCode != 200) _openampErr(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return EnclaveAddressInfo(
      address: '${j['address'] ?? ''}',
      scriptPubkey: '${j['script_pubkey'] ?? ''}',
      transferLeaf: '${j['transfer_leaf'] ?? ''}',
      transferControl: '${j['transfer_control'] ?? ''}',
      userPubkey: '${j['user_pubkey'] ?? ''}',
    );
  }

  /// Resolve one transaction prevout from the block explorer, returning its
  /// explicit asset id, value (atoms), and scriptPubKey aligned for a local
  /// enclave-sighash recomputation. Throws if the output is confidential or
  /// missing, since an unresolved prevout cannot be verified.
  static Future<core.EnclavePrevout> prevoutAt(String txid, int vout) async {
    final r = await http
        .get(Uri.parse('${Backend.esplora}/tx/$txid'), headers: Backend.authHeaders)
        .timeout(_openampTimeout);
    if (r.statusCode != 200) {
      throw Exception('explorer lookup failed for input $txid:$vout (HTTP ${r.statusCode})');
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final vouts = j['vout'];
    if (vouts is! List || vout < 0 || vout >= vouts.length) {
      throw Exception('prevout $txid:$vout not found');
    }
    final o = vouts[vout];
    if (o is! Map) throw Exception('prevout $txid:$vout malformed');
    final asset = o['asset'];
    final valRaw = o['value'];
    final spk = o['scriptpubkey'];
    final value = valRaw is int ? BigInt.from(valRaw) : BigInt.tryParse('$valRaw');
    if (asset is! String || asset.isEmpty || value == null || spk is! String || spk.isEmpty) {
      throw Exception(
          'input spends a confidential or unresolved prevout ($txid:$vout); cannot verify the sighash');
    }
    return core.EnclavePrevout(asset: asset, value: value, script: spk);
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
        // Disclosure fields: eligibility categories + lock-in height live under
        // `rules`; the terms hash under the parsed issuance `contract`.
        final rules = e['rules'];
        final cats = <String>[];
        int lockin = 0;
        if (rules is Map) {
          final ac = rules['allowed_categories'];
          if (ac is List) {
            for (final c in ac) {
              if (c is String && c.isNotEmpty) cats.add(_clean(c, 32));
            }
          }
          final lh = rules['lockin_until_height'];
          lockin = lh is num ? lh.toInt() : (int.tryParse('$lh') ?? 0);
        }
        out.add(OpenAmpAsset(
          id: id,
          ticker: _clean(ticker, 16),
          name: e['name'] is String ? _clean(e['name'] as String, 48) : ticker,
          precision: (prec < 0 || prec > 8) ? 8 : prec,
          clawback: e['clawback'] == true,
          allowedCategories: cats,
          lockinUntilHeight: lockin < 0 ? 0 : lockin,
          termsHash: _termsHash(e['contract']),
        ));
      }
    }
    return out;
  }

  /// Pull the OpenAMP terms hash out of a restricted asset's issuance contract,
  /// which openampd may embed as a JSON object or a JSON string. Returns '' when
  /// absent or malformed (disclosure is best-effort; never throws).
  static String _termsHash(Object? contract) {
    dynamic c = contract;
    if (c is String) {
      try {
        c = jsonDecode(c);
      } catch (_) {
        return '';
      }
    }
    if (c is Map) {
      final oamp = c['openamp'];
      if (oamp is Map && oamp['terms_hash'] is String) {
        return _clean(oamp['terms_hash'] as String, 64);
      }
    }
    return '';
  }

  /// The holder's enclave account record (categories + frozen). Never throws on
  /// absence: a missing/omitted field defaults to empty/not-frozen so a fresh
  /// account isn't misread as frozen.
  static Future<OpenAmpUser> openampUser(String aid) async {
    final r = await http
        .get(Uri.parse('${Backend.openamp}/v1/users/$aid'), headers: Backend.authHeaders)
        .timeout(_openampTimeout);
    if (r.statusCode != 200) _openampErr(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final cats = <String>[];
    final ac = j['categories'];
    if (ac is List) {
      for (final c in ac) {
        if (c is String && c.isNotEmpty) cats.add(_clean(c, 32));
      }
    }
    return OpenAmpUser(categories: cats, frozen: j['frozen'] == true);
  }

  /// Draft a transfer; the enclave returns the sighashes the wallet must sign.
  static Future<OpenAmpTransfer> openampCreateTransfer({
    required String asset,
    required String senderAid,
    required String recipientAid,
    required BigInt atoms,
  }) async {
    // atoms MUST be a JSON NUMBER: openampd uint64-decodes and rejects a string
    // (spec 0.4(5)). jsonEncode(BigInt) throws, so the body is hand-assembled
    // with a bare number literal; the string fields go through jsonEncode so
    // they stay properly escaped.
    final body = '{"asset":${jsonEncode(asset)},'
        '"sender_aid":${jsonEncode(senderAid)},'
        '"recipient_aid":${jsonEncode(recipientAid)},'
        '"atoms":${atoms.toString()},'
        '"fee_mode":"convert"}';
    final r = await http
        .post(Uri.parse('${Backend.openamp}/v1/transfers'), headers: _jsonHeaders, body: body)
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
      tx: '${j['tx'] ?? ''}',
      toSign: toSign,
      convertAtoms: BigInt.tryParse('${j['convert_atoms']}'),
      feeSats: BigInt.tryParse('${j['fee_sats']}'),
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
