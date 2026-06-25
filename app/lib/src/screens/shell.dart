import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../rust/api.dart' as core;
import '../data/config.dart';
import '../data/format.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'faucet_screen.dart';
import 'history_screen.dart';
import 'send_screen.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      const BalanceTab(),
      const SendTab(),
      const ReceiveTab(),
      const HistoryTab(),
      const MoreTab(),
    ];
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbraBackground(child: SafeArea(bottom: false, child: IndexedStack(index: _tab, children: tabs))),
      bottomNavigationBar: _BottomBar(index: _tab, onTap: (i) => setState(() => _tab = i)),
    );
  }
}

// ---------------------------------------------------------------------------
// Balance (M3: shows network + your main receive address; live balances = M4)
// ---------------------------------------------------------------------------
class BalanceTab extends StatefulWidget {
  const BalanceTab({super.key});
  @override
  State<BalanceTab> createState() => _BalanceTabState();
}

class _BalanceTabState extends State<BalanceTab> {
  core.WalletSync? _sync;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _error = null);
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      if (mounted) {
        setState(() {
          _sync = s;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  String _tseq() {
    final hit = _sync?.balances.where((b) => b.assetId == SeqAssets.policy);
    if (hit == null || hit.isEmpty) return '0';
    return formatAtoms(hit.first.atoms, 8);
  }

  @override
  Widget build(BuildContext context) {
    final sync = _sync;
    return RefreshIndicator(
      onRefresh: _refresh,
      color: AmbraColors.amber,
      backgroundColor: AmbraColors.panel,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Row(children: [
            const BrandMark(size: 34),
            const SizedBox(width: 12),
            const Text('Ambra', style: AmbraText.title),
            const Spacer(),
            _SyncChip(loading: _loading, tip: sync?.tipHeight),
          ]),
          const SizedBox(height: 28),
          Text('SEQUENTIA BALANCE', style: AmbraText.label),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(sync == null ? '—' : _tseq(), style: AmbraText.hero),
            const SizedBox(width: 8),
            const Text('tSEQ',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AmbraColors.amber2)),
          ]),
          const SizedBox(height: 24),
          if (_error != null)
            AmbraCard(child: Text('Sync failed: $_error', style: const TextStyle(color: AmbraColors.red)))
          else if (sync == null)
            const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
          else if (sync.balances.isEmpty)
            const AmbraCard(
                child: Text(
                    'No funds yet. Get free testnet coins from the faucet (More tab), '
                    'or share your address on Receive.',
                    style: AmbraText.muted))
          else ...[
            Text('ASSETS', style: AmbraText.label),
            const SizedBox(height: 10),
            AmbraCard(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: Column(children: [for (final b in sync.balances) _AssetRow(balance: b)]),
            ),
          ],
        ],
      ),
    );
  }
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({required this.balance});
  final core.AssetBalance balance;
  @override
  Widget build(BuildContext context) {
    final label = SeqAssets.labelFor(balance.assetId);
    final amount = formatAtoms(balance.atoms, label.precision);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label.ticker,
                style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 2),
            Text(label.subtitle ?? balance.assetId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: label.subtitle != null ? AmbraText.sub : AmbraText.mono.copyWith(fontSize: 11)),
          ]),
        ),
        const SizedBox(width: 12),
        Text(amount,
            style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontSize: 15, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.loading, this.tip});
  final bool loading;
  final int? tip;
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (loading)
        const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: AmbraColors.dim))
      else
        Container(width: 7, height: 7, decoration: const BoxDecoration(color: AmbraColors.green, shape: BoxShape.circle)),
      const SizedBox(width: 7),
      Text(tip == null ? 'syncing' : 'block $tip', style: AmbraText.sub),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Receive (M3: shared tb1 default + confidential tsqb1 opt-in, copy, cycle)
// ---------------------------------------------------------------------------
class ReceiveTab extends StatefulWidget {
  const ReceiveTab({super.key});
  @override
  State<ReceiveTab> createState() => _ReceiveTabState();
}

class _ReceiveTabState extends State<ReceiveTab> {
  int _index = 0;
  bool _confidential = false;
  String? _address;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _address = null;
      _error = null;
    });
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final info = await core.receiveAddressAt(mnemonic: m, index: _index, confidential: _confidential);
      if (mounted) setState(() => _address = info.address);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: [
        const Text('Receive', style: AmbraText.h1),
        const SizedBox(height: 20),
        if (_address != null) ...[
          Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: QrImageView(data: _address!, version: QrVersions.auto, size: 224, backgroundColor: Colors.white),
            ),
          ),
          const SizedBox(height: 18),
        ],
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SectionLabel(_confidential ? 'Confidential address' : 'Address (index $_index)'),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: AmbraColors.red))
            else if (_address == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)),
              )
            else
              SelectableText(_address!, style: AmbraText.mono.copyWith(fontSize: 14)),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: SecondaryButton(
              label: 'Copy',
              icon: Icons.copy,
              onPressed: _address == null
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: _address!));
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('Address copied')));
                    },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SecondaryButton(
              label: 'New address',
              icon: Icons.refresh,
              onPressed: _confidential
                  ? null
                  : () {
                      _index++;
                      _load();
                    },
            ),
          ),
        ]),
        const SizedBox(height: 18),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          activeThumbColor: AmbraColors.amber,
          value: _confidential,
          onChanged: (v) {
            _confidential = v;
            _load();
          },
          title: const Text('Confidential (private) address', style: AmbraText.body),
          subtitle: Text(
            _confidential
                ? 'tsqb… — amount and asset hidden on-chain. Not a Bitcoin address.'
                : 'tb1… — also receives Bitcoin (testnet4). One address, both chains.',
            style: AmbraText.sub,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// More (M3: network info, reveal phrase, lock, remove wallet)
// ---------------------------------------------------------------------------
class MoreTab extends StatelessWidget {
  const MoreTab({super.key});

  Future<void> _reveal(BuildContext context) async {
    final repo = WalletRepository.instance;
    final ok = await repo.authenticate(reason: 'Reveal recovery phrase');
    if (!ok) return;
    final m = await repo.readMnemonic();
    if (m == null || !context.mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AmbraColors.panel,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Recovery phrase', style: AmbraText.h1),
          const SizedBox(height: 16),
          AmbraCard(child: MnemonicWordGrid(words: m.split(' '))),
          const SizedBox(height: 16),
          const WarnCallout('Never share these words. Anyone with them controls your funds.'),
        ]),
      ),
    );
  }

  Future<void> _remove(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: const Text('Remove wallet?', style: AmbraText.title),
        content: const Text(
          'This deletes the recovery phrase from this device. You can only restore '
          'it if you have your 12 words backed up.',
          style: AmbraText.muted,
        ),
        actions: [
          GhostButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: AmbraColors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirm == true) await WalletRepository.instance.removeWallet();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: [
        const Text('More', style: AmbraText.h1),
        const SizedBox(height: 20),
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionLabel('Network'),
            const SizedBox(height: 12),
            const _Kv('Network', 'sequentia-testnet'),
            const _Kv('Explorer API', Backend.esplora),
          ]),
        ),
        const SizedBox(height: 14),
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionLabel('Testnet'),
            const SizedBox(height: 12),
            SecondaryButton(
              label: 'Get testnet coins (faucet)',
              icon: Icons.water_drop_outlined,
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FaucetScreen())),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionLabel('Wallet'),
            const SizedBox(height: 12),
            SecondaryButton(label: 'Reveal recovery phrase', icon: Icons.visibility, onPressed: () => _reveal(context)),
            const SizedBox(height: 10),
            SecondaryButton(
                label: 'Lock now', icon: Icons.lock, onPressed: () => WalletRepository.instance.lock()),
            const SizedBox(height: 10),
            DangerButton(label: 'Remove wallet', onPressed: () => _remove(context)),
          ]),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text('Lightning · T-DEX · Managed assets — coming soon',
              style: AmbraText.sub),
        ),
      ],
    );
  }
}

class _Kv extends StatelessWidget {
  const _Kv(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, style: AmbraText.mono, textAlign: TextAlign.right)),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Bottom navigation — nested-pill active state.
// ---------------------------------------------------------------------------
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  static const _items = [
    (Icons.account_balance_wallet_outlined, 'Balance'),
    (Icons.north_east, 'Send'),
    (Icons.qr_code, 'Receive'),
    (Icons.receipt_long_outlined, 'History'),
    (Icons.more_horiz, 'More'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AmbraColors.bg,
        border: Border(top: BorderSide(color: AmbraColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: List.generate(_items.length, (i) {
              final active = i == index;
              return Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(AmbraRadii.control),
                  onTap: () => onTap(i),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: active ? AmbraColors.buttonSurface : Colors.transparent,
                      borderRadius: BorderRadius.circular(AmbraRadii.control),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_items[i].$1, size: 22, color: active ? AmbraColors.amber2 : AmbraColors.dim),
                      const SizedBox(height: 4),
                      Text(_items[i].$2,
                          style: TextStyle(
                              fontSize: 11, color: active ? AmbraColors.txt : AmbraColors.dim)),
                    ]),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
