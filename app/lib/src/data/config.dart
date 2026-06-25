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

/// Built-in asset labels. The asset registry (/registry) refines these in M4+.
class SeqAssets {
  SeqAssets._();
  static const policy = 'c8eccacf0953e1931cd31e434d8319101cc36e6c38b0e2104d8687552fae3e40';

  static AssetLabel labelFor(String assetId) {
    if (assetId == policy) {
      return const AssetLabel('tSEQ', 8, subtitle: 'Sequentia native asset');
    }
    final short = assetId.length > 12
        ? '${assetId.substring(0, 6)}…${assetId.substring(assetId.length - 4)}'
        : assetId;
    return AssetLabel(short, 8);
  }
}

