import 'dart:typed_data';

import 'package:ambra/src/rust/api/signer.dart' as rust;

/// Dart twin of the web wallet's `seqln-keys.js` — deterministic per-node Lightning device-key
/// derivation. The actual BIP32/BIP39 derivation lives in native `ambra_core` (reusing the same
/// paths), so it is byte-identical to the browser client (proven in
/// `test/seqln_device_key_test.dart`); this is the thin Dart API over it, matching seqln-keys.js
/// (`lnDeriveNode` / `lnDeriveAll` / `lnDeriveAsset`) so the LSP orchestration code reads the same.
///
///   transportPrivkey  the BOLT-8 Noise_XK static privkey the LSP pins (`SEQLN_SIGNER_PEER_PUBKEY`)
///   signingSeed       the opaque 64-hex string fed to SeqlnSigner.fromMnemonic — because the hosted
///                     node is keyless, this alone determines its LN identity (node_id + channels)
typedef LnNodeKeys = rust.LnNodeKeys;

/// Keys for one FIXED hosted node: `'asset'` (Sequentia) or `'btc'` (testnet4).
LnNodeKeys lnDeriveNode(String mnemonic, String node) =>
    rust.seqlnDeriveNode(mnemonic: mnemonic, node: node);

/// Both fixed nodes in one pass: `{ 'asset': ..., 'btc': ... }`.
Map<String, LnNodeKeys> lnDeriveAll(String mnemonic) => {
      'asset': lnDeriveNode(mnemonic, 'asset'),
      'btc': lnDeriveNode(mnemonic, 'btc'),
    };

/// Keys for a PROVISIONED per-asset hosted node (deterministic + unique per 32-byte hex asset id).
LnNodeKeys lnDeriveAsset(String mnemonic, String assetId) =>
    rust.seqlnDeriveAsset(mnemonic: mnemonic, assetId: assetId);

/// The device transport (Noise static) pubkey — 33-byte compressed hex — the LSP pins for a node.
/// This is what a provision call sends as `device_transport_pubkey`, and how the LSP keys the
/// provisioned node (`seq:<assetId>:<pub>` / `btc:<pub>`).
String deviceTransportPubkey(Uint8List transportPrivkey) =>
    rust.devicePubkey(staticPrivkey: transportPrivkey);

/// The LSP registry key for THIS device's own provisioned asset node — reconstructable purely from
/// the mnemonic, so a reopened wallet can pass `?nodes=` to `/status` and read back its own channels
/// (the reload-survival path; mirrors the web wallet's own-key reconstruction). Keyed
/// `seq:<assetId>:<deviceTransportPubkey>` exactly as the LSP keys it at provision time.
String ownNodeKeyForAsset(String mnemonic, String assetId) {
  final k = lnDeriveAsset(mnemonic, assetId);
  return 'seq:${assetId.toLowerCase()}:${deviceTransportPubkey(k.transportPrivkey)}';
}

/// The LSP registry key for THIS device's own provisioned BTC (testnet4) node — `btc:<pub>`.
String ownNodeKeyForBtc(String mnemonic) {
  final k = lnDeriveNode(mnemonic, 'btc');
  return 'btc:${deviceTransportPubkey(k.transportPrivkey)}';
}
