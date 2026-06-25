import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../rust/api.dart' as core;
import 'config.dart';

/// Which backend node Ambra talks to, plus optional HTTP-auth credentials for a
/// private node. The default is the open public Sequentia testnet node. The
/// choice and credentials are persisted (credentials in secure storage) and
/// applied to [Backend] and the core before the first sync/price fetch.
class NodeConfig extends ChangeNotifier {
  NodeConfig._();
  static final NodeConfig instance = NodeConfig._();

  static const _key = 'ambra.node.origin';
  static const _kToken = 'ambra.node.token';
  static const _kUser = 'ambra.node.user';
  static const _kPass = 'ambra.node.pass';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  String _token = '';
  String _user = '';
  String _pass = '';

  String get origin => Backend.origin;
  String get defaultOrigin => Backend.defaultOrigin;
  bool get isDefault => Backend.isDefault;
  String get token => _token;
  String get user => _user;
  String get pass => _pass;

  /// The `Authorization` header value for the given credentials, or null. A
  /// non-empty token wins (bearer); otherwise a non-empty username is basic-auth.
  static String? authHeaderFor(String token, String user, String pass) {
    if (token.trim().isNotEmpty) return 'Bearer ${token.trim()}';
    if (user.trim().isNotEmpty) {
      return 'Basic ${base64Encode(utf8.encode('${user.trim()}:$pass'))}';
    }
    return null;
  }

  void _applyAuth() {
    final h = authHeaderFor(_token, _user, _pass);
    Backend.authHeader = h;
    core.setAuthHeader(value: h ?? '');
  }

  /// Apply any saved custom node and credentials at startup (call before
  /// PriceService.load()).
  Future<void> load() async {
    final saved = await _storage.read(key: _key);
    if (saved != null && saved.trim().isNotEmpty) Backend.origin = saved;
    _token = (await _storage.read(key: _kToken)) ?? '';
    _user = (await _storage.read(key: _kUser)) ?? '';
    _pass = (await _storage.read(key: _kPass)) ?? '';
    _applyAuth();
  }

  Future<void> setOrigin(String origin, {String token = '', String user = '', String pass = ''}) async {
    Backend.origin = origin; // normalized by the setter
    _token = token;
    _user = user;
    _pass = pass;
    await _storage.write(key: _key, value: Backend.origin);
    await _writeOrDelete(_kToken, token);
    await _writeOrDelete(_kUser, user);
    await _writeOrDelete(_kPass, pass);
    _applyAuth();
    notifyListeners();
  }

  Future<void> resetToDefault() async {
    Backend.origin = Backend.defaultOrigin;
    _token = '';
    _user = '';
    _pass = '';
    await _storage.delete(key: _key);
    await _storage.delete(key: _kToken);
    await _storage.delete(key: _kUser);
    await _storage.delete(key: _kPass);
    _applyAuth();
    notifyListeners();
  }

  Future<void> _writeOrDelete(String key, String value) async {
    if (value.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: value);
    }
  }
}
