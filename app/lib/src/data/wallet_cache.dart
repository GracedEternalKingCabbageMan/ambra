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

  // -- OpenAMP restricted-transfer tracker ------------------------------------
  // openampd exposes no per-holder history endpoint, so the wallet tracks its
  // OWN sent transfers locally (mirrors the web wallet's OAMP_XFERS localStorage
  // key) and re-derives confirmation + Bitcoin anchor depth from the explorer.
  static const _kOampXfers = 'ambra.oamp.transfers';

  static Future<List<OampTransfer>> loadOampTransfers() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kOampXfers);
    if (s == null) return const [];
    try {
      return (jsonDecode(s) as List).map((m) => OampTransfer.fromJson(m as Map<String, dynamic>)).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveOampTransfers(List<OampTransfer> xfers) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kOampXfers, jsonEncode(xfers.map((x) => x.toJson()).toList()));
  }

  /// Append one just-sent restricted transfer (confirmation is re-derived later).
  static Future<void> addOampTransfer(OampTransfer x) async {
    final list = List<OampTransfer>.from(await loadOampTransfers())..add(x);
    await saveOampTransfers(list);
  }

  // -- Lightning history (written by the LN pay/receive cards) -----------------
  // The LN send/receive cards persist their own records here; History only READS
  // this key, defensively, so the two never share code. Absent/empty => no rows.
  static const _kLnHistory = 'ambra.ln.history';

  static Future<List<Map<String, dynamic>>> loadLnHistory() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kLnHistory);
    if (s == null) return const [];
    try {
      final list = jsonDecode(s);
      if (list is! List) return const [];
      return [for (final e in list) if (e is Map<String, dynamic>) e];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveLnHistory(List<Map<String, dynamic>> entries) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLnHistory, jsonEncode(entries));
  }

  /// Append one Lightning pay/receive record, written by the LN cards. Shape
  /// mirrors what `_LnRow` (history_screen.dart) renders defensively: `kind`
  /// ('payment' outgoing; 'receive'/'received'/'invoice'/'settle' incoming),
  /// `ticker` + `atoms` + `precision` (preferred) or `amount_msat` (fallback),
  /// `description`, `time` (epoch millis). Extra fields (payment_hash, preimage,
  /// bolt11, destination) are carried along for future use; the reader ignores
  /// unknown keys.
  static Future<void> addLnHistory(Map<String, dynamic> entry) async {
    final list = List<Map<String, dynamic>>.from(await loadLnHistory())..add(entry);
    await saveLnHistory(list);
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kBalances);
    await p.remove(_kTxs);
    await p.remove(_kBtc);
    await p.remove(_kOampXfers);
    await p.remove(_kLnHistory);
  }
}

/// One locally-tracked OpenAMP restricted transfer this wallet sent. Mirrors the
/// web wallet's OAMP_XFERS record. `confirmed`/`blockHash`/`anchorDepth` are
/// re-derived from the live chain (reorg-aware: a confirmed row can revert to
/// pending if its anchoring Bitcoin block is orphaned — never sticky).
class OampTransfer {
  OampTransfer({
    required this.asset,
    required this.ticker,
    required this.precision,
    required this.recipientAid,
    required this.atoms,
    required this.txid,
    required this.time,
    this.confirmed = false,
    this.blockHash,
    this.anchorDepth,
  });

  final String asset;
  final String ticker;
  final int precision;
  final String recipientAid;
  final String atoms;
  final String txid;
  final int time; // epoch millis
  bool confirmed;
  String? blockHash;
  int? anchorDepth;

  Map<String, dynamic> toJson() => {
        'asset': asset,
        'ticker': ticker,
        'precision': precision,
        'recipient_aid': recipientAid,
        'atoms': atoms,
        'txid': txid,
        'time': time,
        'confirmed': confirmed,
        'blockHash': blockHash,
        'anchorDepth': anchorDepth,
      };

  static OampTransfer fromJson(Map<String, dynamic> m) => OampTransfer(
        asset: '${m['asset']}',
        ticker: '${m['ticker']}',
        precision: m['precision'] is num ? (m['precision'] as num).toInt() : int.tryParse('${m['precision']}') ?? 8,
        recipientAid: '${m['recipient_aid']}',
        atoms: '${m['atoms']}',
        txid: '${m['txid']}',
        time: m['time'] is num ? (m['time'] as num).toInt() : int.tryParse('${m['time']}') ?? 0,
        confirmed: m['confirmed'] == true,
        blockHash: (m['blockHash'] is String && (m['blockHash'] as String).isNotEmpty) ? m['blockHash'] as String : null,
        anchorDepth: m['anchorDepth'] is num ? (m['anchorDepth'] as num).toInt() : null,
      );
}
