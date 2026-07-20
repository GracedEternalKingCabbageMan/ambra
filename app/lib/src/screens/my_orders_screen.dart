import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/config.dart';
import '../data/format.dart';
import '../data/placed_orders.dart';
import '../data/sbtc_peg_service.dart';
import '../data/seqob_client.dart';
import '../data/trade_receipts.dart';
import '../data/wallet_repository.dart';
import '../rust/api.dart' as core;
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// The maker's own resting COVENANT orders (funded on-chain, posted to the relay),
/// with a reclaim path.
///
/// A covenant order rests ON-CHAIN until a taker fills it or it expires. Until then
/// its funds are committed — only a taker paying the order's price can move them
/// (that is the covenant CLOB guarantee) — so there is no instant "cancel". After
/// the order expires the maker can spend the locked funds back to their own wallet
/// via the covenant's CLTV REFUND leaf. "Delist" stops advertising the order on the
/// relay immediately; "Reclaim funds" spends it back once it has matured.
class MyOrdersScreen extends StatefulWidget {
  const MyOrdersScreen({super.key, required this.tipHeight});

  /// The Sequentia chain tip, to decide which orders have matured (tip >= expiry).
  final int tipHeight;

  @override
  State<MyOrdersScreen> createState() => _MyOrdersScreenState();
}

class _MyOrdersScreenState extends State<MyOrdersScreen> {
  List<PlacedCovenant> _orders = const [];
  bool _loading = true;
  String? _busyKey; // the order currently reclaiming/delisting
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final o = await PlacedOrders.list();
    if (mounted) {
      setState(() {
        _orders = o;
        _loading = false;
      });
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(ambraSnack(m));

  /// Best-effort relay delist (OfferCancel). The locked funds are NOT freed by this
  /// (they are on-chain until fill/expiry); it only stops new takers seeing the order.
  Future<bool> _delistOnRelay(String mnemonic, PlacedCovenant rec) async {
    if (!(rec.offerId?.isNotEmpty ?? false)) return false;
    final cancel = await core.seqobSignCancel(
      mnemonic: mnemonic,
      offerId: rec.offerId!,
      nonce: BigInt.from(DateTime.now().millisecondsSinceEpoch),
    );
    await SeqObClient.cancelOffer(jsonDecode(cancel) as Map<String, dynamic>);
    return true;
  }

  Future<void> _delist(PlacedCovenant rec) async {
    setState(() {
      _busyKey = rec.key;
      _error = null;
    });
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      await _delistOnRelay(m, rec);
      if (mounted) {
        _snack('Delisted from the relay. The locked funds are reclaimable after block ${rec.expiryLocktime}.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _reclaim(PlacedCovenant rec) async {
    setState(() {
      _busyKey = rec.key;
      _error = null;
    });
    try {
      final m = await WalletRepository.instance.readMnemonic();
      if (m == null) throw Exception('wallet unavailable');
      // Delist first (best-effort) so no taker lifts it while we reclaim.
      if (rec.posted) {
        try {
          await _delistOnRelay(m, rec);
        } catch (_) {/* delist is best-effort; the on-chain reclaim is what frees the funds */}
      }
      // Fee in tSEQ (universally accepted); the reclaimed asset returns whole. If the
      // sold asset IS tSEQ the core takes the fee from the reclaimed value instead.
      final built = await core.covenantBuildRefundTx(
        mnemonic: m,
        esploraUrl: Backend.esplora,
        preparedJson: rec.preparedJson,
        covenantTxid: rec.covTxid,
        covenantVout: rec.covVout,
        makerIndex: rec.makerIndex,
        feeAsset: SeqAssets.policy,
        feeAtoms: BigInt.from(2000),
      );
      final txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: built.rawHex);
      // SBTC silent peg: the reclaimed asset is SBTC, but the maker paid BTC and expects BTC back. Redeem
      // it to real BTC (best-effort; on failure the user simply holds redeemable SBTC — fund-safe).
      // Mirrors the web wallet's reclaim peg-out (pegs the full sellAtoms).
      if (rec.pegged) {
        try {
          await SbtcPegService.pegOutReceivedSbtc(mnemonic: m, atoms: BigInt.parse(rec.sellAtoms));
        } catch (_) {/* non-fatal: the reclaim already landed; the SBTC is redeemable */}
      }
      await PlacedOrders.remove(rec.key);
      final tk = SeqAssets.labelFor(rec.pay).ticker;
      await TradeReceipts.log(
        id: 'reclaim:${rec.covTxid}',
        title: rec.pegged ? 'Reclaimed BTC order' : 'Reclaimed $tk order',
        status: 'Reclaimed',
        txid: txid,
      );
      if (!mounted) return;
      _snack(rec.pegged
          ? 'Order reclaimed · redeeming your SBTC to BTC at the bridge…'
          : 'Order reclaimed · ${txid.substring(0, txid.length < 16 ? txid.length : 16)}…');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My orders')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(16), children: _body()),
            ),
    );
  }

  List<Widget> _body() {
    final w = <Widget>[];
    if (_error != null) {
      w.add(AmbraCard(child: Text(_error!, style: const TextStyle(color: AmbraColors.red))));
      w.add(const SizedBox(height: 12));
    }
    if (_orders.isEmpty) {
      w.add(const AmbraCard(
        child: Text(
          'No resting orders. Orders you post on the Swap tab appear here until they fill or you reclaim them.',
          style: AmbraText.muted,
        ),
      ));
      return w;
    }
    w.add(const Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Text(
        'A covenant order rests on-chain until a taker fills it or it expires. Its funds are committed until then; once it expires you can reclaim them to your wallet.',
        style: AmbraText.sub,
      ),
    ));
    for (final o in _orders) {
      w.add(_orderCard(o));
    }
    return w;
  }

  Widget _orderCard(PlacedCovenant o) {
    final payL = SeqAssets.labelFor(o.pay);
    final recvL = SeqAssets.labelFor(o.receive);
    final matured = widget.tipHeight > 0 && widget.tipHeight >= o.expiryLocktime;
    final blocksLeft = o.expiryLocktime - widget.tipHeight;
    final busy = _busyKey == o.key;
    final status = !o.posted
        ? 'Funded, not yet posted'
        : matured
            ? 'Resting · reclaimable now'
            : 'Resting · reclaimable at block ${o.expiryLocktime}'
                '${blocksLeft > 0 ? ' (~$blocksLeft blocks left)' : ''}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AmbraCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // A pegged order LOCKS SBTC but the maker paid (and gets back) real BTC — show it as a BTC bid,
          // not "Sell N SBTC", so the copy matches what the user did (SBTC is the mechanism, not the ask).
          Text(
            o.pegged
                ? 'Pay ${formatAtoms(o.sellAtoms, 8)} BTC'
                : 'Sell ${formatAtoms(o.sellAtoms, payL.precision)} ${payL.ticker}',
            style: AmbraText.body,
          ),
          Text('for ${formatAtoms(o.recvAtoms, recvL.precision)} ${recvL.ticker}', style: AmbraText.sub),
          const SizedBox(height: 8),
          Text(status, style: AmbraText.sub.copyWith(color: matured ? AmbraColors.amber : AmbraColors.dim)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: PrimaryButton(
                label: matured ? 'Reclaim funds' : 'Reclaim after expiry',
                busy: busy,
                icon: Icons.lock_open,
                onPressed: (matured && !busy) ? () => _reclaim(o) : null,
              ),
            ),
            if (o.posted && (o.offerId?.isNotEmpty ?? false) && !matured) ...[
              const SizedBox(width: 8),
              GhostButton(label: 'Delist', onPressed: busy ? null : () => _delist(o)),
            ],
          ]),
        ]),
      ),
    );
  }
}
