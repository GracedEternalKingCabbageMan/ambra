import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'config.dart';

/// Fetches and caches the public asset registry (ticker / precision / name per
/// asset id) and merges it into [SeqAssets], so assets outside the built-in demo
/// set resolve their real label instead of a hex-derived placeholder with an
/// assumed precision. Cached to disk so the labels are present instantly on the
/// next launch, then refreshed from the network in the background.
class RegistryService extends ChangeNotifier {
  RegistryService._();
  static final RegistryService instance = RegistryService._();

  static const _kCache = 'ambra.cache.registry';

  Future<void> load() async {
    await _applyCached(); // instant, from disk
    unawaited(refresh()); // background: never delays boot on a slow network
  }

  Future<void> _applyCached() async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_kCache);
      if (s == null) return;
      final j = jsonDecode(s) as Map<String, dynamic>;
      final m = <String, AssetLabel>{};
      j.forEach((id, v) {
        final o = v as Map<String, dynamic>;
        m[id] = AssetLabel(o['t'] as String, o['p'] as int, subtitle: o['n'] as String?);
      });
      if (m.isNotEmpty) {
        SeqAssets.mergeRegistry(m);
        notifyListeners();
      }
    } catch (_) {/* fall back to built-in labels */}
  }

  Future<void> refresh() async {
    try {
      final m = await ApiClient.registry();
      if (m.isEmpty) return;
      SeqAssets.mergeRegistry(m);
      notifyListeners();
      final p = await SharedPreferences.getInstance();
      final enc = <String, dynamic>{};
      m.forEach((id, l) => enc[id] = {'t': l.ticker, 'p': l.precision, 'n': l.subtitle});
      await p.setString(_kCache, jsonEncode(enc));
    } catch (_) {/* keep the cached / built-in labels */}
  }
}
