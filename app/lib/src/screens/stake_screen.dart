import 'package:flutter/material.dart';

import '../rust/api.dart' as core;
import '../data/config.dart';
import '../data/format.dart';
import '../data/tx_flow.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Sequentia staking constants (mirrors the chain): 40,000 tSEQ minimum;
/// posunbonding = 43200 (time-based CSV ≈ 15 days).
final BigInt _minStakeAtoms = BigInt.from(40000) * BigInt.from(100000000);
const int _unbondCsv = 43200;

class StakeScreen extends StatefulWidget {
  const StakeScreen({super.key});
  @override
  State<StakeScreen> createState() => _StakeScreenState();
}

class _StakeScreenState extends State<StakeScreen> {
  final _amount = TextEditingController();
  String? _stakerKey;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _loadKey() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    try {
      final k = await core.stakerPublicKey(mnemonic: m);
      if (mounted) setState(() => _stakerKey = k);
    } catch (_) {}
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _stake() async {
    final atoms = parseAtoms(_amount.text, 8);
    if (atoms == null || atoms < _minStakeAtoms) return _snack('Minimum stake is 40,000 tSEQ');
    final key = _stakerKey;
    if (key == null) return _snack('Staker key not ready — try again');
    setState(() => _busy = true);
    try {
      final txid = await authorizeBuildBroadcast((m) => core.buildStakeTx(
            mnemonic: m,
            esploraUrl: Backend.esplora,
            stakerPubkey: key,
            csv: _unbondCsv,
            satoshi: atoms,
          ));
      if (mounted) {
        _amount.clear();
        _snack('Staked — ${txid.substring(0, 16)}…');
      }
    } catch (e) {
      if (mounted) _snack('Stake failed: ${_short(e)}');
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
        title: const Text('Stake', style: AmbraText.title),
        iconTheme: const IconThemeData(color: AmbraColors.dim),
      ),
      body: AmbraBackground(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.all(20), children: [
              const Text(
                'Bond tSEQ to participate in block production. Stake weight = the amount '
                '(no benefit to a longer lock). It uses the network minimum unbonding period.',
                style: AmbraText.muted,
              ),
              const SizedBox(height: 18),
              AmbraField(label: 'Amount (tSEQ)', controller: _amount, hint: '40000'),
              const SizedBox(height: 18),
              AmbraCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(children: [
                  _Kv('Minimum stake', '40,000 tSEQ'),
                  _Kv('Unbonding', '~15 days (network minimum)'),
                  _Kv('Your staker key', _stakerKey == null ? '…' : '${_stakerKey!.substring(0, 16)}…'),
                ]),
              ),
              const SizedBox(height: 14),
              const Text(
                'Staked tSEQ is locked: it keeps earning weight until you spend it, and can '
                'only be withdrawn after the ~15-day timelock. Unbonding lands in a later build.',
                style: AmbraText.sub,
              ),
            ]),
          ),
          BottomActionBar(children: [
            PrimaryButton(label: 'Review & stake', busy: _busy, icon: Icons.lock_outline, onPressed: _busy ? null : _stake),
          ]),
        ]),
      ),
    );
  }
}

class _Kv extends StatelessWidget {
  const _Kv(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          SizedBox(width: 130, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: AmbraText.mono)),
        ]),
      );
}

String _short(Object e) {
  final s = e.toString().replaceFirst('Exception: ', '');
  return s.length > 140 ? '${s.substring(0, 140)}…' : s;
}
