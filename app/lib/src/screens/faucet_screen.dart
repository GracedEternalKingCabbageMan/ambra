import 'package:flutter/material.dart';

import '../rust/api.dart' as core;
import '../data/api_client.dart';
import '../data/config.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

class FaucetScreen extends StatefulWidget {
  const FaucetScreen({super.key});
  @override
  State<FaucetScreen> createState() => _FaucetScreenState();
}

class _FaucetScreenState extends State<FaucetScreen> {
  String? _address;
  bool _busy = false;
  bool _error = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _loadAddress();
  }

  Future<void> _loadAddress() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    final info = await core.receiveAddressAt(mnemonic: m, index: 0, confidential: false);
    if (mounted) setState(() => _address = info.address);
  }

  Future<void> _request(String asset) async {
    final addr = _address;
    if (addr == null || _busy) return;
    setState(() {
      _busy = true;
      _error = false;
      _status = 'Requesting from the faucet…';
    });
    try {
      final r = await ApiClient.faucet(addr, asset: asset);
      if (mounted) {
        setState(() => _status = 'Sent ${r.amount} ${r.asset}. It will appear on Balance once it confirms (~30s).');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _status = 'Faucet error: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Testnet faucet', style: AmbraText.title),
        iconTheme: const IconThemeData(color: AmbraColors.dim),
      ),
      body: AmbraBackground(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Get free testnet coins sent to your wallet address.', style: AmbraText.muted),
          const SizedBox(height: 18),
          AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel('Funding address'),
              const SizedBox(height: 10),
              _address == null
                  ? const Center(
                      child: Padding(
                          padding: EdgeInsets.all(8),
                          child: CircularProgressIndicator(color: AmbraColors.amber)))
                  : SelectableText(_address!, style: AmbraText.mono),
            ]),
          ),
          const SizedBox(height: 20),
          const SectionLabel('Request'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final a in SeqAssets.faucetAssets)
                _FaucetButton(
                  label: a.isEmpty ? 'tSEQ' : a,
                  primary: a.isEmpty,
                  onTap: (_busy || _address == null) ? null : () => _request(a),
                ),
            ],
          ),
          const SizedBox(height: 20),
          AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: const [
              SectionLabel('Bitcoin (testnet4)'),
              SizedBox(height: 10),
              Text(
                'The buttons above fund Sequentia assets only. Your address also receives '
                'Bitcoin on testnet4 (one address, both chains). To get testnet Bitcoin, send '
                'it from a public Bitcoin testnet4 faucet to the funding address shown above.',
                style: AmbraText.sub,
              ),
            ]),
          ),
          const SizedBox(height: 20),
          if (_status != null)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_busy) ...[
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AmbraColors.amber)),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(_status!,
                    style: TextStyle(color: _error ? AmbraColors.red : AmbraColors.green, fontSize: 13, height: 1.4)),
              ),
            ]),
        ]),
      ),
    );
  }
}

class _FaucetButton extends StatelessWidget {
  const _FaucetButton({required this.label, required this.onTap, this.primary = false});
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(AmbraRadii.control),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            gradient: primary ? AmbraColors.goldGradient : null,
            color: primary ? null : AmbraColors.buttonSurface,
            border: primary ? null : Border.all(color: AmbraColors.line),
            borderRadius: BorderRadius.circular(AmbraRadii.control),
          ),
          child: Text(label,
              style: TextStyle(
                  color: primary ? AmbraColors.onGold : AmbraColors.txt, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}
