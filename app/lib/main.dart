import 'package:flutter/material.dart';

import 'src/rust/api.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loads libambra_core.so (from jniLibs on Android) and initializes the bridge.
  await RustLib.init();
  runApp(const AmbraApp());
}

class AmbraApp extends StatelessWidget {
  const AmbraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ambra',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1F6FEB),
          brightness: Brightness.dark,
        ),
      ),
      home: const ReceivePreviewPage(),
    );
  }
}

/// First "the core is alive" screen: generate a fresh wallet in the Rust core
/// and show its Sequentia receive address. This is a Milestone-2 preview, not
/// the real wallet flow (no key persistence yet).
class ReceivePreviewPage extends StatefulWidget {
  const ReceivePreviewPage({super.key});

  @override
  State<ReceivePreviewPage> createState() => _ReceivePreviewPageState();
}

class _ReceivePreviewPageState extends State<ReceivePreviewPage> {
  late Future<_Wallet> _wallet;

  @override
  void initState() {
    super.initState();
    _wallet = _generate();
  }

  Future<_Wallet> _generate() async {
    final mnemonic = await generateMnemonic();
    final address = await receiveAddress(mnemonic: mnemonic);
    return _Wallet(mnemonic: mnemonic, address: address);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ambra'),
        centerTitle: true,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: FutureBuilder<_Wallet>(
              future: _wallet,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Text('Core error: ${snap.error}',
                      style: TextStyle(color: theme.colorScheme.error));
                }
                final w = snap.data!;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Sequentia · ${networkName()}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelLarge
                            ?.copyWith(color: theme.colorScheme.primary)),
                    const SizedBox(height: 32),
                    Text('Your receive address',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(
                          w.address,
                          style: theme.textTheme.bodyLarge?.copyWith(
                              fontFamily: 'monospace', height: 1.4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Non-confidential by default — the same address also '
                      'receives Bitcoin (testnet4).',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => setState(() => _wallet = _generate()),
        icon: const Icon(Icons.refresh),
        label: const Text('New wallet'),
      ),
    );
  }
}

class _Wallet {
  const _Wallet({required this.mnemonic, required this.address});
  final String mnemonic;
  final String address;
}
