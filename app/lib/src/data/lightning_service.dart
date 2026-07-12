import 'package:flutter/foundation.dart';

import '../rust/api/signer.dart' as ffi;
import 'config.dart';
import 'lsp_client.dart';
import 'seqln_keys.dart' as keys;
import 'seqln_signer.dart';
import 'wallet_repository.dart';

/// Ambra's Lightning controller — the mobile twin of the web wallet's `seqln.js`
/// module state + `index.html`'s `initLightning`. Under the hosted-SeqLN LSP
/// model (UX-audit §8, Tier 2): WE host the SeqLN node; the phone is a thin,
/// NON-CUSTODIAL client that (a) holds the keys and co-signs the hosted node's
/// commitment updates via the on-device signer ([SeqlnSigner]) over a wss Noise
/// link, and (b) commands the hosted node to take a pure-LN order-book offer via
/// the [LspClient] HTTP API. The device signer never leaves the phone, so the
/// LSP can command routing but can never move the user's channel funds.
///
/// A [ChangeNotifier] singleton (like [WalletRepository] / [NodeConfig]) so the
/// swap UI can show a status indicator and the "Instant (Lightning)" rail appears
/// only while the signer is actually serving. When Lightning is not deployed for
/// the build ([Backend.lnWsUrl] / [Backend.lnHostPubkey] empty), [start] is a
/// no-op and [available] stays false, so the wallet behaves exactly as the
/// on-chain-only build.
class LightningService extends ChangeNotifier {
  LightningService._();
  static final LightningService instance = LightningService._();

  SeqlnSigner? _signer;

  /// idle | unconfigured | connecting | handshaking | authenticated | node_id |
  /// ready | closed | error.
  String phase = 'idle';
  String detail = '';
  bool connected = false;
  String? nodeId;

  /// Whether Lightning is deployed for this build (a wss endpoint + a pinned host
  /// key). Without both, the on-device signer cannot come online.
  bool get configured => Backend.lnWsUrl.trim().isNotEmpty && Backend.lnHostPubkey.trim().isNotEmpty;

  /// The LN swap rail is offerable only when the on-device signer is actually
  /// serving the hosted node (so it can sign the swap's commitments). Deliberately
  /// conservative: no signer, no LN route — the composer falls back to on-chain.
  bool get available => configured && connected;

  /// Pure-LN happy path: genuinely instant + final (nothing on-chain, zero reorg
  /// risk). The one swap state the DEX 0-conf policy lets us call "final".
  String finalityCopy() =>
      'Instant and final. Pure Lightning: nothing settles on-chain, so there is no Bitcoin-reorg risk.';

  void _set(String p, [String? d]) {
    phase = p;
    detail = d ?? '';
    notifyListeners();
  }

  /// Bring the on-device signer online against the hosted node, so the
  /// "Instant (Lightning)" rail becomes available. Non-fatal and opt-in: if
  /// Lightning is not [configured] the call no-ops (LN stays off and the composer
  /// uses the on-chain rail). Safe to call again — a live signer is kept.
  ///
  /// TODO(device-verify): the real signer connect (Noise_XK over wss to a live
  /// LSP) + a live swap need a device/emulator and a running hosted node. This
  /// wires the flow byte-for-byte; the wss round-trip is device-verified.
  Future<void> start(String mnemonic) async {
    if (!configured) {
      _set('unconfigured', 'Lightning not deployed for this node');
      return;
    }
    if (_signer != null && connected) return; // already serving
    _set('connecting', 'starting on-device signer');
    try {
      final hostPub = _hexBytes(Backend.lnHostPubkey.trim());
      final devicePriv = _deviceTransportPriv(mnemonic);
      final signer = SeqlnSigner.fromMnemonic(mnemonic)
        ..setPolicy(Backend.lnPolicy == 'enforce' ? SeqlnPolicy.enforce : SeqlnPolicy.permissive);
      signer.onStatus = (st) {
        nodeId = st.nodeId ?? nodeId;
        if (st.state == 'closed' || st.state == 'error') connected = false;
        _set(st.state, st.detail);
      };
      _signer = signer;
      await signer.connect(
        wsUrl: Backend.lnWsUrl.trim(),
        hostStaticPubkey: hostPub,
        deviceStaticPrivkey: devicePriv,
      );
      nodeId = await signer.whenNodeId(timeout: const Duration(seconds: 30));
      connected = true;
      _set('ready', 'signer serving');
    } catch (e) {
      _signer = null;
      connected = false;
      _set('error', e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// Tear the signer link down (e.g. on wallet lock / removal).
  Future<void> stop() async {
    try {
      await _signer?.disconnect();
    } catch (_) {}
    _signer = null;
    connected = false;
    for (final n in _own.values) {
      try {
        await n.signer?.disconnect();
      } catch (_) {}
      n.signer = null;
      n.connected = false;
    }
    _own.clear();
    _set('idle');
  }

  // -- LSP HTTP delegates (available even before the signer serves, for status) --

  /// Hosted-node status. Pass [nodes] — this device's OWN provisioned-node keys (from
  /// seqln_keys.dart) — so `/status` also reports THIS device's per-asset channels across restarts.
  Future<LspStatus> getStatus({List<String>? nodes}) => LspClient.getStatus(nodes: nodes);

  Future<LspSwapResult> swap({required String side, required String asset, required num amount}) =>
      LspClient.swap(side: side, asset: asset, amount: amount);

  // -- per-asset OWN-node signers: general Lightning pay / receive + Move-to-Lightning ----------
  // The shared [start]/[_signer] above serves the DEMO node. General pay/receive and the Balance
  // channel flows act on the user's OWN, per-asset (or per-BTC) hosted node, each with its own
  // device signer. This registry keeps those signers keyed by LSP node_key so repeat calls
  // re-attach idempotently. 100% Dart orchestration over the existing FFIs (the twin of seqln.js's
  // provisionAndConnect + the provNodes map); no new Rust.

  final Map<String, _OwnNode> _own = {};

  /// The registry key for this device's OWN hosted node for [asset] (or the BTC node when
  /// [chain] == 'btc'), reconstructable purely from the mnemonic. Used to thread `?nodes=` into
  /// [getStatus] and to name the node in deposit/open/close.
  String ownNodeKey(String mnemonic, {String chain = 'seq', String? asset}) =>
      chain == 'btc' ? keys.ownNodeKeyForBtc(mnemonic) : keys.ownNodeKeyForAsset(mnemonic, asset!);

  /// True once the OWN-node signer for [nodeKey] is connected (so its node can pay/receive/close).
  bool ownConnected(String nodeKey) => _own[nodeKey]?.connected == true;

  /// Provision (or re-attach) the user's OWN hosted node for [asset] (Sequentia) or the BTC node
  /// ([chain] == 'btc'), and bring its on-device signer online over the node's Noise responder.
  /// Idempotent per node_key: a live signer is reused. Returns the LSP registry node_key. Throws a
  /// clean message when Lightning is not [configured] (dormant) or the signer cannot come online.
  /// Mirrors seqln.js provisionAndConnect.
  Future<String> connectNode(String mnemonic, {String chain = 'seq', String? asset}) async {
    if (!configured) throw Exception('Lightning is not enabled on this node.');
    final btc = chain == 'btc';
    if (!btc && (asset == null || asset.isEmpty)) throw Exception('connectNode: an asset id is required.');
    final id = btc ? keys.lnDeriveNode(mnemonic, 'btc') : keys.lnDeriveAsset(mnemonic, asset!);
    final devicePub = keys.deviceTransportPubkey(id.transportPrivkey);
    final label = btc ? 'BTC' : SeqAssets.labelFor(asset!).ticker;
    final node = await LspClient.provisionNode(
      deviceTransportPubkey: devicePub,
      asset: btc ? null : asset,
      chain: btc ? 'btc' : 'seq',
      label: label,
    );
    final nodeKey = node.key.isNotEmpty
        ? node.key
        : (btc ? keys.ownNodeKeyForBtc(mnemonic) : keys.ownNodeKeyForAsset(mnemonic, asset!));
    final existing = _own[nodeKey];
    if (existing != null && existing.connected) return nodeKey; // already serving
    final wsPath = node.publicWsPath;
    final hostPub = node.hostPubkey;
    if (wsPath == null || wsPath.isEmpty || hostPub == null || hostPub.isEmpty) {
      throw Exception('Your Lightning node is still preparing; try again in a moment.');
    }
    // A freshly provisioned node boots + rescans before its RPC answers; wait (bounded) so the
    // first use after connect never hits a "node not ready" error.
    try {
      await LspClient.waitNodeReady(nodeKey);
    } catch (_) {/* the signer connect below surfaces a link error if it truly isn't up */}
    final wsUrl = _wsBaseFor() + wsPath;
    final signer = SeqlnSigner.fromMnemonic(mnemonic)
      ..setPolicy(Backend.lnPolicy == 'enforce' ? SeqlnPolicy.enforce : SeqlnPolicy.permissive);
    final own = _own[nodeKey] = _OwnNode();
    signer.onStatus = (st) {
      own.nodeId = st.nodeId ?? own.nodeId;
      if (st.state == 'closed' || st.state == 'error') {
        own.connected = false;
        own.signer = null; // null the dead signer so a later reconnect rebuilds (mirrors seqln.js)
      }
    };
    own.signer = signer;
    try {
      await signer.connect(
        wsUrl: wsUrl,
        hostStaticPubkey: _hexBytes(hostPub),
        deviceStaticPrivkey: id.transportPrivkey,
      );
      own.nodeId = await signer.whenNodeId(timeout: const Duration(seconds: 30));
      own.connected = true;
      notifyListeners();
    } catch (e) {
      own.signer = null;
      own.connected = false;
      throw Exception(
          'Could not bring your device signer online for your $label Lightning node: ${e.toString().replaceFirst('Exception: ', '')}');
    }
    return nodeKey;
  }

  /// Create a plain bolt11 to RECEIVE [amount] atoms of [asset] into the user's OWN hosted node.
  /// Brings the node + signer online first (the node signs the invoice), then ensures best-effort
  /// JIT inbound liquidity. Throws a clean message when Lightning is dormant.
  Future<NodeInvoice> createInvoice({required String asset, required num amount, String? description}) async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw Exception('Your wallet is locked; unlock it and try again.');
    final nodeKey = await connectNode(m, asset: asset);
    try {
      await LspClient.channelInbound(nodeKey: nodeKey, asset: asset, amount: amount);
    } catch (_) {/* best-effort JIT; a funded channel may already have inbound room */}
    return LspClient.nodeReceive(nodeKey: nodeKey, amount: amount, description: description);
  }

  /// Pay [bolt11] from the user's OWN hosted [asset] node (the device co-signs each HTLC). [asset]
  /// selects which node pays, mirroring the web wallet's pay-from-asset dropdown. Throws a clean
  /// message when Lightning is dormant.
  Future<NodePayResult> payInvoice({required String bolt11, required String asset}) async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw Exception('Your wallet is locked; unlock it and try again.');
    final nodeKey = await connectNode(m, asset: asset);
    return LspClient.nodePay(nodeKey: nodeKey, bolt11: bolt11);
  }

  /// The wss base for a provisioned node's Noise responder: the active node origin, scheme-swapped
  /// http->ws / https->wss (the per-node `public_ws_path` is appended). Mirrors seqln.js provWsUrl.
  String _wsBaseFor() => Backend.origin.replaceFirst(RegExp(r'^http'), 'ws');

  // -- device transport key ---------------------------------------------------

  /// The pinned Noise static privkey the LSP has provisioned for this wallet:
  /// [Backend.lnDeviceKeyOverride] (harness pinning) when set, else derived
  /// deterministically from the seed at BIP32 m/1017'/0'/0' — the exact twin of
  /// the web wallet's `lnDeviceTransportPriv`, so a wallet imported into either
  /// client presents the same device identity.
  List<int> _deviceTransportPriv(String mnemonic) {
    final ov = Backend.lnDeviceKeyOverride.trim();
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(ov)) return _hexBytes(ov);
    return ffi.seqlnDeviceTransportPrivkey(mnemonic: mnemonic);
  }

  static List<int> _hexBytes(String hex) {
    final s = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (s.length.isOdd) throw const FormatException('odd-length hex');
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// One entry in the OWN-node signer registry (a per-asset or per-BTC hosted node the user provisioned
/// and whose device signer this wallet serves). The twin of seqln.js's `provNodes` map value.
class _OwnNode {
  SeqlnSigner? signer;
  bool connected = false;
  String? nodeId;
}
