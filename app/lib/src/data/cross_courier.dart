import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../rust/api.dart' as core;
import 'config.dart';

/// XcMsg type tags — mirror the Go XcMsgType and the web wallet's xcourier.js XcType. An XcMsg is a JSON
/// object with a `type`, sealed E2E (AES-256-GCM over sha256(secp256k1 ECDH raw-X)); the relay only ever
/// moves sealed bytes.
class XcType {
  static const termsRequest = 'terms_request';
  static const terms = 'terms';
  static const btcLegFunded = 'btc_leg_funded';
  static const fail = 'fail';
}

/// A live E2E cross-lift courier session over the relay WebSocket: sealed send + typed recv — the mobile
/// twin of the web wallet's CourierSession. Opening it COMMITS NO FUNDS: the pre-lock terms handshake
/// fails fast (spending nothing) if the maker/relay does not answer, so a durably-resting cross offer
/// whose agent is momentarily offline strands nobody.
class CrossCourier {
  CrossCourier._(this._ws, this._myPriv, this._makerPub);

  final WebSocket _ws;
  final String _myPriv; // taker ephemeral session priv (hex)
  final String _makerPub; // maker identity pubkey (hex)
  String sessionId = '';

  final _buffer = <Map<String, dynamic>>[];
  Completer<void>? _wake;
  StreamSubscription? _sub;
  bool _closed = false;

  /// The relay WS endpoint: the same-origin /seqob base, scheme-swapped to ws(s), + /v1/ws.
  static String wsUrl() => '${Backend.seqob.replaceFirst(RegExp(r'^http'), 'ws')}/v1/ws';

  static Uint8List _hexBytes(String hex) {
    final s = hex.startsWith('0x') ? hex.substring(2) : hex;
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  void _attach() {
    _sub = _ws.listen(
      (data) {
        try {
          final s = data is String ? data : utf8.decode((data as List<int>));
          final m = jsonDecode(s);
          if (m is Map<String, dynamic>) {
            _buffer.add(m);
            _wake?.complete();
            _wake = null;
          }
        } catch (_) {/* ignore undecodable frames */}
      },
      onError: (_) {
        _wake?.complete();
        _wake = null;
      },
      onDone: () {
        _closed = true;
        _wake?.complete();
        _wake = null;
      },
    );
  }

  /// Pull the next raw envelope whose [pick] returns a Map payload, within [timeout]. [onError] pulls a
  /// relay error field (throws if present). A pull-based reader over the push WebSocket.
  Future<Map<String, dynamic>> _await(
    Object? Function(Map<String, dynamic>) pick, {
    Object? Function(Map<String, dynamic>)? onError,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      while (_buffer.isNotEmpty) {
        final m = _buffer.removeAt(0);
        if (onError != null) {
          final e = onError(m);
          if (e != null) throw Exception('relay: $e');
        }
        final p = pick(m);
        if (p is Map) return Map<String, dynamic>.from(p);
      }
      final remaining = deadline.difference(DateTime.now());
      if (_closed || remaining.isNegative || remaining == Duration.zero) {
        throw Exception('the relay did not respond in time');
      }
      _wake = Completer<void>();
      await _wake!.future.timeout(remaining, onTimeout: () {});
    }
  }

  /// Open a courier session for [offerId] against [makerPubHex]. Generates an ephemeral session key,
  /// sends StartLift, awaits LiftAccepted (MITM-checks the echoed maker key), returns the live session.
  /// Throws (spending nothing) if the relay/maker does not accept in time.
  static Future<CrossCourier> open({
    required String offerId,
    required String makerPubHex,
    required BigInt takeAmount,
    String takerFeeAsset = '',
    Duration acceptTimeout = const Duration(seconds: 25),
  }) async {
    final kp = await core.seqobEphemeralKey();
    final ws = await WebSocket.connect(wsUrl()).timeout(const Duration(seconds: 15));
    final c = CrossCourier._(ws, kp.privHex, makerPubHex).._attach();
    try {
      ws.add(jsonEncode({
        'start_lift': {
          'offer_id': offerId,
          'maker_pubkey': makerPubHex,
          'take_amount': takeAmount.toString(),
          'taker_fee_asset': takerFeeAsset,
          'taker_session_pubkey': base64Encode(_hexBytes(kp.pubHex)),
        }
      }));
      final la = await c._await(
        (m) => m['lift_accepted'] ?? m['liftAccepted'],
        onError: (m) => m['error'],
        timeout: acceptTimeout,
      );
      final echo = la['maker_session_pubkey'] ?? la['makerSessionPubkey'];
      if (echo != null && base64Encode(_hexBytes(makerPubHex)) != echo) {
        throw Exception('The relay returned a mismatched maker key (possible MITM); aborting.');
      }
      c.sessionId = '${la['session_id'] ?? la['sessionId'] ?? ''}';
      if (c.sessionId.isEmpty) throw Exception('The relay did not accept the lift.');
      return c;
    } catch (e) {
      await c.close();
      rethrow;
    }
  }

  /// Seal + courier an XcMsg to the maker.
  Future<void> send(Map<String, dynamic> xcmsg) async {
    final sealed = await core.seqobE2ESeal(
      myPrivHex: _myPriv,
      peerPubHex: _makerPub,
      plaintext: Uint8List.fromList(utf8.encode(jsonEncode(xcmsg))),
    );
    _ws.add(jsonEncode({
      'swap_msg': {'session_id': sessionId, 'ciphertext': base64Encode(sealed)}
    }));
  }

  /// Await the next XcMsg of [wantType] for this session, opening sealed swap_msgs and skipping
  /// unknown/out-of-order ones (continue-on-open-failure, matching the Go driver). Surfaces a peer
  /// `fail` as an exception; times out (spending nothing) if the maker goes silent.
  Future<Map<String, dynamic>> recv(String wantType, {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) throw Exception('The maker did not respond in time.');
      final env = await _await((m) => m['swap_msg'] ?? m['swapMsg'], timeout: remaining);
      if ('${env['session_id'] ?? env['sessionId'] ?? ''}' != sessionId) continue;
      final ct = env['ciphertext'];
      if (ct is! String) continue;
      Map<String, dynamic> xc;
      try {
        final pt = await core.seqobE2EOpen(myPrivHex: _myPriv, peerPubHex: _makerPub, sealed: base64Decode(ct));
        final j = jsonDecode(utf8.decode(pt));
        if (j is! Map<String, dynamic>) continue;
        xc = j;
      } catch (_) {
        continue; // open failure -> skip, don't abort (matches the Go recvXcType loop)
      }
      final t = '${xc['type'] ?? ''}';
      if (t == XcType.fail) {
        throw Exception('The maker failed the lift: ${xc['code'] ?? ''} ${xc['message'] ?? ''}'.trim());
      }
      if (t == wantType) return xc;
      // else: an out-of-order/unknown XcMsg — skip and keep waiting.
    }
  }

  /// Best-effort tell the peer we are aborting, then close.
  Future<void> fail(String code, String message) async {
    try {
      await send({'type': XcType.fail, 'code': code, 'message': message});
    } catch (_) {}
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _sub?.cancel();
    } catch (_) {}
    try {
      await _ws.close();
    } catch (_) {}
    _wake?.complete();
    _wake = null;
  }
}
