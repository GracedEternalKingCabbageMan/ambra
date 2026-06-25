import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rust/api.dart' as core;
import '../data/config.dart';
import '../data/format.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});
  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  List<core.TxRow>? _txs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
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
      if (mounted) setState(() => _txs = txs);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final txs = _txs;
    return RefreshIndicator(
      onRefresh: _load,
      color: AmbraColors.amber,
      backgroundColor: AmbraColors.panel,
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 24), children: [
        const Text('History', style: AmbraText.h1),
        const SizedBox(height: 16),
        if (_error != null)
          AmbraCard(child: Text('Could not load history: $_error', style: const TextStyle(color: AmbraColors.red)))
        else if (txs == null)
          const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator(color: AmbraColors.amber)))
        else if (txs.isEmpty)
          const AmbraCard(child: Text('No transactions yet.', style: AmbraText.muted))
        else
          AmbraCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(children: [for (final t in txs) _TxRowView(tx: t)]),
          ),
      ]),
    );
  }
}

class _TxRowView extends StatelessWidget {
  const _TxRowView({required this.tx});
  final core.TxRow tx;

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
      onTap: () {
        Clipboard.setData(ClipboardData(text: tx.txid));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transaction id copied')));
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
