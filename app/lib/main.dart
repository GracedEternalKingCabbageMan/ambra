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
import 'src/theme/theme.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
