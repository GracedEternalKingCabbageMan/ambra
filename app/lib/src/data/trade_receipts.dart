import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A local receipt for one DEX trade this wallet did (a same-chain covenant fill,
/// a cross-chain lift, an LN swap). Purely a local activity log so the user can
/// see recent trades and their last-known status even after the relay forgets the
/// order; it holds no key material and is not consensus state.
///
/// Mirrors the web wallet's `logTrade({id, title, status, txid})`: entries are
/// upserted by a stable [id] (e.g. `lift:<txid>`, `take:<offerId>`) so a trade
/// that progresses through states (locked -> claimed) updates one row rather than
/// appending duplicates.
class TradeReceipt {
  final String id; // stable key across status updates
  final String title; // "Bought 10 GOLD for USDX"
  final String status; // last-known status ("settled", "BTC locked", ...)
  final String? txid; // settling txid when known
  final int ts; // unix seconds, first seen

  TradeReceipt({required this.id, required this.title, required this.status, this.txid, required this.ts});

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'status': status, 'txid': txid, 'ts': ts};

  factory TradeReceipt.fromJson(Map<String, dynamic> j) => TradeReceipt(
        id: '${j['id'] ?? ''}',
        title: '${j['title'] ?? ''}',
        status: '${j['status'] ?? ''}',
        txid: (j['txid'] as String?)?.isEmpty ?? true ? null : j['txid'] as String?,
        ts: (j['ts'] as num?)?.toInt() ?? 0,
      );
}

/// Persistent, capped store of DEX trade receipts (newest first).
class TradeReceipts {
  static const _key = 'ambra.dex.receipts';
  static const _cap = 50; // keep the log small (secure storage is size-limited)
  static const _storage = FlutterSecureStorage();

  static Future<List<TradeReceipt>> list() async {
    final s = await _storage.read(key: _key);
    if (s == null || s.isEmpty) return [];
    try {
      final arr = jsonDecode(s) as List<dynamic>;
      return arr.map((e) => TradeReceipt.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<TradeReceipt> items) => _storage.write(
      key: _key, value: jsonEncode(items.take(_cap).map((e) => e.toJson()).toList()));

  /// Upsert a receipt by [id]: a new id inserts at the front (preserving its first
  /// [ts]); an existing id updates its title/status/txid in place, keeping the
  /// original timestamp and list position so a progressing trade stays put.
  static Future<void> log({required String id, required String title, required String status, String? txid}) async {
    final items = await list();
    final i = items.indexWhere((e) => e.id == id);
    if (i >= 0) {
      final prev = items[i];
      items[i] = TradeReceipt(id: id, title: title, status: status, txid: txid ?? prev.txid, ts: prev.ts);
    } else {
      items.insert(0, TradeReceipt(id: id, title: title, status: status, txid: txid, ts: _nowS()));
    }
    await _save(items);
  }

  static Future<void> clear() => _storage.delete(key: _key);

  static int _nowS() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
