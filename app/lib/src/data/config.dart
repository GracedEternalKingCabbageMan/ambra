/// App version shown in the More footer. Bump alongside pubspec on release.
const kAppVersion = '0.10.3';

/// Backend node the wallet talks to. Defaults to the public Sequentia testnet
/// node; users can point Ambra at their own (persisted via [NodeConfig]). Every
/// endpoint derives from the active [origin], so switching nodes is one change.
class Backend {
  Backend._();

  /// The public Sequentia testnet node (the default backend).
  static const defaultOrigin = 'http://159.195.15.140';

  static String _origin = defaultOrigin;
  static String get origin => _origin;
  static set origin(String v) => _origin = _normalize(v);
  static bool get isDefault => _origin == defaultOrigin;

  static String get esplora => '$_origin/api';
  static String get testnet4 => '$_origin/testnet4/api';
  static String get dex => '$_origin/dex'; // SeqDEX daemon (grpc-gateway REST) reverse-proxy
  static String get seqob => '$_origin/seqob'; // SeqOB order-book relay (grpc-gateway REST), matches the web wallet's SEQOB default
  static String get feerates => '$_origin/feerates';
  static String get prices => '$_origin/prices';
  static String get registry => '$_origin/registry/index.minimal.json';
  static String get faucet => '$_origin/faucet';

  /// The OpenAMP restricted-asset enclave API base (`/v1/users`, `/v1/assets`,
  /// `/v1/transfers`), same-origin by default (live at `<origin>/openamp`). The
  /// wallet holds the enclave's signing key on-device (m/5/0 x-only) and the
  /// enclave only ever asks it to sign; restricted balances show as ordinary
  /// rows. When the endpoint is absent/offline the OpenAMP layer stays dormant.
  static String get openamp => '$_origin/openamp';

  /// The hosted-SeqLN LSP HTTP API (`GET /status`, `POST /swap`), same-origin by
  /// default. This is the SAME contract the web wallet's seqln.js speaks, so one
  /// hosted LSP serves both clients. See [lnWsUrl] for the on-device signer link.
  static String get lsp => '$_origin/lsp';

  // -- Lightning (hosted-SeqLN LSP) transport config -------------------------
  // Mirrors the web wallet's window.SEQ_LSP_* globals. Empty [lnWsUrl] /
  // [lnHostPubkey] => Lightning is NOT deployed for this build: the on-device
  // signer stays offline, the "Instant (Lightning)" swap rail is hidden, and the
  // wallet behaves exactly as the on-chain-only build. Point these at the harness
  // (or a future hosted LSP) to bring the non-custodial LN rail online.

  /// wss front of the hosted node's Noise_XK responder (a WS<->TCP relay). Absent
  /// => the on-device signer cannot come online, so the LN route stays unavailable.
  static String lnWsUrl = '';

  /// The hosted node's pinned 33-byte transport static pubkey (hex). Absent => LN
  /// unavailable (the device must authenticate the host it co-signs for).
  static String lnHostPubkey = '';

  /// Optional bearer token for the LSP HTTP API. When empty the LSP calls reuse
  /// the node [authHeaders] plumbing (same as /dex, /feerates).
  static String lnToken = '';

  /// Harness pinning: a fixed 64-hex device transport privkey to use instead of
  /// the seed-derived one (the twin of the web wallet's SEQ_LSP_DEV_KEY). Empty =>
  /// derive deterministically from the wallet seed (m/1017'/0'/0').
  static String lnDeviceKeyOverride = '';

  /// Device signer validating policy: 'permissive' or 'enforce'.
  static String lnPolicy = 'permissive';

  /// Optional `Authorization` header for a node behind HTTP auth. Set by
  /// [NodeConfig]; applied to the sidecar HTTP calls (and, via the core, to
  /// Esplora). Null when the node is open (the public default).
  static String? _authHeader;
  static String? get authHeader => _authHeader;
  static set authHeader(String? v) => _authHeader = (v != null && v.isNotEmpty) ? v : null;

  /// Header map to spread into sidecar requests; empty when no auth is set.
  static Map<String, String> get authHeaders =>
      _authHeader == null ? const {} : {'Authorization': _authHeader!};

  /// Public block-explorer (Esplora SPA) page for a transaction.
  static String explorerTx(String txid) => '$_origin/explorer/tx/$txid';

  /// Trim whitespace and trailing slashes so endpoint concatenation stays clean.
  static String _normalize(String v) {
    var s = v.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

class AssetLabel {
  const AssetLabel(this.ticker, this.precision, {this.subtitle});
  final String ticker;
  final int precision;
  final String? subtitle;
}

/// Built-in labels for the public testnet demo assets (mirrors the web wallet).
/// The asset registry (/registry) can refine these later.
class SeqAssets {
  SeqAssets._();
  static const policy = 'c8eccacf0953e1931cd31e434d8319101cc36e6c38b0e2104d8687552fae3e40';

  static const _builtin = <String, AssetLabel>{
    'c8eccacf0953e1931cd31e434d8319101cc36e6c38b0e2104d8687552fae3e40':
        AssetLabel('tSEQ', 8, subtitle: 'Sequence'),
    '2a515539da5e6a60caa7766ecd65bac0c10d15717ddd2088844ba58f4d04b9de':
        AssetLabel('USDX', 8, subtitle: 'USD Stablecoin'),
    'e39685e718516156679088d9400d11a1eb82bf7cc27c5b9f5a614b8c91246d13':
        AssetLabel('EURX', 8, subtitle: 'Euro Stablecoin'),
    '3a0f9192219db59f8d7f87d93ac6311095dfe1255d149727b87baaa7d2cc71a1':
        AssetLabel('GOLD', 8, subtitle: 'Gold (troy ounce)'),
    '57dfa6b0eff594cc3ef1de5555e0526d1eb5590289e014e7663b292edcd63f48':
        AssetLabel('SILVR', 8, subtitle: 'Silver (troy ounce)'),
    '4dfe69c334a9cdf4005ddf3889bba1bc397703fa8da669254877f3209caf7c8f':
        AssetLabel('OILX', 8, subtitle: 'Crude Oil (barrel)'),
  };

  /// Faucet-dispensable assets (empty string = tSEQ).
  static const faucetAssets = <String>['', 'USDX', 'EURX', 'GOLD', 'SILVR', 'OILX'];

  /// Registry-fetched labels (asset id -> label), populated by [RegistryService]
  /// at startup. Overlaid BELOW the built-in demo set so an asset outside that set
  /// resolves its real ticker/precision/name from the public registry instead of a
  /// hex-derived placeholder with an assumed precision.
  static final Map<String, AssetLabel> _registry = {};

  /// OpenAMP restricted-asset labels (asset id -> label), populated from the
  /// enclave's `GET /v1/assets` by [OpenAmpService]. Kept separate from the
  /// public registry so the two overlays don't clobber each other.
  static final Map<String, AssetLabel> _openamp = {};

  /// Replace the registry overlay (from a fetch or the on-disk cache).
  static void mergeRegistry(Map<String, AssetLabel> m) {
    _registry
      ..clear()
      ..addAll(m);
  }

  /// Replace the OpenAMP overlay (from the enclave's asset list).
  static void mergeOpenamp(Map<String, AssetLabel> m) {
    _openamp
      ..clear()
      ..addAll(m);
  }

  static AssetLabel labelFor(String assetId) {
    // Curated demo assets are authoritative (correct even offline).
    final hit = _builtin[assetId];
    if (hit != null) return hit;
    // Restricted (OpenAMP) assets carry their ticker/precision from the enclave.
    final amp = _openamp[assetId];
    if (amp != null) return amp;
    // The public registry supplies the real ticker + precision + name — use it so
    // we don't fabricate a ticker from the hex id or assume precision 8.
    final reg = _registry[assetId];
    if (reg != null) return reg;
    // Truly unknown: elide the hex id (precision unknown; keep the 8-dp default
    // that issued assets use).
    final short = assetId.length > 12
        ? '${assetId.substring(0, 6)}…${assetId.substring(assetId.length - 4)}'
        : assetId;
    return AssetLabel(short, 8);
  }
}

