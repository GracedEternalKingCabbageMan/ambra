import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// Thin HTTP client for the hosted-SeqLN LSP — the Dart twin of the web wallet's
/// `seqln.js` LSP client (`seqlnGetStatus` / `seqlnSwap`). It speaks the SAME
/// contract as the browser client, so ONE hosted LSP serves both:
///
///   GET  /status  -> hosted node id + per-asset channel balances
///   POST /swap {side, asset, amount}
///        -> { ok, preimage, base_amount, quote_asset, quote_amount,
///             finality: 'final', settled_ms, direction, asset }
///
/// Base URL is [Backend.lsp] (origin + '/lsp' by default). Auth reuses the node
/// [Backend.authHeaders] plumbing (as /dex, /feerates do); a set [Backend.lnToken]
/// overrides with a Bearer. Plain `http` so it is fully unit-testable with a mock
/// client (see [client]).
class LspClient {
  LspClient._();

  /// The HTTP client used for all calls. Swap for a `MockClient` in tests.
  static http.Client client = http.Client();

  static Map<String, String> _headers() {
    final h = <String, String>{'Content-Type': 'application/json', ...Backend.authHeaders};
    if (Backend.lnToken.trim().isNotEmpty) h['Authorization'] = 'Bearer ${Backend.lnToken.trim()}';
    return h;
  }

  /// Parse the body, applying the same `!ok || ok===false -> throw` rule the web
  /// client uses (a 200 with `{ok:false,error}` is still a failure).
  static Map<String, dynamic> _decode(http.Response r) {
    Map<String, dynamic> j;
    try {
      j = r.body.isNotEmpty ? jsonDecode(r.body) as Map<String, dynamic> : <String, dynamic>{};
    } catch (_) {
      j = {'ok': false, 'error': r.body.isEmpty ? 'empty response' : r.body};
    }
    if (r.statusCode < 200 || r.statusCode >= 300 || j['ok'] == false) {
      throw Exception('${j['error'] ?? j['message'] ?? 'HTTP ${r.statusCode}'}');
    }
    return j;
  }

  /// Hosted node id + per-asset channel balances (spendable = send capacity,
  /// receivable = recv capacity).
  static Future<LspStatus> getStatus() async {
    final r = await client
        .get(Uri.parse('${Backend.lsp}/status'), headers: _headers())
        .timeout(const Duration(seconds: 20));
    return LspStatus.fromJson(_decode(r));
  }

  /// Take a pure-LN offer: [side] is 'buy' (BTC -> asset) or 'sell' (asset -> BTC).
  /// [amount] is a plain number (the amount the user typed), mirroring the web
  /// client (which posts a JSON number). Returns the settle (preimage + amounts).
  /// The on-device signer co-signs the hosted node's commitment updates over the
  /// wss link during this call.
  static Future<LspSwapResult> swap({
    required String side,
    required String asset,
    required num amount,
  }) async {
    final r = await client
        .post(Uri.parse('${Backend.lsp}/swap'),
            headers: _headers(), body: jsonEncode({'side': side, 'asset': asset, 'amount': amount}))
        .timeout(const Duration(seconds: 90));
    return LspSwapResult.fromJson(_decode(r));
  }
}

/// One hosted channel's per-asset balances, as reported by `GET /status`.
class LspChannel {
  LspChannel({required this.asset, required this.spendable, required this.receivable});
  final String asset; // asset id (hex) or ticker, as the LSP reports it
  final BigInt spendable; // send capacity (atoms)
  final BigInt receivable; // recv capacity (atoms)

  static LspChannel fromJson(Map m) => LspChannel(
        asset: '${m['asset'] ?? m['asset_id'] ?? m['assetId'] ?? ''}',
        spendable: BigInt.tryParse('${m['spendable'] ?? m['send'] ?? m['spendable_msat'] ?? 0}') ?? BigInt.zero,
        receivable: BigInt.tryParse('${m['receivable'] ?? m['recv'] ?? m['receivable_msat'] ?? 0}') ?? BigInt.zero,
      );
}

/// The hosted node's status: its node id + the assets it can route.
class LspStatus {
  LspStatus({required this.nodeId, required this.channels, required this.raw});
  final String? nodeId;
  final List<LspChannel> channels;
  final Map<String, dynamic> raw;

  /// The set of asset ids/tickers the hosted node has channels for (routable).
  List<String> get assets => channels.map((c) => c.asset).where((a) => a.isNotEmpty).toList();

  static LspStatus fromJson(Map<String, dynamic> j) {
    final ch = (j['channels'] as List?) ?? const [];
    return LspStatus(
      nodeId: (j['node_id'] ?? j['nodeId'] ?? j['id'])?.toString(),
      channels: ch.whereType<Map>().map(LspChannel.fromJson).toList(),
      raw: j,
    );
  }
}

/// The settle of a pure-LN swap. Amounts are kept as display strings (exactly the
/// web client's usage: it interpolates `base_amount` / `quote_amount` directly),
/// so no atom/unit assumption is baked in wallet-side.
class LspSwapResult {
  LspSwapResult({
    required this.preimage,
    required this.direction,
    required this.asset,
    required this.baseAmount,
    required this.quoteAsset,
    required this.quoteAmount,
    required this.finality,
    required this.settledMs,
    required this.raw,
  });

  final String preimage;
  final String? direction; // 'bought' | 'sold'
  final String? asset; // base asset id/ticker
  final String? baseAmount; // display string of the base leg
  final String? quoteAsset; // typically BTC
  final String? quoteAmount; // display string of the quote leg
  final String finality; // 'final' for pure-LN
  final int? settledMs;
  final Map<String, dynamic> raw;

  /// Pure-LN is the one swap state the DEX 0-conf policy lets us call final.
  bool get isFinal => finality == 'final';

  static LspSwapResult fromJson(Map<String, dynamic> j) => LspSwapResult(
        preimage: '${j['preimage'] ?? ''}',
        direction: j['direction']?.toString(),
        asset: j['asset']?.toString(),
        baseAmount: (j['base_amount'] ?? j['baseAmount'])?.toString(),
        quoteAsset: (j['quote_asset'] ?? j['quoteAsset'])?.toString(),
        quoteAmount: (j['quote_amount'] ?? j['quoteAmount'])?.toString(),
        finality: '${j['finality'] ?? ''}',
        settledMs: (j['settled_ms'] ?? j['settledMs']) is num ? (j['settled_ms'] ?? j['settledMs']).toInt() : null,
        raw: j,
      );
}
