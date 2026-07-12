import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zxing2/qrcode.dart';

import '../data/lightning_service.dart';
import '../theme/theme.dart';
import '../widgets/ln_cards.dart';
import '../widgets/widgets.dart';

/// Full-screen QR scanner built on the first-party camera (CameraX preview) and
/// a pure-Dart ZXing decoder, so it needs no Google ML Kit or Play Services.
/// Pops the first decoded payload (raw string); the caller parses out the
/// address. Returns null if the user backs out or types the address instead.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  PermissionStatus? _perm;
  String? _error;
  bool _busy = false; // a decode is in flight (frames are skipped meanwhile)
  bool _handled = false; // a code was found; ignore further frames
  DateTime _lastDecode = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.resumed) {
      _start(); // re-acquire the camera after returning to the foreground
    } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      c.dispose();
      _controller = null;
    }
  }

  Future<void> _start() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _perm = status;
      _error = null;
    });
    if (!status.isGranted) return;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw Exception('no camera found');
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final c = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      await c.startImageStream(_onFrame);
      setState(() => _controller = c);
    } catch (e) {
      if (mounted) setState(() => _error = 'The camera could not start. $e');
    }
  }

  void _onFrame(CameraImage image) {
    if (_busy || _handled) return;
    final now = DateTime.now();
    if (now.difference(_lastDecode).inMilliseconds < 220) return; // ease CPU/battery
    _lastDecode = now;
    _busy = true;
    String? code;
    try {
      code = _decode(image);
    } catch (_) {
      code = null;
    }
    if (code != null && code.trim().isNotEmpty && !_handled && mounted) {
      _handled = true;
      _controller?.stopImageStream();
      final trimmed = code.trim();
      // A scanned BOLT11 invoice isn't an on-chain address: route it to the Lightning pay card
      // (the caller's Send screen only handles addresses). Only when Lightning is deployed — when
      // dormant, pop the raw string so Send can show its own "not a valid address" message rather
      // than opening a dead LN screen.
      final invoice = _bolt11(trimmed);
      if (invoice != null && LightningService.instance.configured) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LnPayScreen(invoice: invoice)));
      } else {
        Navigator.of(context).pop(trimmed);
      }
      return;
    }
    _busy = false;
  }

  /// The BOLT11 invoice in [raw] (optionally behind a `lightning:` URI prefix), or null if the code
  /// isn't a Lightning invoice. Matches the human-readable prefix for Bitcoin main/test/signet/regtest
  /// (lnbc / lntb / lntbs / lnbcrt), case-insensitively.
  static String? _bolt11(String raw) {
    var s = raw.trim();
    if (s.toLowerCase().startsWith('lightning:')) s = s.substring('lightning:'.length).trim();
    final ok = RegExp(r'^(lnbcrt|lntbs|lnbc|lntb)[0-9]', caseSensitive: false).hasMatch(s);
    return ok ? s : null;
  }

  /// Decode a QR from the frame's luminance (Y) plane. Returns null when there's
  /// no readable QR in the frame.
  String? _decode(CameraImage image) {
    final plane = image.planes.first; // Y (luminance) for yuv420
    final w = image.width;
    final h = image.height;
    final bytes = plane.bytes;
    final stride = plane.bytesPerRow; // may exceed width (row padding)
    final pixels = Int32List(w * h);
    for (int y = 0; y < h; y++) {
      final row = y * stride;
      final out = y * w;
      for (int x = 0; x < w; x++) {
        final lum = bytes[row + x];
        pixels[out + x] = 0xff000000 | (lum << 16) | (lum << 8) | lum;
      }
    }
    final bitmap = BinaryBitmap(HybridBinarizer(RGBLuminanceSource(w, h, pixels)));
    final hints = DecodeHints()..put(DecodeHintType.tryHarder);
    try {
      return QRCodeReader().decode(bitmap, hints: hints).text;
    } on ReaderException {
      return null; // no / unreadable QR in this frame
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Scan address', style: AmbraText.title),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    final perm = _perm;
    if (perm == null) {
      return const Center(child: CircularProgressIndicator(color: AmbraColors.amber));
    }
    if (!perm.isGranted) {
      return _Notice(
        icon: Icons.no_photography_outlined,
        text: 'Camera access is needed to scan a QR code.',
        actionLabel: perm.isPermanentlyDenied ? 'Open settings' : 'Allow camera',
        actionIcon: perm.isPermanentlyDenied ? Icons.settings : Icons.camera_alt,
        onAction: () => perm.isPermanentlyDenied ? openAppSettings() : _start(),
      );
    }
    if (_error != null) {
      return _Notice(
        icon: Icons.videocam_off_outlined,
        text: _error!,
        actionLabel: 'Try again',
        actionIcon: Icons.refresh,
        onAction: _start,
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: AmbraColors.amber));
    }
    final preview = controller.value.previewSize;
    return Stack(fit: StackFit.expand, children: [
      // Cover the screen with the preview (previewSize is in sensor/landscape
      // orientation, so width/height are swapped for the portrait scaffold).
      FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: preview?.height ?? 1080,
          height: preview?.width ?? 1920,
          child: CameraPreview(controller),
        ),
      ),
      // Decorative only; must not absorb taps.
      IgnorePointer(
        child: Stack(fit: StackFit.expand, children: [
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: AmbraColors.amber, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 60,
            child: Center(
              child: Text('Point the camera at a Sequentia address QR',
                  style: TextStyle(color: Colors.white70, fontSize: 14)),
            ),
          ),
        ]),
      ),
    ]);
  }
}

/// A centered icon + message with a primary action and an always-available
/// "Enter address manually" escape (pops with no result).
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
  });

  final IconData icon;
  final String text;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.white54, size: 48),
          const SizedBox(height: 16),
          Text(text,
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 15)),
          const SizedBox(height: 20),
          SizedBox(width: 240, child: PrimaryButton(label: actionLabel, icon: actionIcon, onPressed: onAction)),
          const SizedBox(height: 10),
          GhostButton(label: 'Enter address manually', onPressed: () => Navigator.of(context).pop()),
        ]),
      ),
    );
  }
}
