import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A same-chain COVENANT order this wallet placed (funded on-chain).
///
/// Fund-safety: a covenant is funded ON-CHAIN before its offer is posted to the relay, so if the post
/// fails (a relay reject, a dropped connection) the funds would otherwise sit in a covenant with no
/// local record to reclaim them. We persist this record — with the material needed to rebuild the
/// covenant for a REFUND reclaim (preparedJson, makerIndex, covenant spk, expiry) — BEFORE the post,
/// keyed by the funding outpoint (covTxid:covVout), and flip [posted] true once the relay accepts it.
class PlacedCovenant {
  final String covTxid;
  final int covVout;
  final String? offerId; // set once the offer is finalized (needed to cancel a live order)
  final String pay; // asset A (sold) id hex
  final String receive; // asset B (wanted) id hex
  final String sellAtoms;
  final String recvAtoms;
  final int makerIndex; // re-derives the maker payout for a reclaim
  final String covenantSpkHex;
  final String preparedJson; // the covenant recipe — enough to rebuild for a REFUND reclaim
  final int expiryLocktime; // the covenant becomes reclaimable at this block height
  final bool posted; // true once the relay accepted the offer
  final int createdMs;

  /// SBTC silent peg: this covenant LOCKS SBTC (`pay`) but was ADVERTISED as
  /// [advertiseAs] (the BTC sentinel) so it rests in the asset/BTC market (the ONE
  /// place SBTC touches the DEX). Tagged so the cancel/reclaim path knows to peg the
  /// reclaimed SBTC back OUT to real BTC — the user paid BTC and expects BTC back.
  /// Absent (false / null) for ordinary same-chain covenant orders. Mirrors the web
  /// wallet's PLACED `pegged`/`advertiseAs` tag (swap.js placeCovenant).
  final bool pegged;
  final String? advertiseAs;

  PlacedCovenant({
    required this.covTxid,
    required this.covVout,
    this.offerId,
    required this.pay,
    required this.receive,
    required this.sellAtoms,
    required this.recvAtoms,
    required this.makerIndex,
    required this.covenantSpkHex,
    required this.preparedJson,
    required this.expiryLocktime,
    required this.posted,
    required this.createdMs,
    this.pegged = false,
    this.advertiseAs,
  });

  /// Stable identity: the funding outpoint (known the instant the covenant is funded).
  String get key => '$covTxid:$covVout';

  Map<String, dynamic> toJson() => {
        'covTxid': covTxid,
        'covVout': covVout,
        'offerId': offerId,
        'pay': pay,
        'receive': receive,
        'sellAtoms': sellAtoms,
        'recvAtoms': recvAtoms,
        'makerIndex': makerIndex,
        'covenantSpkHex': covenantSpkHex,
        'preparedJson': preparedJson,
        'expiryLocktime': expiryLocktime,
        'posted': posted,
        'createdMs': createdMs,
        'pegged': pegged,
        'advertiseAs': advertiseAs,
      };

  factory PlacedCovenant.fromJson(Map<String, dynamic> j) => PlacedCovenant(
        covTxid: j['covTxid'] as String,
        covVout: (j['covVout'] as num).toInt(),
        offerId: j['offerId'] as String?,
        pay: j['pay'] as String,
        receive: j['receive'] as String,
        sellAtoms: j['sellAtoms'].toString(),
        recvAtoms: j['recvAtoms'].toString(),
        makerIndex: (j['makerIndex'] as num).toInt(),
        covenantSpkHex: j['covenantSpkHex'] as String,
        preparedJson: j['preparedJson'] as String,
        expiryLocktime: (j['expiryLocktime'] as num?)?.toInt() ?? 0,
        posted: j['posted'] as bool? ?? false,
        createdMs: (j['createdMs'] as num?)?.toInt() ?? 0,
        pegged: j['pegged'] as bool? ?? false,
        advertiseAs: j['advertiseAs'] as String?,
      );

  PlacedCovenant copyWith({String? offerId, bool? posted}) => PlacedCovenant(
        covTxid: covTxid,
        covVout: covVout,
        offerId: offerId ?? this.offerId,
        pay: pay,
        receive: receive,
        sellAtoms: sellAtoms,
        recvAtoms: recvAtoms,
        makerIndex: makerIndex,
        covenantSpkHex: covenantSpkHex,
        preparedJson: preparedJson,
        expiryLocktime: expiryLocktime,
        posted: posted ?? this.posted,
        createdMs: createdMs,
        pegged: pegged,
        advertiseAs: advertiseAs,
      );
}

/// Persistent store of placed covenant orders (recorded before the post — see [PlacedCovenant]).
class PlacedOrders {
  static const _key = 'ambra.dex.placed';
  static const _storage = FlutterSecureStorage();

  static Future<List<PlacedCovenant>> list() async {
    final s = await _storage.read(key: _key);
    if (s == null || s.isEmpty) return [];
    try {
      final arr = jsonDecode(s) as List<dynamic>;
      return arr.map((e) => PlacedCovenant.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<PlacedCovenant> items) =>
      _storage.write(key: _key, value: jsonEncode(items.map((e) => e.toJson()).toList()));

  /// Add or replace a record by its funding-outpoint key (newest first).
  static Future<void> put(PlacedCovenant rec) async {
    final items = await list();
    items.removeWhere((e) => e.key == rec.key);
    items.insert(0, rec);
    await _save(items);
  }

  static Future<void> remove(String key) async {
    final items = await list();
    items.removeWhere((e) => e.key == key);
    await _save(items);
  }
}
