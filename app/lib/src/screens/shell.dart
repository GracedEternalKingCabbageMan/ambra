import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../rust/api.dart' as core;
import '../data/btc_state.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../data/lightning_service.dart';
import '../data/node_config.dart';
import '../data/price_service.dart';
import '../data/registry_service.dart';
import '../data/wallet_cache.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'assets_screen.dart';
import 'faucet_screen.dart';
import 'history_screen.dart';
import 'node_screen.dart';
import 'send_screen.dart';
import 'stake_screen.dart';
import 'swap_screen.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // The wallet is unlocked once the Shell is shown. Bring the on-device
    // Lightning signer online (the mobile twin of the web wallet's post-unlock
    // initLightning), so the "Instant (Lightning)" swap rail becomes available.
    // Non-fatal + opt-in: no-op unless a hosted LSP is configured for this build
    // (Backend.lnWsUrl / lnHostPubkey), and idempotent if already serving.
    _initLightning();
  }

  Future<void> _initLightning() async {
    if (!LightningService.instance.configured) return; // LN not deployed here
    final m = await WalletRepository.instance.readMnemonic();
    if (m != null) await LightningService.instance.start(m);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      BalanceTab(isActive: _tab == 0),
      SendTab(isActive: _tab == 1),
      const ReceiveTab(),
      SwapTab(isActive: _tab == 3),
      HistoryTab(isActive: _tab == 4),
      const MoreTab(),
    ];
    // TODO(device-verify): confirm the Android hardware/gesture back returns to
    // Balance from other tabs and only exits from Balance (needs a device).
    return PopScope(
      // Android back should return to the Balance tab from any other tab, and only
      // exit the app when already on Balance — not drop out of the wallet on the
      // first back press from Send/Swap/History/More.
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted) setState(() => _tab = 0);
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AmbraBackground(child: SafeArea(bottom: false, child: IndexedStack(index: _tab, children: tabs))),
        bottomNavigationBar: _BottomBar(index: _tab, onTap: (i) => setState(() => _tab = i)),
      ),
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
  core.BtcBalance? _btc; // parent-chain (testnet4) balance, first-class like any asset
  String? _btcCachedSats; // last-known BTC sats from disk, shown if a fresh scan fails
  bool _btcStale = false; // true when the shown BTC balance is last-known (scan failed)
  List<core.AssetBalance>? _cachedBalances; // last-known, shown instantly while syncing
  String? _error;
  bool _loading = true;
  DateTime? _lastSync; // time of the last successful Sequentia sync (for the chip)
  bool _syncFailed = false; // the latest refresh errored (chip shows offline + last-sync time)

  @override
  void initState() {
    super.initState();
    PriceService.instance.addListener(_onPrice);
    // Asset labels can arrive after first paint (network registry); rebuild so
    // rows show the real ticker/precision instead of a hex placeholder.
    RegistryService.instance.addListener(_onPrice);
    _loadCached(); // show outdated balances at once, refresh below
    _refresh(); // eager: every tab loads at launch (cheap now that the wallet is cached)
  }

  Future<void> _loadCached() async {
    final b = await WalletCache.loadBalances();
    final btcSats = await WalletCache.loadBtc();
    if (mounted && _sync == null) {
      setState(() {
        if (b != null) _cachedBalances = b;
        if (btcSats != null && _btc == null) _btcCachedSats = btcSats;
      });
    }
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
    RegistryService.instance.removeListener(_onPrice);
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _error = null);
    PriceService.instance.refreshPrices();
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      // Scan both chains. Kick off the Bitcoin scan concurrently; a BTC failure
      // must not break the Sequentia balance, so it resolves to null on error.
      final btcF = () async {
        try {
          return await core.btcSync(mnemonic: m, t4Api: Backend.testnet4);
        } catch (_) {
          return null;
        }
      }();
      final s = await core.syncWallet(mnemonic: m, esploraUrl: Backend.esplora);
      final btc = await btcF;
      WalletCache.saveBalances(s.balances); // persist for the next launch
      if (btc != null) WalletCache.saveBtc(btc.balanceSats); // persist last-known BTC
      // Feed both chains' indices into the shared cross-chain receive cycling.
      BtcState.instance.observe(btc: btc, seqNext: s.nextIndex);
      if (mounted) {
        setState(() {
          _sync = s;
          _lastSync = DateTime.now();
          _syncFailed = false;
          if (btc != null) {
            _btc = btc;
            _btcCachedSats = btc.balanceSats;
            _btcStale = false;
          } else {
            // The testnet4 scan failed. Keep showing the last-known BTC balance
            // (fresh _btc or the disk cache) marked offline, instead of silently
            // dropping the row while the sync chip reads green.
            _btcStale = _btc != null || _btcCachedSats != null;
          }
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _syncFailed = true; // latest refresh failed; chip reflects it (may show stale data)
          // Surface an error only when there's nothing (not even stale data) to show.
          if (_sync == null && _cachedBalances == null) _error = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  /// Total portfolio value in the reference currency, summed across every asset
  /// equally (no asset privileged). null if nothing held can be priced.
  double? _totalRef(List<core.AssetBalance> balances) {
    double sum = 0;
    bool any = false;
    for (final b in balances) {
      final label = SeqAssets.labelFor(b.assetId);
      final v = PriceService.instance.refValue(label.ticker, b.atoms, label.precision);
      if (v != null) {
        sum += v;
        any = true;
      }
    }
    // Parent-chain Bitcoin counts equally toward the portfolio total (using the
    // last-known balance if the latest testnet4 scan didn't complete).
    final btcSats = _btc?.balanceSats ?? _btcCachedSats;
    if (btcSats != null) {
      final v = PriceService.instance.refValue('BTC', btcSats, 8);
      if (v != null) {
        sum += v;
        any = true;
      }
    }
    return any ? sum : null;
  }

  @override
  Widget build(BuildContext context) {
    // Prefer fresh sync data; fall back to cached balances so a launch shows the
    // last-known values instantly instead of a spinner. tSEQ is not privileged,
    // so a 0 balance is hidden like any other asset's.
    final balances = _sync?.balances ?? _cachedBalances;
    final held = balances == null
        ? const <core.AssetBalance>[]
        : balances.where((b) => (BigInt.tryParse(b.atoms) ?? BigInt.zero) > BigInt.zero).toList();
    final total = balances == null ? null : _totalRef(balances);
    // Bitcoin is first-class: shown when held (a 0 balance is hidden like any
    // asset). Resolve to the last-known balance if a fresh testnet4 scan failed.
    final btcSatsStr = _btc?.balanceSats ?? _btcCachedSats;
    final btcSats = BigInt.tryParse(btcSatsStr ?? '0') ?? BigInt.zero;
    final hasBtc = btcSats > BigInt.zero;
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
            _SyncChip(loading: _loading, tip: _sync?.tipHeight, failed: _syncFailed, lastSync: _lastSync),
          ]),
          const SizedBox(height: 28),
          Text('TOTAL BALANCE', style: AmbraText.label),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(total == null ? '—' : PriceService.instance.fmtRef(total), style: AmbraText.hero),
            const SizedBox(width: 8),
            Text(PriceService.instance.ref,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AmbraColors.amber2)),
          ]),
          if (balances != null && total == null)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Live prices unavailable; see per-asset amounts below.', style: AmbraText.sub),
            ),
          const SizedBox(height: 24),
          if (_error != null && balances == null)
            AmbraCard(child: Text(_error!, style: const TextStyle(color: AmbraColors.red)))
          else if (balances == null)
            const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
          else if (held.isEmpty && !hasBtc)
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
              child: Column(children: [
                if (hasBtc) _BtcRow(sats: btcSatsStr!, stale: _btcStale),
                for (final b in held) _AssetRow(balance: b),
              ]),
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

/// The Bitcoin parent-chain balance row — first-class, same layout as [_AssetRow].
class _BtcRow extends StatelessWidget {
  const _BtcRow({required this.sats, this.stale = false});
  final String sats;
  final bool stale; // showing the last-known balance because the latest scan failed
  @override
  Widget build(BuildContext context) {
    final amount = formatAtoms(sats, 8);
    final approx = PriceService.instance.approx('BTC', sats, 8);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('BTC',
                style: TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 2),
            Text(stale ? 'Bitcoin testnet4 · last known (offline)' : 'Bitcoin testnet4',
                style: stale ? AmbraText.sub.copyWith(color: AmbraColors.amber2) : AmbraText.sub),
          ]),
        ),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          Text(amount,
              style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontSize: 15, fontWeight: FontWeight.w700)),
          if (approx != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(approx, style: AmbraText.sub),
            ),
        ]),
      ]),
    );
  }
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.loading, this.tip, this.failed = false, this.lastSync});
  final bool loading;
  final int? tip;
  final bool failed; // the latest refresh errored
  final DateTime? lastSync; // time of the last successful sync

  static String _hhmm(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Row(mainAxisSize: MainAxisSize.min, children: const [
        SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: AmbraColors.dim)),
        SizedBox(width: 7),
        Text('syncing', style: AmbraText.sub),
      ]);
    }
    // Green + block height when the latest sync succeeded; amber + "offline" when
    // it failed, with the last-synced time so "offline" isn't undated (the screen
    // is then showing last-known data).
    final synced = tip != null && !failed;
    final String label;
    if (synced) {
      label = 'block $tip';
    } else if (lastSync != null) {
      label = 'offline · synced ${_hhmm(lastSync!)}';
    } else {
      label = 'offline';
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: synced ? AmbraColors.green : AmbraColors.amber,
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 7),
      Text(label, style: AmbraText.sub),
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
    // Start at the cross-chain unified next-unused index, and follow it forward as
    // either chain's scan advances it (the shared address discourages reuse).
    _index = BtcState.instance.unifiedNext;
    BtcState.instance.addListener(_onUnified);
    _load();
  }

  void _onUnified() {
    final next = BtcState.instance.unifiedNext;
    if (next > _index && mounted) {
      setState(() => _index = next);
      _load();
    }
  }

  @override
  void dispose() {
    BtcState.instance.removeListener(_onUnified);
    super.dispose();
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
                    ? 'Private: the amount and asset are hidden on-chain. This is NOT a Bitcoin address.'
                    : 'Also receives Bitcoin (testnet4); one address, both chains.',
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
                  BtcState.instance.bumpTo(_index); // keep the cross-chain cycle in step
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
    if (confirm == true) {
      await WalletRepository.instance.removeWallet();
      await WalletCache.clear();
    }
  }

  Future<void> _toggleLock(BuildContext context, bool on) async {
    final repo = WalletRepository.instance;
    if (on) {
      // Only enable if the device can actually enforce it (has a screen lock).
      if (!await repo.canEnforceLock()) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Set up a screen lock (PIN, pattern, or biometrics) on your device first.')));
        }
        return;
      }
      // Confirm the user can authenticate before relying on the lock.
      if (!await repo.authenticate(reason: 'Confirm to enable the app lock')) return;
      await repo.setLockEnabled(true);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App lock enabled.')));
      }
    } else {
      // Disabling the lock must require auth too, or anyone holding the unlocked
      // phone could just turn it off.
      if (!await repo.authenticate(reason: 'Confirm to disable the app lock')) return;
      await repo.setLockEnabled(false);
    }
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
        ListenableBuilder(
          listenable: WalletRepository.instance,
          builder: (context, _) {
            final repo = WalletRepository.instance;
            return AmbraCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Security'),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AmbraColors.amber,
                  value: repo.lockEnabled,
                  onChanged: (v) => _toggleLock(context, v),
                  title: const Text('App lock', style: AmbraText.body),
                  subtitle: const Text('Require biometrics or your device PIN to open Ambra.', style: AmbraText.sub),
                ),
                if (repo.lockEnabled) ...[
                  const SizedBox(height: 8),
                  SecondaryButton(label: 'Lock now', icon: Icons.lock, onPressed: repo.lock),
                ],
              ]),
            );
          },
        ),
        const SizedBox(height: 14),
        AmbraCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionLabel('Wallet'),
            const SizedBox(height: 12),
            SecondaryButton(label: 'Reveal recovery phrase', icon: Icons.visibility, onPressed: () => _reveal(context)),
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
          child: Text('Ambra v$kAppVersion · Bitcoin testnet4 + Sequentia testnet', style: AmbraText.sub),
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
    (Icons.swap_horiz, 'Swap'),
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
