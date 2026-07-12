import 'dart:convert';

import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import 'config.dart';
import 'seqdex_client.dart' show pick;

/// A resting offer on the SeqOB order-book relay (a covenant SELL of `baseAsset`
/// for `quoteAsset`). The raw JSON is kept so the covenant terms can be fed
/// verbatim into the covenant FILL FFI, and every offer carries a locally-checked
/// `verified` flag (the relay is untrusted; signatures are validated in Rust).
class SeqObOffer {
  SeqObOffer({
    required this.raw,
    required this.offerId,
    required this.baseAsset,
    required this.quoteAsset,
    required this.tradeDir,
    required this.baseAtoms,
    required this.wantAtoms,
    required this.minLot,
    required this.covenant,
    required this.makerPubkey,
    required this.verified,
    this.confidential = false,
  });

  final Map<String, dynamic> raw;
  final String offerId;
  final String baseAsset; // the asset the maker SELLS (asset A)
  final String quoteAsset; // the asset the maker WANTS (asset B)
  final int tradeDir; // 1 = SELL
  final BigInt baseAtoms; // available base atoms (sold)
  final BigInt wantAtoms; // quote atoms for a full fill
  final BigInt minLot; // min fillable base lot
  final Map<String, dynamic>? covenant; // CovenantTerms sub-object (or null)
  final String makerPubkey;
  final bool verified;

  /// Field-19 book-namespace tag: a blinded (confidential) resting offer whose
  /// both legs settle confidentially. A confidential offer rests as an interactive
  /// intent (NOT a covenant — a covenant FILL introspects EXPLICIT amounts, which
  /// CT cannot satisfy), so it carries no on-chain covenant to permissionlessly
  /// lift. See [SeqObClient.fetchBook] and the swap screen's Blinded book.
  final bool confidential;

  /// Quote atoms per 1 base atom (the price a taker pays). Lower = cheaper base.
  double get priceAtomsPerBase =>
      baseAtoms > BigInt.zero ? wantAtoms.toDouble() / baseAtoms.toDouble() : 0;

  /// A funded, on-chain covenant this wallet can permissionlessly fill.
  bool get isFillableCovenant =>
      covenant != null && (pick(covenant, ['covenant_txid', 'covenantTxid'])?.toString().isNotEmpty ?? false);

  /// The covenant terms JSON (bytes fields normalized to HEX) for the FILL FFI.
  String get covenantTermsJson => jsonEncode(_covenantHexNormalized(covenant ?? const {}));
}

/// A book snapshot for one pair, sorted best-price-first (cheapest base to buy).
class OrderBook {
  OrderBook(this.baseAsset, this.quoteAsset, this.offers);
  final String baseAsset;
  final String quoteAsset;
  final List<SeqObOffer> offers; // fillable covenant SELLs, cheapest first

  bool get isEmpty => offers.isEmpty;

  /// The best (cheapest) resting offer, or null on an empty book.
  SeqObOffer? get best => offers.isEmpty ? null : offers.first;

  /// Total base atoms available to buy across the book.
  BigInt get depthBaseAtoms => offers.fold(BigInt.zero, (a, o) => a + o.baseAtoms);
}

/// Thin HTTP client for the SeqOB relay (grpc-gateway REST under [Backend.seqob]).
/// All signing/verification is delegated to the ambra_core FFIs so the bytes match
/// the Go relay; this client is pure transport + parsing.
class SeqObClient {
  SeqObClient._();

  static Future<Map<String, dynamic>> _get(String path) async {
    final r = await http
        .get(Uri.parse('${Backend.seqob}$path'), headers: {...Backend.authHeaders})
        .timeout(const Duration(seconds: 30));
    return _decode(r);
  }

  static Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final r = await http
        .post(Uri.parse('${Backend.seqob}$path'),
            headers: {'Content-Type': 'application/json', ...Backend.authHeaders}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 30));
    return _decode(r);
  }

  static Map<String, dynamic> _decode(http.Response r) {
    Map<String, dynamic> j;
    try {
      j = r.body.isNotEmpty ? jsonDecode(r.body) as Map<String, dynamic> : <String, dynamic>{};
    } catch (_) {
      j = {'_raw': r.body};
    }
    if (r.statusCode != 200) {
      throw Exception('${pick(j, ['message', 'error']) ?? j['_raw'] ?? 'HTTP ${r.statusCode}'}');
    }
    return j;
  }

  /// Fetch the order book for (base, quote), verified locally and sorted
  /// cheapest-first.
  ///
  /// Default (Unblinded book): resting covenant SELLs of `base` for `quote` —
  /// only funded, fillable covenant offers are returned (the transparent book,
  /// byte-identical to the live route).
  ///
  /// `confidential: true` (Blinded book): requests the relay's segregated
  /// confidential namespace (`?confidential=1`). These offers rest as interactive
  /// intents (no on-chain covenant to lift), so they are returned regardless of a
  /// covenant and shown read-only; interactive confidential settlement is the
  /// documented courier residual.
  static Future<OrderBook> fetchBook(String baseAsset, String quoteAsset,
      {bool confidential = false}) async {
    final q = confidential ? '?confidential=1' : '';
    final j = await _get('/v1/market/$baseAsset/$quoteAsset/orderbook$q');
    final list = (j['offers'] as List?) ?? (j['Offers'] as List?) ?? const [];
    final offers = <SeqObOffer>[];
    for (final e in list) {
      if (e is! Map) continue;
      final o = Map<String, dynamic>.from(e);
      final offer = await _parseOffer(o);
      if (offer == null || offer.baseAtoms <= BigInt.zero) continue;
      if (confidential) {
        // Confidential offers carry no covenant; keep the ones tagged confidential.
        if (offer.confidential) offers.add(offer);
      } else if (offer.isFillableCovenant) {
        offers.add(offer);
      }
    }
    offers.sort((a, b) => a.priceAtomsPerBase.compareTo(b.priceAtomsPerBase));
    return OrderBook(baseAsset, quoteAsset, offers);
  }

  /// A maker's own resting orders (for a My-Orders list + cancel).
  static Future<List<SeqObOffer>> myOffers(String makerPubkey) async {
    final j = await _get('/v1/offers?maker_pubkey=${Uri.encodeComponent(makerPubkey)}');
    final list = (j['offers'] as List?) ?? (j['Offers'] as List?) ?? const [];
    final out = <SeqObOffer>[];
    for (final e in list) {
      if (e is! Map) continue;
      final offer = await _parseOffer(Map<String, dynamic>.from(e));
      if (offer != null) out.add(offer);
    }
    return out;
  }

  /// POST a signed covenant offer. The covenant `bytes` fields are HEX in the
  /// signed object (so the canonical bytes hashed in Rust match the Go relay); the
  /// grpc-gateway JSON wants base64 for proto `bytes`, so convert on the way out.
  static Future<void> postOffer(Map<String, dynamic> signedOffer) async {
    await _post('/v1/offers', _covenantOfferForPost(signedOffer));
  }

  /// POST a signed CONFIDENTIAL (blinded) offer. A confidential offer carries no
  /// covenant (only `same_chain{maker_recv_address, maker_blinding_pub}` + the
  /// signed `confidential:true` field-19 tag), so there is nothing to hex/base64
  /// normalize — the signed object is posted verbatim into the relay's
  /// confidential namespace.
  static Future<void> postConfidentialOffer(Map<String, dynamic> signedOffer) async {
    await _post('/v1/offers', signedOffer);
  }

  /// POST a signed OfferCancel (already assembled + signed by the core FFI).
  static Future<void> cancelOffer(Map<String, dynamic> signedCancel) async {
    await _post('/v1/offers/cancel', signedCancel);
  }

  // --- parsing helpers -------------------------------------------------------

  static Future<SeqObOffer?> _parseOffer(Map<String, dynamic> o) async {
    final covRaw = o['covenant'] ?? o['Covenant'];
    final cov = covRaw is Map ? Map<String, dynamic>.from(covRaw) : null;
    final pairRaw = o['pair'] ?? o['Pair'];
    final pair = pairRaw is Map ? Map<String, dynamic>.from(pairRaw) : const {};
    bool verified;
    try {
      verified = await core.seqobVerifyOffer(offerJson: jsonEncode(o));
    } catch (_) {
      verified = false;
    }
    return SeqObOffer(
      raw: o,
      offerId: '${pick(o, ['offer_id', 'offerId']) ?? ''}',
      baseAsset: '${pick(pair, ['base_asset', 'baseAsset']) ?? ''}',
      quoteAsset: '${pick(pair, ['quote_asset', 'quoteAsset']) ?? ''}',
      tradeDir: _dir(pick(o, ['trade_dir', 'tradeDir'])),
      baseAtoms: _big(pick(o, ['base_amount', 'baseAmount'])),
      wantAtoms: _big(pick(o, ['want_amount', 'wantAmount'])),
      minLot: cov == null ? BigInt.one : _big(pick(cov, ['min_lot', 'minLot'])),
      covenant: cov,
      makerPubkey: '${pick(o, ['maker_pubkey', 'makerPubkey']) ?? ''}',
      verified: verified,
      confidential: _bool(pick(o, ['confidential'])),
    );
  }

  static bool _bool(dynamic v) => v == true || v == 1 || v == '1' || v == 'true';

  static int _dir(dynamic v) {
    if (v is int) return v;
    final s = '$v';
    if (s == 'TRADE_DIR_SELL' || s == '1') return 1;
    if (s == 'TRADE_DIR_BUY' || s == '2') return 2;
    return int.tryParse(s) ?? 0;
  }

  static BigInt _big(dynamic v) => BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
}

// --- byte-field normalization (hex <-> base64) -------------------------------

const _covBytesFields = ['maker_prog', 'makerProg', 'maker_x', 'makerX', 'internal_key', 'internalKey'];

/// Return a copy of a CovenantTerms object with its `bytes` fields as HEX (the
/// relay may serve them as base64 via grpc-gateway; the covenant derivation +
/// FILL builder need hex). Idempotent for already-hex values.
Map<String, dynamic> _covenantHexNormalized(Map<String, dynamic> cov) {
  final out = Map<String, dynamic>.from(cov);
  for (final k in _covBytesFields) {
    final v = out[k];
    if (v is String && v.isNotEmpty) out[k] = _toHex(v);
  }
  final mp = out['merkle_path'] ?? out['merklePath'];
  if (mp is List) {
    out['merkle_path'] = mp.map((e) => _toHex('$e')).toList();
    out.remove('merklePath');
  }
  return out;
}

/// Build the POST body: a shallow copy of the signed offer whose covenant `bytes`
/// fields (HEX in the signed object) are converted to base64 for the proto JSON.
Map<String, dynamic> _covenantOfferForPost(Map<String, dynamic> offer) {
  final covRaw = offer['covenant'];
  if (covRaw is! Map) return offer;
  final cov = Map<String, dynamic>.from(covRaw);
  String b64(String hex) => base64.encode(_hexBytes(hex));
  for (final k in ['maker_prog', 'maker_x', 'internal_key']) {
    final v = cov[k];
    if (v is String && v.isNotEmpty) cov[k] = b64(v);
  }
  final mp = cov['merkle_path'];
  if (mp is List) cov['merkle_path'] = mp.map((e) => b64('$e')).toList();
  return {...offer, 'covenant': cov};
}

bool _isHex(String s) => s.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);

/// Coerce a hex-or-base64 string to lowercase hex.
String _toHex(String s) {
  if (_isHex(s)) return s.toLowerCase();
  try {
    final bytes = base64.decode(base64.normalize(s));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  } catch (_) {
    return s.toLowerCase();
  }
}

List<int> _hexBytes(String hex) {
  final out = <int>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    out.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return out;
}
