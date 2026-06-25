import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Full-screen camera QR scanner. Requests the camera permission up front and
/// recovers gracefully if it is denied. Pops the first decoded payload (raw
/// string); the caller parses out the address. Returns null if the user backs out.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  MobileScannerController? _controller;
  PermissionStatus? _perm;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _request();
  }

  Future<void> _request() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _perm = status;
      if (status.isGranted) _controller ??= MobileScannerController();
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final code = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (code != null && code.trim().isNotEmpty) {
      _handled = true;
      Navigator.of(context).pop(code.trim());
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
        actions: [
          if (_controller != null)
            IconButton(
              icon: const Icon(Icons.flash_on, color: Colors.white),
              onPressed: () => _controller!.toggleTorch(),
            ),
        ],
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.no_photography_outlined, color: Colors.white54, size: 48),
            const SizedBox(height: 16),
            const Text('Camera access is needed to scan a QR code.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 15)),
            const SizedBox(height: 20),
            SizedBox(
              width: 240,
              child: PrimaryButton(
                label: perm.isPermanentlyDenied ? 'Open settings' : 'Allow camera',
                icon: Icons.camera_alt,
                onPressed: () => perm.isPermanentlyDenied ? openAppSettings() : _request(),
              ),
            ),
            const SizedBox(height: 10),
            GhostButton(label: 'Enter address manually', onPressed: () => Navigator.of(context).pop()),
          ]),
        ),
      );
    }
    return Stack(fit: StackFit.expand, children: [
      MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
        errorBuilder: (context, error, child) => Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Text('Camera error (${error.errorCode.name}). Try again, or check app permissions.',
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ),
        ),
      ),
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
    ]);
  }
}
