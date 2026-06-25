import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'config.dart';

/// Which backend node Ambra talks to. Defaults to the public Sequentia testnet
/// node; users can switch to their own. The choice is persisted across launches
/// and applied to [Backend] before the first sync/price fetch.
class NodeConfig extends ChangeNotifier {
  NodeConfig._();
  static final NodeConfig instance = NodeConfig._();

  static const _key = 'ambra.node.origin';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  String get origin => Backend.origin;
  String get defaultOrigin => Backend.defaultOrigin;
  bool get isDefault => Backend.isDefault;

  /// Apply any saved custom node at startup (call before PriceService.load()).
  Future<void> load() async {
    final saved = await _storage.read(key: _key);
    if (saved != null && saved.trim().isNotEmpty) Backend.origin = saved;
  }

  Future<void> setOrigin(String origin) async {
    Backend.origin = origin; // normalized by the setter
    await _storage.write(key: _key, value: Backend.origin);
    notifyListeners();
  }

  Future<void> resetToDefault() async {
    Backend.origin = Backend.defaultOrigin;
    await _storage.delete(key: _key);
    notifyListeners();
  }
}
