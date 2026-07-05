// SeqLN Tier-2 wallet device-signer SDK (phone).
//
// The Dart twin of the browser `seqln-signer-sdk.js`. One clean class the wallet
// drives to turn the on-device mnemonic into a live, NON-CUSTODIAL signer for a
// HOSTED SeqLN node. The wallet never ships keys off the phone: this SDK holds
// the mnemonic-derived signer in native Rust (via flutter_rust_bridge), connects
// OUT over a WebSocket to the LSP's Noise_XK responder (behind a WS<->TCP relay),
// authenticates with BOLT-8 Noise_XK, and then SERVES the hosted lightningd's
// stream of hsmd sign-requests for the life of the connection. The host can never
// move the user's funds; it only asks the device to co-sign, and (in enforce
// mode) the device refuses theft-shaped requests.
//
//   final s = SeqlnSigner.fromMnemonic(mnemonic);        // native signer on device
//   s.onStatus  = (st)  => setState(...);                // connecting/serving/...
//   s.onRequest = (req) => log(req);                     // per hsmd sign request
//   await s.connect(
//     wsUrl: 'wss://lsp.example/seqln',
//     hostStaticPubkey: hostPubBytes,
//     deviceStaticPrivkey: devicePrivBytes,
//   );
//   print('node id ${s.nodeId()}');                      // derived over the link
//   ...
//   await s.disconnect();
//
// The only transports are Dart's `WebSocket` (production, to the LSP) and `Socket`
// (raw TCP, for the laptop harness / a proxy in SEQLN_SIGNER_LISTEN mode). The
// Noise handshake + the u32-LE signer-split frame codec are transport-agnostic
// opaque bytes, so both paths share one serve loop.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../rust/api/signer.dart' as ffi;

/// The M4 validating policy mode. `enforce` makes the device refuse to sign a
/// commitment that moves funds to a non-channel destination.
enum SeqlnPolicy { permissive, enforce }

/// A connection lifecycle status pushed to [SeqlnSigner.onStatus].
class SeqlnStatus {
  const SeqlnStatus(this.state, {this.detail, this.nodeId, this.devicePubkey});

  /// idle | connecting | handshaking | authenticated | node_id | closed | error.
  final String state;
  final String? detail;
  final String? nodeId;
  final String? devicePubkey;

  @override
  String toString() => 'SeqlnStatus($state${detail == null ? '' : ': $detail'})';
}

/// One served hsmd sign-request, pushed to [SeqlnSigner.onRequest].
class SeqlnRequest {
  const SeqlnRequest({
    required this.seq,
    required this.type,
    required this.name,
    required this.replyBytes,
    required this.rejected,
  });

  final int seq;
  final int type;
  final String name;
  final int replyBytes;

  /// True when the reply is the zero-length sentinel — an unimplemented message
  /// or (in enforce mode) a policy rejection.
  final bool rejected;
}

/// hsmd request type names (from `hsmd/hsmd_wire.csv`), for a readable log.
const Map<int, String> _hsmdNames = {
  1: 'ECDH', 2: 'CANNOUNCEMENT_SIG', 3: 'CUPDATE_SIG', 4: 'SIGN_ANY_CANNOUNCEMENT',
  5: 'SIGN_COMMITMENT_TX', 6: 'NODE_ANNOUNCEMENT_SIG', 7: 'SIGN_WITHDRAWAL',
  8: 'SIGN_INVOICE', 9: 'CLIENT_HSMFD', 10: 'GET_CHANNEL_BASEPOINTS', 11: 'INIT',
  12: 'SIGN_DELAYED_PAYMENT_TO_US', 13: 'SIGN_REMOTE_HTLC_TO_US',
  14: 'SIGN_PENALTY_TO_US', 18: 'GET_PER_COMMITMENT_POINT',
  19: 'SIGN_REMOTE_COMMITMENT_TX', 20: 'SIGN_REMOTE_HTLC_TX',
  21: 'SIGN_MUTUAL_CLOSE_TX', 24: 'GET_OUTPUT_SCRIPTPUBKEY', 27: 'DERIVE_SECRET',
  28: 'CHECK_PUBKEY', 30: 'NEW_CHANNEL', 31: 'SETUP_CHANNEL', 32: 'CHECK_OUTPOINT',
  34: 'FORGET_CHANNEL', 35: 'VALIDATE_COMMITMENT_TX', 36: 'VALIDATE_REVOCATION',
  37: 'LOCK_OUTPOINT', 40: 'REVOKE_COMMITMENT_TX', 56: 'CHECK_BIP86_PUBKEY',
  142: 'SIGN_ANY_DELAYED_PAYMENT_TO_US', 143: 'SIGN_ANY_REMOTE_HTLC_TO_US',
  144: 'SIGN_ANY_PENALTY_TO_US', 146: 'SIGN_ANY_LOCAL_HTLC_TX',
};

String _hsmdName(int t) => _hsmdNames[t] ?? 'type $t';

/// The device signer + its live connection to a hosted SeqLN node.
class SeqlnSigner {
  SeqlnSigner._(this._inner);

  final ffi.SeqlnSigner _inner;

  /// Build from a BIP-39 mnemonic (no passphrase). The mnemonic is derived into
  /// the native signer and never leaves the device.
  factory SeqlnSigner.fromMnemonic(String mnemonic) =>
      SeqlnSigner._(ffi.SeqlnSigner.fromMnemonic(mnemonic: mnemonic.trim()));

  /// Build from the raw `hsm_secret` bytes (`32 zero bytes || mnemonic`).
  factory SeqlnSigner.fromHsmSecret(List<int> bytes) =>
      SeqlnSigner._(ffi.SeqlnSigner.fromHsmSecret(hsmSecretBytes: bytes));

  /// The transport pubkey (33-byte hex) a host must pin for a device privkey,
  /// without constructing a signer (handy for a provisioning UI).
  static String devicePubkey(List<int> privkey) =>
      ffi.devicePubkey(staticPrivkey: privkey);

  // UI hooks (assignable).
  void Function(SeqlnStatus status)? onStatus;
  void Function(SeqlnRequest req)? onRequest;

  String _state = 'idle';
  String? _nodeId;
  String? _devicePub;
  String? _closeErr;
  final Map<int, int> _served = {};

  WebSocket? _ws;
  Socket? _socket;
  StreamSubscription<void>? _sub;
  Future<void>? _serveLoop;

  /// The device node id: known from the mnemonic immediately, and re-confirmed
  /// against the hosted node's INIT reply once the link is up.
  String nodeId() => _nodeId ?? _inner.nodeId();

  /// The pinned device transport pubkey (hex), once [connect] has run.
  String? devicePubkeyHex() => _devicePub;

  /// A copy of the per-hsmd-type served counters.
  Map<int, int> servedCounts() => Map.of(_served);

  String state() => _state;

  /// Select the validating policy. Returns `this` for chaining.
  SeqlnSigner setPolicy(SeqlnPolicy mode) {
    _inner.setEnforce(enforce: mode == SeqlnPolicy.enforce);
    return this;
  }

  void _status(String state, [String? detail]) {
    _state = state;
    final cb = onStatus;
    if (cb != null) {
      cb(SeqlnStatus(state, detail: detail, nodeId: _nodeId, devicePubkey: _devicePub));
    }
  }

  /// Open a WebSocket to the LSP, run the Noise_XK INITIATOR handshake, and start
  /// serving the hosted node's sign requests. Resolves once authenticated +
  /// serving (the node id arrives shortly after, on the first INIT; see
  /// [whenNodeId]). Throws if the socket, handshake, or host key check fails.
  Future<void> connect({
    required String wsUrl,
    required List<int> hostStaticPubkey,
    required List<int> deviceStaticPrivkey,
    Duration openTimeout = const Duration(seconds: 15),
  }) async {
    if (_ws != null || _socket != null) {
      throw StateError('already connected');
    }
    _status('connecting', wsUrl);
    final WebSocket ws;
    try {
      ws = await WebSocket.connect(wsUrl).timeout(openTimeout);
    } catch (e) {
      _status('error', 'websocket connect failed: $e');
      rethrow;
    }
    _ws = ws;
    // Binary frames arrive as List<int>; coerce (text is unexpected on this link).
    final reader = _ByteStreamReader(
      ws.map<List<int>>((d) => d is String ? d.codeUnits : (d as List<int>)),
    );
    await _handshakeAndServe(reader, ws.add, hostStaticPubkey, deviceStaticPrivkey);
  }

  /// The raw-TCP variant (the laptop harness / a proxy in SEQLN_SIGNER_LISTEN
  /// responder mode). Identical Noise handshake + serve loop, over a `Socket`.
  Future<void> connectTcp({
    required String host,
    required int port,
    required List<int> hostStaticPubkey,
    required List<int> deviceStaticPrivkey,
    Duration openTimeout = const Duration(seconds: 15),
  }) async {
    if (_ws != null || _socket != null) {
      throw StateError('already connected');
    }
    _status('connecting', '$host:$port');
    final Socket sock;
    try {
      sock = await Socket.connect(host, port, timeout: openTimeout);
    } catch (e) {
      _status('error', 'tcp connect failed: $e');
      rethrow;
    }
    sock.setOption(SocketOption.tcpNoDelay, true);
    _socket = sock;
    final reader = _ByteStreamReader(sock);
    await _handshakeAndServe(reader, sock.add, hostStaticPubkey, deviceStaticPrivkey);
  }

  Future<void> _handshakeAndServe(
    _ByteStreamReader reader,
    void Function(List<int>) send,
    List<int> hostStaticPubkey,
    List<int> deviceStaticPrivkey,
  ) async {
    _sub = reader.subscription;
    _devicePub = ffi.devicePubkey(staticPrivkey: deviceStaticPrivkey);

    // --- BOLT-8 Noise_XK handshake as INITIATOR ---
    _status('handshaking', 'Noise_XK act one');
    final noise = ffi.NoiseSession.newInitiator(
      hostStaticPubkey: hostStaticPubkey,
      deviceStaticPrivkey: deviceStaticPrivkey,
      ephemeralEntropy: _rand32(),
    );

    send(noise.writeActOne()); // 50 bytes
    final Uint8List act2;
    try {
      act2 = await reader.readExact(50);
    } catch (e) {
      _status('error', 'no act two (handshake rejected: wrong host key or unreachable)');
      await _closeTransport();
      throw StateError('handshake failed before act two: $e');
    }
    final Uint8List act3;
    try {
      act3 = noise.readActTwo(act2: act2); // throws if the host key is wrong
    } catch (e) {
      _status('error', 'host authentication failed (wrong host key)');
      await _closeTransport();
      throw StateError('Noise_XK host auth failed: $e');
    }
    send(act3); // 66 bytes
    _status('authenticated', 'Noise_XK complete; serving sign requests');

    // Serve for the life of the connection (not awaited by connect()).
    _serveLoop = _serve(reader, send, noise);
  }

  Future<void> _serve(
    _ByteStreamReader reader,
    void Function(List<int>) send,
    ffi.NoiseSession noise,
  ) async {
    var plain = <int>[];

    Future<void> refill() async {
      final hdr = await reader.readExact(18);
      final bodyLen = noise.decryptHeader(hdr: hdr);
      final body = await reader.readExact(bodyLen + 16);
      plain.addAll(noise.decryptBody(body: body));
    }

    var seq = 0;
    try {
      while (true) {
        while (plain.length < 4) {
          await refill();
        }
        final flen = _readU32LE(plain, 0);
        while (plain.length < 4 + flen) {
          await refill();
        }
        final frame = Uint8List.fromList(plain.sublist(0, 4 + flen));
        plain = plain.sublist(4 + flen);

        final type = _frameHsmdType(frame);
        _served.update(type, (v) => v + 1, ifAbsent: () => 1);

        final reply = _inner.processFrame(frameBytes: frame); // native signs
        if (_nodeId == null) {
          final id = _nodeIdFromInitReply(reply);
          if (id != null) {
            _nodeId = id;
            _status('node_id', id);
          }
        }
        seq += 1;
        onRequest?.call(SeqlnRequest(
          seq: seq,
          type: type,
          name: _hsmdName(type),
          replyBytes: reply.length - 4,
          rejected: reply.length == 4,
        ));
        send(noise.encrypt(msg: reply));
      }
    } catch (e) {
      if (_state != 'closed') {
        _closeErr = e.toString();
        _status('error', e.toString());
      }
      await _closeTransport();
    }
  }

  /// Block until the node id is known (first INIT served) or the link ends.
  Future<String> whenNodeId({Duration timeout = const Duration(seconds: 20)}) async {
    final start = DateTime.now();
    while (_nodeId == null) {
      if (_state == 'closed' || _state == 'error') {
        throw StateError(_closeErr ?? 'link ended before INIT');
      }
      if (DateTime.now().difference(start) > timeout) {
        throw TimeoutException('timed out waiting for node id');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return _nodeId!;
  }

  /// Close the link and stop serving.
  Future<void> disconnect() async {
    _status('closed', 'disconnect()');
    await _closeTransport();
    // Let the serve loop unwind (its readExact throws once the stream is done).
    try {
      await _serveLoop;
    } catch (_) {}
    _serveLoop = null;
  }

  Future<void> _closeTransport() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _ws?.close();
    } catch (_) {}
    try {
      await _socket?.close();
    } catch (_) {}
    _socket?.destroy();
    _ws = null;
    _socket = null;
  }
}

// ---- transport-agnostic byte-stream reader --------------------------------

/// Buffers a byte stream (WebSocket binary frames or a TCP socket, which may
/// coalesce or split at arbitrary boundaries) and offers [readExact]. The app
/// framing (Noise records, then u32-LE signer frames) is self-delimiting, so a
/// faithful in-order byte reader is all that is required.
class _ByteStreamReader {
  _ByteStreamReader(Stream<List<int>> stream) {
    subscription = stream.listen(
      _onData,
      onError: (Object e) {
        _error = e;
        _closed = true;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<void> subscription;
  Uint8List _buf = Uint8List(0);
  Completer<void>? _waiter;
  bool _closed = false;
  Object? _error;

  void _onData(List<int> chunk) {
    final next = Uint8List(_buf.length + chunk.length);
    next.setRange(0, _buf.length, _buf);
    next.setRange(_buf.length, next.length, chunk);
    _buf = next;
    _wake();
  }

  void _wake() {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete();
    }
  }

  Future<Uint8List> readExact(int n) async {
    while (_buf.length < n) {
      if (_closed) {
        throw StateError(_error?.toString() ?? 'link closed');
      }
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final out = Uint8List.fromList(_buf.sublist(0, n));
    _buf = Uint8List.fromList(_buf.sublist(n));
    return out;
  }
}

// ---- byte helpers ----------------------------------------------------------

Uint8List _rand32() {
  final r = Random.secure();
  final b = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

int _readU32LE(List<int> b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) & 0xffffffff;

/// hsmd request type out of a signer-split frame:
///   u32-LE len | u8 is_main | [33B node_id if !is_main] | u64 dbid | u64 caps | u16 type ...
int _frameHsmdType(Uint8List frame) {
  final isMain = frame[4];
  final off = 4 + 1 + (isMain != 0 ? 0 : 33) + 8 + 8;
  if (frame.length < off + 2) return -1;
  return (frame[off] << 8) | frame[off + 1];
}

/// node_id out of a WIRE_HSMD_INIT_REPLY_V4 framed reply:
///   [u32 len] u16 type(114) u32 hsm_version u16 num_caps caps(4*n) node_id(33) ...
String? _nodeIdFromInitReply(Uint8List framed) {
  if (framed.length < 4 + 8) return null;
  final body = framed.sublist(4);
  if (((body[0] << 8) | body[1]) != 114) return null; // 114 = INIT_REPLY_V4
  final numCaps = (body[6] << 8) | body[7];
  final off = 2 + 4 + 2 + 4 * numCaps;
  if (body.length < off + 33) return null;
  final sb = StringBuffer();
  for (var i = off; i < off + 33; i++) {
    sb.write(body[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
