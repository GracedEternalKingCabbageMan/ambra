import 'package:flutter/material.dart';

import 'src/data/price_service.dart';
import 'src/data/wallet_repository.dart';
import 'src/rust/frb_generated.dart';
import 'src/screens/lock_screen.dart';
import 'src/screens/onboarding.dart';
import 'src/screens/shell.dart';
import 'src/theme/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await WalletRepository.instance.load();
  await PriceService.instance.load();
  runApp(const AmbraApp());
}

class AmbraApp extends StatelessWidget {
  const AmbraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ambra',
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
