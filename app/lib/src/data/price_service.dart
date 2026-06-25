import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

/// Wallet-wide reference-currency valuation. Prices are USD-base from /prices;
/// the user picks a reference (USD, BTC, or any priced ticker) and every amount
/// is shown ≈ in it. Display-only — never a fee rate.
class PriceService extends ChangeNotifier {
  PriceService._();
  static final PriceService instance = PriceService._();

  static const _kRef = 'ambra.refccy';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  Map<String, double> _prices = {}; // TICKER(upper) -> USD price
  String _ref = 'USD';

  String get ref => _ref;
  bool get hasPrices => _prices.isNotEmpty;

  Future<void> load() async {
    _ref = (await _storage.read(key: _kRef)) ?? 'USD';
    await refreshPrices();
  }

  Future<void> refreshPrices() async {
    try {
      _prices = await ApiClient.prices();
    } catch (_) {/* keep last-good */}
    notifyListeners();
  }

  Future<void> setRef(String r) async {
    _ref = r;
    await _storage.write(key: _kRef, value: r);
    notifyListeners();
  }

  List<String> refOptions() {
    final tickers = _prices.keys.where((t) => t != 'WBTC').toList()..sort();
    return ['USD', 'BTC', ...tickers];
  }

  double? _priceUsd(String ticker) {
    final t = ticker.toUpperCase();
    if (t == 'TSEQ' || t == 'SEQ') return _prices['SEQ'];
    return _prices[t];
  }

  double? _refPriceUsd() {
    if (_ref == 'USD') return 1.0;
    if (_ref == 'BTC') return _prices['WBTC'] ?? _prices['BTC'];
    return _priceUsd(_ref);
  }

  /// "≈ 1.23 USD" for an asset amount, or null if it can't be priced.
  String? approx(String ticker, String atoms, int precision) {
    final p = _priceUsd(ticker);
    final rp = _refPriceUsd();
    if (p == null || rp == null || rp == 0) return null;
    final amt = (BigInt.tryParse(atoms) ?? BigInt.zero).toDouble() / math.pow(10, precision);
    return '≈ ${_fmt(amt * p / rp)} $_ref';
  }

  String _fmt(double v) {
    final abs = v.abs();
    final digits = abs >= 1000
        ? 0
        : abs >= 1
            ? 2
            : abs >= 0.01
                ? 4
                : 6;
    return v.toStringAsFixed(digits);
  }
}
