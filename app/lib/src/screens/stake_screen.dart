import 'package:flutter/material.dart';

import '../rust/api.dart' as core;
import '../data/config.dart';
import '../data/format.dart';
import '../data/tx_flow.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Sequentia staking constants (mirror the chain): 40,000 tSEQ minimum; the
/// stake CSV is TIME-based — SEQUENCE_LOCKTIME_TYPE_FLAG (1<<22) OR
/// ceil(posunbonding * posslotinterval / 512) = ceil(43200*30/512) = 2532
/// (≈15 days). A bare height count (43200) would be parsed height-based by the
/// node and lock by block-count, not wall-clock.
final BigInt _minStakeAtoms = BigInt.from(40000) * BigInt.from(100000000);
const int _unbondCsv = (1 << 22) | 2532;

class StakeScreen extends StatefulWidget {
  const StakeScreen({super.key});
  @override
  State<StakeScreen> createState() => _StakeScreenState();
}

class _StakeScreenState extends State<StakeScreen> {
  final _amount = TextEditingController();
  String? _stakerKey;
  BigInt _tseq = BigInt.zero;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    try {
      final key = await core.stakerPublicKey(mnemonic: m);
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      BigInt tseq = BigInt.zero;
      for (final b in s.balances) {
        if (b.assetId == SeqAssets.policy) tseq = BigInt.tryParse(b.atoms) ?? BigInt.zero;
      }
      if (mounted) {
        setState(() {
          _stakerKey = key;
          _tseq = tseq;
        });
      }
    } catch (_) {}
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _stake() async {
    final atoms = parseAtoms(_amount.text, 8);
    if (atoms == null || atoms < _minStakeAtoms) return _snack('Minimum stake is 40,000 tSEQ');
    if (atoms >= (BigInt.one << 64)) return _snack('Amount is too large');
    final key = _stakerKey;
    if (key == null) return _snack('Staker key not ready; try again');
    if (_tseq <= atoms) {
      return _snack('Not enough tSEQ. You need the staked amount plus a network fee.');
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: const Text('Confirm stake', style: AmbraText.title),
        content: Text(
          'Stake ${formatAtoms(atoms.toString(), 8)} tSEQ to staker key '
          '${key.substring(0, 16)}…\n\n'
          'Staked tSEQ LEAVES your spendable balance and is locked for ~15 days. '
          'Unbonding (withdrawing it) is not available yet.',
          style: AmbraText.muted,
        ),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stake', style: TextStyle(color: AmbraColors.amber2, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

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
        _snack('Staked · ${txid.substring(0, 16)}…');
        _load();
      }
    } catch (e) {
      if (mounted) _snack('Stake failed: ${friendlyError(e)}');
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
                'Bond Sequence (tSEQ) to participate in block production. Stake weight = the amount '
                '(no benefit to a longer lock). It uses the network minimum unbonding period.',
                style: AmbraText.muted,
              ),
              const SizedBox(height: 18),
              AmbraField(label: 'Amount (tSEQ)', controller: _amount, hint: '40000'),
              const SizedBox(height: 18),
              AmbraCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(children: [
                  _Kv('Spendable tSEQ', formatAtoms(_tseq.toString(), 8)),
                  _Kv('Minimum stake', '40,000 tSEQ'),
                  _Kv('Unbonding', '~15 days (network minimum)'),
                  _Kv('Your staker key', _stakerKey == null ? '…' : '${_stakerKey!.substring(0, 16)}…'),
                ]),
              ),
              const SizedBox(height: 14),
              const WarnCallout(
                'Staked tSEQ leaves your visible balance once it confirms and is locked for '
                '~15 days. Unbonding is not available yet; only stake what you can lock.',
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
