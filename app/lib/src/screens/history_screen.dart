import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../rust/api.dart' as core;
import '../data/config.dart';
import '../data/format.dart';
import '../data/price_service.dart';
import '../data/wallet_cache.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'rescue_screen.dart';
import 'sign_screen.dart';

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key, this.isActive = false});
  final bool isActive;
  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  List<core.TxRow>? _txs;
  String? _error;
  List<OampTransfer> _oamp = const []; // locally-tracked restricted transfers
  List<Map<String, dynamic>> _ln = const []; // Lightning history (written by the LN cards)

  @override
  void initState() {
    super.initState();
    _loadCached(); // show last-known history at once, refresh below
    _load(); // eager: load at launch (also reloads on activation)
    _loadSidecars(); // restricted-transfer tracker + Lightning history
  }

  Future<void> _loadCached() async {
    final txs = await WalletCache.loadTxs();
    if (txs != null && mounted && _txs == null) setState(() => _txs = txs);
  }

  /// Load (then re-derive) the restricted-transfer tracker and the Lightning
  /// history. Both fail soft to whatever is on disk.
  Future<void> _loadSidecars() async {
    final xfers = await WalletCache.loadOampTransfers();
    final ln = await WalletCache.loadLnHistory();
    if (mounted) setState(() { _oamp = xfers; _ln = ln; });
    await _refreshOamp();
  }

  /// Re-check every tracked restricted transfer against the Sequentia explorer
  /// and the Bitcoin anchor. Reorg-aware: a confirmed transfer reverts to
  /// pending if its anchoring Bitcoin block (and so the Sequentia block) is
  /// orphaned (anchoring supremacy) — never sticky, always re-derived live.
  Future<void> _refreshOamp() async {
    final xfers = await WalletCache.loadOampTransfers();
    if (xfers.isEmpty) {
      if (mounted) setState(() => _oamp = xfers);
      return;
    }
    var changed = false;
    await Future.wait(xfers.map((x) async {
      try {
        final r = await http
            .get(Uri.parse('${Backend.esplora}/tx/${x.txid}/status'), headers: Backend.authHeaders)
            .timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) return;
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final confirmed = j['confirmed'] == true;
        if (confirmed != x.confirmed) {
          x.confirmed = confirmed;
          changed = true;
          if (!confirmed) x.anchorDepth = null; // dropped back to the mempool
        }
        final bh = j['block_hash'];
        if (confirmed && bh is String && bh.isNotEmpty && bh != x.blockHash) {
          x.blockHash = bh;
          changed = true;
        }
        if (x.confirmed && x.blockHash != null) {
          final ar = await http
              .get(Uri.parse(Backend.anchor(x.blockHash!)), headers: Backend.authHeaders)
              .timeout(const Duration(seconds: 20));
          if (ar.statusCode != 200) return;
          final aj = jsonDecode(ar.body) as Map<String, dynamic>;
          final ah = aj['anchorheight'];
          final anchorH = ah is num ? ah.toInt() : int.tryParse('$ah');
          if (anchorH == null) return;
          final tr = await http
              .get(Uri.parse('${Backend.testnet4}/blocks/tip/height'), headers: Backend.authHeaders)
              .timeout(const Duration(seconds: 20));
          if (tr.statusCode != 200) return;
          final tip = int.tryParse(tr.body.trim());
          if (tip == null) return;
          final d = tip - anchorH + 1;
          final depth = d < 0 ? 0 : d;
          if (depth != x.anchorDepth) {
            x.anchorDepth = depth;
            changed = true;
          }
        }
      } catch (_) {/* transient — leave this entry as last known, don't drop it */}
    }));
    if (changed) await WalletCache.saveOampTransfers(xfers);
    if (mounted) setState(() => _oamp = xfers);
  }

  @override
  void didUpdateWidget(HistoryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-pull when the tab is opened so newly-confirmed/received txs show up
    // without restarting the app.
    if (widget.isActive && !oldWidget.isActive) {
      _load();
      _loadSidecars();
    }
  }

  Future<void> _load() async {
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) return;
      final txs = await core.walletTransactions(mnemonic: m, esploraUrl: Backend.esplora);
      txs.sort((a, b) {
        if (a.height == null && b.height == null) return 0;
        if (a.height == null) return -1; // unconfirmed first
        if (b.height == null) return 1;
        return b.height!.compareTo(a.height!);
      });
      WalletCache.saveTxs(txs); // persist for the next launch
      if (mounted) {
        setState(() {
          _txs = txs;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _txs == null) setState(() => _error = friendlyError(e)); // keep last-good on reload
    }
  }

  @override
  Widget build(BuildContext context) {
    final txs = _txs;
    return RefreshIndicator(
      onRefresh: () async {
        await _load();
        await _refreshOamp();
        final ln = await WalletCache.loadLnHistory();
        if (mounted) setState(() => _ln = ln);
      },
      color: AmbraColors.amber,
      backgroundColor: AmbraColors.panel,
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
        const Text('History', style: AmbraText.h1),
        const SizedBox(height: 16),
        if (_error != null)
          AmbraCard(child: Text(_error!, style: const TextStyle(color: AmbraColors.red)))
        else if (txs == null)
          const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
        else if (txs.isEmpty)
          const AmbraCard(child: Text('No transactions yet.', style: AmbraText.muted))
        else
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(children: [for (final t in txs) _TxRowView(tx: t, onRescued: () => _load())]),
          ),
        if (_ln.isNotEmpty) ...[
          const SizedBox(height: 22),
          const SectionLabel('Lightning'),
          const SizedBox(height: 8),
          _LnHistoryCard(entries: _ln),
        ],
        if (_oamp.isNotEmpty) ...[
          const SizedBox(height: 22),
          const SectionLabel('Restricted transfers (OpenAMP)'),
          const SizedBox(height: 8),
          _OampHistoryCard(xfers: _oamp),
        ],
        const SizedBox(height: 22),
        SecondaryButton(
          label: 'Sign an OpenAMP request',
          icon: Icons.draw,
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SignScreen())),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Restricted-transfer (OpenAMP) tracker — locally-tracked sent transfers, with
// a pending/confirmed chip, an explorer link, and a Bitcoin anchor-depth chip.
// openampd has no per-holder history endpoint, so the wallet follows its OWN
// sends until confirmed. Nothing is labelled final at 0-conf.
// ---------------------------------------------------------------------------
class _OampHistoryCard extends StatelessWidget {
  const _OampHistoryCard({required this.xfers});
  final List<OampTransfer> xfers;

  @override
  Widget build(BuildContext context) {
    final rows = xfers.reversed.toList();
    return AmbraCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(children: [for (final x in rows) _OampRow(x: x)]),
    );
  }
}

class _OampRow extends StatelessWidget {
  const _OampRow({required this.x});
  final OampTransfer x;

  Future<void> _open(BuildContext context) async {
    final url = Uri.parse(Backend.explorerTx(x.txid));
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } catch (_) {/* fall through to copy */}
    if (context.mounted) {
      Clipboard.setData(ClipboardData(text: url.toString()));
      ScaffoldMessenger.of(context).showSnackBar(ambraSnack('Explorer link copied'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = !x.confirmed;
    final when = DateTime.fromMillisecondsSinceEpoch(x.time).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${when.year}-${two(when.month)}-${two(when.day)} ${two(when.hour)}:${two(when.minute)}';
    final aidShort = x.recipientAid.length > 10 ? '${x.recipientAid.substring(0, 10)}…' : x.recipientAid;
    final status = pending
        ? 'pending, not final at 0-conf'
        : (x.anchorDepth != null ? 'Bitcoin anchor depth ${x.anchorDepth}' : 'confirmed, anchor depth pending');

    return InkWell(
      onTap: () => _open(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          _Badge(
            text: pending ? 'PENDING' : 'CONFIRMED',
            fg: pending ? AmbraColors.amber2 : AmbraColors.green,
            bg: pending ? const Color(0xFF241C0A) : const Color(0xFF10241A),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${x.txid.substring(0, 12)}…', style: AmbraText.mono.copyWith(fontSize: 12)),
              const SizedBox(height: 3),
              Text('$ts · to $aidShort', style: AmbraText.sub, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(status, style: AmbraText.sub.copyWith(color: pending ? AmbraColors.amber2 : AmbraColors.dim)),
            ]),
          ),
          const SizedBox(width: 10),
          Text('${formatAtoms(x.atoms, x.precision)} ${x.ticker}',
              style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontWeight: FontWeight.w700, fontSize: 14)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lightning history — payments/receives/settles written by the LN cards. This
// tab only READS the shared record; it renders defensively (any missing field
// degrades gracefully). Only the pure-LN rail is instant + final.
// ---------------------------------------------------------------------------
class _LnHistoryCard extends StatelessWidget {
  const _LnHistoryCard({required this.entries});
  final List<Map<String, dynamic>> entries;

  @override
  Widget build(BuildContext context) {
    // Newest first when a `time` field is present; otherwise keep insertion order.
    final rows = List<Map<String, dynamic>>.from(entries);
    rows.sort((a, b) {
      final ta = a['time'] is num ? (a['time'] as num).toInt() : 0;
      final tb = b['time'] is num ? (b['time'] as num).toInt() : 0;
      return tb.compareTo(ta);
    });
    return AmbraCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(children: [for (final e in rows) _LnRow(entry: e)]),
    );
  }
}

class _LnRow extends StatelessWidget {
  const _LnRow({required this.entry});
  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final kind = '${entry['kind'] ?? 'payment'}'.toLowerCase();
    final incoming = kind == 'receive' || kind == 'received' || kind == 'invoice' || kind == 'settle';
    final badge = incoming ? 'LN IN' : 'LN OUT';
    final color = incoming ? AmbraColors.green : AmbraColors.amber2;
    final bg = incoming ? const Color(0xFF10241A) : const Color(0xFF241C0A);

    // Amount: prefer explicit atoms + ticker, else msat, else omit.
    String amount = '';
    final ticker = entry['ticker'] is String ? entry['ticker'] as String : '';
    if (entry['atoms'] != null && ticker.isNotEmpty) {
      final prec = entry['precision'] is num ? (entry['precision'] as num).toInt() : 8;
      amount = '${formatAtoms('${entry['atoms']}', prec)} $ticker';
    } else if (entry['amount_msat'] != null) {
      final msat = BigInt.tryParse('${entry['amount_msat']}') ?? BigInt.zero;
      amount = '${(msat ~/ BigInt.from(1000))} sat';
    }

    final desc = entry['description'] is String && (entry['description'] as String).isNotEmpty
        ? entry['description'] as String
        : (incoming ? 'Lightning invoice' : 'Lightning payment');
    final t = entry['time'] is num ? (entry['time'] as num).toInt() : 0;
    String sub = desc;
    if (t > 0) {
      final w = DateTime.fromMillisecondsSinceEpoch(t).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      sub = '$desc · ${w.year}-${two(w.month)}-${two(w.day)} ${two(w.hour)}:${two(w.minute)}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        _Badge(text: badge, fg: color, bg: bg),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(incoming ? 'Received over Lightning' : 'Lightning payment',
                style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 3),
            Text(sub, style: AmbraText.sub, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (amount.isNotEmpty) ...[
          const SizedBox(width: 10),
          Text(amount, style: AmbraText.mono.copyWith(color: color, fontWeight: FontWeight.w700, fontSize: 14)),
        ],
      ]),
    );
  }
}

class _TxRowView extends StatelessWidget {
  const _TxRowView({required this.tx, required this.onRescued});
  final core.TxRow tx;
  final VoidCallback onRescued;

  core.AssetDelta? _top() {
    core.AssetDelta? top;
    BigInt best = BigInt.from(-1);
    for (final d in tx.deltas) {
      final v = (BigInt.tryParse(d.atoms) ?? BigInt.zero).abs();
      if (v > best) {
        best = v;
        top = d;
      }
    }
    return top;
  }

  @override
  Widget build(BuildContext context) {
    final (fg, bg, text) = _badgeFor(tx.kind);
    final top = _top();
    String amount = '';
    Color amountColor = AmbraColors.dim;
    if (top != null) {
      final label = SeqAssets.labelFor(top.assetId);
      final atoms = BigInt.tryParse(top.atoms) ?? BigInt.zero;
      final neg = atoms.isNegative;
      final formatted = formatAtoms(atoms.toString(), label.precision);
      amount = '${neg ? '' : '+'}$formatted ${label.ticker}';
      amountColor = neg ? AmbraColors.amber2 : AmbraColors.green;
    }
    final when = tx.height == null ? 'unconfirmed' : 'block ${tx.height}';

    return InkWell(
      onTap: () async {
        final rescuedTxid = await showTxDetail(context, tx);
        if (rescuedTxid != null && context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Rescue broadcast · ${rescuedTxid.substring(0, 16)}…')));
          onRescued();
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          _Badge(text: text, fg: fg, bg: bg),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${tx.txid.substring(0, 12)}…', style: AmbraText.mono.copyWith(fontSize: 12)),
              const SizedBox(height: 3),
              Text(when, style: AmbraText.sub),
            ]),
          ),
          const SizedBox(width: 10),
          Text(amount,
              style: AmbraText.mono.copyWith(color: amountColor, fontWeight: FontWeight.w700, fontSize: 14)),
        ]),
      ),
    );
  }
}

(Color, Color, String) _badgeFor(String kind) {
  switch (kind) {
    case 'incoming':
      return (AmbraColors.green, const Color(0xFF10241A), 'IN');
    case 'outgoing':
      return (AmbraColors.amber2, const Color(0xFF241C0A), 'OUT');
    case 'burn':
      return (AmbraColors.amber2, const Color(0xFF241C0A), 'BURN');
    case 'issuance':
    case 'reissuance':
      return (AmbraColors.blue, const Color(0xFF0D1F2A), 'ISSUE');
    default:
      return (AmbraColors.dim, AmbraColors.panelDeep, kind.toUpperCase());
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.fg, required this.bg});
  final String text;
  final Color fg;
  final Color bg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: fg.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
      );
}

// ---------------------------------------------------------------------------
// Transaction detail — full breakdown + explorer link, opened on tap.
// Returns a txid if a rescue was broadcast from here (caller refreshes).
// ---------------------------------------------------------------------------
Future<String?> showTxDetail(BuildContext context, core.TxRow tx) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) => _TxDetailSheet(tx: tx),
  );
}

String _kindTitle(String kind) {
  switch (kind) {
    case 'incoming':
      return 'Received';
    case 'outgoing':
      return 'Sent';
    case 'issuance':
      return 'Asset issuance';
    case 'reissuance':
      return 'Asset reissuance';
    case 'burn':
      return 'Burn';
    case 'redeposit':
      return 'Internal transfer';
    default:
      return 'Transaction';
  }
}

/// The network fee rendered in its REAL asset (Sequentia's any-asset fee market),
/// not a hardcoded "tSEQ". An empty fee_asset (older cached rows) falls back to
/// the policy asset.
String _feeText(core.TxRow tx) {
  final feeLabel = SeqAssets.labelFor(tx.feeAsset.isEmpty ? SeqAssets.policy : tx.feeAsset);
  return '${formatAtoms(tx.fee.toString(), feeLabel.precision)} ${feeLabel.ticker}';
}

String _fmtTime(BigInt? ts) {
  if (ts == null) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ts.toInt() * 1000).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class _TxDetailSheet extends StatelessWidget {
  const _TxDetailSheet({required this.tx});
  final core.TxRow tx;

  Future<void> _openExplorer(BuildContext context) async {
    final url = Uri.parse(Backend.explorerTx(tx.txid));
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } catch (_) {/* no browser / blocked — fall through to copy */}
    if (context.mounted) {
      Clipboard.setData(ClipboardData(text: url.toString()));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Couldn\'t open a browser; explorer link copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final (fg, bg, badge) = _badgeFor(tx.kind);
    final settled = tx.height != null;
    final showFee = tx.fee > BigInt.zero &&
        (tx.kind == 'outgoing' || tx.kind == 'burn' || tx.kind == 'issuance' || tx.kind == 'reissuance');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              _Badge(text: badge, fg: fg, bg: bg),
              const SizedBox(width: 12),
              Text(_kindTitle(tx.kind), style: AmbraText.h1),
            ]),
            const SizedBox(height: 18),
            AmbraCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(children: [
                _DetailRow('Status', settled ? 'Settled · block ${tx.height} (anchor-bound to Bitcoin)' : 'Pending; not yet in a block'),
                _DetailRow('Date', _fmtTime(tx.timestamp)),
                _DetailRow('Network', 'sequentia-testnet'),
                if (showFee) _DetailRow('Network fee', _feeText(tx)),
              ]),
            ),
            const SizedBox(height: 14),
            const SectionLabel('Amount'),
            const SizedBox(height: 8),
            AmbraCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(children: [for (final d in tx.deltas) _DeltaRow(delta: d)]),
            ),
            const SizedBox(height: 14),
            const SectionLabel('Transaction ID'),
            const SizedBox(height: 8),
            SelectableText(tx.txid, style: AmbraText.mono.copyWith(fontSize: 13)),
            const SizedBox(height: 16),
            SecondaryButton(label: 'View in explorer', icon: Icons.open_in_new, onPressed: () => _openExplorer(context)),
            const SizedBox(height: 10),
            SecondaryButton(
              label: 'Copy transaction id',
              icon: Icons.copy,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: tx.txid));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Transaction id copied')));
              },
            ),
            if (!settled) ...[
              const SizedBox(height: 10),
              PrimaryButton(
                label: 'Speed up / bump fee',
                icon: Icons.bolt,
                onPressed: () async {
                  final txid = await showRescueActions(context, tx);
                  if (txid != null && context.mounted) Navigator.of(context).pop(txid);
                },
              ),
            ],
            const SizedBox(height: 6),
            GhostButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
          ]),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 96, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: AmbraText.body)),
        ]),
      );
}

class _DeltaRow extends StatelessWidget {
  const _DeltaRow({required this.delta});
  final core.AssetDelta delta;
  @override
  Widget build(BuildContext context) {
    final label = SeqAssets.labelFor(delta.assetId);
    final atoms = BigInt.tryParse(delta.atoms) ?? BigInt.zero;
    final neg = atoms.isNegative;
    final amount = '${neg ? '' : '+'}${formatAtoms(atoms.toString(), label.precision)} ${label.ticker}';
    final approx = PriceService.instance.approx(label.ticker, atoms.toString(), label.precision);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label.ticker,
                style: const TextStyle(color: AmbraColors.txt, fontWeight: FontWeight.w600, fontSize: 14)),
            if (label.subtitle != null) ...[
              const SizedBox(height: 2),
              Text(label.subtitle!, style: AmbraText.sub, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ]),
        ),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          Text(amount,
              style: AmbraText.mono.copyWith(
                  color: neg ? AmbraColors.amber2 : AmbraColors.green, fontWeight: FontWeight.w700, fontSize: 14)),
          if (approx != null) ...[
            const SizedBox(height: 2),
            Text(approx, style: AmbraText.sub),
          ],
        ]),
      ]),
    );
  }
}
