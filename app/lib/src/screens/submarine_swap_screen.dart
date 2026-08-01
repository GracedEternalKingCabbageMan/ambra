import 'package:flutter/material.dart';

import '../data/config.dart';
import '../data/format.dart';
import '../data/seqob_client.dart';
import '../data/subswap_service.dart';
import '../data/trade_slots.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// The peer-to-peer SUBMARINE swap wizard — the mobile twin of the web wallet's reviewSubmarineP2P +
/// startSubswapP2P (swap.js/subswap.js). A rail crossing on the BTC leg settled DIRECTLY with an
/// interactive maker (no LSP in the value path, so no bridge fee): a BUY pays Bitcoin over Lightning and
/// receives the asset in a single on-chain HTLC bound to the SAME secret; a SELL funds the asset HTLC and
/// receives Bitcoin over Lightning. One on-chain HTLC, one T_seq gate.
///
/// Fund-safety (all in [SubswapService], the verified port): the BUY VERIFIES the asset is locked to the
/// taker's OWN key on H (asset/amount/locktime), that the funding output pays the HTLC P2SH, and that it
/// is anchor-buried, ALL before it pays — and PERSISTS P + the leg before claiming. The SELL never reveals
/// the secret without capturing the Bitcoin. This screen is the review + drive surface over that service.
class SubmarineSwapScreen extends StatefulWidget {
  const SubmarineSwapScreen({super.key, required this.buy, required this.offer, this.recordId});

  /// true = a BUY (pay BTC over Lightning, receive the asset on-chain); false = a SELL.
  final bool buy;

  /// The resting cross offer to take (whole-offer — a submarine take is the whole resting offer).
  final CrossOffer offer;

  /// A specific persisted record to open (the composer's in-flight card taps pass it). Null = the
  /// first non-terminal submarine record, if any (multi-record store).
  final String? recordId;

  @override
  State<SubmarineSwapScreen> createState() => _SubmarineSwapScreenState();
}

class _SubmarineSwapScreenState extends State<SubmarineSwapScreen> {
  String _phase = 'review'; // review | running | done | error | inflight
  String _status = '';
  String? _error;
  SubswapRecord? _rec;

  String get _tk => SeqAssets.labelFor(widget.offer.seqAsset).ticker;
  int get _aprec => SeqAssets.labelFor(widget.offer.seqAsset).precision;

  @override
  void initState() {
    super.initState();
    _checkInFlight();
  }

  /// Adopt the record this screen was opened FOR (a tapped in-flight card passes its id), else surface
  /// a matching live record so it resumes rather than being duplicated. With the multi-record store a
  /// second submarine no longer blocks the rail — the shared trade-slot bound gates dispatch instead.
  Future<void> _checkInFlight() async {
    SubswapRecord? rec;
    try {
      if (widget.recordId != null && widget.recordId!.isNotEmpty) {
        rec = await SubswapStore.load(id: widget.recordId);
      } else {
        // No specific record: adopt a live record for THIS offer, if one exists (never start a
        // duplicate take of the same offer from the review).
        final all = await SubswapStore.loadAll();
        for (final r in all) {
          if (!r.terminal && r.offerId == widget.offer.offerId) {
            rec = r;
            break;
          }
        }
      }
    } catch (_) {
      // loadAll() FAILED SAFE (guard closed): we cannot READ or DECODE the store, but MUST NOT start a
      // fresh record over it. The corrupt vs transient split below decides which surface to show.
      rec = null;
    }
    if (!mounted) return;
    if (rec != null && !rec.terminal) {
      setState(() {
        _rec = rec;
        _phase = 'inflight';
      });
    } else if (SubswapStore.corrupt) {
      // Corrupt/undrivable material is pending (a whole-blob corrupt store, an undecodable entry, or an
      // unknown-state record): surface the recovery affordance — it never self-heals, and the composer's
      // corrupt banner routes here expecting it (Task 2). Healthy records elsewhere stay drivable.
      setState(() => _phase = 'corrupt');
    }
  }

  Future<void> _start() async {
    // Belt-and-suspenders + SELF-HEAL (Task 1): the synchronous guard is authoritative only once cold-start
    // priming has run (shell's AWAITED SubswapStore.primeInFlight). Re-run an AUTHORITATIVE load here when the
    // guard is UNPRIMED (fast cold start) OR the last read/decode ERRORED (SubswapStore.primeErrored) — a
    // transient cold-start read failure fails the guard SAFE (in-flight), which would otherwise leave an IDLE
    // wallet blocked with the false 'swap in progress' until some unrelated load succeeded. A now-succeeding
    // read HEALS the guard right at this choke point (an idle wallet becomes startable again); a still-failing
    // read fails safe again inside load() (the guard below blocks), and a DURABLE decode error surfaces the
    // corrupt-recovery view instead of an unbounded block.
    if (!SubswapStore.primed || SubswapStore.primeErrored) {
      try {
        await SubswapStore.loadAll();
      } catch (_) {/* loadAll() failed safe (guard closed); the guard(s) below handle transient vs corrupt */}
      if (!mounted) return;
    }
    // A DURABLE corrupt record can never heal by retrying — surface the honest recovery affordance rather
    // than the false 'in progress' block (Task 2).
    if (SubswapStore.corrupt) {
      setState(() => _phase = 'corrupt');
      return;
    }
    // SHARED SLOT GATE at the dispatch choke point (web tradeSlotsFree): records upsert by per-record id
    // so a fresh save can no longer OVERWRITE a live record's H/P/redeem/txid — the fund-safety the old
    // single-slot hasInFlight refusal enforced is now structural. What remains is the bounded
    // concurrent-trade count, refused with the web's honest message.
    final refusal = await TradeSlots.refusalIfFull();
    if (!mounted) return;
    if (refusal != null) {
      setState(() {
        _phase = 'error';
        _error = refusal;
      });
      return;
    }
    setState(() {
      _phase = 'running';
      _error = null;
      _status = 'Starting…';
    });
    final rec = SubswapRecord(
      buy: widget.buy,
      state: SubState.starting,
      asset: widget.offer.seqAsset,
      assetAtoms: widget.offer.assetAtoms, // whole-offer: a submarine take is the whole resting offer
      btcSats: widget.offer.btcSats,
      offerId: widget.offer.offerId,
      makerPubkey: widget.offer.makerPubkey,
    );
    await SubswapStore.save(rec);
    await _drive(rec);
  }

  Future<void> _resume() async {
    setState(() {
      _phase = 'running';
      _error = null;
      _status = 'Resuming your swap…';
    });
    try {
      await SubswapService.resume(onStep: _onStep);
      final rec = _rec != null ? await SubswapStore.load(id: _rec!.id) : await SubswapStore.load();
      if (!mounted) return;
      setState(() {
        _rec = rec;
        _phase = (rec == null || rec.state == SubState.settled || rec.state == SubState.refunded) ? 'done' : 'inflight';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = 'error';
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  void _onStep(String s) {
    if (mounted) setState(() => _status = s);
  }

  Future<void> _drive(SubswapRecord rec) async {
    try {
      final done = widget.buy
          ? await SubswapService.runReverseBuy(rec, onStep: _onStep)
          : await SubswapService.runSubmarineSell(rec, onStep: _onStep);
      if (!mounted) return;
      setState(() {
        _rec = done;
        _phase = 'done';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = 'error';
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(widget.buy ? 'Submarine buy' : 'Submarine sell', style: AmbraText.title),
      ),
      body: AmbraBackground(
        child: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: _body()),
        ),
      ),
    );
  }

  List<Widget> _body() {
    switch (_phase) {
      case 'running':
        return _runningView();
      case 'done':
        return _doneView();
      case 'error':
        return _errorView();
      case 'inflight':
        return _inflightView();
      case 'corrupt':
        return _corruptView();
      default:
        return _reviewView();
    }
  }

  List<Widget> _reviewView() {
    final assetStr = '${formatAtoms(widget.offer.assetAtoms.toString(), _aprec)} $_tk';
    final btcStr = '${formatAtoms(widget.offer.btcSats.toString(), 8)} BTC';
    final rows = widget.buy
        ? <List<String>>[
            ['Route', 'Peer-to-peer submarine · you pay Bitcoin over Lightning and the maker locks the $_tk in a '
                'single on-chain HTLC bound to the SAME secret. No bridge, no bridge fee — the service is not in the value path.'],
            ['Direction', 'Buy $_tk with Bitcoin over Lightning · receive $_tk on-chain'],
            ['You pay', btcStr],
            ['You receive', assetStr],
            ['Fund-safety', 'Your device VERIFIES the on-chain $_tk is locked to YOUR key on the secret hash (right '
                'asset, amount, timeout), that the invoice it pays is bound to the SAME secret hash and price, and that '
                'the $_tk is anchor-buried under Bitcoin — ALL before it pays. The only way to learn the secret is to pay.'],
            ['Finality', 'Anchored to Bitcoin (reverts only if Bitcoin reverts), so not the instant finality of a pure-Lightning swap.'],
            ['If it stalls', 'Nothing is lost · you never pay until the $_tk HTLC is verified + anchor-buried, and once paid you claim it before its timeout.'],
          ]
        : <List<String>>[
            ['Route', 'Peer-to-peer submarine · you fund the $_tk in a single on-chain HTLC and receive Bitcoin over '
                'Lightning on the SAME secret. No bridge, no bridge fee.'],
            ['Direction', 'Sell $_tk on-chain · receive Bitcoin over Lightning'],
            ['You sell', assetStr],
            ['You receive', btcStr],
            ['Fund-safety', 'You receive the Bitcoin the instant you settle your held Lightning invoice with the '
                'secret — which is also what reveals it to the maker. You never reveal the secret without capturing the Bitcoin.'],
            ['Finality', 'The Bitcoin arrives over Lightning; the $_tk leg is a single on-chain HTLC.'],
            ['If it stalls', 'Nothing is lost · if the maker never pays your invoice, you reclaim the $_tk after its on-chain timeout.'],
          ];
    return [
      const Text('A submarine take settles the WHOLE resting offer, bound by one secret.', style: AmbraText.sub),
      const SizedBox(height: 16),
      AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final kv in rows) _kv(kv[0], kv[1]),
        ]),
      ),
      const SizedBox(height: 18),
      PrimaryButton(
        label: widget.buy ? 'Buy over Lightning' : 'Sell over Lightning',
        icon: Icons.bolt,
        onPressed: _start,
      ),
      const SizedBox(height: 8),
      GhostButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
    ];
  }

  List<Widget> _runningView() => [
        const SizedBox(height: 40),
        const Center(child: CircularProgressIndicator(color: AmbraColors.amber)),
        const SizedBox(height: 20),
        Center(child: Text(_status, textAlign: TextAlign.center, style: AmbraText.body)),
        const SizedBox(height: 12),
        const Center(
          child: Text('Keep the app open until this completes. It is safe to resume if interrupted.',
              textAlign: TextAlign.center, style: AmbraText.sub),
        ),
      ];

  List<Widget> _doneView() {
    final rec = _rec;
    final settled = rec != null && rec.state == SubState.settled;
    final refunded = rec != null && rec.state == SubState.refunded;
    return [
      AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(settled ? Icons.check_circle : Icons.info_outline,
                color: settled ? AmbraColors.green : AmbraColors.amber, size: 20),
            const SizedBox(width: 8),
            Text(settled ? 'Swap settled' : (refunded ? 'Refunded' : 'In progress'), style: AmbraText.title),
          ]),
          const SizedBox(height: 12),
          Text(
            settled
                ? (widget.buy
                    ? 'You bought $_tk over Lightning, anchor-bound to Bitcoin.'
                    : 'You received Bitcoin over Lightning.')
                : refunded
                    ? 'The maker never paid, so your $_tk was reclaimed via its on-chain timeout.'
                    : (rec?.detail.isNotEmpty == true ? rec!.detail : 'Your swap is still settling; reopen to resume.'),
            style: AmbraText.sub,
          ),
        ]),
      ),
      const SizedBox(height: 16),
      PrimaryButton(label: 'Done', icon: Icons.check, onPressed: () => Navigator.of(context).pop()),
    ];
  }

  List<Widget> _errorView() => [
        AmbraCard(child: Text(_error ?? 'The swap could not complete.', style: const TextStyle(color: AmbraColors.red))),
        const SizedBox(height: 16),
        // A record may still be resumable (P learned / asset funded); offer resume before giving up.
        SecondaryButton(label: 'Resume', icon: Icons.refresh, onPressed: _resume),
        const SizedBox(height: 8),
        GhostButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
      ];

  List<Widget> _inflightView() {
    final rec = _rec;
    // ROUND 8: a stuck SELL 'funding' record (broadcast intent set but nothing landed) can never auto-clear
    // and, being non-corrupt, has no other escape — offer the guarded, fund-safe manual abandon. It is a
    // candidate ONLY when it is a SELL still in 'funding' with legTxid + seqFundTxid empty (not yet settling).
    // ROUND 12 (fully clock-free): there is NO wall-clock age gate on the offer anymore. The authoritative
    // on-chain HTLC scan gates entirely on a CLOCK-FREE tip-HEIGHT proof ([scanHtlcForAbandon] — an empty scan
    // is only trusted once the tip is ~240 blocks past the broadcast height); until then the scan reads as
    // UNREADABLE and [confirmAbandonUnfundedSell] tells the user it could not verify yet, keeping it resumable.
    // The scan + fresh reload in [abandonUnfundedSell] are the final gates.
    final canAbandon = rec != null && SubswapService.canAbandonFunding(rec);
    return [
      AmbraCard(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.warning_amber_rounded, color: AmbraColors.amber, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                canAbandon
                    ? 'You already have a rail-crossing swap in progress. Resume it before starting another — or, if '
                        'nothing was funded, abandon it to free this rail.'
                    : 'You already have a rail-crossing swap in progress. Resume it before starting another.',
                style: AmbraText.sub),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      PrimaryButton(label: 'Resume swap', icon: Icons.play_arrow, onPressed: _resume),
      const SizedBox(height: 8),
      if (canAbandon) ...[
        SecondaryButton(label: 'Abandon (nothing was funded)', icon: Icons.cancel_outlined, onPressed: _abandonFunding),
        const SizedBox(height: 8),
      ],
      GhostButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    ];
  }

  /// Guarded manual ABANDON of a stuck SELL 'funding' record (round 8) — the liveness escape for a record that
  /// can never auto-clear (broadcast intent set but nothing landed) and is not corrupt. Delegates to the shared
  /// [confirmAbandonUnfundedSell] gate, which runs the AUTHORITATIVE on-chain HTLC scan and clears ONLY on a
  /// DEFINITIVELY-EMPTY result behind an explicit warning; a funded/unreadable scan keeps it resumable and says
  /// so. On a clear, the guard resets (rail freed) and we return to the review surface.
  Future<void> _abandonFunding() async {
    final rec = _rec;
    if (rec == null) return;
    final cleared = await confirmAbandonUnfundedSell(context, rec);
    if (!mounted) return;
    if (cleared) {
      setState(() {
        _rec = null;
        _phase = 'review';
      });
    }
  }

  /// The DURABLE-CORRUPT recovery surface (Task 2). A present-but-undecodable record throws on every load, so
  /// the rail would otherwise be blocked forever behind the false 'you already have one in progress'. Be
  /// HONEST about the ambiguity (it MAY represent a real in-flight swap) and offer an explicit, guarded
  /// clear — inspect the raw bytes, then discard only after an unambiguous warning.
  List<Widget> _corruptView() => [
        AmbraCard(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.error_outline, color: AmbraColors.red, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Swap record unreadable — recovery needed', style: AmbraText.title),
                const SizedBox(height: 8),
                const Text(
                  'Your saved rail-crossing swap record is present but could not be read (a partial write or a '
                  'keystore change). It CANNOT be resumed automatically, and it is blocking new swaps. It MAY '
                  'represent a real in-flight swap — if you have a swap that has not finished, do NOT clear it '
                  'until it settles or refunds. If you are sure nothing is in flight, you can clear it to unblock '
                  'this rail.',
                  style: AmbraText.sub,
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        SecondaryButton(label: 'Inspect & clear record', icon: Icons.delete_outline, onPressed: _recoverCorrupt),
        const SizedBox(height: 8),
        GhostButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
      ];

  /// Guarded RECOVER: show the raw undecodable value for inspection, then clear it ONLY on an explicit
  /// confirmation that warns it may represent an in-flight swap. Clearing resets the in-flight/corrupt guard
  /// so the rail is usable again; the review surface returns.
  Future<void> _recoverCorrupt() async {
    final raw = await SubswapStore.readRaw();
    if (!mounted) return;
    final preview = (raw == null || raw.isEmpty)
        ? '(the stored value could not be read for inspection)'
        : (raw.length > 800 ? '${raw.substring(0, 800)}…' : raw);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: const Text('Clear the unreadable swap record?', style: AmbraText.title),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
              'This discards the saved record so you can start new rail-crossing swaps. If it represents a swap '
              'that is still in flight, clearing it loses the ability to resume or refund it — only clear if you '
              'are sure nothing is in progress.',
              style: AmbraText.sub,
            ),
            const SizedBox(height: 12),
            const Text('Stored value (unreadable):', style: AmbraText.sub),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(6)),
              child: Text(preview, style: const TextStyle(fontFamily: kMono, fontSize: 11, color: AmbraColors.mono)),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear record', style: TextStyle(color: AmbraColors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Drop EXACTLY the corrupt material (undecodable blob / entries / unknown-state records) — healthy
    // records survive. Resets the corrupt + primeErrored flags; the rail is usable again.
    await SubswapStore.clearCorrupt();
    if (!mounted) return;
    setState(() {
      _rec = null;
      _phase = 'review';
    });
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: AmbraText.sub),
          const SizedBox(height: 2),
          Text(v, style: AmbraText.body),
        ]),
      );
}

/// The SHARED fund-safe ABANDON gate for a stuck SELL 'funding' record (round 8), used by BOTH in-flight
/// surfaces — [_SubmarineSwapScreenState._inflightView] and the Swap-tab in-flight banner — so there is exactly
/// ONE guarded path. Runs the AUTHORITATIVE on-chain HTLC-address scan and clears the record ONLY when it is
/// DEFINITIVELY EMPTY (no output at the HTLC P2SH, the read did not error), behind an explicit hard warning that
/// the asset could be at the HTLC address. A FUNDED scan (an output is there) or an UNREADABLE scan (a read
/// error / no scannable address) NEVER clears — it keeps the record resumable and tells the user why. It is
/// USER-initiated + warned, never automatic. Returns true iff the record was cleared (rail freed).
Future<bool> confirmAbandonUnfundedSell(BuildContext context, SubswapRecord rec) async {
  if (!SubswapService.canAbandonFunding(rec)) return false;
  // ROUND 12 (fully clock-free): there is NO wall-clock age gate here anymore. The staleness/reorg margin comes
  // ENTIRELY from the CLOCK-FREE tip-HEIGHT proof inside [scanHtlcForAbandon] — an empty /utxo scan is trusted as
  // [HtlcScanResult.empty] only once the backend's tip is ~240 blocks (kAbandonMinConfDepth) past the height
  // captured at broadcast. Until the chain has advanced that far, the scan comes back UNREADABLE and the
  // "Could not verify on-chain" branch below keeps the record resumable. No DateTime.now() on this path.
  //
  // (1) The AUTHORITATIVE on-chain scan over the persisted HTLC P2SH (confirmed AND mempool), height-proof gated.
  final scan = await SubswapService.scanHtlcForAbandon(rec);
  if (!context.mounted) return false;
  // (2) FUND-SAFE: anything but a definitively-empty read refuses to clear and stays resumable.
  if (scan == HtlcScanResult.funded) {
    await _abandonInfoDialog(
      context,
      'Your asset is on-chain — do not abandon',
      'We found an output at this swap\'s on-chain HTLC address, so it is NOT safe to abandon. Your asset is '
          'locked there and the swap is still resumable — it settles when the maker pays, or refunds after its '
          'timeout. Nothing was cleared. Tap Resume instead.',
    );
    return false;
  }
  if (scan == HtlcScanResult.unreadable) {
    await _abandonInfoDialog(
      context,
      'Could not verify on-chain yet',
      'We could not confirm nothing was funded at this swap\'s asset HTLC address right now — either the chain has '
          'not advanced far enough past the funding window to prove it is buried, or the address could not be read. '
          'Nothing was cleared — keep it resumable and try again shortly (or when you have a connection).',
    );
    return false;
  }
  // (3) DEFINITIVELY EMPTY: warn hard, then clear only on an explicit confirm.
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AmbraColors.panel,
      title: const Text('Abandon this swap?', style: AmbraText.title),
      content: const SingleChildScrollView(
        child: Text(
          'We scanned this swap\'s on-chain HTLC address and found NOTHING funded there, so it is safe to abandon '
          'and free this rail.\n\nIf you completed or funded this swap, do NOT abandon — your asset could be at the '
          'HTLC address. Only abandon if you are sure nothing was funded.',
          style: AmbraText.sub,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep')),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Abandon', style: TextStyle(color: AmbraColors.red)),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  // (4) The single SAFE-BY-CONSTRUCTION clear gate (fully CLOCK-FREE — no wall-clock age gate): it re-verifies
  // not-driving + a FRESH RELOAD (a concurrent resume that found the funding wins; a different swap in the slot is
  // refused) + the SEQ-FUND-TXID guard + a RE-SCAN of the fresh record's HTLC address. That re-scan (not the
  // pre-dialog scan above) is the authoritative empty signal: the pre-dialog result is NOT trusted at clear time,
  // so a funding tx that (re)confirmed while this warning was up is caught and the clear is refused. The re-scan's
  // clock-free tip-HEIGHT proof is its only staleness/reorg margin. So even after this warning it REFUSES if the
  // record advanced, a resume grabbed it, or the HTLC funded during the dialog. Resets the guard on a clear →
  // rail freed. If it refuses, tell the user nothing was cleared (still resumable).
  final cleared = await SubswapService.abandonUnfundedSell(rec, scan);
  if (!cleared && context.mounted) {
    await _abandonInfoDialog(
      context,
      'Nothing was cleared',
      'This swap changed while you were confirming — it may have started resuming or found its on-chain lock. It is '
          'still resumable, so nothing was cleared. Tap Resume.',
    );
  }
  return cleared;
}

/// A simple one-button info dialog for the abandon flow's fund-safe refusals (funded / unreadable scan).
Future<void> _abandonInfoDialog(BuildContext context, String title, String body) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AmbraColors.panel,
        title: Text(title, style: AmbraText.title),
        content: SingleChildScrollView(child: Text(body, style: AmbraText.sub)),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
      ),
    );
