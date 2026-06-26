/// App version shown in the More footer. Bump alongside pubspec on release.
const kAppVersion = '0.10.1';

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
  static String get feerates => '$_origin/feerates';
  static String get prices => '$_origin/prices';
  static String get registry => '$_origin/registry/index.minimal.json';
  static String get faucet => '$_origin/faucet';

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
    'dc7f45fcfeb17c8ae74e284472d85543395f50e88f4a36cb652e8102703b7027':
        AssetLabel('USDX', 8, subtitle: 'USD Stablecoin'),
    'f7a756b4e966623065543e52b754324629295c895046a0916a939898ad373667':
        AssetLabel('EURX', 8, subtitle: 'Euro Stablecoin'),
    'c28fc933ce41f7a9188da029c6f7377fc961e2d58588372ef4073438610b9283':
        AssetLabel('GOLD', 8, subtitle: 'Gold (troy ounce)'),
    '3e30ad0ebd13cc7ac1bbd12df1414b213708a6048b745d185fe935d9624024db':
        AssetLabel('WBTC', 8, subtitle: 'Wrapped Bitcoin'),
    '50a00211d7074d5f857a3dec6cb84a1f3fefb26e56a94a954a299b28ac9f32df':
        AssetLabel('SILVR', 8, subtitle: 'Silver (troy ounce)'),
    'f9b069ac00f4dc57381a304704fac93301f90d3d509d207cfbddc8367d4e9cfb':
        AssetLabel('OILX', 8, subtitle: 'Crude Oil (barrel)'),
  };

  /// Faucet-dispensable assets (empty string = tSEQ).
  static const faucetAssets = <String>['', 'USDX', 'EURX', 'GOLD', 'WBTC', 'SILVR', 'OILX'];

  static AssetLabel labelFor(String assetId) {
    final hit = _builtin[assetId];
    if (hit != null) return hit;
    final short = assetId.length > 12
        ? '${assetId.substring(0, 6)}…${assetId.substring(assetId.length - 4)}'
        : assetId;
    return AssetLabel(short, 8);
  }
}

