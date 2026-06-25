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
