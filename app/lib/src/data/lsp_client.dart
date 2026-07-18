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
  /// receivable = recv capacity). Pass [nodes] — this device's OWN provisioned-node
  /// registry keys (reconstructable from the mnemonic via seqln_keys.dart) — so `/status`
  /// ALSO reports THIS device's per-asset channels (`?nodes=`), letting the Balance tab read
  /// back a channel the user created on their own node, including across app restarts. Only
  /// keys this device could derive are sent, so it stays self-scoped (mirrors seqln.js).
  static Future<LspStatus> getStatus({List<String>? nodes}) async {
    final q = (nodes != null && nodes.isNotEmpty)
        ? '?nodes=${Uri.encodeComponent(nodes.join(','))}'
        : '';
    final r = await client
        .get(Uri.parse('${Backend.lsp}/status$q'), headers: _headers())
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

  // -- Move-to-Lightning: per-user, non-custodial channel lifecycle -----------------
  // These mirror seqln.js's LSP client one-for-one. The device signer (seqln_signer.dart,
  // native ambra_core) must be attached to the node for the funding/closing tx to be
  // co-signed — the LSP orchestrates but is KEYLESS, so it can never move the user's funds.

  static Future<http.Response> _postJson(String path, Map<String, dynamic> body,
          {Duration timeout = const Duration(seconds: 30)}) =>
      client
          .post(Uri.parse('${Backend.lsp}$path'), headers: _headers(), body: jsonEncode(body))
          .timeout(timeout);
  static Future<http.Response> _get(String path, {Duration timeout = const Duration(seconds: 20)}) =>
      client.get(Uri.parse('${Backend.lsp}$path'), headers: _headers()).timeout(timeout);

  /// Provision (or re-attach) a hosted SeqLN node for [asset], keyed to THIS device by its
  /// per-node Noise transport pubkey [deviceTransportPubkey] (seqln_keys.dart). SeqLN nodes are
  /// single-asset, so moving a new asset into Lightning first needs its own node. A per-user BTC
  /// node passes [chain] = 'btc' and NO asset (device-keyed); a Sequentia node passes the asset id.
  static Future<ProvisionedNode> provisionNode({
    required String deviceTransportPubkey,
    String? asset,
    String chain = 'seq',
    String? label,
  }) async {
    final body = <String, dynamic>{'device_transport_pubkey': deviceTransportPubkey};
    if (chain == 'btc') {
      body['chain'] = 'btc';
    } else {
      body['asset'] = asset;
    }
    if (label != null) body['label'] = label;
    return ProvisionedNode.fromJson(_decode(await _postJson('/node/provision', body)));
  }

  /// Readiness of ONE provisioned node (by its registry key). A freshly-provisioned node boots +
  /// rescans, so its rpc is unanswerable for the first seconds; poll this before funding.
  static Future<NodeInfo> nodeGetinfo(String nodeKey) async =>
      NodeInfo.fromJson(_decode(await _get('/node/getinfo?node=${Uri.encodeComponent(nodeKey)}')));

  /// Poll [nodeGetinfo] until the node's rpc answers, or [timeout] elapses — the honest,
  /// bounded "preparing your node…" wait that replaces a "still connecting" dead end.
  static Future<NodeInfo> waitNodeReady(
    String nodeKey, {
    void Function()? onProgress,
    Duration timeout = const Duration(minutes: 3),
    Duration poll = const Duration(milliseconds: 2500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    for (;;) {
      NodeInfo? info;
      try {
        info = await nodeGetinfo(nodeKey);
      } catch (_) {/* transient while booting */}
      if (info != null && info.ready) return info;
      onProgress?.call();
      if (DateTime.now().isAfter(deadline)) {
        throw Exception('your Lightning node is still preparing (booting + syncing); try again in a moment');
      }
      await Future<void>.delayed(poll);
    }
  }

  /// The hosted node's on-chain deposit address for [chain] (of the user's OWN node when [node] is
  /// given). The wallet then sends the deposit to this address itself (it signs it — the LSP never
  /// holds the key), before [channelOpen].
  static Future<String> channelDeposit({required String chain, String? asset, String? node}) async {
    final q = StringBuffer('/channel/deposit?chain=${Uri.encodeComponent(chain)}');
    if (asset != null) q.write('&asset=${Uri.encodeComponent(asset)}');
    if (node != null) q.write('&node=${Uri.encodeComponent(node)}');
    final j = _decode(await _get(q.toString()));
    final addr = '${j['address'] ?? ''}';
    if (addr.isEmpty) throw Exception('LSP returned no deposit address');
    return addr;
  }

  /// Start watching for the confirmed deposit + `fundchannel` (device co-signs). Returns the job to
  /// poll with [channelOpenPoll]. Thread [node] (the user's OWN node key) so the fundchannel targets
  /// that node, not the shared demo node — omitting it silently funds the demo node.
  static Future<ChannelJob> channelOpen({required String chain, required num amount, String? asset, String? node}) async {
    final body = <String, dynamic>{'chain': chain, 'amount': amount};
    if (asset != null) body['asset'] = asset;
    if (node != null) body['node'] = node;
    return ChannelJob.fromJson(_decode(await _postJson('/channel/open', body)));
  }

  /// Poll a channel-open job (by its `poll` path / job id) toward `active`.
  static Future<ChannelJob> channelOpenPoll(String pollPathOrId) async {
    final path = pollPathOrId.startsWith('/') ? pollPathOrId : '/channel/open/$pollPathOrId';
    return ChannelJob.fromJson(_decode(await _get(path)));
  }

  /// "Move back to chain": cooperatively close a channel on the user's OWN node and send the
  /// reclaimed funds to [destination] (a wallet address). Device-signed (the caller attaches the
  /// signer first); the LSP drives the close but can't redirect the funds.
  static Future<CloseResult> channelClose({
    required String chain,
    required String destination,
    String? asset,
    String? node,
    String? scid,
    int? unilateraltimeout,
  }) async {
    final body = <String, dynamic>{'chain': chain, 'destination': destination};
    if (asset != null) body['asset'] = asset;
    if (node != null) body['node'] = node;
    if (scid != null) body['scid'] = scid;
    if (unilateraltimeout != null) body['unilateraltimeout'] = unilateraltimeout;
    return CloseResult.fromJson(_decode(await _postJson('/channel/close', body, timeout: const Duration(seconds: 120))));
  }

  /// The provisioned per-device hosted nodes (the dynamic "M" in "LN N/M").
  static Future<List<ProvisionedNode>> nodeList() async {
    final j = _decode(await _get('/node/list'));
    return ((j['nodes'] as List?) ?? const []).whereType<Map>().map(ProvisionedNode.fromJson).toList();
  }

  // -- generic Lightning pay / receive over the user's OWN hosted node ----------------
  // The Dart twins of seqln.js's node/* wrappers. These drive general BOLT11 pay/receive (NOT the
  // DEX swap rail): the user's own single-asset hosted node signs an invoice (receive) or co-signs
  // every HTLC (pay), with the on-device signer (attached via LightningService.connectNode) online.

  /// Generic Lightning RECEIVE: a plain (non-HODL) bolt11 for [amount] (asset sats) into the user's
  /// OWN hosted node. The node signs the invoice, so the device signer must be online. Mirrors
  /// seqln.js `seqlnNodeReceive`. Returns { bolt11, payment_hash }.
  static Future<NodeInvoice> nodeReceive({
    required String nodeKey,
    required num amount,
    String? description,
  }) async {
    final body = <String, dynamic>{'node_key': nodeKey, 'amount': amount};
    if (description != null) body['description'] = description;
    return NodeInvoice.fromJson(_decode(await _postJson('/node/receive', body)));
  }

  /// Generic Lightning SEND: the user's OWN hosted node PAYS [bolt11] (the device co-signs every
  /// HTLC). Mirrors seqln.js `seqlnNodePay`. Returns { paid, preimage, amount_msat, destination }.
  static Future<NodePayResult> nodePay({required String nodeKey, required String bolt11}) async =>
      NodePayResult.fromJson(_decode(
          await _postJson('/node/pay', {'node_key': nodeKey, 'bolt11': bolt11}, timeout: const Duration(seconds: 90))));

  /// Register a HODL invoice by hash on the user's OWN node (the DEVICE keeps the preimage; the
  /// node/LSP never learn it). The maker pays the hash by-hash. Mirrors seqln.js `seqlnNodeInvoice`.
  /// [amount] in asset sats. Returns { payment_hash, bolt11:null, node_id, hodl:true }.
  static Future<NodeInvoice> nodeInvoice({
    required String nodeKey,
    required String asset,
    required num amount,
    required String paymentHash,
  }) async =>
      NodeInvoice.fromJson(_decode(await _postJson(
          '/node/invoice', {'node_key': nodeKey, 'asset': asset, 'amount': amount, 'payment_hash': paymentHash})));

  /// Device-settle a HELD HODL invoice with the preimage: releases the held payment AND reveals the
  /// preimage to the maker atomically. Mirrors seqln.js `seqlnNodeSettle`. Call only once held.
  static Future<Map<String, dynamic>> nodeSettle({
    required String nodeKey,
    required String paymentHash,
    required String preimage,
  }) async =>
      _decode(await _postJson('/node/settle', {'node_key': nodeKey, 'payment_hash': paymentHash, 'preimage': preimage}));

  /// Best-effort JIT inbound liquidity so the user's OWN node can RECEIVE [amount] asset sats of
  /// [asset] over Lightning. Mirrors seqln.js `seqlnChannelInbound`. Callers treat failure as
  /// non-fatal (a funded channel may already have inbound room).
  static Future<Map<String, dynamic>> channelInbound({
    required String nodeKey,
    required String asset,
    required num amount,
  }) async =>
      _decode(await _postJson('/channel/inbound', {'node_key': nodeKey, 'asset': asset, 'amount': amount}));

  // -- Sub-asset swap rail (asset over Lightning <-> BTC on-chain HTLC) ----------------
  // The Dart twins of seqln.js's invoiceStatus / jobStatus / swap(sub-asset branch) / book,
  // ADDED without touching the pure-LN [swap] above. They drive the 4th BTC<->asset leg-combo:
  // the ASSET leg moves over Lightning, the BTC leg is an on-chain HTLC. Two flows share them —
  // SELL (pay asset over LN, claim BTC on-chain) and BUY (fund BTC on-chain, receive asset over LN).

  /// Poll a HODL invoice's state on the user's OWN node (mirrors seqln.js `seqlnInvoiceStatus`):
  /// `{ held /* the maker's payment is accepted + held */, settled }`. The sub-asset BUY driver
  /// waits for `held`, then device-settles with the preimage. May throw (offline / 404); the caller
  /// treats a throw as "keep waiting" (mirrors the web's `.catch(() => null)`).
  static Future<HodlInvoiceStatus> invoiceStatus({required String nodeKey, required String paymentHash}) async {
    final r = await _get(
        '/node/invoice-status?node=${Uri.encodeComponent(nodeKey)}&payment_hash=${Uri.encodeComponent(paymentHash)}');
    return HodlInvoiceStatus.fromJson(_decode(r));
  }

  /// Advisory liveness of an async LSP swap job (mirrors seqln.js `seqlnJobStatus`). [pollPathOrId]
  /// is the poll path the /swap 202 returned (`/swap/<id>`) or a bare id. TOLERANT: a non-2xx / 404
  /// / parse failure returns a DEAD [SwapJob] (never throws), so the BUY driver can treat
  /// failed / interrupted / gone uniformly as "re-issue the swap".
  static Future<SwapJob> jobStatus(String pollPathOrId) async {
    final path = pollPathOrId.startsWith('/') ? pollPathOrId : '/swap/$pollPathOrId';
    try {
      final r = await _get(path);
      if (r.statusCode < 200 || r.statusCode >= 300) return SwapJob.dead();
      final j = r.body.isNotEmpty ? jsonDecode(r.body) as Map<String, dynamic> : <String, dynamic>{};
      return SwapJob.fromJson(j);
    } catch (_) {
      return SwapJob.dead();
    }
  }

  /// Take a SUB-ASSET offer (asset over Lightning <-> BTC on-chain HTLC) — the Dart twin of the
  /// sub-asset branch of seqln.js's `seqlnSwap`. Kept SEPARATE from the pure-LN [swap] so that
  /// byte-identical call is never disturbed. Parses the response UNION:
  ///   • SELL (payRail:ln, recvRail:chain) -> `{ settled, preimage, hash_h, btc_htlc }`
  ///   • BUY  (payRail:chain, recvRail:ln, hodl:true) -> a 202 `{ job_id, poll, held:false }`
  static Future<SubSwapResult> swapSub({
    required String side,
    required String asset,
    required String nodeKey,
    num? amount,
    bool hodl = false,
    String? paymentHash,
    BigInt? assetAmount,
    required String payRail,
    required String recvRail,
    Map<String, dynamic>? btcHtlc,
    String? btcClaimPub,
    String? offerId,
    String? makerPubkey,
  }) async {
    final body = <String, dynamic>{
      'side': side,
      'asset': asset,
      'node_key': nodeKey,
      'payRail': payRail,
      'recvRail': recvRail,
    };
    if (amount != null) body['amount'] = amount;
    if (hodl) body['hodl'] = true;
    if (paymentHash != null) body['payment_hash'] = paymentHash;
    if (assetAmount != null) body['asset_amount'] = assetAmount.toInt();
    if (btcHtlc != null) body['btc_htlc'] = btcHtlc;
    if (btcClaimPub != null) body['btc_claim_pub'] = btcClaimPub;
    if (offerId != null) body['offer_id'] = offerId;
    if (makerPubkey != null) body['maker_pubkey'] = makerPubkey;
    final r = await _postJson('/swap', body, timeout: const Duration(seconds: 90));
    return SubSwapResult.fromJson(_decode(r));
  }

  /// The sub-asset order book for [asset] (mirrors seqln.js `seqlnBook`): rail availability + the
  /// resting offers on each side. Gates the sub-asset rail buttons and sources the best offer.
  /// `{ sell_available, buy_available, sell_offers[], buy_offers[] }`.
  static Future<SubassetBook> subassetBook(String asset) async {
    final r = await _get('/book?asset=${Uri.encodeComponent(asset)}');
    return SubassetBook.fromJson(_decode(r));
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

/// A provisioned hosted node (from `POST /node/provision` or `GET /node/list`). `key` is the LSP
/// registry key the wallet threads into deposit/open/close + `?nodes=`; `hostPubkey` + `publicWsPath`
/// wire the device signer's BOLT-8 connection (seqln_signer.dart) to the node's Noise responder.
class ProvisionedNode {
  ProvisionedNode({
    required this.key,
    required this.assetId,
    required this.label,
    required this.status,
    required this.nodeId,
    required this.hostPubkey,
    required this.publicWsPath,
    required this.wsPort,
    required this.network,
    required this.chain,
    required this.raw,
  });
  final String key;
  final String? assetId;
  final String? label;
  final String? status; // 'booting' | 'running' | ...
  final String? nodeId;
  final String? hostPubkey; // the node's Noise static pubkey the device pins
  final String? publicWsPath; // '/lsp-ws-node/<id>' the device connects its signer to
  final int? wsPort;
  final String? network;
  final String chain; // 'seq' | 'btc'

  final Map<String, dynamic> raw;

  static int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  static ProvisionedNode fromJson(Map m) => ProvisionedNode(
        key: '${m['key'] ?? ''}',
        assetId: (m['asset_id'] ?? m['assetId'])?.toString(),
        label: m['label']?.toString(),
        status: m['status']?.toString(),
        nodeId: (m['node_id'] ?? m['nodeId'])?.toString(),
        hostPubkey: (m['host_pubkey'] ?? m['hostPubkey'])?.toString(),
        publicWsPath: (m['public_ws_path'] ?? m['publicWsPath'])?.toString(),
        wsPort: _int(m['ws_port'] ?? m['wsPort']),
        network: m['network']?.toString(),
        chain: '${m['chain'] ?? 'seq'}',
        raw: Map<String, dynamic>.from(m),
      );
}

/// Readiness of one node, from `GET /node/getinfo`.
class NodeInfo {
  NodeInfo({required this.ready, required this.nodeId, required this.blockheight, required this.synced});
  final bool ready;
  final String? nodeId;
  final int? blockheight;
  final bool synced;
  static NodeInfo fromJson(Map<String, dynamic> j) => NodeInfo(
        ready: j['ready'] == true,
        nodeId: (j['node_id'] ?? j['nodeId'])?.toString(),
        blockheight: j['blockheight'] is num ? (j['blockheight'] as num).toInt() : null,
        synced: j['synced'] == true,
      );
}

/// A channel-open job (`POST /channel/open` + `GET /channel/open/<id>`), polled to `active`.
class ChannelJob {
  ChannelJob({
    required this.jobId,
    required this.poll,
    required this.status,
    required this.shortChannelId,
    required this.spendableMsat,
    required this.error,
    required this.raw,
  });
  final String? jobId;
  final String? poll; // the poll path to fetch next
  final String status; // pending_deposit | opening | awaiting_lockin | active | failed
  final String? shortChannelId;
  final String? spendableMsat;
  final String? error;
  final Map<String, dynamic> raw;

  bool get isActive => status == 'active';
  bool get isFailed => status == 'failed';

  static ChannelJob fromJson(Map<String, dynamic> j) => ChannelJob(
        jobId: (j['job_id'] ?? j['jobId'])?.toString(),
        poll: j['poll']?.toString(),
        status: '${j['status'] ?? ''}',
        shortChannelId: (j['short_channel_id'] ?? j['shortChannelId'])?.toString(),
        spendableMsat: (j['spendable_msat'] ?? j['spendableMsat'])?.toString(),
        error: j['error']?.toString(),
        raw: j,
      );
}

/// A bolt11 invoice created on the user's OWN hosted node (`/node/receive`, or the HODL
/// `/node/invoice` which returns a null bolt11 + a payment hash).
class NodeInvoice {
  NodeInvoice({
    required this.bolt11,
    required this.paymentHash,
    required this.nodeId,
    required this.hodl,
    required this.raw,
  });
  final String? bolt11;
  final String? paymentHash;
  final String? nodeId;
  final bool hodl;
  final Map<String, dynamic> raw;

  static NodeInvoice fromJson(Map<String, dynamic> j) => NodeInvoice(
        bolt11: j['bolt11']?.toString(),
        paymentHash: (j['payment_hash'] ?? j['paymentHash'])?.toString(),
        nodeId: (j['node_id'] ?? j['nodeId'])?.toString(),
        hodl: j['hodl'] == true,
        raw: j,
      );
}

/// The result of paying a bolt11 from the user's OWN hosted node (`/node/pay`). Never "final" copy:
/// a completed Lightning pay reports as "Paid", not a 0-conf finality claim.
class NodePayResult {
  NodePayResult({
    required this.paid,
    required this.preimage,
    required this.amountMsat,
    required this.destination,
    required this.raw,
  });
  final bool paid;
  final String? preimage;
  final String? amountMsat;
  final String? destination;
  final Map<String, dynamic> raw;

  static NodePayResult fromJson(Map<String, dynamic> j) => NodePayResult(
        paid: j['paid'] == true,
        preimage: j['preimage']?.toString(),
        amountMsat: (j['amount_msat'] ?? j['amountMsat'])?.toString(),
        destination: j['destination']?.toString(),
        raw: j,
      );
}

/// The result of a cooperative close (`POST /channel/close`).
class CloseResult {
  CloseResult({required this.closingTxid, required this.type, required this.scid, required this.destination, required this.raw});
  final String? closingTxid;
  final String? type; // 'mutual' | 'unilateral'
  final String? scid;
  final String? destination;
  final Map<String, dynamic> raw;
  static CloseResult fromJson(Map<String, dynamic> j) => CloseResult(
        closingTxid: (j['closing_txid'] ?? j['closingTxid'])?.toString(),
        type: j['type']?.toString(),
        scid: j['scid']?.toString(),
        destination: j['destination']?.toString(),
        raw: j,
      );
}

/// Parse a JSON scalar as an int (number or numeric string), else null. Shared by the sub-asset
/// models below, whose height/vout/cltv fields arrive as numbers OR strings across the FFI/relay.
int? _asInt(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

/// A HODL invoice's state on the user's own node (`GET /node/invoice-status`): whether the maker's
/// pay-by-hash payment is HELD (ready for the device to settle with the preimage) and whether it has
/// already been settled. Mirrors seqln.js's `seqlnInvoiceStatus` shape.
class HodlInvoiceStatus {
  HodlInvoiceStatus({required this.held, required this.settled, required this.raw});
  final bool held;
  final bool settled;
  final Map<String, dynamic> raw;
  static HodlInvoiceStatus fromJson(Map<String, dynamic> j) =>
      HodlInvoiceStatus(held: j['held'] == true, settled: j['settled'] == true, raw: j);
}

/// Advisory status of an async LSP swap job (`GET /swap/<id>`). [alive] is false once the maker's
/// pay-by-hash is no longer being driven (failed / interrupted / gone) — the signal the BUY driver
/// uses to drop a stale job id and re-issue the swap. A [dead] instance encodes a 404 / non-2xx.
class SwapJob {
  SwapJob({required this.ok, required this.status, required this.interrupted, required this.held, required this.raw});
  final bool ok;
  final String status;
  final bool interrupted;
  final bool held;
  final Map<String, dynamic> raw;

  SwapJob.dead()
      : ok = false,
        status = '',
        interrupted = true,
        held = false,
        raw = const {};

  /// The maker's pay-by-hash is still being driven (so no re-issue is needed).
  bool get alive => ok && status != 'failed' && status != 'interrupted' && !interrupted;

  static SwapJob fromJson(Map<String, dynamic> j) => SwapJob(
        ok: j['ok'] != false,
        status: '${j['status'] ?? ''}',
        interrupted: j['interrupted'] == true,
        held: j['held'] == true,
        raw: j,
      );
}

/// The BTC HTLC terms the LSP returns on a sub-asset SELL settle (`btc_htlc`): the on-chain output
/// the taker CLAIMS with the maker-revealed preimage. The taker rebuilds this from H + its own claim
/// key + the maker refund key and byte-compares before trusting it (never on the LSP's word).
class SubBtcHtlc {
  SubBtcHtlc({
    required this.txid,
    required this.vout,
    required this.amount,
    required this.redeemScript,
    required this.takerClaimPubkey,
    required this.makerRefundPubkey,
    required this.tBtc,
    required this.raw,
  });
  final String txid;
  final int vout;
  final BigInt amount;
  final String redeemScript;
  final String takerClaimPubkey;
  final String makerRefundPubkey;
  final int tBtc;
  final Map<String, dynamic> raw;

  Map<String, dynamic> toJson() => raw;

  static SubBtcHtlc fromJson(Map m) => SubBtcHtlc(
        txid: '${m['txid'] ?? ''}',
        vout: _asInt(m['vout']) ?? -1,
        amount: BigInt.tryParse('${m['amount'] ?? 0}') ?? BigInt.zero,
        redeemScript: '${m['redeem_script'] ?? m['redeemScript'] ?? ''}',
        takerClaimPubkey: '${m['taker_claim_pubkey'] ?? m['takerClaimPubkey'] ?? ''}',
        makerRefundPubkey: '${m['maker_refund_pubkey'] ?? m['makerRefundPubkey'] ?? ''}',
        tBtc: _asInt(m['t_btc'] ?? m['tBtc']) ?? 0,
        raw: Map<String, dynamic>.from(m),
      );
}

/// The 202 job handle returned when a sub-asset BUY is issued (`{ job_id, poll, held }`). The device
/// drives its OWN settle; [poll] is the advisory [jobStatus] path to reconcile a dropped job.
class SubSwapJob {
  SubSwapJob({required this.jobId, required this.poll, required this.held});
  final String? jobId;
  final String? poll;
  final bool held;
  static SubSwapJob fromJson(Map<String, dynamic> j) => SubSwapJob(
        jobId: (j['job_id'] ?? j['jobId'])?.toString(),
        poll: j['poll']?.toString(),
        held: j['held'] == true,
      );
}

/// The settle returned by a sub-asset SELL (`{ settled, preimage, hash_h, btc_htlc }`): the maker
/// revealed the preimage over Lightning, so the taker now claims [btcHtlc] on-chain with it.
class SubSwapSettle {
  SubSwapSettle({required this.settled, required this.preimage, required this.hashHex, required this.btcHtlc});
  final bool settled;
  final String preimage;
  final String hashHex;
  final SubBtcHtlc? btcHtlc;
  static SubSwapSettle fromJson(Map<String, dynamic> j) {
    final h = j['btc_htlc'] ?? j['btcHtlc'];
    return SubSwapSettle(
      settled: j['settled'] == true,
      preimage: '${j['preimage'] ?? ''}',
      hashHex: '${j['hash_h'] ?? j['hashHex'] ?? ''}',
      btcHtlc: h is Map ? SubBtcHtlc.fromJson(h) : null,
    );
  }
}

/// The parsed UNION of a sub-asset [swapSub] response: [job] for a BUY (202), [settle] for a SELL.
/// Both are always constructed from the raw body (empty / default when that shape is absent); each
/// caller reads the one for its side.
class SubSwapResult {
  SubSwapResult({required this.job, required this.settle, required this.raw});
  final SubSwapJob job;
  final SubSwapSettle settle;
  final Map<String, dynamic> raw;
  static SubSwapResult fromJson(Map<String, dynamic> j) =>
      SubSwapResult(job: SubSwapJob.fromJson(j), settle: SubSwapSettle.fromJson(j), raw: j);
}

/// One resting sub-asset offer from the book. Only the fields the taker needs to build its leg are
/// surfaced: the maker's on-chain CLAIM key + CLTV (the BUY builds a BTC HTLC the maker claims with
/// the preimage), the offer size (`assetAmount` / `btcSats`, BigInt for exact partial-fill math),
/// and the ids to attach to the swap.
class SubOffer {
  SubOffer({
    required this.offerId,
    required this.makerPubkey,
    required this.makerClaimPub,
    required this.assetAmount,
    required this.btcSats,
    required this.onchainCltv,
    required this.raw,
  });
  final String offerId;
  final String makerPubkey;
  final String makerClaimPub;
  final BigInt assetAmount;
  final BigInt btcSats;
  final int onchainCltv;
  final Map<String, dynamic> raw;

  static SubOffer fromJson(Map m) => SubOffer(
        offerId: '${m['offer_id'] ?? m['offerId'] ?? ''}',
        makerPubkey: '${m['maker_pubkey'] ?? m['makerPubkey'] ?? ''}',
        makerClaimPub: '${m['maker_claim_pub'] ?? m['maker_claim_pubkey'] ?? m['makerClaimPub'] ?? ''}',
        assetAmount: BigInt.tryParse('${m['asset_amount'] ?? m['assetAmount'] ?? 0}') ?? BigInt.zero,
        btcSats: BigInt.tryParse('${m['btc_sats'] ?? m['btcSats'] ?? 0}') ?? BigInt.zero,
        onchainCltv: _asInt(m['onchain_cltv'] ?? m['onchainCltv']) ?? 0,
        raw: Map<String, dynamic>.from(m),
      );
}

/// The sub-asset order book for one asset (`GET /book?asset=`): rail availability + the resting
/// offers on each side. `buyAvailable` lights the sub-asset BUY rail (a resting asset-over-LN SELLER
/// exists to take); `sellAvailable` lights the SELL rail (a resting BTC-on-chain BUYER exists).
class SubassetBook {
  SubassetBook({
    required this.sellAvailable,
    required this.buyAvailable,
    required this.sellOffers,
    required this.buyOffers,
    required this.raw,
  });
  final bool sellAvailable;
  final bool buyAvailable;
  final List<SubOffer> sellOffers;
  final List<SubOffer> buyOffers;
  final Map<String, dynamic> raw;

  static SubassetBook fromJson(Map<String, dynamic> j) => SubassetBook(
        sellAvailable: j['sell_available'] == true || j['sellAvailable'] == true,
        buyAvailable: j['buy_available'] == true || j['buyAvailable'] == true,
        sellOffers: (((j['sell_offers'] ?? j['sellOffers']) as List?) ?? const [])
            .whereType<Map>()
            .map(SubOffer.fromJson)
            .toList(),
        buyOffers: (((j['buy_offers'] ?? j['buyOffers']) as List?) ?? const [])
            .whereType<Map>()
            .map(SubOffer.fromJson)
            .toList(),
        raw: j,
      );
}
