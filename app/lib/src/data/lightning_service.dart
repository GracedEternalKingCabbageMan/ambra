import 'package:flutter/foundation.dart';

import '../rust/api/signer.dart' as ffi;
import 'config.dart';
import 'lsp_client.dart';
import 'seqln_signer.dart';

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
    _set('idle');
  }

  // -- LSP HTTP delegates (available even before the signer serves, for status) --

  Future<LspStatus> getStatus() => LspClient.getStatus();

  Future<LspSwapResult> swap({required String side, required String asset, required num amount}) =>
      LspClient.swap(side: side, asset: asset, amount: amount);

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
