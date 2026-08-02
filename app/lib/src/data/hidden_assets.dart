import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'swap_route.dart' show kBtcSentinel;

/// The per-wallet set of HIDDEN assets (Balance-tab Hide control).
///
/// Hiding is VISUAL DECLUTTERING ONLY: a hidden asset keeps its full standing
/// everywhere that matters — it still counts toward the reference-currency
/// headline total, still trades, and is still FOUND by search or a pasted id in
/// the asset sheets. It just leaves the default balance list + default picker
/// rows. Native BTC (the parent-chain first-class asset) can never be hidden.
///
/// Persisted in SharedPreferences (Ambra's non-secret local-state idiom, like
/// [WalletCache]) but keyed PER WALLET by a mnemonic fingerprint — Ambra holds
/// one wallet at a time, yet remove-and-recover of a DIFFERENT wallet must not
/// inherit the old wallet's hidden set (mirrors the web wallet's
/// per-wallet-fingerprint `swk.hidden.<tag>` key). The fingerprint is a
/// truncated SHA-256 of the mnemonic: a stable, non-reversible tag, never key
/// material, and never sent anywhere.
class HiddenAssets extends ChangeNotifier {
  HiddenAssets();
  static final HiddenAssets instance = HiddenAssets();

  static const _prefix = 'ambra.hidden.';

  String? _fp; // active wallet fingerprint; null until loadFor ran
  Set<String> _set = <String>{};

  /// Stable per-wallet tag for the storage key (truncated SHA-256, hex).
  static String fingerprintOf(String mnemonic) =>
      sha256.convert(utf8.encode(mnemonic.trim())).toString().substring(0, 16);

  /// Load (or switch to) the hidden set for [mnemonic]'s wallet. Cheap when the
  /// wallet hasn't changed; call it wherever the mnemonic is already in hand
  /// (Balance refresh, swap-composer load).
  Future<void> loadFor(String mnemonic) async {
    final fp = fingerprintOf(mnemonic);
    if (fp == _fp) return;
    final p = await SharedPreferences.getInstance();
    Set<String> s;
    try {
      final raw = p.getString(_prefix + fp);
      s = raw == null ? <String>{} : {for (final e in jsonDecode(raw) as List) '$e'};
    } catch (_) {
      s = <String>{};
    }
    _fp = fp;
    _set = s;
    notifyListeners();
  }

  /// The current wallet's hidden asset ids (empty until [loadFor] ran).
  Set<String> get hidden => Set.unmodifiable(_set);

  /// Whether [hex] is hidden. BTC is never hidden, whatever storage says.
  bool isHidden(String hex) => hex != kBtcSentinel && _set.contains(hex);

  /// Hide/unhide [hex] and persist. REFUSES native BTC (the parent-chain asset
  /// is always visible) and is a no-op before [loadFor] (no wallet, nothing to
  /// key the set by).
  Future<void> setHidden(String hex, bool on) async {
    if (hex.isEmpty || hex == kBtcSentinel) return;
    final fp = _fp;
    if (fp == null) return;
    final changed = on ? _set.add(hex) : _set.remove(hex);
    if (!changed) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefix + fp, jsonEncode(_set.toList()));
    } catch (_) {/* best-effort persistence; the in-memory set still applies */}
    notifyListeners();
  }
}
