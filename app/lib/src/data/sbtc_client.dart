import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

/// Thin client for the SBTC bridge peg endpoints ([Backend.sbtc] = /sbtc, reverse-proxied to the
/// bridge with the token injected by Caddy so the app never holds a secret). It ONLY allocates
/// peg-in / peg-out addresses; the wallet's own signed sends move the funds. Mirror of the web
/// wallet's sbtc.js. See doc/sequentia/sbtc-peg-design.md.
class SbtcClient {
  static Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final r = await http
        .post(Uri.parse('${Backend.sbtc}$path'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    final j = (r.body.isEmpty ? {} : jsonDecode(r.body)) as Map<String, dynamic>;
    if (r.statusCode >= 400 || j['ok'] == false) {
      throw Exception((j['error'] ?? 'SBTC bridge HTTP ${r.statusCode}').toString());
    }
    return j;
  }

  /// PEG-IN: a fresh Bitcoin deposit address bound to [seqRecipient] (a Sequentia address credited
  /// SBTC 1:1 once the BTC deposit confirms). The wallet then sends real BTC there.
  static Future<String> requestPegIn(String seqRecipient) async {
    final j = await _post('/pegin', {'seq_recipient': seqRecipient});
    final a = j['deposit_address'];
    if (a == null) throw Exception('bridge returned no deposit address');
    return a.toString();
  }

  /// PEG-OUT: a fresh Sequentia address bound to [btcDest] (a Bitcoin address that receives real BTC
  /// 1:1 once SBTC arrives). The wallet then sends SBTC there.
  static Future<String> requestPegOut(String btcDest) async {
    final j = await _post('/pegout', {'btc_dest': btcDest});
    final a = j['sbtc_address'];
    if (a == null) throw Exception('bridge returned no SBTC address');
    return a.toString();
  }
}
