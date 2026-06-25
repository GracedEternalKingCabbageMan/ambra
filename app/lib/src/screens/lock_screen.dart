import 'package:flutter/material.dart';

import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _busy = false;

  // No auto-unlock on appear: the lock must hold until the user explicitly
  // authenticates (otherwise "Lock now" would immediately bounce back).
  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    await WalletRepository.instance.authenticate();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbraBackground(
        child: SafeArea(
          child: Column(children: [
            Expanded(
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const BrandMark(size: 64),
                  const SizedBox(height: 24),
                  const Text('Ambra is locked', style: AmbraText.h1),
                  const SizedBox(height: 8),
                  const Text('Unlock with your device credentials.', style: AmbraText.muted),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: 220,
                    child: PrimaryButton(label: 'Unlock', busy: _busy, icon: Icons.lock_open, onPressed: _unlock),
                  ),
                ]),
              ),
            ),
            const Padding(padding: EdgeInsets.only(bottom: 24), child: SequentiaWordmark()),
          ]),
        ),
      ),
    );
  }
}
