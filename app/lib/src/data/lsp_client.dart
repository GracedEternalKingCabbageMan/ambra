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
  ///
  /// SELF-CUSTODY (mirror the web wallet's reviewLn L.swap): name the user's OWN per-asset nodes so the
  /// LSP drives the swap on THEM (the device co-signs over the wss link), not the LSP's shared node:
  /// [nodeKey] = the base asset node; [counterNodeKey] = the counter-asset node for an asset↔asset
  /// pure-LN swap, or the user's BTC node for asset↔BTC. [quoteAsset] carries the REAL counter asset for
  /// a same-chain asset↔asset pure-LN swap (priority D). [offerId]/[makerPubkey] PIN the exact resting
  /// offer the user reviewed so the LSP lifts THIS one, not a relay-arbitrary one at a different price.
  /// [takeAtoms] is the SLICE of the pinned offer to lift, as a wire-integer of base-ASSET ATOMS
  /// (`take_atoms`); when > 0 the LSP passes it to the settlement driver and the maker re-rests the
  /// remainder; null / 0 = lift the whole offer (the pre-slice wire shape, untouched).
  static Future<LspSwapResult> swap({
    required String side,
    required String asset,
    required num amount,
    String? nodeKey,
    String? counterNodeKey,
    String? quoteAsset,
    String? offerId,
    String? makerPubkey,
    BigInt? takeAtoms,
  }) async {
    final body = <String, dynamic>{'side': side, 'asset': asset, 'amount': amount};
    if (quoteAsset != null && quoteAsset.isNotEmpty) body['quote_asset'] = quoteAsset;
    if (nodeKey != null && nodeKey.isNotEmpty) body['node_key'] = nodeKey;
    if (counterNodeKey != null && counterNodeKey.isNotEmpty) body['counter_node_key'] = counterNodeKey;
    if (offerId != null && offerId.isNotEmpty) body['offer_id'] = offerId;
    if (makerPubkey != null && makerPubkey.isNotEmpty) body['maker_pubkey'] = makerPubkey;
    // Integer on the wire (atoms are int64-ranged; BigInt only guards the intermediate math).
    if (takeAtoms != null && takeAtoms > BigInt.zero) body['take_atoms'] = takeAtoms.toInt();
    final r = await client
        .post(Uri.parse('${Backend.lsp}/swap'), headers: _headers(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 90));
    return LspSwapResult.fromJson(_decode(r));
  }

  /// The pure-LN order book for (base [asset], [quoteAsset]) sourced from the LSP's `/lnbook` (the
  /// pure-LN relay), the twin of the web wallet's `L.lnBook`. Distinct from [subassetBook] (the
  /// sub-asset `/book`): the pure-LN rail takes against THIS book (a slice of the best offer; any
  /// remainder re-rests), so the composer pre-checks it before enabling Review — never
  /// enable-then-fail. [quoteAsset] is null for asset↔BTC (BTC implied).
  /// TOLERANT: an unreachable / older LSP without `/lnbook` returns an EMPTY book (honest "no pure-LN
  /// liquidity"), never throws — mirroring the web's `.catch`.
  static Future<LnBook> lnBook(String asset, {String? quoteAsset}) async {
    try {
      final q = StringBuffer('/lnbook?asset=${Uri.encodeComponent(asset)}');
      if (quoteAsset != null && quoteAsset.isNotEmpty) q.write('&quote_asset=${Uri.encodeComponent(quoteAsset)}');
      final r = await _get(q.toString());
      if (r.statusCode < 200 || r.statusCode >= 300) return LnBook.empty();
      final j = r.body.isNotEmpty ? jsonDecode(r.body) as Map<String, dynamic> : <String, dynamic>{};
      return LnBook.fromJson(j);
    } catch (_) {
      return LnBook.empty();
    }
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
  ///
  /// The submarine taker THREADS [wantHash] (bind the payment_hash to the asset HTLC's H), [amountMsat]
  /// (bind the amount to the offer price), [maxCltv] (cap the route's total CLTV delay to the hold-safe
  /// ceiling so a masqueraded hold fails back / refunds early), and [minFinalCltv] (a hold's committed
  /// min-final-cltv) into `/node/pay` — mirroring the Go `PayInvoice(bolt11, wantHash, amountMsat)`.
  /// Each is serialized ONLY when present, so the plain pay body is untouched. The client-side pre-pay
  /// gates (payment_hash == H, overpay, hold-CLTV) remain the PRIMARY guard; these are defence-in-depth.
  static Future<NodePayResult> nodePay({
    required String nodeKey,
    required String bolt11,
    String? wantHash,
    BigInt? amountMsat,
    int? maxCltv,
    int? minFinalCltv,
  }) async {
    final body = <String, dynamic>{'node_key': nodeKey, 'bolt11': bolt11};
    if (wantHash != null && wantHash.isNotEmpty) body['want_hash'] = wantHash;
    if (amountMsat != null) body['amount_msat'] = amountMsat.toInt();
    if (maxCltv != null && maxCltv > 0) body['max_cltv'] = maxCltv;
    if (minFinalCltv != null && minFinalCltv > 0) body['min_final_cltv'] = minFinalCltv;
    return NodePayResult.fromJson(
        _decode(await _postJson('/node/pay', body, timeout: const Duration(seconds: 90))));
  }

  /// Register a HODL invoice by hash on the user's OWN node (the DEVICE keeps the preimage; the
  /// node/LSP never learn it). The maker pays the hash by-hash. Mirrors seqln.js `seqlnNodeInvoice`.
  /// [amount] in asset sats (or BTC sats for a BTC node). [asset] selects the Sequentia-asset node and
  /// is OMITTED for the user's BTC node (the submarine SELL mints its BTC-LN hold there). [preimage]
  /// (submarine SELL) lets the node mint a PLAIN bolt11 that auto-settles on payment (the maker's driver
  /// needs a payable bolt11); the device-held settle loop is the HODL fallback if the node returns none.
  /// [expiry] bounds the hold's life. Returns { payment_hash, bolt11?, node_id, hodl:true }.
  static Future<NodeInvoice> nodeInvoice({
    required String nodeKey,
    required num amount,
    required String paymentHash,
    String? asset,
    String? preimage,
    int? expiry,
  }) async {
    final body = <String, dynamic>{'node_key': nodeKey, 'amount': amount, 'payment_hash': paymentHash};
    if (asset != null && asset.isNotEmpty) body['asset'] = asset;
    if (preimage != null && preimage.isNotEmpty) body['preimage'] = preimage;
    if (expiry != null && expiry > 0) body['expiry'] = expiry;
    return NodeInvoice.fromJson(_decode(await _postJson('/node/invoice', body)));
  }

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
    required num amount,
    String? asset,
  }) async {
    final body = <String, dynamic>{'node_key': nodeKey, 'amount': amount};
    if (asset != null && asset.isNotEmpty) body['asset'] = asset; // omitted for a BTC node (submarine SELL)
    return _decode(await _postJson('/channel/inbound', body));
  }

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
    String? swapNonce,
    String? quoteAsset,
  }) async {
    final body = <String, dynamic>{
      'side': side,
      'asset': asset,
      'node_key': nodeKey,
      'payRail': payRail,
      'recvRail': recvRail,
    };
    // Same-chain asset<->asset pure-LN swap (priority D): the COUNTER asset the base is priced against
    // takes BTC's structural place, so the LSP settles both legs asset-over-LN. Serialized ONLY when
    // present, so the asset<->BTC pure-LN, sub-asset BUY, and submarine SELL bodies are untouched.
    if (quoteAsset != null && quoteAsset.isNotEmpty) body['quote_asset'] = quoteAsset;
    if (amount != null) body['amount'] = amount;
    if (hodl) body['hodl'] = true;
    if (paymentHash != null) body['payment_hash'] = paymentHash;
    if (assetAmount != null) body['asset_amount'] = assetAmount.toInt();
    if (btcHtlc != null) body['btc_htlc'] = btcHtlc;
    if (btcClaimPub != null) body['btc_claim_pub'] = btcClaimPub;
    if (offerId != null) body['offer_id'] = offerId;
    if (makerPubkey != null) body['maker_pubkey'] = makerPubkey;
    // Sub-asset SELL idempotency key: the wallet persists it BEFORE this call and re-sends the SAME
    // value on recovery, so the LSP returns the already-settled result without re-paying the asset.
    // Serialized ONLY when present, so the pure-LN swap and the sub-asset BUY bodies are untouched.
    if (swapNonce != null) body['swap_nonce'] = swapNonce;
    final r = await _postJson('/swap', body, timeout: const Duration(seconds: 90));
    return SubSwapResult.fromJson(_decode(r));
  }

  /// The sub-asset order book for [asset] (mirrors seqln.js `seqlnBook(asset, quote)`): rail
  /// availability + the resting offers on each side. Gates the sub-asset rail buttons and sources the
  /// best offer. `{ sell_available, buy_available, sell_offers[], buy_offers[] }`. [quote] keys the
  /// MIXED same-chain book per (base, quote) pair — the on-chain leg's REAL asset; omitted = BTC.
  static Future<SubassetBook> subassetBook(String asset, {String? quote}) async {
    final q = StringBuffer('/book?asset=${Uri.encodeComponent(asset)}');
    if (quote != null && quote.isNotEmpty) q.write('&quote=${Uri.encodeComponent(quote)}');
    final r = await _get(q.toString());
    return SubassetBook.fromJson(_decode(r));
  }

  // -- LSP payer leg-bridge (a BUY paying BTC over Lightning vs an on-chain-only maker) ------------
  // The Dart twins of the web's bridged /swap body (swap.js driveLspPayerBridge), seqlnBridgeHold and
  // seqlnNodePayHash — byte-compatible bodies, so ONE hosted LSP serves both wallets. The DRIVER with
  // its fund-safety ordering lives in lsp_bridge_service.dart; these are transport only.

  /// Start a BRIDGED buy: POST /swap {bridge:true, ...} — the taker mints H (holds P self-custody) and
  /// hands its OWN asset-claim key; the LSP secures the forward-maker terms, fronts the on-chain BTC
  /// HTLC, and relays the maker's asset leg. Returns the 202 job handle to poll with [bridgeStatus].
  /// Body byte-mirrors the web driver's swapBody (amounts as STRINGS; the maker binds exact amounts).
  static Future<SubSwapJob> swapBridge({
    required String asset,
    required BigInt assetAtoms,
    required BigInt btcSats,
    required String offerId,
    required String makerPubkey,
    String? relayUrl,
    required String hashH,
    required String takerSeqClaimPub,
  }) async {
    final body = <String, dynamic>{
      'side': 'buy',
      'bridge': true,
      'payRail': 'ln',
      'recvRail': 'chain',
      'asset': asset,
      'amount': assetAtoms.toString(),
      'asset_atoms': assetAtoms.toString(),
      'btc_sats': btcSats.toString(),
      'offer_id': offerId,
      'maker_pubkey': makerPubkey,
      // The relay HOLDING this offer (the unified book merges several); '' lets the LSP default.
      'relay_url': relayUrl ?? '',
      'hash_h': hashH.toLowerCase(),
      'taker_seq_claim_pub': takerSeqClaimPub.toLowerCase(),
      'maker_btc_rail': 'chain',
      'maker_asset_rail': 'chain',
      'taker_asset_inbound': false,
      'taker_btc_inbound': false,
    };
    final r = await _postJson('/swap', body, timeout: const Duration(seconds: 90));
    return SubSwapJob.fromJson(_decode(r));
  }

  /// Ask the LSP to issue the BTC-LN HOLD on the taker's H (POST /bridge/hold {job_id}) — the target the
  /// taker then pays BY BARE HASH. The driver validates hash/amount/CLTV BEFORE paying (fail closed).
  static Future<BridgeHold> bridgeHold({required String jobId}) async =>
      BridgeHold.fromJson(_decode(await _postJson('/bridge/hold', {'job_id': jobId})));

  /// Pay a BARE-HASH hold from the user's OWN hosted BTC node (POST /node/payhash, mirror
  /// seqlnNodePayHash): commit an HTLC to [nodeId] on [hash] with a final-hop CLTV >= [minFinalCltv].
  /// It lands HELD at the LSP (never captured) and settles only when the LSP recoups with P read from
  /// the taker's on-chain asset claim. Returns the raw body ({committed}/{status}) — the driver checks
  /// commitment; a `{ok:false}` body throws here like every other command.
  static Future<Map<String, dynamic>> nodePayHash({
    required String nodeKey,
    required String nodeId,
    required String hash,
    required BigInt amountMsat,
    int? minFinalCltv,
    List<dynamic>? connectHints,
  }) async {
    final body = <String, dynamic>{
      'node_key': nodeKey,
      'node_id': nodeId.toLowerCase(),
      'hash': hash.toLowerCase(),
      'amount_msat': amountMsat.toInt(),
    };
    if (minFinalCltv != null) body['min_final_cltv'] = minFinalCltv;
    if (connectHints != null && connectHints.isNotEmpty) body['connect_hints'] = connectHints;
    return _decode(await _postJson('/node/payhash', body, timeout: const Duration(seconds: 90)));
  }

  /// The RICH status of a bridged job (GET `/swap/<id>`) — [jobStatus]'s tolerant transport with the
  /// bridge fields parsed (bridge_terms / maker_seq_leg). Mirrors the web's seqlnJobStatusRaw: a
  /// well-formed `{ok:false, status:'failed'}` body IS the answer for a status read (returned, not
  /// thrown); a transport failure / non-2xx returns null so the poller keeps waiting.
  static Future<BridgeJobStatus?> bridgeStatus(String pollPathOrId) async {
    final path = pollPathOrId.startsWith('/') ? pollPathOrId : '/swap/$pollPathOrId';
    try {
      final r = await _get(path);
      if (r.statusCode < 200 || r.statusCode >= 300) return null;
      final j = r.body.isNotEmpty ? jsonDecode(r.body) as Map<String, dynamic> : <String, dynamic>{};
      return BridgeJobStatus.fromJson(j);
    } catch (_) {
      return null;
    }
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

/// One resting PURE-LN offer from `/lnbook` (the twin of the web wallet's lnBook offers): the offer's
/// real amounts (`assetAtoms` in asset atoms / `btcAtoms` in BTC SATS — never msat; the one unit
/// authority the slice math prices from), plus its id/maker_pubkey so the composer PINS the exact
/// offer the LSP then lifts (never a relay-arbitrary one at a different price). A take lifts
/// min(typed, offer) of it — `take_atoms` on the POST; the maker re-rests the remainder.
class LnOffer {
  LnOffer({required this.offerId, required this.makerPubkey, required this.assetAtoms, required this.btcAtoms});
  final String? offerId;
  final String? makerPubkey;
  final BigInt assetAtoms;
  final BigInt btcAtoms;

  static LnOffer fromJson(Map m) => LnOffer(
        offerId: (m['offer_id'] ?? m['offerId'])?.toString(),
        makerPubkey: (m['maker_pubkey'] ?? m['makerPubkey'])?.toString(),
        assetAtoms: BigInt.tryParse('${m['asset_amount'] ?? m['assetAmount'] ?? 0}') ?? BigInt.zero,
        btcAtoms: BigInt.tryParse('${m['btc_sats'] ?? m['btcSats'] ?? 0}') ?? BigInt.zero,
      );

  /// A liftable offer moves real amounts on both legs.
  bool get liftable => assetAtoms > BigInt.zero && btcAtoms > BigInt.zero;
}

/// The pure-LN order book (`GET /lnbook`): the resting offers on each side. `buyOffers` are what a BUYER
/// lifts (the maker sells the asset); `sellOffers` what a SELLER lifts. Empty when the LSP is unreachable
/// or predates `/lnbook` — the honest "no pure-LN liquidity" state the composer gates on.
class LnBook {
  LnBook({required this.buyOffers, required this.sellOffers, required this.raw});
  final List<LnOffer> buyOffers;
  final List<LnOffer> sellOffers;
  final Map<String, dynamic> raw;

  LnBook.empty()
      : buyOffers = const [],
        sellOffers = const [],
        raw = const {};

  /// The best resting offer for [side] ('buy' | 'sell'), or null when that side is empty.
  LnOffer? best(String side) {
    final list = side == 'buy' ? buyOffers : sellOffers;
    for (final o in list) {
      if (o.liftable) return o;
    }
    return null;
  }

  static LnBook fromJson(Map<String, dynamic> j) => LnBook(
        buyOffers: (((j['buy_offers'] ?? j['buyOffers']) as List?) ?? const [])
            .whereType<Map>()
            .map(LnOffer.fromJson)
            .toList(),
        sellOffers: (((j['sell_offers'] ?? j['sellOffers']) as List?) ?? const [])
            .whereType<Map>()
            .map(LnOffer.fromJson)
            .toList(),
        raw: j,
      );
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

/// The LSP's answer to `POST /bridge/hold`: the BARE-HASH hold target the taker pays. The seqln
/// holdinvoice mints NO bolt11, so the LSP registers a hold on the taker's OWN H at its node and
/// returns `{ node_id, payment_hash:H, amount_msat, hold_min_final_cltv, connect_hints }` (a future
/// fork MAY mint a [bolt11] instead — it too must bind H). The DRIVER validates every field against
/// the taker's own H / the offer price / the CLTV cap before paying — never on the LSP's word.
class BridgeHold {
  BridgeHold({
    required this.nodeId,
    required this.bolt11,
    required this.paymentHash,
    required this.amountMsat,
    required this.holdMinFinalCltv,
    required this.connectHints,
    required this.raw,
  });
  final String? nodeId;
  final String? bolt11;
  final String? paymentHash;
  final BigInt? amountMsat;
  final int? holdMinFinalCltv;
  final List<dynamic>? connectHints;
  final Map<String, dynamic> raw;

  static BridgeHold fromJson(Map<String, dynamic> j) => BridgeHold(
        nodeId: (j['node_id'] ?? j['nodeId'])?.toString(),
        bolt11: j['bolt11']?.toString(),
        paymentHash: (j['payment_hash'] ?? j['paymentHash'])?.toString(),
        amountMsat: j['amount_msat'] == null ? null : BigInt.tryParse('${j['amount_msat']}'),
        holdMinFinalCltv: _asInt(j['hold_min_final_cltv'] ?? j['holdMinFinalCltv']),
        connectHints: j['connect_hints'] is List ? j['connect_hints'] as List : null,
        raw: j,
      );
}

/// The maker's relayed Sequentia asset leg inside a bridged job poll (`maker_seq_leg`). The taker
/// REBUILDS the redeem from its own key + H and byte-compares before trusting any of this.
class BridgeLeg {
  BridgeLeg({
    required this.txid,
    required this.vout,
    required this.amount,
    required this.asset,
    required this.redeemScript,
    required this.locktime,
    required this.blockHash,
  });
  final String txid;
  final int vout;
  final BigInt amount;
  final String asset;
  final String redeemScript;
  final int locktime;
  final String blockHash;

  static BridgeLeg? fromJson(Object? v) {
    if (v is! Map) return null;
    final txid = '${v['txid'] ?? ''}';
    if (txid.isEmpty) return null;
    return BridgeLeg(
      txid: txid,
      vout: _asInt(v['vout']) ?? -1,
      amount: BigInt.tryParse('${v['amount'] ?? 0}') ?? BigInt.zero,
      asset: '${v['asset'] ?? ''}',
      redeemScript: '${v['redeem_script'] ?? v['redeemScript'] ?? ''}',
      locktime: _asInt(v['locktime']) ?? 0,
      blockHash: '${v['block_hash'] ?? v['blockHash'] ?? ''}',
    );
  }
}

/// One rich poll of a bridged job (`GET /swap/<id>`), the parsed fields the payer-bridge driver keys
/// on: `bridge_terms` (the forward-maker terms the LSP secured — hash H, T_seq, the leg's refund key)
/// and `maker_seq_leg` (the relayed asset leg, possibly nested inside bridge_terms). `failed` is a
/// definitive verdict (the LSP stopped driving); a null poll (transport) is NOT.
class BridgeJobStatus {
  BridgeJobStatus({
    required this.ok,
    required this.status,
    required this.error,
    required this.termsHashH,
    required this.seqLocktime,
    required this.makerSeqRefundPub,
    required this.makerSeqLeg,
    required this.handshakeFailed,
    this.frontMode,
    this.expectedWait,
    required this.raw,
  });
  final bool ok;
  final String status;
  final String? error;
  final String? termsHashH; // bridge_terms.hash_h (lowercased), null until the terms arrive
  final int? seqLocktime; // bridge_terms.seq_locktime
  final String? makerSeqRefundPub; // bridge_terms.maker_seq_refund_pub — re-read WITH the leg (fronted legs)
  final BridgeLeg? makerSeqLeg;
  final bool handshakeFailed; // bridgeHandshake.ok === false

  /// How the LSP is serving the asset leg — `'inventory'` (fronted from its own inventory, fast) or
  /// `'maker-first'` (waits on Bitcoin confirmations, slow). TOLERANT: an older LSP omits it, and
  /// ABSENT means the slow maker-first path — never assume fast.
  final String? frontMode;

  /// The LSP's own human-readable timescale for the current wait (`expected_wait`), when it gives one.
  final String? expectedWait;
  final Map<String, dynamic> raw;

  bool get hasTerms => termsHashH != null && termsHashH!.isNotEmpty;
  bool get failed => status == 'failed' || handshakeFailed;

  /// True ONLY when the LSP explicitly says it fronts the asset from inventory (the fast variant).
  bool get frontedFromInventory => frontMode == 'inventory';

  static BridgeJobStatus fromJson(Map<String, dynamic> j) {
    final terms = j['bridge_terms'];
    final t = terms is Map ? terms : const {};
    final hs = j['bridgeHandshake'];
    return BridgeJobStatus(
      ok: j['ok'] != false,
      status: '${j['status'] ?? ''}',
      error: (j['error'] ?? (hs is Map ? hs['error'] : null))?.toString(),
      termsHashH: t['hash_h']?.toString().toLowerCase(),
      seqLocktime: _asInt(t['seq_locktime'] ?? t['seqLocktime']),
      makerSeqRefundPub: (t['maker_seq_refund_pub'] ?? t['makerSeqRefundPub'])?.toString(),
      makerSeqLeg: BridgeLeg.fromJson(j['maker_seq_leg'] ?? t['maker_seq_leg']),
      handshakeFailed: hs is Map && hs['ok'] == false,
      // Asset-side fronting fields — read TOLERANTLY (top-level or inside bridge_terms, either casing);
      // absent stays null, which every reader treats as the slow maker-first path.
      frontMode: (j['front_mode'] ?? j['frontMode'] ?? t['front_mode'] ?? t['frontMode'])
          ?.toString()
          .toLowerCase(),
      expectedWait: (j['expected_wait'] ?? j['expectedWait'] ?? t['expected_wait'] ?? t['expectedWait'])?.toString(),
      raw: j,
    );
  }
}
