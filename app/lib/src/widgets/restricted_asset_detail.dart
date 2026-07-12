import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/api_client.dart';
import '../data/config.dart';
import '../data/format.dart';
import '../data/openamp_service.dart';
import '../data/price_service.dart';
import '../data/wallet_repository.dart';
import '../theme/theme.dart';
import 'widgets.dart';

/// Compose the plain-language restriction legend from a restricted asset's
/// disclosure (spec 0.6/1.5(d)). No privileged framing: this is disclosure, one
/// row among equals. Mirrors the web wallet's `oampComposeLegend`.
List<String> restrictedLegend(OpenAmpAsset? a) {
  final parts = <String>['Restricted asset: every transfer needs the policy server co-signature.'];
  if (a == null) return parts;
  if (a.clawback) parts.add('Issuer clawback is disclosed and in force.');
  if (a.allowedCategories.isNotEmpty) parts.add('Only eligible, categorised holders may receive it.');
  if (a.lockinUntilHeight > 0) parts.add('Locked until Sequentia block ${a.lockinUntilHeight}.');
  return parts;
}

/// Open the disclosure detail view for a restricted [assetId]: the restriction
/// legend, a frozen banner, the read-only legacy-identity note, a terms-hash
/// link, and a Send affordance. Safe to call for any asset id (renders whatever
/// the enclave disclosed). Exposed so the balance row / receive tab can push it
/// without either owning this widget's internals.
Future<void> showRestrictedAssetDetail(BuildContext context, String assetId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AmbraColors.panel,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AmbraRadii.card))),
    builder: (_) => _RestrictedAssetDetail(assetId: assetId),
  );
}

class _RestrictedAssetDetail extends StatelessWidget {
  const _RestrictedAssetDetail({required this.assetId});
  final String assetId;

  Future<void> _openTerms(BuildContext context) async {
    final url = Uri.parse(Backend.explorerAsset(assetId));
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
    final svc = OpenAmpService.instance;
    final asset = svc.assetFor(assetId);
    final label = SeqAssets.labelFor(assetId);
    final frozen = svc.isFrozen;
    final legend = restrictedLegend(asset);
    final terms = asset?.termsHash ?? '';

    // The held balance, if any (already fetched into the enclave balance list).
    String? heldAmount;
    String? heldApprox;
    for (final b in svc.balances) {
      if (b.assetId == assetId) {
        heldAmount = '${formatAtoms(b.atoms, label.precision)} ${label.ticker}';
        heldApprox = PriceService.instance.approx(label.ticker, b.atoms, label.precision);
      }
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label.ticker, style: AmbraText.h1),
                  if (label.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(label.subtitle!, style: AmbraText.sub),
                  ],
                ]),
              ),
              if (heldAmount != null)
                Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                  Text(heldAmount, style: AmbraText.mono.copyWith(color: AmbraColors.txt, fontSize: 15)),
                  if (heldApprox != null) ...[
                    const SizedBox(height: 2),
                    Text(heldApprox, style: AmbraText.sub),
                  ],
                ]),
            ]),
            const SizedBox(height: 16),
            if (frozen) ...[
              WarnCallout(
                'This account is frozen by the issuer. Transfers of ${label.ticker} will be refused '
                'until it is unfrozen.',
              ),
              const SizedBox(height: 14),
            ],
            const SectionLabel('What this means'),
            const SizedBox(height: 8),
            AmbraCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final line in legend)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2, right: 8),
                        child: Icon(Icons.circle, size: 6, color: AmbraColors.amber),
                      ),
                      Expanded(child: Text(line, style: AmbraText.body)),
                    ]),
                  ),
                const SizedBox(height: 4),
                const Text('Self-custodial subject to disclosed clawback and co-sign powers.',
                    style: AmbraText.sub),
              ]),
            ),
            if (terms.isNotEmpty) ...[
              const SizedBox(height: 14),
              const SectionLabel('Terms'),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => _openTerms(context),
                child: Row(children: [
                  Expanded(
                    child: Text('${terms.substring(0, terms.length >= 16 ? 16 : terms.length)}…',
                        style: AmbraText.mono.copyWith(color: AmbraColors.blue)),
                  ),
                  const Icon(Icons.open_in_new, size: 16, color: AmbraColors.blue),
                ]),
              ),
            ],
            const SizedBox(height: 14),
            // Read-only legacy m/3/0 identity note (disclosure only; no migration).
            const AmbraCard(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Legacy identity', style: AmbraText.label),
                SizedBox(height: 6),
                Text(
                  'Restricted balances are held under this wallet\'s current identity (m/5/0). Any '
                  'balance stranded under an earlier m/3/0 identity is not spendable from here and is '
                  'not moved automatically; migrating it needs the platform.',
                  style: AmbraText.sub,
                ),
              ]),
            ),
            const SizedBox(height: 18),
            if (heldAmount != null)
              PrimaryButton(
                label: frozen ? 'Frozen — cannot send' : 'Send ${label.ticker}',
                icon: Icons.north_east,
                onPressed: frozen
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        showRestrictedSend(context, assetId);
                      },
              ),
            const SizedBox(height: 6),
            GhostButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
          ]),
        ),
      ),
    );
  }
}

/// Open the restricted-asset send review for [assetId], optionally prefilled with
/// a recipient account id and an atom amount (used by the `ambra://oamp-send`
/// deep link, spec 1.9 WW-3). The verified prepare -> decode -> confirm ->
/// complete path (spec 0.4(3)) takes over from here; nothing is submitted until
/// the user confirms.
Future<String?> showRestrictedSend(
  BuildContext context,
  String assetId, {
  String? toAid,
  String? atoms,
}) {
  return Navigator.of(context, rootNavigator: true).push<String>(
    MaterialPageRoute(
      builder: (_) => RestrictedSendScreen(assetId: assetId, toAid: toAid, atomsStr: atoms),
    ),
  );
}

/// A self-contained restricted-transfer flow: collect (or accept prefilled)
/// recipient + amount, VERIFY the draft on-device (recompute every enclave
/// sighash, refuse on mismatch), show the decoded effects, then sign and
/// complete under payment auth. Uses only [OpenAmpService]; never blind-signs.
class RestrictedSendScreen extends StatefulWidget {
  const RestrictedSendScreen({super.key, required this.assetId, this.toAid, this.atomsStr});
  final String assetId;
  final String? toAid;
  final String? atomsStr;

  @override
  State<RestrictedSendScreen> createState() => _RestrictedSendScreenState();
}

class _RestrictedSendScreenState extends State<RestrictedSendScreen> {
  final _to = TextEditingController();
  final _amount = TextEditingController();

  bool _busy = false;
  String? _error;
  OpenampPrepared? _prepared;

  int get _precision => SeqAssets.labelFor(widget.assetId).precision;
  String get _ticker => SeqAssets.labelFor(widget.assetId).ticker;

  @override
  void initState() {
    super.initState();
    if (widget.toAid != null) _to.text = widget.toAid!;
    if (widget.atomsStr != null && BigInt.tryParse(widget.atomsStr!) != null) {
      _amount.text = formatAtoms(widget.atomsStr!, _precision);
    }
  }

  @override
  void dispose() {
    _to.dispose();
    _amount.dispose();
    super.dispose();
  }

  BigInt? _atoms() => parseAtoms(_amount.text, _precision);

  Future<void> _review() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final aid = _to.text.trim();
      if (aid.isEmpty) throw Exception('enter the recipient account id (AID)');
      final atoms = _atoms();
      if (atoms == null || atoms <= BigInt.zero) throw Exception('enter a valid amount');
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final prepared = await OpenAmpService.instance.prepareTransfer(
        mnemonic: m,
        assetId: widget.assetId,
        recipientAid: aid,
        atoms: atoms,
      );
      if (!mounted) return;
      setState(() {
        _prepared = prepared;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e, pullToRefresh: false);
      });
    }
  }

  Future<void> _confirm() async {
    final prepared = _prepared;
    if (prepared == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await WalletRepository.instance.requirePaymentAuth();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Authentication failed or cancelled; nothing was sent.';
        });
        return;
      }
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      final txid = await OpenAmpService.instance.completePrepared(prepared, m);
      if (!mounted) return;
      Navigator.of(context).pop(txid);
      ScaffoldMessenger.of(context)
          .showSnackBar(ambraSnack('Transfer broadcast · ${txid.substring(0, txid.length >= 16 ? 16 : txid.length)}…'));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e, pullToRefresh: false);
      });
    }
  }

  List<Widget> _effectRows() {
    final p = _prepared;
    if (p == null) return const [];
    final e = p.effects;
    final rows = <Widget>[];
    final spent = e.myInputsSpent.length;
    rows.add(_kv('Spending', '$spent of your $_ticker enclave ${spent == 1 ? 'output' : 'outputs'}'));
    if (p.convertAtoms != null && p.convertAtoms! > BigInt.zero) {
      rows.add(_kv('Fee (converted)', '${formatAtoms(p.convertAtoms!.toString(), _precision)} $_ticker (in-asset)'));
    }
    for (final o in e.outputs) {
      if (o.isFee) continue;
      final amt = (o.value != null && o.asset != null)
          ? '${formatAtoms(o.value!.toString(), SeqAssets.labelFor(o.asset!).precision)} ${SeqAssets.labelFor(o.asset!).ticker}'
          : 'confidential';
      rows.add(_kv('Output', '$amt · ${o.mine ? 'to you (change/receipt)' : 'to recipient'}'));
    }
    if (e.anyConfidential) {
      rows.add(_kv('Warning', 'A confidential output was decoded; restricted spends must be transparent.'));
    }
    return rows;
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(k, style: AmbraText.sub)),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: AmbraText.body)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final reviewing = _prepared != null;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(reviewing ? 'Confirm transfer' : 'Send $_ticker', style: AmbraText.title),
      ),
      body: AmbraBackground(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
          if (!reviewing) ...[
            AmbraField(label: 'Recipient account id (AID)', controller: _to, hint: 'the recipient\'s OpenAMP AID', mono: true),
            const SizedBox(height: 16),
            AmbraField(label: 'Amount ($_ticker)', controller: _amount, hint: '0.0'),
            const SizedBox(height: 20),
            PrimaryButton(label: 'Review transfer', icon: Icons.fact_check, busy: _busy, onPressed: _busy ? null : _review),
          ] else ...[
            AmbraCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(children: [
                _kv('To', '${_to.text.trim().substring(0, _to.text.trim().length >= 12 ? 12 : _to.text.trim().length)}…'),
                ..._effectRows(),
              ]),
            ),
            const SizedBox(height: 12),
            const Text('These effects were recomputed and verified on-device. Nothing is signed until you confirm.',
                style: AmbraText.sub),
            const SizedBox(height: 18),
            PrimaryButton(label: 'Confirm and send', icon: Icons.check, busy: _busy, onPressed: _busy ? null : _confirm),
            const SizedBox(height: 6),
            GhostButton(label: 'Back', onPressed: _busy ? null : () => setState(() => _prepared = null)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AmbraColors.red)),
          ],
        ]),
      ),
    );
  }
}
