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
  static const _kLockEnabled = 'ambra.lock.enabled';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  final LocalAuthentication _auth = LocalAuthentication();

  bool loading = true;
  bool hasWallet = false;
  bool unlocked = false;
  bool lockEnabled = false; // opt-in app lock (off by default)

  Future<void> load() async {
    hasWallet = await _storage.containsKey(key: _kMnemonic);
    lockEnabled = (await _storage.read(key: _kLockEnabled)) == '1';
    // Locked on cold start only if a wallet exists AND the user opted into the
    // app lock; otherwise the wallet opens directly.
    unlocked = !(hasWallet && lockEnabled);
    loading = false;
    notifyListeners();
  }

  /// Enable/disable the app lock. Disabling opens the wallet immediately.
  Future<void> setLockEnabled(bool on) async {
    lockEnabled = on;
    await _storage.write(key: _kLockEnabled, value: on ? '1' : '0');
    if (!on) unlocked = true;
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
    await _storage.delete(key: _kLockEnabled);
    hasWallet = false;
    lockEnabled = false;
    unlocked = false;
    notifyListeners();
  }

  void lock() {
    if (hasWallet && lockEnabled) {
      unlocked = false;
      notifyListeners();
    }
  }

  /// Unlock with device biometrics/passcode. FAILS CLOSED: a cancelled prompt or
  /// an auth error leaves the wallet locked (the user retries) — the lock must
  /// never open itself. A device with NO screen lock at all has nothing to
  /// authenticate against, so it opens (keeps the testnet preview usable on a
  /// bare emulator); real protection requires the user to set a device lock.
  Future<bool> authenticate({String reason = 'Unlock Ambra'}) async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return _grant(); // no device credential to enforce
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
      );
      return ok ? _grant() : false; // cancelled/failed → stay locked
    } catch (_) {
      return false; // auth error → stay locked, never fail open
    }
  }

  /// Whether the device can enforce the app lock (has a biometric/PIN/pattern).
  Future<bool> canEnforceLock() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
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
