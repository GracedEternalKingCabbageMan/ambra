import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Owns the non-custodial secret and the app-lock state.
///
/// The mnemonic lives only in platform secure storage (Android Keystore-backed
/// EncryptedSharedPreferences / iOS Keychain). It is read out transiently for
/// derivation/signing and never cached in this object.
class WalletRepository extends ChangeNotifier {
  WalletRepository._();
  static final WalletRepository instance = WalletRepository._();

  static const _kMnemonic = 'ambra.mnemonic';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  final LocalAuthentication _auth = LocalAuthentication();

  bool loading = true;
  bool hasWallet = false;
  bool unlocked = false;

  Future<void> load() async {
    hasWallet = await _storage.containsKey(key: _kMnemonic);
    // A wallet created this session is already unlocked; an existing wallet on
    // cold start must be unlocked.
    unlocked = !hasWallet;
    loading = false;
    notifyListeners();
  }

  /// Read the mnemonic transiently (for derivation/signing). Never cached.
  Future<String?> readMnemonic() => _storage.read(key: _kMnemonic);

  Future<void> persistNewWallet(String mnemonic) async {
    await _storage.write(key: _kMnemonic, value: mnemonic.trim());
    hasWallet = true;
    unlocked = true;
    notifyListeners();
  }

  Future<void> removeWallet() async {
    await _storage.delete(key: _kMnemonic);
    hasWallet = false;
    unlocked = false;
    notifyListeners();
  }

  void lock() {
    if (hasWallet) {
      unlocked = false;
      notifyListeners();
    }
  }

  /// Unlock with device biometrics/passcode. Degrades gracefully on devices
  /// without an enrolled credential (e.g. a bare emulator) so the testnet
  /// preview is never un-openable.
  Future<bool> authenticate({String reason = 'Unlock Ambra'}) async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return _grant();
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
      );
      if (ok) _grant();
      return ok;
    } catch (_) {
      return _grant();
    }
  }

  /// Authorize a money-moving action. Unlike [authenticate], this FAILS CLOSED:
  /// any auth error or user denial returns false — a payment must never be
  /// signed without real authentication. Does not touch the app-lock state.
  /// (A device with no enrolled credential at all — e.g. a bare emulator — is
  /// allowed through, as this is a testnet build.)
  Future<bool> requirePaymentAuth() async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return true;
      return await _auth.authenticate(
        localizedReason: 'Authorize this payment',
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
      );
    } catch (_) {
      return false;
    }
  }

  bool _grant() {
    unlocked = true;
    notifyListeners();
    return true;
  }
}
