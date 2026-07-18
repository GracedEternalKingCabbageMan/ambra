import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../rust/api.dart' as core;
import 'config.dart';
import 'lightning_service.dart';
import 'lsp_client.dart';
import 'trade_receipts.dart';
import 'wallet_repository.dart';

/// A conservative fee (sats) for the legacy-P2SH BTC HTLC claim spend (~200 vB at ~2 sat/vB),
/// matching the reverse cross-chain claim. The claim pays `amount - fee` to a fresh wallet address.
final BigInt _kClaimFeeSats = BigInt.from(440);

/// Local, taker-centric state of an in-flight sub-asset SELL (pay a Sequentia asset over Lightning,
/// receive Bitcoin on-chain). The wallet is the source of truth (the maker/LSP state is in-memory and
/// dies on restart), so this is persisted after every transition.
///
/// FUND DISCIPLINE: the asset is paid FIRST over Lightning (claim-or-lose — there is NO BTC refund
/// path in this direction; once the maker reveals the preimage the BTC HTLC is ours to claim). So the
/// preimage + the maker's BTC HTLC terms are persisted at [SubSellStep.claiming] BEFORE the first
/// on-chain claim, and [SubassetSellService.resume] re-attempts the claim idempotently on reload.
enum SubSellStep {
  paying, // paying the asset over Lightning (transient; not normally persisted)
  claiming, // asset paid + preimage known; claiming the BTC HTLC on-chain (the recovery window)
  done, // BTC claimed; swap complete
  failed,
}

class SubSellRecord {
  SubSellRecord({
    required this.step,
    required this.asset,
    required this.ticker,
    required this.preimage,
    required this.hashHex,
    required this.btcLeg,
    required this.expectedBtc,
    this.claimTxid = '',
    this.shortfall = false,
  });

  SubSellStep step;
  final String asset; // the Sequentia asset paid over Lightning
  final String ticker;
  final String preimage; // NOT HD-derivable — the recovery-critical secret (claims the BTC)
  final String hashHex;
  final SubBtcHtlc btcLeg; // the maker's BTC HTLC the taker claims with [preimage]
  final BigInt expectedBtc; // the BTC the offer quoted (economic gate); 0 when no offer was attached
  String claimTxid;
  bool shortfall; // the on-chain HTLC value came in below [expectedBtc] (claimed anyway, flagged)

  /// The BTC value actually locked in the maker's HTLC (what the claim recovers).
  BigInt get gotBtc => btcLeg.amount;

  Map<String, dynamic> toJson() => {
        'step': step.name,
        'asset': asset,
        'ticker': ticker,
        'preimage': preimage,
        'hashHex': hashHex,
        'btcLeg': btcLeg.toJson(),
        'expectedBtc': expectedBtc.toString(),
        'claimTxid': claimTxid,
        'shortfall': shortfall,
      };

  static SubSellRecord fromJson(Map<String, dynamic> j) => SubSellRecord(
        step: SubSellStep.values.firstWhere((s) => s.name == j['step'], orElse: () => SubSellStep.failed),
        asset: '${j['asset']}',
        ticker: '${j['ticker']}',
        preimage: '${j['preimage']}',
        hashHex: '${j['hashHex']}',
        btcLeg: SubBtcHtlc.fromJson((j['btcLeg'] as Map?) ?? const {}),
        expectedBtc: BigInt.tryParse('${j['expectedBtc'] ?? 0}') ?? BigInt.zero,
        claimTxid: '${j['claimTxid'] ?? ''}',
        shortfall: j['shortfall'] == true,
      );

  /// True while the asset has been paid but the BTC claim has not confirmed — the recovery window
  /// where [SubassetSellService.resume] must re-attempt the claim.
  bool get inFlight => step == SubSellStep.claiming;
}

/// Persists the single active sub-asset SELL. It carries the preimage (the only thing that claims the
/// BTC), so it lives in secure storage. A distinct key from the BUY store so the two never clobber.
class SubSellStore {
  SubSellStore._();
  static const _key = 'ambra.subasset.sell.active';
  static const _storage = FlutterSecureStorage();

  static Future<SubSellRecord?> load() async {
    final s = await _storage.read(key: _key);
    if (s == null || s.isEmpty) return null;
    try {
      return SubSellRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(SubSellRecord r) => _storage.write(key: _key, value: jsonEncode(r.toJson()));
  static Future<void> clear() => _storage.delete(key: _key);
}

/// Drives the sub-asset SELL from LOCAL state: pay the asset over Lightning, then CLAIM the maker's
/// BTC HTLC on-chain with the revealed preimage. The on-chain claim is built by the audited core FFI
/// ([core.xchainBtcClaim] — the proven legacy-P2SH spend), never hand-rolled. Each method advances one
/// step and persists; [resume] re-runs the claim idempotently after a reload.
class SubassetSellService {
  SubassetSellService._();

  /// Synchronous in-flight sentinel closing the TOCTOU window the async [hasInFlight] leaves open:
  /// the asset is paid INSIDE [begin]'s swapSub, so a second [begin] slipping in before the record is
  /// persisted would pay a SECOND time and overwrite the single preimage handle. Checked-and-set
  /// atomically at the top of [begin] (no await between), cleared in its finally. Mirrors the web's
  /// `_sellStarting`.
  static bool _starting = false;

  static Future<String> _mnemonic() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw Exception('wallet unavailable');
    return m;
  }

  /// True while a sell is persisted with its BTC claim not yet confirmed — the single-active guard +
  /// the screen's gating both read this so a second sell can never overwrite the recovery handle.
  static Future<bool> hasInFlight() async {
    final r = await SubSellStore.load();
    return r != null && r.inFlight;
  }

  /// Pay the asset over Lightning, learn the preimage + the maker's BTC HTLC terms, PERSIST them, then
  /// claim the BTC on-chain. FUND-SAFETY: the asset is paid inside [LightningService.swapSub]; the
  /// moment it settles we hold the only recovery handle (the preimage), so we persist BEFORE the first
  /// claim and [resume] re-attempts it. Refuses to start while another sell's BTC claim is unconfirmed.
  static Future<SubSellRecord> begin({required String asset, required num amount, SubOffer? offer}) async {
    // FUND-SAFETY self-guard: a second sell would pay the asset again + overwrite the persisted
    // preimage/HTLC — the single handle to the claimable BTC. The sync sentinel is checked-and-set
    // atomically (no await between) so a concurrent begin can't slip through before the persist below.
    if (_starting) {
      throw Exception('A sub-asset sell is already starting; wait for it to finish.');
    }
    _starting = true;
    try {
      if (await hasInFlight()) {
        throw Exception('You already have a sub-asset sell in progress (claiming your BTC). '
            'Finish or retry it first.');
      }
      final m = await _mnemonic();
      final ticker = SeqAssets.labelFor(asset).ticker;
      // The device CLAIM key — only we can claim the maker's BTC HTLC. The maker embeds it as the
      // IF/claim key so the LSP (keyless) can never take the BTC.
      final btcClaimPub = await core.xchainBtcClaimPubkey(mnemonic: m);
      // Bring our OWN hosted asset node's device signer online so the LSP can command the LN pay.
      final nodeKey = await LightningService.instance.connectNode(m, asset: asset);
      // Pay the asset over Lightning; on settle the maker reveals the preimage, returned WITH the BTC
      // HTLC terms. The LSP never claims (no claim key) — we claim on-chain ourselves.
      final resp = await LightningService.instance.swapSub(
        side: 'sell',
        asset: asset,
        nodeKey: nodeKey,
        amount: amount,
        // State the rails EXPLICITLY (asset over LN, BTC on-chain) so the LSP routes this to the
        // sub-asset SELL, not the pure-LN default.
        payRail: 'ln',
        recvRail: 'chain',
        btcClaimPub: btcClaimPub,
        offerId: offer?.offerId,
        makerPubkey: offer?.makerPubkey,
      );
      final s = resp.settle;
      if (!(s.settled && s.preimage.isNotEmpty && s.btcHtlc != null)) {
        throw Exception('The sell did not settle over Lightning.');
      }
      // PERSIST BEFORE the on-chain claim: the asset is now paid, so the BTC claim is the fund step and
      // MUST survive a reload — resume() re-attempts it from here.
      final rec = SubSellRecord(
        step: SubSellStep.claiming,
        asset: asset,
        ticker: ticker,
        preimage: s.preimage,
        hashHex: s.hashHex.isNotEmpty ? s.hashHex : s.btcHtlc!.raw['hash_h']?.toString() ?? '',
        btcLeg: s.btcHtlc!,
        expectedBtc: offer?.btcSats ?? BigInt.zero,
      );
      await SubSellStore.save(rec);
      await claim(rec); // verify + claim; mutates + persists rec
      return rec;
    } finally {
      _starting = false;
    }
  }

  /// Independently VERIFY the maker's BTC HTLC binds OUR claim key + H before trusting it: rebuild the
  /// redeemScript from (H, our claim key, the maker refund key, T_btc) and byte-compare it to the
  /// reported script, confirm our preimage hashes to H, and confirm the funding output exists on-chain
  /// with the expected vout + value. Throws on any mismatch — never claim into a leg we can't spend.
  static Future<void> verifyClaimable(SubSellRecord rec) async {
    final m = await _mnemonic();
    final h = rec.btcLeg;
    final ours = (await core.xchainBtcClaimPubkey(mnemonic: m)).toLowerCase();
    if (h.takerClaimPubkey.toLowerCase() != ours) {
      throw Exception('The BTC HTLC is not locked to this wallet\'s claim key.');
    }
    final rebuilt = await core.xchainBtcHtlc(
      hashHex: rec.hashHex,
      claimPubHex: h.takerClaimPubkey,
      refundPubHex: h.makerRefundPubkey,
      locktime: h.tBtc,
    );
    if (rebuilt.redeemScriptHex.toLowerCase() != h.redeemScript.toLowerCase()) {
      throw Exception('The BTC HTLC redeem script does not match H + the claim/refund keys.');
    }
    final digest = sha256.convert(_hexBytes(rec.preimage)).toString();
    if (digest.toLowerCase() != rec.hashHex.toLowerCase()) {
      throw Exception('The revealed preimage does not hash to H.');
    }
    final f = await core.xchainFindBtcFunding(t4Api: Backend.testnet4, txid: h.txid, p2ShSpkHex: rebuilt.p2ShSpkHex);
    if (f.vout != h.vout) {
      throw Exception('The BTC HTLC funding output was not found on-chain.');
    }
    final onchain = BigInt.tryParse(f.valueSats);
    if (onchain != null && onchain != h.amount) {
      throw Exception('The BTC HTLC on-chain amount does not match the reported value.');
    }
  }

  /// CLAIM the maker's BTC HTLC with the preimage, to a fresh wallet address. Economic gate: if the
  /// on-chain HTLC is worth LESS than the quote ([SubSellRecord.expectedBtc]), we flag the shortfall
  /// but STILL claim — recovering the dust beats letting the maker refund it. Idempotent-ish: a
  /// duplicate claim of an already-spent HTLC just errors, which the caller surfaces.
  static Future<SubSellRecord> claim(SubSellRecord rec) async {
    // ECONOMIC gate (best-effort; only when an offer's quote was attached). verifyClaimable only
    // checks the HTLC's on-chain value equals what the LSP reported, NOT that it meets the quote, so a
    // shortchanging counterparty could hand back a dust HTLC after we already paid the asset over LN.
    if (rec.expectedBtc > BigInt.zero && rec.gotBtc < rec.expectedBtc && !rec.shortfall) {
      rec.shortfall = true;
      await SubSellStore.save(rec);
    }
    await verifyClaimable(rec);
    final m = await _mnemonic();
    final h = rec.btcLeg;
    final dest = await core.receiveAddress(mnemonic: m); // our own tb1
    final hex = await core.xchainBtcClaim(
      mnemonic: m,
      btcTxid: h.txid,
      btcVout: h.vout,
      btcAmountSats: h.amount,
      destAddress: dest,
      feeSats: _kClaimFeeSats,
      redeemScriptHex: h.redeemScript,
      preimageHex: rec.preimage,
    );
    final txid = await core.btcBroadcast(t4Api: Backend.testnet4, txHex: hex);
    rec
      ..claimTxid = txid
      ..step = SubSellStep.done;
    await SubSellStore.save(rec);
    TradeReceipts.log(
      id: 'subsell:${rec.hashHex}',
      title: 'Sold ${rec.ticker} for BTC',
      status: rec.shortfall ? 'BTC claimed (below quote)' : 'BTC claimed',
      txid: rec.claimTxid,
    ).ignore();
    return rec;
  }

  /// On wallet load / cold start: if a sell paid the asset but its BTC claim never confirmed, re-attempt
  /// the claim (the preimage + HTLC terms are persisted). The fund-recovery path. Leaves the record in
  /// place on success (terminal 'done'); a failure keeps it 'claiming' for the next retry.
  static Future<void> resume() async {
    final rec = await SubSellStore.load();
    if (rec == null || rec.step != SubSellStep.claiming || rec.preimage.isEmpty) return;
    try {
      await claim(rec);
    } catch (_) {
      // Leave persisted; the HTLC may already be claimed, or the claim needs a retry — surfaced when
      // the user re-enters the sub-asset SELL screen.
    }
  }
}

/// hex string -> bytes (for the sha256(preimage) == H check).
List<int> _hexBytes(String hex) {
  final s = hex.startsWith('0x') ? hex.substring(2) : hex;
  if (s.length.isOdd) throw const FormatException('odd-length hex');
  final out = List<int>.filled(s.length ~/ 2, 0);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
