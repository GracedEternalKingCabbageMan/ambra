import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'format.dart';

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
    // 'BTC' is offered explicitly below; drop the feed's own tBTC key so Bitcoin
    // isn't listed twice.
    final tickers = _prices.keys.where((t) => t != 'TBTC' && t != 'WBTC').toList()..sort();
    return ['USD', 'BTC', ...tickers];
  }

  double? _priceUsd(String ticker) {
    final t = ticker.toUpperCase();
    if (t == 'TSEQ' || t == 'SEQ') return _prices['SEQ'];
    // Parent-chain Bitcoin is priced under tBTC (testnet Bitcoin) on /prices
    // (the key is uppercased to TBTC on load). Accept every Bitcoin alias.
    if (t == 'BTC' || t == 'WBTC' || t == 'TBTC') return _prices['TBTC'];
    return _prices[t];
  }

  double? _refPriceUsd() {
    if (_ref == 'USD') return 1.0;
    if (_ref == 'BTC') return _prices['TBTC'];
    return _priceUsd(_ref);
  }

  /// Numeric value of an asset amount in the reference currency, or null if it
  /// can't be priced. Used to total a multi-asset portfolio without privileging
  /// any single asset.
  double? refValue(String ticker, String atoms, int precision) {
    final p = _priceUsd(ticker);
    final rp = _refPriceUsd();
    if (p == null || rp == null || rp == 0) return null;
    final amt = (BigInt.tryParse(atoms) ?? BigInt.zero).toDouble() / math.pow(10, precision);
    return amt * p / rp;
  }

  /// The atom amount of [ticker] worth [refAmount] units of the reference currency — the INVERSE of
  /// [refValue]. Lets a user enter size in their chosen reference currency (USD / BTC / chosen) and have it
  /// converted to the asset amount (spec §6.2, priority A). Rounds to the nearest atom; returns null when
  /// the asset can't be priced or the input is non-positive / non-finite.
  BigInt? atomsForRef(String ticker, double refAmount, int precision) {
    if (!refAmount.isFinite || refAmount <= 0) return null;
    final p = _priceUsd(ticker);
    final rp = _refPriceUsd();
    if (p == null || rp == null || p == 0) return null;
    final amt = refAmount * rp / p; // whole units of the asset
    final atoms = (amt * math.pow(10, precision)).round();
    return atoms > 0 ? BigInt.from(atoms) : null;
  }

  /// "≈ 1.23 USD" for an asset amount, or null if it can't be priced.
  String? approx(String ticker, String atoms, int precision) {
    final v = refValue(ticker, atoms, precision);
    return v == null ? null : '≈ ${_fmt(v)} $_ref';
  }

  /// Format a reference-currency value (digits only; caller appends [ref]).
  String fmtRef(double v) => _fmt(v);

  String _fmt(double v) {
    final abs = v.abs();
    final digits = abs >= 1000
        ? 0
        : abs >= 1
            ? 2
            : abs >= 0.01
                ? 4
                : 6;
    // Thousands-separate the whole part (e.g. 64,793.75) so large values read
    // clearly; keep the fractional part as-is. Sign handled separately since the
    // grouper takes unsigned digit strings.
    final s = abs.toStringAsFixed(digits);
    final dot = s.indexOf('.');
    final grouped = dot < 0
        ? groupThousands(s)
        : '${groupThousands(s.substring(0, dot))}${s.substring(dot)}';
    return v < 0 ? '-$grouped' : grouped;
  }
}
