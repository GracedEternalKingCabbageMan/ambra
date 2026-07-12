import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/config.dart';
import '../data/format.dart';
import '../data/lightning_service.dart';
import '../data/lsp_client.dart';
import '../data/wallet_cache.dart';
import '../theme/theme.dart';
import 'widgets.dart';

/// The general (non-DEX) Lightning pay/receive cards — the mobile twins of the web wallet's
/// "Pay a Lightning invoice" / "Receive over Lightning" cards (index.html initLnSendReceive). They
/// drive the user's OWN per-asset hosted node via [LightningService.payInvoice] / [createInvoice].
/// When Lightning is not deployed for the build ([LightningService.configured] false) they render a
/// muted dormant state and never crash — exactly as the on-chain-only build behaves.

/// One selectable paying/receiving asset (the user's held assets — each can run a hosted LN node).
class LnAssetOption {
  const LnAssetOption(this.id, this.ticker, this.precision);
  final String id;
  final String ticker;
  final int precision;
}

/// Load the assets the wallet holds (from the shared last-known cache) as LN pay/receive options.
/// A per-asset node is single-asset, so only held assets are offerable. Returns an empty list when
/// nothing is held — the cards then show an honest "no assets yet" note rather than a dead dropdown.
Future<List<LnAssetOption>> loadLnAssetOptions() async {
  final out = <LnAssetOption>[];
  final seen = <String>{};
  final held = await WalletCache.loadBalances();
  if (held != null) {
    for (final b in held) {
      final atoms = BigInt.tryParse(b.atoms) ?? BigInt.zero;
      if (atoms <= BigInt.zero || !seen.add(b.assetId)) continue;
      final l = SeqAssets.labelFor(b.assetId);
      out.add(LnAssetOption(b.assetId, l.ticker, l.precision));
    }
  }
  return out;
}

/// A muted card shown when Lightning is not deployed for this build (dormant), so the surfaces that
/// mount the LN cards degrade cleanly instead of hiding capability without explanation.
class _LnDormantCard extends StatelessWidget {
  const _LnDormantCard({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) {
    return AmbraCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionLabel(title),
        const SizedBox(height: 10),
        const Text('Lightning is not enabled on this node yet.', style: AmbraText.sub),
      ]),
    );
  }
}

/// A theme-styled asset dropdown shared by both cards.
class _LnAssetDropdown extends StatelessWidget {
  const _LnAssetDropdown({required this.options, required this.value, required this.onChanged});
  final List<LnAssetOption> options;
  final String? value;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AmbraColors.panelDeep,
        border: Border.all(color: AmbraColors.line),
        borderRadius: BorderRadius.circular(AmbraRadii.input),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: AmbraColors.panel,
          iconEnabledColor: AmbraColors.dim,
          style: const TextStyle(color: AmbraColors.txt, fontSize: 15, fontWeight: FontWeight.w600),
          items: [
            for (final o in options) DropdownMenuItem(value: o.id, child: Text(o.ticker)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Receive over Lightning
// ---------------------------------------------------------------------------
class LnReceiveCard extends StatefulWidget {
  const LnReceiveCard({super.key});
  @override
  State<LnReceiveCard> createState() => _LnReceiveCardState();
}

class _LnReceiveCardState extends State<LnReceiveCard> {
  final _amount = TextEditingController();
  List<LnAssetOption> _assets = const [];
  String? _asset;
  bool _busy = false;
  String? _status; // neutral progress / success line
  String? _error;
  String? _bolt11;

  @override
  void initState() {
    super.initState();
    _loadAssets();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _loadAssets() async {
    final a = await loadLnAssetOptions();
    if (!mounted) return;
    setState(() {
      _assets = a;
      _asset = a.isNotEmpty ? a.first.id : null;
    });
  }

  LnAssetOption? get _selected {
    for (final a in _assets) {
      if (a.id == _asset) return a;
    }
    return _assets.isEmpty ? null : _assets.first;
  }

  Future<void> _create() async {
    final sel = _selected;
    if (sel == null) return;
    final atoms = parseAtoms(_amount.text, sel.precision);
    if (atoms == null || atoms <= BigInt.zero) {
      setState(() => _error = 'Enter an amount.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _bolt11 = null;
      _status = 'Bringing your ${sel.ticker} node online…';
    });
    try {
      final NodeInvoice inv =
          await LightningService.instance.createInvoice(asset: sel.id, amount: atoms.toInt(), description: 'Receive ${sel.ticker}');
      final b11 = inv.bolt11;
      if (b11 == null || b11.isEmpty) throw Exception('no invoice returned');
      // Record the incoming invoice so the History "Lightning" card shows it. The
      // app has no settlement listener yet, so this records at creation (an
      // incoming record — never labelled final since it isn't a pure-LN swap
      // settle); tracking is best-effort and never blocks the invoice itself.
      try {
        await WalletCache.addLnHistory({
          'kind': 'invoice',
          'ticker': sel.ticker,
          'precision': sel.precision,
          'atoms': atoms.toString(),
          'description': 'Receive ${sel.ticker}',
          'time': DateTime.now().millisecondsSinceEpoch,
          'payment_hash': inv.paymentHash,
          'bolt11': b11,
        });
      } catch (_) {/* history tracking is best-effort */}
      if (mounted) {
        setState(() {
          _bolt11 = b11;
          _status = 'Invoice ready — share it to receive ${formatAtoms(atoms.toString(), sel.precision)} ${sel.ticker}.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not create the invoice: ${_pretty(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!LightningService.instance.configured) return const _LnDormantCard(title: 'Receive over Lightning');
    return AmbraCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionLabel('Receive over Lightning'),
        const SizedBox(height: 8),
        const Text('Generate a Lightning invoice paid into your hosted node. Your device must be online to sign it.',
            style: AmbraText.sub),
        const SizedBox(height: 12),
        if (_assets.isEmpty)
          const Text('You hold no assets to receive over Lightning yet.', style: AmbraText.muted)
        else ...[
          Row(children: [
            Expanded(child: _LnAssetDropdown(options: _assets, value: _asset, onChanged: (v) => setState(() => _asset = v))),
            const SizedBox(width: 10),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: AmbraText.mono.copyWith(color: AmbraColors.txt),
                decoration: InputDecoration(
                  hintText: 'amount',
                  hintStyle: const TextStyle(color: AmbraColors.dim),
                  filled: true,
                  fillColor: AmbraColors.panelDeep,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AmbraRadii.input),
                    borderSide: const BorderSide(color: AmbraColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AmbraRadii.input),
                    borderSide: const BorderSide(color: AmbraColors.amber),
                  ),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          PrimaryButton(label: 'Create invoice', icon: Icons.bolt, busy: _busy, onPressed: _busy ? null : _create),
          if (_status != null && _error == null) ...[
            const SizedBox(height: 10),
            Text(_status!, style: AmbraText.sub),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: AmbraColors.red)),
          ],
          if (_bolt11 != null) ...[
            const SizedBox(height: 10),
            SelectableText(_bolt11!, style: AmbraText.mono.copyWith(fontSize: 11)),
            const SizedBox(height: 8),
            SecondaryButton(
              label: 'Copy invoice',
              icon: Icons.copy,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _bolt11!));
                ScaffoldMessenger.of(context).showSnackBar(ambraSnack('Invoice copied.'));
              },
            ),
          ],
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Pay a Lightning invoice
// ---------------------------------------------------------------------------
class LnPayCard extends StatefulWidget {
  const LnPayCard({super.key, this.invoice});

  /// An optional prefilled BOLT11 (e.g. from a scanned QR routed here by [ScanScreen]).
  final String? invoice;
  @override
  State<LnPayCard> createState() => _LnPayCardState();
}

class _LnPayCardState extends State<LnPayCard> {
  final _bolt11 = TextEditingController();
  List<LnAssetOption> _assets = const [];
  String? _asset;
  bool _busy = false;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.invoice != null) _bolt11.text = widget.invoice!.trim();
    _loadAssets();
  }

  @override
  void dispose() {
    _bolt11.dispose();
    super.dispose();
  }

  Future<void> _loadAssets() async {
    final a = await loadLnAssetOptions();
    if (!mounted) return;
    setState(() {
      _assets = a;
      _asset = a.isNotEmpty ? a.first.id : null;
    });
  }

  Future<void> _pay() async {
    final asset = _asset;
    if (asset == null) return;
    final bolt11 = _bolt11.text.trim();
    if (bolt11.isEmpty) {
      setState(() => _error = 'Paste an invoice.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Paying over Lightning…';
    });
    try {
      final NodePayResult r = await LightningService.instance.payInvoice(bolt11: bolt11, asset: asset);
      if (!r.paid) throw Exception('payment did not complete');
      // Record the outgoing payment so the History "Lightning" card shows it.
      // Best-effort — tracking never blocks a payment that already succeeded.
      try {
        LnAssetOption? sel;
        for (final a in _assets) {
          if (a.id == asset) {
            sel = a;
            break;
          }
        }
        final entry = <String, dynamic>{
          'kind': 'payment',
          'description': 'Lightning payment',
          'time': DateTime.now().millisecondsSinceEpoch,
          'preimage': r.preimage,
          'destination': r.destination,
        };
        final msat = r.amountMsat == null ? null : BigInt.tryParse(r.amountMsat!);
        if (sel != null) {
          entry['ticker'] = sel.ticker;
          entry['precision'] = sel.precision;
          if (msat != null) entry['atoms'] = (msat ~/ BigInt.from(1000)).toString();
        } else if (r.amountMsat != null) {
          entry['amount_msat'] = r.amountMsat;
        }
        await WalletCache.addLnHistory(entry);
      } catch (_) {/* history tracking is best-effort */}
      if (mounted) {
        setState(() {
          _bolt11.clear();
          final pre = r.preimage;
          _status = pre != null && pre.length >= 16 ? 'Paid · preimage ${pre.substring(0, 16)}…' : 'Paid';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Payment failed: ${_pretty(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!LightningService.instance.configured) return const _LnDormantCard(title: 'Pay a Lightning invoice');
    return AmbraCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionLabel('Pay a Lightning invoice'),
        const SizedBox(height: 8),
        const Text('Your hosted node pays the invoice and your device co-signs. Pick the asset to pay from.',
            style: AmbraText.sub),
        const SizedBox(height: 12),
        if (_assets.isEmpty)
          const Text('You hold no assets to pay over Lightning yet.', style: AmbraText.muted)
        else ...[
          _LnAssetDropdown(options: _assets, value: _asset, onChanged: (v) => setState(() => _asset = v)),
          const SizedBox(height: 10),
          TextField(
            controller: _bolt11,
            maxLines: 3,
            style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontSize: 12),
            decoration: InputDecoration(
              hintText: 'lnbc… — paste a BOLT11 invoice',
              hintStyle: const TextStyle(color: AmbraColors.dim),
              filled: true,
              fillColor: AmbraColors.panelDeep,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AmbraRadii.input),
                borderSide: const BorderSide(color: AmbraColors.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AmbraRadii.input),
                borderSide: const BorderSide(color: AmbraColors.amber),
              ),
            ),
          ),
          const SizedBox(height: 12),
          PrimaryButton(label: 'Pay invoice', icon: Icons.bolt, busy: _busy, onPressed: _busy ? null : _pay),
          if (_status != null && _error == null) ...[
            const SizedBox(height: 10),
            Text(_status!, style: AmbraText.sub),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: AmbraColors.red)),
          ],
        ],
      ]),
    );
  }
}

/// A full-screen wrapper around [LnPayCard] with an optional prefilled invoice, so a scanned BOLT11
/// can be routed straight to the pay card without editing the (un-owned) Send screen.
class LnPayScreen extends StatelessWidget {
  const LnPayScreen({super.key, this.invoice});
  final String? invoice;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbraBackground(
        child: SafeArea(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
              child: Row(children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: AmbraColors.txt),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const Text('Pay over Lightning', style: AmbraText.h1),
              ]),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [LnPayCard(invoice: invoice)],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

String _pretty(Object e) => e.toString().replaceFirst('Exception: ', '');
