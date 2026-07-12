import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/data/node_config.dart';
import 'src/data/price_service.dart';
import 'src/data/registry_service.dart';
import 'src/data/wallet_repository.dart';
import 'src/rust/api.dart' as core;
import 'src/rust/frb_generated.dart';
import 'src/screens/lock_screen.dart';
import 'src/screens/onboarding.dart';
import 'src/screens/shell.dart';
import 'src/screens/sign_screen.dart';
import 'src/theme/theme.dart';
import 'src/widgets/restricted_asset_detail.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  // Persist wallet state to a writable dir so cold starts resume scanned state
  // from disk instead of a full re-scan. Best-effort: an in-memory wallet still
  // works if this fails.
  try {
    final dir = await getApplicationSupportDirectory();
    core.setDataDir(path: dir.path);
  } catch (_) {}
  await NodeConfig.instance.load(); // apply a saved custom node before any fetch
  await WalletRepository.instance.load();
  await PriceService.instance.load();
  await RegistryService.instance.load(); // asset labels (cached instantly, refreshed in bg)
  runApp(const AmbraApp());
}

class AmbraApp extends StatefulWidget {
  const AmbraApp({super.key});
  @override
  State<AmbraApp> createState() => _AmbraAppState();
}

class _AmbraAppState extends State<AmbraApp> with WidgetsBindingObserver {
  // Owns the root Navigator so the lock can dismiss any pushed sheet/route before
  // it engages (see didChangeAppLifecycleState).
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  // OpenAMP deep links (ambra://oamp-sign / ambra://oamp-send, or the web
  // wallet's #oamp-sign / #oamp-send fragment form). A link that arrives before
  // a wallet is unlocked is deferred until the shell is up (never routed to a
  // locked/empty app).
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  Uri? _pendingUri;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WalletRepository.instance.addListener(_onRepoChanged);
    _initDeepLinks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WalletRepository.instance.removeListener(_onRepoChanged);
    _linkSub?.cancel();
    super.dispose();
  }

  Future<void> _initDeepLinks() async {
    _linkSub = _appLinks.uriLinkStream.listen(_onUri, onError: (_) {});
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _onUri(initial);
    } catch (_) {/* no launch link */}
  }

  void _onRepoChanged() {
    // Flush a deferred deep link once the wallet is unlocked and the shell is up.
    final repo = WalletRepository.instance;
    if (_pendingUri != null && repo.hasWallet && repo.unlocked) {
      final u = _pendingUri!;
      _pendingUri = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _route(u));
    }
  }

  void _onUri(Uri uri) {
    final repo = WalletRepository.instance;
    if (!(repo.hasWallet && repo.unlocked)) {
      _pendingUri = uri; // handled by _onRepoChanged once the shell is up
      return;
    }
    _route(uri);
  }

  /// Route an OpenAMP deep link. Supports the custom scheme
  /// (`ambra://oamp-sign?...`, `ambra://oamp-send?...`) and the web wallet's
  /// hash-fragment form (`...#oamp-sign?...`). Anything else is ignored.
  void _route(Uri uri) {
    final nav = _navKey.currentState;
    if (nav == null) return;
    final parsed = _parseOampRoute(uri);
    if (parsed == null) return;
    final (route, params) = parsed;
    if (route == 'oamp-sign') {
      Map<String, dynamic>? payload;
      final p = params['payload'];
      if (p != null && p.isNotEmpty) {
        try {
          final j = jsonDecode(_b64urlDecodeUtf8(p));
          if (j is Map<String, dynamic>) payload = j;
        } catch (_) {/* malformed payload — open a blank card */}
      }
      final mode = (payload?['mode'] == 'document') ? SignMode.document : SignMode.challenge;
      nav.push(MaterialPageRoute(
        builder: (_) => SignScreen(
          initialMode: mode,
          initialChallenge: (mode == SignMode.challenge && payload?['challenge'] is String)
              ? payload!['challenge'] as String
              : '',
          initialDocHash: (mode == SignMode.document && payload?['doc_hash'] is String)
              ? payload!['doc_hash'] as String
              : '',
          callback: payload?['callback'] is String ? payload!['callback'] as String : null,
          label: payload?['label'] is String ? payload!['label'] as String : null,
        ),
      ));
    } else if (route == 'oamp-send') {
      final asset = (params['asset'] ?? '').trim().toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(asset)) return;
      final to = (params['to'] ?? '').trim();
      final atoms = (params['atoms'] ?? '').trim();
      nav.push(MaterialPageRoute(
        builder: (_) => RestrictedSendScreen(
          assetId: asset,
          toAid: to.isEmpty ? null : to,
          atomsStr: RegExp(r'^\d+$').hasMatch(atoms) ? atoms : null,
        ),
      ));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-lock when the app leaves the foreground, so returning to it requires
    // auth again (no-op unless the opt-in lock is enabled). Only on `paused`
    // (backgrounded), not `inactive`, so the biometric prompt itself never locks.
    if (state == AppLifecycleState.paused) {
      final repo = WalletRepository.instance;
      // Locking only swaps the RootGate's child (Shell -> LockScreen). Any route
      // or modal sheet pushed ABOVE home — e.g. the "Reveal recovery phrase"
      // sheet — would otherwise survive on TOP of the lock screen when the app
      // returns. Pop back to the first route so nothing sensitive outlives the
      // lock. Guarded on the lock actually engaging, so an unlocked session
      // doesn't lose the user's place (mid-send review, etc.) on every switch.
      // TODO(device-verify): background the app with the recovery-phrase sheet
      // open and confirm it's gone (not on top of the lock) after returning.
      if (repo.hasWallet && repo.lockEnabled) {
        _navKey.currentState?.popUntil((r) => r.isFirst);
      }
      repo.lock();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ambra',
      navigatorKey: _navKey,
      debugShowCheckedModeBanner: false,
      theme: ambraTheme(),
      home: const RootGate(),
    );
  }
}

/// Parse an OpenAMP deep link into (route, params). Accepts the custom scheme
/// (`ambra://oamp-sign?...`) where the route is the URI host, and the web
/// wallet's fragment form (`...#oamp-sign?...`) where it is in the fragment.
/// Returns null for any non-OpenAMP link.
(String, Map<String, String>)? _parseOampRoute(Uri uri) {
  if (uri.scheme == 'ambra' && (uri.host == 'oamp-sign' || uri.host == 'oamp-send')) {
    return (uri.host, uri.queryParameters);
  }
  final frag = uri.fragment;
  if (frag.startsWith('oamp-sign') || frag.startsWith('oamp-send')) {
    final qm = frag.indexOf('?');
    final route = qm < 0 ? frag : frag.substring(0, qm);
    final params = qm < 0 ? const <String, String>{} : Uri.splitQueryString(frag.substring(qm + 1));
    return (route, params);
  }
  return null;
}

/// Decode a base64url string (the `#oamp-sign?payload=` JSON) to UTF-8 text.
String _b64urlDecodeUtf8(String s) {
  var t = s.replaceAll('-', '+').replaceAll('_', '/');
  while (t.length % 4 != 0) {
    t += '=';
  }
  return utf8.decode(base64.decode(t));
}

/// Routes between boot, onboarding, lock, and the wallet shell based on the
/// repository's state.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: WalletRepository.instance,
      builder: (context, _) {
        final repo = WalletRepository.instance;
        if (repo.loading) return const _Boot();
        if (!repo.hasWallet) return const WelcomeScreen();
        if (!repo.unlocked) return const LockScreen();
        return const Shell();
      },
    );
  }
}

class _Boot extends StatelessWidget {
  const _Boot();
  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: Colors.transparent,
        body: AmbraBackground(child: Center(child: CircularProgressIndicator(color: AmbraColors.amber))),
      );
}
