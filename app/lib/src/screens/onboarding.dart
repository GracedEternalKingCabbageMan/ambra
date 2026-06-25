import 'dart:math';

import 'package:flutter/material.dart';

import '../rust/api.dart' as core;
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

const _wordmark = TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.7, color: AmbraColors.txt);

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbraBackground(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 28),
                      const BrandMark(size: 60),
                      const SizedBox(height: 22),
                      const Text('Ambra', style: _wordmark),
                      const SizedBox(height: 6),
                      Row(children: [
                        const Text('Sequentia wallet', style: AmbraText.muted),
                        const SizedBox(width: 8),
                        _Pill('testnet'),
                      ]),
                      const SizedBox(height: 14),
                      const Text(
                        'A self-custodial wallet for Sequentia: Proof-of-Stake, '
                        'Bitcoin-anchored, with fees payable in any asset.',
                        style: AmbraText.muted,
                      ),
                      const Spacer(),
                      const WarnCallout(
                        'Testnet. Your recovery phrase is stored on this device, '
                        'protected by your device lock. For real funds, use a hardware wallet.',
                      ),
                      const SizedBox(height: 22),
                      const Center(child: SequentiaWordmark()),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),
              BottomActionBar(children: [
                PrimaryButton(
                  label: 'Create new wallet',
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreateScreen())),
                ),
                const SizedBox(height: 12),
                SecondaryButton(
                  label: 'Import a recovery phrase',
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ImportScreen())),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: AmbraColors.line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: const TextStyle(color: AmbraColors.amber2, fontSize: 11, letterSpacing: 0.5)),
      );
}

class CreateScreen extends StatefulWidget {
  const CreateScreen({super.key});
  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

class _CreateScreenState extends State<CreateScreen> {
  List<String>? _words;
  String? _error;

  @override
  void initState() {
    super.initState();
    _gen();
  }

  Future<void> _gen() async {
    try {
      final phrase = await core.generateMnemonic();
      setState(() => _words = phrase.split(RegExp(r'\s+')));
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final words = _words;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _bar(context, 'Recovery phrase'),
      body: AmbraBackground(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: words == null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 80),
                        child: Center(
                          child: _error == null
                              ? const CircularProgressIndicator(color: AmbraColors.amber)
                              : Text('$_error', style: const TextStyle(color: AmbraColors.red)),
                        ),
                      )
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Write these 12 words down in order and keep them offline.',
                            style: AmbraText.muted),
                        const SizedBox(height: 18),
                        AmbraCard(child: MnemonicWordGrid(words: words)),
                        const SizedBox(height: 16),
                        const WarnCallout(
                            'Anyone with these 12 words controls the wallet. Never share them or store them online.'),
                      ]),
              ),
            ),
            if (words != null)
              BottomActionBar(children: [
                PrimaryButton(
                  label: "I've written it down",
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => VerifyScreen(words: words))),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}

class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key, required this.words});
  final List<String> words;
  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  late final List<int> _targets;
  late final List<List<String>> _choices;
  int _step = 0;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final rng = Random();
    final idx = List<int>.generate(widget.words.length, (i) => i)..shuffle(rng);
    _targets = idx.take(3).toList()..sort();
    _choices = _targets.map((t) {
      final correct = widget.words[t];
      final pool = widget.words.where((w) => w != correct).toList()..shuffle(rng);
      final opts = <String>{correct, ...pool.take(5)}.toList()..shuffle(rng);
      return opts;
    }).toList();
  }

  Future<void> _pick(String word) async {
    if (_busy) return;
    final target = _targets[_step];
    if (word != widget.words[target]) {
      setState(() => _error = 'That is not word #${target + 1}. Try again.');
      return;
    }
    if (_step < 2) {
      setState(() {
        _step++;
        _error = null;
      });
      return;
    }
    // All three correct -> persist + activate.
    setState(() => _busy = true);
    await WalletRepository.instance.persistNewWallet(widget.words.join(' '));
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final target = _targets[_step];
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _bar(context, 'Confirm backup'),
      body: AmbraBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Step ${_step + 1} of 3', style: AmbraText.label),
              const SizedBox(height: 10),
              Text('Tap word #${target + 1}', style: AmbraText.h1),
              const SizedBox(height: 24),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _choices[_step]
                    .map((w) => _ChoiceChip(label: w, onTap: _busy ? null : () => _pick(w)))
                    .toList(),
              ),
              const SizedBox(height: 16),
              if (_error != null) Text(_error!, style: const TextStyle(color: AmbraColors.red)),
              const Spacer(),
              if (_busy) const Center(child: CircularProgressIndicator(color: AmbraColors.amber)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AmbraRadii.chip),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AmbraColors.buttonSurface,
          border: Border.all(color: AmbraColors.line),
          borderRadius: BorderRadius.circular(AmbraRadii.chip),
        ),
        child: Text(label, style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});
  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final phrase = _ctrl.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await core.validateMnemonic(mnemonic: phrase);
      await WalletRepository.instance.persistNewWallet(phrase);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Invalid phrase: ${_pretty(e)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _bar(context, 'Import wallet'),
      body: AmbraBackground(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Enter your 12- or 24-word recovery phrase.', style: AmbraText.muted),
                  const SizedBox(height: 18),
                  AmbraField(
                    label: 'Recovery phrase',
                    controller: _ctrl,
                    hint: 'abandon abandon abandon …',
                    maxLines: 4,
                  ),
                  const SizedBox(height: 12),
                  if (_error != null) Text(_error!, style: const TextStyle(color: AmbraColors.red)),
                ]),
              ),
            ),
            BottomActionBar(children: [
              PrimaryButton(label: 'Import', busy: _busy, onPressed: _busy ? null : _import),
            ]),
          ],
        ),
      ),
    );
  }
}

PreferredSizeWidget _bar(BuildContext context, String title) => AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      title: Text(title, style: AmbraText.title),
      iconTheme: const IconThemeData(color: AmbraColors.dim),
    );

String _pretty(Object e) {
  final s = e.toString();
  return s.length > 160 ? '${s.substring(0, 160)}…' : s;
}
