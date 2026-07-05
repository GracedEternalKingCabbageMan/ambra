import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as core;

/// Caches the last-known balances and history on disk so the UI shows them
/// instantly on launch (outdated, but not a blank loading screen) and then
/// refreshes in the background. Single-wallet, so the keys are not per-mnemonic.
class WalletCache {
  WalletCache._();
  static const _kBalances = 'ambra.cache.balances';
  static const _kTxs = 'ambra.cache.txs';
  static const _kBtc = 'ambra.cache.btcsats';

  /// Persist the last-known Bitcoin (testnet4) balance in sats, so a later
  /// testnet4-scan failure shows the last value (marked offline) instead of
  /// silently hiding the BTC row.
  static Future<void> saveBtc(String sats) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBtc, sats);
  }

  static Future<String?> loadBtc() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kBtc);
  }

  static Future<void> saveBalances(List<core.AssetBalance> b) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBalances, jsonEncode(b.map((e) => {'a': e.assetId, 'v': e.atoms}).toList()));
  }

  static Future<List<core.AssetBalance>?> loadBalances() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kBalances);
    if (s == null) return null;
    try {
      return (jsonDecode(s) as List)
          .map((m) => core.AssetBalance(assetId: m['a'] as String, atoms: m['v'] as String))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveTxs(List<core.TxRow> txs) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kTxs,
      jsonEncode(txs.map((t) => {
            'id': t.txid,
            'h': t.height,
            'ts': t.timestamp?.toString(),
            'k': t.kind,
            'f': t.fee.toString(),
            'fa': t.feeAsset,
            'd': t.deltas.map((d) => {'a': d.assetId, 'v': d.atoms}).toList(),
          }).toList()),
    );
  }

  static Future<List<core.TxRow>?> loadTxs() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kTxs);
    if (s == null) return null;
    try {
      return (jsonDecode(s) as List)
          .map((m) => core.TxRow(
                txid: m['id'] as String,
                height: m['h'] as int?,
                timestamp: m['ts'] == null ? null : BigInt.parse(m['ts'] as String),
                kind: m['k'] as String,
                fee: BigInt.parse(m['f'] as String),
                // Older cached rows predate fee_asset; fall back to '' (rendered as tSEQ).
                feeAsset: (m['fa'] as String?) ?? '',
                deltas: (m['d'] as List)
                    .map((d) => core.AssetDelta(assetId: d['a'] as String, atoms: d['v'] as String))
                    .toList(),
              ))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kBalances);
    await p.remove(_kTxs);
    await p.remove(_kBtc);
  }
}
