import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// Full-screen camera QR scanner. Requests the camera permission up front and
/// recovers gracefully if it is denied or the camera fails to start. Pops the
/// first decoded payload (raw string); the caller parses out the address.
/// Returns null if the user backs out or chooses to type the address instead.
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
      if (status.isGranted) {
        // QR-only and de-duplicated; the widget auto-starts the camera and
        // drives its lifecycle (start/stop on resume/pause).
        _controller ??= MobileScannerController(
          formats: const [BarcodeFormat.qrCode],
          detectionSpeed: DetectionSpeed.noDuplicates,
        );
      }
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
      return _Notice(
        icon: Icons.no_photography_outlined,
        text: 'Camera access is needed to scan a QR code.',
        actionLabel: perm.isPermanentlyDenied ? 'Open settings' : 'Allow camera',
        actionIcon: perm.isPermanentlyDenied ? Icons.settings : Icons.camera_alt,
        onAction: () => perm.isPermanentlyDenied ? openAppSettings() : _request(),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator(color: AmbraColors.amber));
    }
    return Stack(fit: StackFit.expand, children: [
      MobileScanner(
        controller: controller,
        onDetect: _onDetect,
        errorBuilder: (context, error) => _Notice(
          icon: Icons.videocam_off_outlined,
          text: 'The camera could not start (${error.errorCode.name}).${_detail(error)}',
          actionLabel: 'Try again',
          actionIcon: Icons.refresh,
          onAction: () => controller.start(),
        ),
      ),
      // Decorative only; must not absorb taps meant for the error card / preview.
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

  /// The underlying native error (code/message), shown beneath the generic code
  /// so a failure is diagnosable without a logcat.
  String _detail(MobileScannerException error) {
    final d = error.errorDetails;
    final parts = [d?.code, d?.message].where((s) => s != null && s.trim().isNotEmpty).toList();
    return parts.isEmpty ? '' : '\n${parts.join(' · ')}';
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
