import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../rust/api.dart' as core;
import '../data/config.dart';
import '../data/format.dart';
import '../data/node_config.dart';
import '../data/price_service.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'assets_screen.dart';
import 'faucet_screen.dart';
import 'history_screen.dart';
import 'node_screen.dart';
import 'send_screen.dart';
import 'stake_screen.dart';

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
      BalanceTab(isActive: _tab == 0),
      SendTab(isActive: _tab == 1),
      const ReceiveTab(),
      HistoryTab(isActive: _tab == 3),
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
  const BalanceTab({super.key, this.isActive = false});
  final bool isActive;
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
    PriceService.instance.addListener(_onPrice);
    _refresh();
  }

  @override
  void didUpdateWidget(BalanceTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-sync whenever this tab becomes visible (assets may have arrived while
    // the user was on another tab).
    if (widget.isActive && !oldWidget.isActive) _refresh();
  }

  void _onPrice() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    PriceService.instance.removeListener(_onPrice);
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _error = null);
    PriceService.instance.refreshPrices();
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
          if (_sync == null) _error = friendlyError(e); // keep last-good on a transient reload error
          _loading = false;
        });
      }
    }
  }

  /// Total portfolio value in the reference currency, summed across every asset
  /// equally (no asset privileged). null if nothing held can be priced.
  double? _totalRef() {
    final s = _sync;
    if (s == null) return null;
    double sum = 0;
    bool any = false;
    for (final b in s.balances) {
      final label = SeqAssets.labelFor(b.assetId);
      final v = PriceService.instance.refValue(label.ticker, b.atoms, label.precision);
      if (v != null) {
        sum += v;
        any = true;
      }
    }
    return any ? sum : null;
  }

  @override
  Widget build(BuildContext context) {
    final sync = _sync;
    // Only assets actually held — tSEQ is not privileged, so a 0 balance is
    // hidden just like any other asset's would be.
    final held = sync == null
        ? const <core.AssetBalance>[]
        : sync.balances.where((b) => (BigInt.tryParse(b.atoms) ?? BigInt.zero) > BigInt.zero).toList();
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
            _RefChip(ref: PriceService.instance.ref),
            const SizedBox(width: 10),
            _SyncChip(loading: _loading, tip: sync?.tipHeight),
          ]),
          const SizedBox(height: 28),
          Text('TOTAL BALANCE', style: AmbraText.label),
          const SizedBox(height: 6),
          Builder(builder: (_) {
            final total = sync == null ? null : _totalRef();
            return Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Text(total == null ? '—' : PriceService.instance.fmtRef(total), style: AmbraText.hero),
              const SizedBox(width: 8),
              Text(PriceService.instance.ref,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AmbraColors.amber2)),
            ]);
          }),
          if (sync != null && _totalRef() == null)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Live prices unavailable — see per-asset amounts below.', style: AmbraText.sub),
            ),
          const SizedBox(height: 24),
          if (_error != null)
            AmbraCard(child: Text(_error!, style: const TextStyle(color: AmbraColors.red)))
          else if (sync == null)
            const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
          else if (held.isEmpty)
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
              child: Column(children: [for (final b in held) _AssetRow(balance: b)]),
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
        Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          Text(amount,
              style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontSize: 15, fontWeight: FontWeight.w700)),
          if (PriceService.instance.approx(label.ticker, balance.atoms, label.precision) != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(PriceService.instance.approx(label.ticker, balance.atoms, label.precision)!,
                  style: AmbraText.sub),
            ),
        ]),
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

class _RefChip extends StatelessWidget {
  const _RefChip({required this.ref});
  final String ref;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _showRefSheet(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: AmbraColors.line), borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(ref, style: const TextStyle(color: AmbraColors.amber2, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: 3),
          const Icon(Icons.expand_more, color: AmbraColors.dim, size: 16),
        ]),
      ),
    );
  }
}

void _showRefSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        const Padding(padding: EdgeInsets.all(16), child: Text('Show values in', style: AmbraText.title)),
        for (final r in PriceService.instance.refOptions())
          ListTile(
            title: Text(r, style: AmbraText.body),
            trailing: r == PriceService.instance.ref ? const Icon(Icons.check, color: AmbraColors.amber) : null,
            onTap: () {
              PriceService.instance.setRef(r);
              Navigator.pop(context);
            },
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
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
  String? _bitcoinAddress; // the tb1 form, shown alongside a confidential address
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _address = null;
      _bitcoinAddress = null;
      _error = null;
    });
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final info = await core.receiveAddressAt(mnemonic: m, index: _index, confidential: _confidential);
      String? bitcoin;
      if (_confidential) {
        bitcoin = (await core.receiveAddressAt(mnemonic: m, index: _index, confidential: false)).address;
      }
      if (mounted) {
        setState(() {
          _address = info.address;
          _bitcoinAddress = bitcoin;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _copy(String text, String msg) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
            SectionLabel(
                _confidential ? 'Confidential address (index $_index)' : 'Address (index $_index)'),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: AmbraColors.red))
            else if (_address == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)),
              )
            else ...[
              SelectableText(_address!, style: AmbraText.mono.copyWith(fontSize: 14)),
              const SizedBox(height: 10),
              Text(
                _confidential
                    ? 'Private — the amount and asset are hidden on-chain. This is NOT a Bitcoin address.'
                    : 'Also receives Bitcoin (testnet4) — one address, both chains.',
                style: AmbraText.sub,
              ),
              const SizedBox(height: 14),
              SecondaryButton(
                label: _confidential ? 'Copy confidential address' : 'Copy address',
                icon: Icons.copy,
                onPressed: () =>
                    _copy(_address!, _confidential ? 'Confidential address copied' : 'Address copied'),
              ),
            ],
          ]),
        ),
        if (_confidential && _bitcoinAddress != null) ...[
          const SizedBox(height: 12),
          AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel('Bitcoin / non-confidential address'),
              const SizedBox(height: 14),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                  child: QrImageView(
                      data: _bitcoinAddress!, version: QrVersions.auto, size: 168, backgroundColor: Colors.white),
                ),
              ),
              const SizedBox(height: 14),
              SelectableText(_bitcoinAddress!, style: AmbraText.mono.copyWith(fontSize: 14)),
              const SizedBox(height: 10),
              const Text('Use this transparent address to also receive Bitcoin (testnet4).',
                  style: AmbraText.sub),
              const SizedBox(height: 14),
              SecondaryButton(
                label: 'Copy Bitcoin address',
                icon: Icons.copy,
                onPressed: () => _copy(_bitcoinAddress!, 'Bitcoin address copied'),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 14),
        SecondaryButton(
          label: _confidential ? 'New addresses' : 'New address',
          icon: Icons.refresh,
          onPressed: _address == null
              ? null
              : () {
                  _index++;
                  _load();
                },
        ),
        const SizedBox(height: 18),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          activeThumbColor: AmbraColors.amber,
          value: _confidential,
          onChanged: (v) {
            _confidential = v;
            _load();
          },
          title: const Text('Show confidential address', style: AmbraText.body),
          subtitle: const Text('A private address that hides the amount and asset.', style: AmbraText.sub),
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
        ListenableBuilder(
          listenable: NodeConfig.instance,
          builder: (context, _) => AmbraCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel('Node'),
              const SizedBox(height: 12),
              const _Kv('Network', 'sequentia-testnet'),
              _Kv('Node', NodeConfig.instance.origin),
              _Kv('Source', NodeConfig.instance.isDefault ? 'Default (public testnet)' : 'Custom'),
              const SizedBox(height: 12),
              SecondaryButton(
                label: 'Change node',
                icon: Icons.dns_outlined,
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NodeScreen())),
              ),
            ]),
          ),
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
        const SizedBox(height: 14),
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionLabel('Assets & staking'),
            const SizedBox(height: 12),
            SecondaryButton(
              label: 'Issue / manage assets',
              icon: Icons.toll,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AssetsScreen())),
            ),
            const SizedBox(height: 10),
            SecondaryButton(
              label: 'Stake tSEQ',
              icon: Icons.lock_outline,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StakeScreen())),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text('Lightning · T-DEX · Managed assets — coming soon', style: AmbraText.sub),
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
