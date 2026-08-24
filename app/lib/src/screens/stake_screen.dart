import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/reward_convert.dart';
import '../rust/api/rewards.dart' as rewards_api;
import 'package:http/http.dart' as http;

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

  // Staking rewards, and what the standing instruction would do with them.
  List<Map<String, dynamic>> _rewardTotals = <Map<String, dynamic>>[];
  List<RewardPassRow> _rewardRows = <RewardPassRow>[];

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

  /// What staking has paid, and a DRY RUN of what would be converted.
  ///
  /// Dry, always, on a render path: a cross-chain conversion waits on Bitcoin
  /// confirmations and can run for the better part of an hour, and a screen that
  /// awaited one would simply hang. The real pass runs in the background.
  Future<void> _loadRewards(String mnemonic) async {
    try {
      await RewardConvert.instance.loadFor(mnemonic);
      final txsJson = await rewards_api.walletTxFacts(
          mnemonic: mnemonic, esploraUrl: Backend.esplora);
      final keysJson = await rewards_api.stakingKeyFacts(
          mnemonic: mnemonic, delegated: false);
      final tip = await rewards_api.tipHeight(
          mnemonic: mnemonic, esploraUrl: Backend.esplora);
      // The maturity comes from the kit, never a literal here: Sequentia's is
      // 1,000 blocks, not Bitcoin's 100, because the protection is a wall-clock
      // one and this chain runs at 60 seconds. A wallet that guessed 100 would
      // call a reward spendable 900 blocks early and then build a transaction
      // the chain rejects.
      final rewardsJson = await rewards_api.attributeStakingRewards(
        txsJson: txsJson,
        stakingKeysJson: keysJson,
        tipHeight: tip,
        coinbaseMaturity: await rewards_api.sequentiaCoinbaseMaturity(),
      );
      final rewards = (jsonDecode(rewardsJson) as List).cast<Map<String, dynamic>>();
      final report = await RewardConvert.instance.runPass(
        rewards: rewards,
        quoteFor: (asset, atoms, target) async => null,
        execute: (asset, atoms, target) async => null,
        dryRun: true,
      );
      if (!mounted) return;
      setState(() {
        _rewardTotals = rewardTotals(rewards);
        _rewardRows = report.considered;
      });
    } catch (_) {
      // A wallet that cannot answer yet is not an error worth a banner: the
      // card simply shows nothing until it can.
    }
  }

  Future<void> _load() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) return;
    unawaited(_loadRewards(m));
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
              RewardsCard(
                totals: _rewardTotals,
                rows: _rewardRows,
                onChanged: () async {
                  final m = await WalletRepository.instance.readMnemonic();
                  if (m != null) await _loadRewards(m);
                },
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
              const SizedBox(height: 26),
              const _PoolSection(),
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


/// A pool as the public board reports it.
class _Pool {
  _Pool(this.signer, this.weight, this.delegators, this.payout, this.reliability,
      this.eligible, this.pendingBlocks, this.pendingMode, this.declared);
  final String signer;
  /// Whether this signer declared itself a pool by committing a payout policy.
  /// The feed carries every staker so the screen can describe whichever one this
  /// wallet is lent to; only declared ones are offered to join.
  final bool declared;
  final BigInt weight;
  final int delegators;
  final String payout;
  final double? reliability;
  final bool eligible;
  final int? pendingBlocks;
  final String? pendingMode;

  static _Pool? parse(dynamic j) {
    if (j is! Map) return null;
    final signer = j['signer'];
    if (signer is! String) return null;
    final pending = (j['policy_pending'] is List && (j['policy_pending'] as List).isNotEmpty)
        ? (j['policy_pending'] as List).first
        : null;
    return _Pool(
      signer,
      BigInt.tryParse('${j['weight']}') ?? BigInt.zero,
      (j['delegators'] as num?)?.toInt() ?? 0,
      (j['payout'] as String?) ?? '',
      (j['reliability'] as num?)?.toDouble(),
      j['eligible'] != false,
      pending is Map ? (pending['blocks_away'] as num?)?.toInt() : null,
      pending is Map ? pending['mode'] as String? : null,
      j['declared'] != false,
    );
  }
}

/// Joining, moving between and leaving staking pools.
///
/// Delegating lends this wallet's stake WEIGHT to a pool's signer. The staked
/// coins are never touched and the pool can never spend them: its key appears
/// nowhere in the staking output's spending condition. Leaving is unilateral,
/// which is why it is always one tap away here and never behind a confirmation
/// that could fail.
///
/// Starting a pool is deliberately absent. Announcing a payout policy binds
/// every block a key ever produces and needs that key online on the machine
/// producing them, which a phone cannot promise, so it lives only in the node
/// wallet.
class _PoolSection extends StatefulWidget {
  const _PoolSection();
  @override
  State<_PoolSection> createState() => _PoolSectionState();
}

/// Signers this device has delegated to. A HINT for finding a record again, not
/// a source of truth: a pool with no weight and no announced policy never
/// appears on the board, so nothing else would remember its key.
const _hintKey = 'seq.staking.signerHints';

Future<List<String>> _loadHints() async {
  try {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_hintKey) ?? const [];
  } catch (_) { return const []; }
}

Future<void> _rememberSigner(String signer) async {
  try {
    final p = await SharedPreferences.getInstance();
    final seen = p.getStringList(_hintKey) ?? <String>[];
    if (seen.contains(signer)) return;
    await p.setStringList(_hintKey, [signer, ...seen].take(20).toList());
  } catch (_) { /* a hint that cannot be stored simply is not used */ }
}

class _PoolSectionState extends State<_PoolSection> {
  List<_Pool> _pools = const [];
  BigInt _networkWeight = BigInt.zero;
  int _stakers = 0;
  int _blockSeconds = 60;
  core.DelegationRecord? _deleg;
  String? _selected;
  bool _busy = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // The board and the wallet's own delegation are independent: a board that is
    // briefly away must never hide the Leave button, because leaving is the one
    // thing that has to work at all times.
    try {
      final r = await http.get(Uri.parse(Backend.pools)).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        final list = (j['pools'] as List?) ?? const [];
        final parsed = <_Pool>[];
        for (final e in list) {
          final p = _Pool.parse(e);
          if (p != null) parsed.add(p);
        }
        if (mounted) {
          setState(() {
            _pools = parsed;
            _networkWeight = BigInt.tryParse('${j['network_weight']}') ?? BigInt.zero;
            _blockSeconds = (j['block_seconds'] as num?)?.toInt() ?? 60;
            _stakers = (j['stakers'] as num?)?.toInt() ?? 0;
          });
        }
      }
    } catch (_) {
      // keep whatever was showing; the card says when it has no list
    }
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m != null) {
        final d = await core.findDelegation(
            mnemonic: m, esploraUrl: Backend.esplora, probeSigners: await _probeSigners());
        if (mounted) setState(() => _deleg = d);
      }
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Everything worth probing for a record of ours, in the ORDER it should be
  /// tried: the signers this device has used, then the rest of the board.
  ///
  /// The order is part of the contract. find_delegation stops as soon as a probe
  /// finds something, so putting the one or two keys this device actually used
  /// first turns the ordinary case into a single request instead of one per
  /// pool. A Dart Set preserves insertion order, which is what keeps that true.
  Future<List<String>> _probeSigners() async {
    final out = <String>{...await _loadHints()};
    for (final p in _pools) {
      out.add(p.signer);
    }
    return out.toList();
  }

  _Pool? get _currentPool {
    final d = _deleg;
    if (d == null) return null;
    for (final p in _pools) {
      if (p.signer == d.signer) return p;
    }
    return null;
  }

  Future<void> _delegate() async {
    final target = _selected;
    if (target == null) return _snack('Choose a pool first');
    final d = _deleg;
    if (d != null && d.signer == target) return _snack('You are already in that pool');

    final moving = d != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: Text(moving ? 'Move to this pool?' : 'Delegate to this pool?', style: AmbraText.title),
        content: Text(
          'Your stake’s block-signing rights go to ${target.substring(0, 16)}…\n\n'
          'Your coins do NOT move, and this pool can never spend them: only this wallet can. '
          'You can take the rights back at any time, immediately, without the pool’s cooperation.\n\n'
          'What you are trusting it for is the reward. Check what it has committed to paying.',
          style: AmbraText.muted,
        ),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(moving ? 'Move' : 'Delegate',
                style: const TextStyle(color: AmbraColors.amber2, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    await _rememberSigner(target);
    try {
      if (moving) {
        // Moving spends the old record and creates the new one in ONE
        // transaction: consensus permits at most one live record per staking
        // key, so two loose transactions could be mined in the order that
        // invalidates a block.
        final m = await WalletRepository.instance.readMnemonic();
        if (m == null) throw Exception('wallet unavailable');
        final raw = await core.buildDelegationSpend(
            mnemonic: m, esploraUrl: Backend.esplora, rotateTo: target,
            probeSigners: await _probeSigners());
        final txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: raw);
        _snack('Moving pool · ${txid.substring(0, 16)}…');
      } else {
        final txid = await authorizeBuildBroadcast((m) => core.buildDelegateTx(
              mnemonic: m,
              esploraUrl: Backend.esplora,
              signerPubkey: target,
            ));
        _snack('Delegated · ${txid.substring(0, 16)}…');
      }
      await _load();
    } catch (e) {
      _snack('Failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: const Text('Leave this pool?', style: AmbraText.title),
        content: const Text(
          'Your stake’s weight counts for you again from the next confirmation, and the pool loses it.\n\n'
          'This does NOT unstake: your coins were never moved by delegating and are not moved now.',
          style: AmbraText.muted,
        ),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave',
                style: TextStyle(color: AmbraColors.amber2, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final raw = await core.buildDelegationSpend(
          mnemonic: m, esploraUrl: Backend.esplora, rotateTo: null,
          probeSigners: await _probeSigners());
      final txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: raw);
      _snack('Left the pool · ${txid.substring(0, 16)}…');
      await _load();
    } catch (e) {
      _snack('Failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What a delegator most needs to see, and would otherwise have to go looking
  /// for: a pool that has promised nothing, and a promise about to change.
  List<String> get _warnings {
    final d = _deleg;
    if (d == null) return const [];
    final out = <String>[];
    if (!d.confirmed) {
      out.add('This change has not confirmed yet. Until it does, your weight still counts for you.');
    }
    final p = _currentPool;
    if (p == null) {
      out.add('This pool is not on the board right now, so what it has committed to cannot be shown. '
          'Leaving always works.');
      return out;
    }
    if (!p.declared) {
      out.add('This signer has not declared itself a pool: it has committed to no payout policy and never '
          'asked for delegations. It keeps everything its blocks earn, and nothing on-chain obliges it to '
          'pay you.');
    } else if (p.payout.contains('no policy committed')) {
      out.add('This pool has committed to no payout policy, so by default it keeps everything its '
          'blocks earn. Nothing on-chain obliges it to pay you.');
    } else if (p.payout.startsWith('pays a committed address')) {
      out.add('This pool pays a committed address. The chain stops it redirecting the reward '
          'silently, but does not check that address shares anything with you.');
    } else if (p.payout.startsWith('pays every delegator')) {
      out.add('This pool shares rewards proportionally: they pool up on-chain and anyone can '
          'trigger the payout. Leaving forfeits your unclaimed share, so claim your rewards '
          'before you leave.');
    }
    final away = p.pendingBlocks;
    if (away != null) {
      final when = DateTime.now().add(Duration(seconds: away * _blockSeconds));
      out.add('This pool has announced a NEW payout policy (${p.pendingMode ?? 'changed'}) binding in '
          '$away blocks, around ${when.toLocal()}. If you do not accept it, leave before then: '
          'leaving is immediate and needs nobody’s permission.');
    }
    if ((p.reliability ?? 1) < 0.5) {
      out.add('This pool has produced far fewer blocks than its weight is owed. While that lasts, '
          'your delegated weight is earning you nothing.');
    }
    return out;
  }

  String _share(BigInt w) {
    if (_networkWeight == BigInt.zero) return '';
    final pct = w * BigInt.from(1000) ~/ _networkWeight;
    return ' · ${(pct.toInt() / 10).toStringAsFixed(1)}% of the network';
  }

  @override
  Widget build(BuildContext context) {
    final d = _deleg;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Staking pool', style: AmbraText.title),
      const SizedBox(height: 8),
      const Text(
        'A pool produces blocks on your behalf, so a stake too small to win blocks often, or a '
        'wallet you would rather keep closed, still earns. Your coins never move and the pool can '
        'never spend them: it is lent only the right to sign with your weight. You can take that '
        'back at any moment, without asking anyone.',
        style: AmbraText.muted,
      ),
      const SizedBox(height: 14),
      AmbraCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(children: [
          _Kv('Status',
              d == null ? 'Not delegating' : (d.confirmed ? 'Delegated' : 'Waiting to confirm')),
          if (d != null) _Kv('Pool', '${d.signer.substring(0, 16)}…'),
          if (d != null) _Kv('In the record', '${formatAtoms(d.value.toString(), 8)} tSEQ'),
        ]),
      ),
      for (final w in _warnings) ...[
        const SizedBox(height: 10),
        WarnCallout(w),
      ],
      if (_error != null) ...[
        const SizedBox(height: 10),
        WarnCallout('Could not read your delegation: $_error'),
      ],
      const SizedBox(height: 16),
      Row(children: [
        const Expanded(child: Text('Choose a pool', style: AmbraText.title)),
        IconButton(
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh, color: AmbraColors.dim, size: 20),
          tooltip: 'Refresh',
        ),
      ]),
      const Text(
        '"Pays out" is what each pool has committed to on-chain. A pool that has committed to '
        'nothing keeps every fee its blocks earn.',
        style: AmbraText.muted,
      ),
      const SizedBox(height: 10),
      if (_loading && _pools.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text('Loading pools…', style: AmbraText.muted))
      else if (!_pools.any((p) => p.declared))
        Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
                'No pool has declared itself yet. $_stakers signer(s) are producing blocks for themselves; '
                'a staker becomes a pool by committing a payout policy on-chain, and appears here when it does.',
                style: AmbraText.muted))
      else
        for (final p in _pools.where((p) => p.declared))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () => setState(() => _selected = p.signer),
              child: AmbraCard(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${p.signer.substring(0, 16)}…', style: AmbraText.mono)),
                    if (_selected == p.signer || (d != null && d.signer == p.signer))
                      const Icon(Icons.check_circle, color: AmbraColors.amber2, size: 18),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    '${formatAtoms(p.weight.toString(), 8)} tSEQ${_share(p.weight)} · '
                    '${p.delegators} delegator(s)'
                    '${p.reliability == null ? '' : ' · produces ${p.reliability!.toStringAsFixed(2)} of its share'}',
                    style: AmbraText.sub,
                  ),
                  const SizedBox(height: 4),
                  Text(p.payout, style: AmbraText.sub),
                  if (p.pendingBlocks != null) ...[
                    const SizedBox(height: 4),
                    Text('⚠ has announced a payout change binding in ${p.pendingBlocks} blocks',
                        style: const TextStyle(color: AmbraColors.amber2, fontSize: 12)),
                  ],
                  if (!p.eligible) ...[
                    const SizedBox(height: 4),
                    const Text('below the network minimum stake, so it cannot produce yet',
                        style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ],
                ]),
              ),
            ),
          ),
      const SizedBox(height: 12),
      PrimaryButton(
        label: d == null ? 'Delegate to the selected pool' : 'Move to the selected pool',
        busy: _busy,
        icon: Icons.groups_outlined,
        onPressed: _busy || _selected == null ? null : _delegate,
      ),
      if (d != null) ...[
        const SizedBox(height: 10),
        GhostButton(label: 'Leave this pool', onPressed: _busy ? null : _leave),
      ],
    ]);
  }
}


/// STAKING REWARDS — what staking has paid, and the standing instruction to
/// convert it.
///
/// A staker earns the transaction fees of the blocks it produces, in whichever
/// assets the payers chose, so rewards arrive as a tail of small balances in
/// assets nobody chose to hold. This card shows that tail, and offers to sell it
/// for ONE asset the staker picks. Bitcoin is the default and the first entry,
/// but not the only choice: outside staking no asset is privileged.
///
/// Which coins are rewards, and which batches convert, are decided by the kit
/// (see [RewardConvert]) — never here, and never differently from the desktop
/// wallet watching the same keys.
class RewardsCard extends StatefulWidget {
  const RewardsCard({super.key, required this.totals, required this.rows, this.onChanged});

  /// Per-asset totals, from `rewardTotals`.
  final List<Map<String, dynamic>> totals;

  /// What a dry run says would happen, from `RewardConvert.runPass`.
  final List<RewardPassRow> rows;

  final VoidCallback? onChanged;

  @override
  State<RewardsCard> createState() => _RewardsCardState();
}

class _RewardsCardState extends State<RewardsCard> {
  RewardConvert get _rc => RewardConvert.instance;

  @override
  Widget build(BuildContext context) {
    return AmbraCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Staking rewards', style: AmbraText.title),
        const SizedBox(height: 8),
        const Text(
          'What staking has paid you, in whatever assets the fees were paid in. Sequentia has no '
          'block subsidy: a block earns its own transaction fees and nothing else. Block rewards '
          'are spendable 100 blocks after they are earned; a pool payout is spendable at once.',
          style: AmbraText.muted,
        ),
        const SizedBox(height: 12),
        if (widget.totals.isEmpty)
          const Text(
            'No staking rewards yet. A block pays its own fees, so rewards appear once a block '
            'you (or your pool) produced carried some.',
            style: AmbraText.muted,
          )
        else
          ...widget.totals.map((t) {
            final mature = (t['mature'] as BigInt).toString();
            final immature = (t['immature'] as BigInt).toString();
            final maturing = (t['immature'] as BigInt) > BigInt.zero ? ' · $immature maturing' : '';
            return _Kv(t['asset'] as String, '$mature spendable$maturing');
          }),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Convert my staking rewards automatically', style: AmbraText.body),
          value: _rc.enabled,
          onChanged: (v) async {
            setState(() => _rc.enabled = v);
            await _rc.save();
            widget.onChanged?.call();
          },
        ),
        const Text(
          'Once this is on, the wallet sells without asking again. It never converts more than '
          'staking has paid you, never touches your stake, and never converts what it cannot get '
          'a fair price for — but the selling itself is unattended, which is the point of it.',
          style: AmbraText.muted,
        ),
        if (_rc.enabled) ...[
          const SizedBox(height: 12),
          _Kv('Convert into', _rc.target == RewardConvert.btc ? 'BTC (Bitcoin)' : _rc.target),
          _Kv('Only once worth at least', _rc.minReceive.toString()),
          _Kv('Refuse a price worse than', '${(_rc.maxSlippageBp / 100).toStringAsFixed(2)}%'),
          const SizedBox(height: 12),
          if (widget.rows.isEmpty)
            const Text(
              'Nothing to convert right now. Rewards are gathered per asset until a batch is '
              'worth converting.',
              style: AmbraText.muted,
            )
          else
            // Why it would NOT convert matters as much as why it would:
            // "nothing happened" and "nothing should have happened" look
            // identical otherwise, and the second is far the more common.
            ...widget.rows.map((r) => _Kv(
                  '${r.value} ${r.asset}',
                  r.converts ? 'converting' : r.reason,
                )),
        ],
      ]),
    );
  }
}
