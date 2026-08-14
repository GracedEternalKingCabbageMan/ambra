import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as core;
import 'config.dart';
import 'placed_orders.dart';
import 'sbtc_client.dart';
import 'seqdex_client.dart' show pick;
import 'seqob_client.dart';
import 'swap_route.dart' show kBtcSentinel;

/// A pending SBTC peg-in whose BUY-with-BTC covenant order is still being assembled — persisted so the
/// order survives the wallet closing during the (multi-block) peg-in wait and resumes on reopen.
///
/// FUND-SAFETY: the bridge credits SBTC to [seqAddr] regardless of this wallet, so a crash never loses
/// funds — worst case the user simply holds SBTC to reconcile, and [SbtcPegService.resumePegIns]
/// finishes the covenant post next load. Mirrors the web wallet's PEGPENDING record (swap.js).
class PegPending {
  PegPending({
    required this.id,
    required this.seqAddr,
    required this.depositAddr,
    required this.btcSats,
    required this.assetHex,
    required this.assetAtoms,
    required this.sbtcHex,
    required this.btcTxid,
    required this.beforeSbtc,
    required this.phase,
    required this.createdMs,
  });

  final String id;
  final String seqAddr; // the wallet address the bridge credits SBTC to
  final String depositAddr; // the BTC deposit address the bridge bound to seqAddr
  final String btcSats; // BTC paid in (== SBTC minted == the covenant's locked/advertised amount)
  final String assetHex; // asset wanted by the resting order
  final String assetAtoms; // amount of the asset wanted
  final String sbtcHex; // the SBTC asset id
  final String? btcTxid; // set once the BTC deposit is broadcast; null => nothing pegged in yet
  final String beforeSbtc; // this wallet's SBTC balance before the peg-in (to detect the credit)
  final String phase; // 'depositing' | 'minting'
  final int createdMs;

  PegPending copyWith({String? btcTxid, String? phase}) => PegPending(
        id: id,
        seqAddr: seqAddr,
        depositAddr: depositAddr,
        btcSats: btcSats,
        assetHex: assetHex,
        assetAtoms: assetAtoms,
        sbtcHex: sbtcHex,
        btcTxid: btcTxid ?? this.btcTxid,
        beforeSbtc: beforeSbtc,
        phase: phase ?? this.phase,
        createdMs: createdMs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'seqAddr': seqAddr,
        'depositAddr': depositAddr,
        'btcSats': btcSats,
        'assetHex': assetHex,
        'assetAtoms': assetAtoms,
        'sbtcHex': sbtcHex,
        'btcTxid': btcTxid,
        'beforeSbtc': beforeSbtc,
        'phase': phase,
        'createdMs': createdMs,
      };

  factory PegPending.fromJson(Map<String, dynamic> j) => PegPending(
        id: j['id'] as String,
        seqAddr: j['seqAddr'] as String,
        depositAddr: j['depositAddr'] as String,
        btcSats: j['btcSats'].toString(),
        assetHex: j['assetHex'] as String,
        assetAtoms: j['assetAtoms'].toString(),
        sbtcHex: j['sbtcHex'] as String,
        btcTxid: j['btcTxid'] as String?,
        beforeSbtc: (j['beforeSbtc'] ?? '0').toString(),
        phase: (j['phase'] ?? 'depositing').toString(),
        createdMs: (j['createdMs'] as num?)?.toInt() ?? 0,
      );
}

/// Persistent store of pending peg-ins (recorded BEFORE the BTC deposit is broadcast — see [PegPending]).
/// Mirrors the web wallet's PEGPENDING_KEY localStorage list.
class PegPendingStore {
  static const _key = 'ambra.sbtc.pegpending';

  static Future<List<PegPending>> list() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_key);
    if (s == null || s.isEmpty) return [];
    try {
      final arr = jsonDecode(s) as List<dynamic>;
      return arr.map((e) => PegPending.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<PegPending> items) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  /// Add or replace a record by id.
  static Future<void> upsert(PegPending rec) async {
    final items = await list();
    items.removeWhere((e) => e.id == rec.id);
    items.add(rec);
    await _save(items);
  }

  static Future<void> drop(String id) async {
    final items = await list();
    items.removeWhere((e) => e.id == id);
    await _save(items);
  }
}

/// The wallet-side glue for the SBTC silent peg — the ONE place SBTC touches the DEX (spec §5,
/// sbtc-peg-design.md). A direct port of the web wallet's swap.js pegged-covenant flow:
///
///   MAKER  a BUY-with-on-chain-BTC LIMIT order with "keep resting while offline" ON pegs the maker's
///          real BTC IN to SBTC, then rests that SBTC in a covenant ADVERTISED as a BTC offer so it
///          stays live while the wallet is offline; funds return as real BTC on fill/cancel.
///   TAKER  a resting pegged covenant (advertised BTC, locks SBTC) is filled permissionlessly with the
///          covenant FILL primitive; the taker receives SBTC and pegs it OUT to real BTC.
///
/// SBTC == BTC 1:1, so every advertised amount equals the locked amount. When SBTC is not registered on
/// the network the peg is simply unavailable and the caller falls back to native BTC.
///
/// AUTH: every path here SPENDS real funds (the BTC deposit, the covenant funding, the peg-out send).
/// Payment auth is the CALLER's responsibility and MUST pass before invoking these (mirrors the review
/// sheets + subasset_buy.fund) — the service assumes it already did.
class SbtcPegService {
  SbtcPegService._();

  /// The SBTC asset id (ticker "SBTC") resolved from the merged asset registry, or null if the
  /// pegged-BTC asset isn't registered on this network (then the silent peg is unavailable). Mirrors
  /// sbtc.resolveSbtcAsset — the "which asset is SBTC" rule lives in one place.
  static String? sbtcAssetId() {
    for (final id in SeqAssets.resolvedIds) {
      try {
        if (SeqAssets.labelFor(id).ticker.toUpperCase() == 'SBTC') return id;
      } catch (_) {/* skip an unlabelable id */}
    }
    return null;
  }

  // --- MAKER ----------------------------------------------------------------

  /// MAKER flow: peg the maker's real BTC IN to SBTC, then rest that SBTC in a covenant ADVERTISED as a
  /// BTC offer on the asset/BTC market (advertise_sell_as = BTC) so BTC takers find + fill it (and peg
  /// out to real BTC). [btcSats] = BTC paid; [assetHex]/[assetAtoms] = the asset + amount wanted.
  /// [makerIndex] = a fresh covenant payout index (caller allocates). Persists a pending peg-in record
  /// BEFORE broadcasting the BTC deposit, and a PlacedCovenant BEFORE posting the offer (fund-safety).
  /// Mirrors swap.js placePeggedBtcCovenant.
  static Future<PlacedCovenant> placePeggedBtcCovenant({
    required String mnemonic,
    required String assetHex,
    required BigInt btcSats,
    required BigInt assetAtoms,
    required int makerIndex,
    required int tipHeight,
    void Function(String)? onStatus,
  }) async {
    final sbtcHex = sbtcAssetId();
    if (sbtcHex == null) {
      throw Exception('SBTC (the pegged-BTC asset) isn\'t available on this network, so an '
          'offline-resting BTC order can\'t be placed. Turn off "keep resting while offline" to rest as native BTC.');
    }
    if (btcSats <= BigInt.zero || assetAtoms <= BigInt.zero) {
      throw Exception('Enter both the BTC you pay and the amount you want.');
    }

    // A fresh TRANSPARENT tb1 address of THIS wallet: it receives the minted SBTC AND is a valid
    // Sequentia address (one address, both chains; principle #6).
    onStatus?.call('Preparing the peg-in…');
    final seqAddr = await core.receiveAddress(mnemonic: mnemonic);
    final depositAddr = await SbtcClient.requestPegIn(seqAddr);

    // This wallet's SBTC balance BEFORE the peg-in, to detect the credit later.
    final beforeSbtc = await _sbtcBalance(mnemonic, sbtcHex);

    // Persist the intent BEFORE broadcasting the BTC deposit, so a crash after broadcast can resume.
    final rec = PegPending(
      id: _randHex(8),
      seqAddr: seqAddr,
      depositAddr: depositAddr,
      btcSats: btcSats.toString(),
      assetHex: assetHex,
      assetAtoms: assetAtoms.toString(),
      sbtcHex: sbtcHex,
      btcTxid: null,
      beforeSbtc: beforeSbtc.toString(),
      phase: 'depositing',
      createdMs: DateTime.now().millisecondsSinceEpoch,
    );
    await PegPendingStore.upsert(rec);

    // Send the maker's BTC to the bridge deposit address (testnet4). FUND-SAFETY: btcPrepare returns a
    // fully-signed tx whose txid is final (segwit inputs), so persist the txid + advance the phase
    // BEFORE btcBroadcast — a crash mid-broadcast still resumes (never re-sends the same deposit).
    onStatus?.call('Sending your BTC to the peg…');
    final tx = await core.btcPrepare(
      mnemonic: mnemonic,
      t4Api: Backend.testnet4,
      address: depositAddr,
      amountSats: btcSats,
      feeRate: 0, // 0 => the wallet's estimated testnet4 fee rate
    );
    await PegPendingStore.upsert(rec.copyWith(btcTxid: tx.txid, phase: 'minting'));
    await core.btcBroadcast(t4Api: Backend.testnet4, txHex: tx.hex);

    // Wait for the bridge to mint SBTC to seqAddr (needs BTC confirmations). On timeout the funds are
    // safe (SBTC will still arrive) and resumePegIns finishes the order once credited.
    onStatus?.call('Waiting for the bridge to mint SBTC (this can take a few blocks)…');
    await _awaitSbtcCredit(mnemonic, sbtcHex, beforeSbtc, btcSats);

    onStatus?.call('Resting your order…');
    final placed = await postCovenantOrder(
      mnemonic: mnemonic,
      sellAsset: sbtcHex,
      buyAsset: assetHex,
      sellAtoms: btcSats,
      buyAtoms: assetAtoms,
      makerIndex: makerIndex,
      tipHeight: tipHeight,
      advertiseSellAs: kBtcSentinel, // SBTC peg: advertise BTC while the covenant locks SBTC
      onStatus: onStatus,
    );
    await PegPendingStore.drop(rec.id); // peg-in complete + order resting
    return placed;
  }

  /// Fund a covenant on-chain with [sellAtoms] of [sellAsset], then sign + post its resting SELL offer
  /// to the relay. When [advertiseSellAs] is set (the SBTC silent peg), the OFFER ENVELOPE advertises
  /// that asset (BTC) while the covenant terms + on-chain funding stay [sellAsset] (SBTC): the key is
  /// injected into the prepared-JSON STRING (jsonDecode -> add key -> jsonEncode), which
  /// covenant_finalize_offer already reads, so NO flutter_rust_bridge regen is needed. The reclaim
  /// material persisted is the ORIGINAL (un-injected) prepared JSON, so the REFUND taptree derives
  /// byte-identically to a plain same-chain order. Persists the PlacedCovenant BEFORE posting
  /// (fund-safety), tagged pegged/advertiseAs. Mirrors swap.js placeCovenant.
  static Future<PlacedCovenant> postCovenantOrder({
    required String mnemonic,
    required String sellAsset,
    required String buyAsset,
    required BigInt sellAtoms,
    required BigInt buyAtoms,
    required int makerIndex,
    required int tipHeight,
    String? advertiseSellAs,
    void Function(String)? onStatus,
  }) async {
    final pegged = advertiseSellAs != null && advertiseSellAs.isNotEmpty;

    onStatus?.call('Deriving the covenant…');
    final prepared = await core.covenantPrepareOffer(
      mnemonic: mnemonic,
      sellAsset: sellAsset,
      sellAtoms: sellAtoms,
      buyAsset: buyAsset,
      buyAtoms: buyAtoms,
      tipHeight: tipHeight,
      expiryBlocks: 0, // 0 => default ~1 day horizon
      makerIndex: makerIndex,
    );

    // SBTC silent peg: inject advertise_sell_as into the prepared JSON STRING used ONLY for finalize.
    // covenant_finalize_offer honors it for the offer envelope (pair base + offer_asset); the covenant
    // terms + funding stay sell_asset. No Rust param, no FRB regen. Absent -> a plain same-chain post.
    var finalizeJson = prepared.preparedJson;
    if (pegged) {
      final m = jsonDecode(finalizeJson) as Map<String, dynamic>;
      m['advertise_sell_as'] = advertiseSellAs;
      finalizeJson = jsonEncode(m);
    }

    onStatus?.call('Funding the order on-chain…');
    // The covenant funding is a SEQUENTIA tx, so its fee is paid in the policy asset (tSEQ, universally
    // accepted) from the wallet's own coins — never in the advertised BTC (not a Sequentia asset) nor in
    // the sold SBTC (which must transfer whole into the covenant). null => the builder's policy default.
    final pset = await core.buildSendTx(
      mnemonic: mnemonic,
      esploraUrl: Backend.esplora,
      recipients: [
        core.Recipient(address: prepared.covenantAddress, assetId: sellAsset, satoshi: sellAtoms),
      ],
      feeRateSatKvb: null,
      feeAsset: null,
    );
    final signed = await core.signPset(mnemonic: mnemonic, pset: pset);
    final covTxid = await core.finalizeAndBroadcast(mnemonic: mnemonic, esploraUrl: Backend.esplora, pset: signed);

    onStatus?.call('Locating the funded output…');
    final covVout = await _resolveCovenantVout(covTxid, prepared.covenantSpkHex);

    // FUND-SAFETY: persist the reclaim material (outpoint + ORIGINAL preparedJson + makerIndex + expiry)
    // BEFORE posting, so a post failure can never strand the funds without a local record to reclaim
    // (and, for a pegged order, to peg the reclaimed SBTC back out). Flip posted:true once accepted.
    var placed = PlacedCovenant(
      covTxid: covTxid,
      covVout: covVout,
      pay: sellAsset,
      receive: buyAsset,
      sellAtoms: sellAtoms.toString(),
      recvAtoms: buyAtoms.toString(),
      makerIndex: makerIndex,
      covenantSpkHex: prepared.covenantSpkHex,
      preparedJson: prepared.preparedJson, // ORIGINAL: the refund taptree derives from sell_asset (SBTC)
      expiryLocktime: prepared.expiryLocktime,
      posted: false,
      createdMs: DateTime.now().millisecondsSinceEpoch,
      pegged: pegged,
      advertiseAs: pegged ? advertiseSellAs : null,
    );
    await PlacedOrders.put(placed);

    onStatus?.call('Signing & posting your order…');
    final signedOffer = await core.covenantFinalizeOffer(
      mnemonic: mnemonic,
      preparedJson: finalizeJson, // INJECTED: advertises BTC while the covenant locks SBTC
      covenantTxid: covTxid,
      covenantVout: covVout,
    );
    final offer = jsonDecode(signedOffer) as Map<String, dynamic>;
    placed = placed.copyWith(offerId: offer['offer_id'] as String?);
    await PlacedOrders.put(placed);
    await SeqObClient.postOffer(offer);
    placed = placed.copyWith(posted: true);
    await PlacedOrders.put(placed); // the relay accepted it; it is now a live resting order
    return placed;
  }

  /// Resume any peg-in that was mid-flight when the wallet last closed: if its SBTC has since been
  /// credited, finish by posting the covenant; otherwise leave it pending (it credits and resumes on a
  /// later load). Never re-sends BTC (idempotent by record). [nextMakerIndex] allocates a fresh covenant
  /// payout index per resumed order. Mirrors swap.js resumePegIns.
  static Future<void> resumePegIns({
    required String mnemonic,
    required int tipHeight,
    required int Function() nextMakerIndex,
  }) async {
    for (final rec in await PegPendingStore.list()) {
      try {
        if (rec.btcTxid == null || rec.btcTxid!.isEmpty) {
          await PegPendingStore.drop(rec.id); // never broadcast; nothing pegged in
          continue;
        }
        final have = (await _sbtcBalance(mnemonic, rec.sbtcHex)) - BigInt.parse(rec.beforeSbtc);
        if (have < BigInt.parse(rec.btcSats)) continue; // not yet credited; leave it pending
        await postCovenantOrder(
          mnemonic: mnemonic,
          sellAsset: rec.sbtcHex,
          buyAsset: rec.assetHex,
          sellAtoms: BigInt.parse(rec.btcSats),
          buyAtoms: BigInt.parse(rec.assetAtoms),
          makerIndex: nextMakerIndex(),
          tipHeight: tipHeight,
          advertiseSellAs: kBtcSentinel,
        );
        await PegPendingStore.drop(rec.id);
      } catch (_) {/* leave pending; a later load retries */}
    }
  }

  // --- TAKER / peg-out ------------------------------------------------------

  /// TRUE if a covenant offer advertised as BTC LOCKS SBTC — i.e. filling it pays us SBTC for BTC we
  /// were buying (we were selling the asset), so the received SBTC must be pegged OUT to real BTC.
  /// Distinguished from a genuine SBTC market trade (whose advertised pair carries no BTC sentinel).
  /// Mirrors swap.js isPeggedFillToRedeem.
  static bool isPeggedFillToRedeem(SeqObOffer offer) {
    final cov = offer.covenant;
    if (cov == null) return false;
    final gotAsset = (pick(cov, ['asset_a', 'assetA'])?.toString() ?? '').toLowerCase();
    final sbtcHex = (sbtcAssetId() ?? '').toLowerCase();
    if (sbtcHex.isEmpty || gotAsset != sbtcHex) return false; // we didn't receive SBTC
    return offer.baseAsset == kBtcSentinel || offer.quoteAsset == kBtcSentinel; // advertised BTC -> redeem
  }

  /// Peg the just-received (or just-reclaimed) SBTC back OUT to real BTC: ask the bridge for a peg-out
  /// address bound to a wallet BTC address, send the SBTC there, and the bridge releases real BTC.
  /// Best-effort + safe: on any failure the user simply holds redeemable SBTC (never lost). [atoms] =
  /// the SBTC to redeem. Returns the send txid, or null when there is nothing to redeem. The tx fee is
  /// paid in the policy asset (tSEQ) so the FULL SBTC amount transfers to the bridge. Mirrors swap.js
  /// pegOutReceivedSbtc.
  static Future<String?> pegOutReceivedSbtc({required String mnemonic, required BigInt atoms}) async {
    if (atoms <= BigInt.zero) return null;
    final sbtcHex = sbtcAssetId();
    if (sbtcHex == null) throw Exception('SBTC (the pegged-BTC asset) is unavailable, so it can\'t be redeemed to BTC.');
    // Our own tb1 is a valid BTC destination (one address, both chains).
    final btcDest = await core.receiveAddress(mnemonic: mnemonic);
    final sbtcAddr = await SbtcClient.requestPegOut(btcDest);
    final pset = await core.buildSendTx(
      mnemonic: mnemonic,
      esploraUrl: Backend.esplora,
      recipients: [core.Recipient(address: sbtcAddr, assetId: sbtcHex, satoshi: atoms)],
      feeRateSatKvb: null,
      feeAsset: null, // policy default (tSEQ) — never SBTC, so the full amount reaches the bridge
    );
    final signed = await core.signPset(mnemonic: mnemonic, pset: pset);
    return await core.finalizeAndBroadcast(mnemonic: mnemonic, esploraUrl: Backend.esplora, pset: signed);
  }

  // --- internal helpers -----------------------------------------------------

  /// This wallet's current SBTC balance (atoms) from a fresh sync.
  static Future<BigInt> _sbtcBalance(String mnemonic, String sbtcHex) async {
    final s = await core.syncWallet(mnemonic: mnemonic, esploraUrl: Backend.esplora);
    for (final b in s.balances) {
      if (b.assetId == sbtcHex) return BigInt.tryParse(b.atoms) ?? BigInt.zero;
    }
    return BigInt.zero;
  }

  /// Poll this wallet's SBTC balance until it has risen by >= [amount] (the bridge minted the peg-in).
  /// Generous timeout: a peg-in needs BTC confirmations. On timeout the funds are safe (SBTC will still
  /// arrive) and the order resumes once credited. Mirrors swap.js awaitSbtcCredit.
  static Future<void> _awaitSbtcCredit(String mnemonic, String sbtcHex, BigInt before, BigInt amount,
      {Duration timeout = const Duration(minutes: 45)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final now = await _sbtcBalance(mnemonic, sbtcHex);
      if (now - before >= amount) return;
      await Future<void>.delayed(const Duration(seconds: 15));
    }
    throw Exception('The peg-in hasn\'t been credited yet. Your BTC is safe at the bridge and your SBTC '
        'will arrive; re-open the order once it does.');
  }

  /// Locate the covenant funding vout by matching its scriptPubKey on the broadcast tx.
  static Future<int> _resolveCovenantVout(String txid, String spkHex) async {
    final r = await http
        .get(Uri.parse('${Backend.esplora}/tx/$txid'), headers: {...Backend.authHeaders})
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw Exception('esplora /tx/$txid returned ${r.statusCode}');
    final tx = jsonDecode(r.body) as Map<String, dynamic>;
    final vout = (tx['vout'] as List?) ?? const [];
    for (var i = 0; i < vout.length; i++) {
      final o = vout[i] as Map;
      if ('${o['scriptpubkey'] ?? ''}'.toLowerCase() == spkHex.toLowerCase()) return i;
    }
    throw Exception('funded covenant output not found in $txid');
  }

  static String _randHex(int bytes) {
    final rng = Random.secure();
    final b = List<int>.generate(bytes, (_) => rng.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }
}
