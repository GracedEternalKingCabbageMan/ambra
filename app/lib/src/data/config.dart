/// Backend the wallet talks to (Sequentia testnet box). Overridable later.
class Backend {
  Backend._();
  static const origin = 'http://159.195.15.140';
  static const esplora = '$origin/api';
  static const testnet4 = '$origin/testnet4/api';
  static const feerates = '$origin/feerates';
  static const prices = '$origin/prices';
  static const registry = '$origin/registry/index.minimal.json';
  static const faucet = '$origin/faucet';
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
        AssetLabel('tSEQ', 8, subtitle: 'Sequentia native asset'),
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

