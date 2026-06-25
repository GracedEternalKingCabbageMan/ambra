import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/theme.dart';

/// Full-screen camera QR scanner. Pops the first decoded payload (raw string);
/// the caller parses out the address. Returns null if the user backs out.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
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
          IconButton(
            icon: const Icon(Icons.flash_on, color: Colors.white),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        // Simple framing guide.
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
    );
  }
}
