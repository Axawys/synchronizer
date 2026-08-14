import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'layout.dart';

/// Reads a QR code with the device's camera.
///
/// A camera is the one thing this app cannot reach in pure Dart, and the
/// desktop has no scanner worth the name, so - like the hotspot controls - the
/// apps supply this and the screen adapts to its absence. Android implements
/// it; Linux passes nothing and the button is not offered.
abstract interface class QrScanner {
  /// Opens a camera view and returns the first code read, or null if the user
  /// backed out or refused the camera.
  Future<String?> scan(BuildContext context);
}

/// The code itself, drawn large enough to be read across a desk.
///
/// Deliberately plain black-on-white regardless of the app's theme: a scanner
/// looks for contrast, and a tinted code in a dark theme is a code that takes
/// three tries to read.
class PairingQrCode extends StatelessWidget {
  const PairingQrCode({super.key, required this.data, this.size = 220});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Layout.gap),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: Layout.cardCorners,
      ),
      child: QrImageView(
        data: data,
        size: size,
        backgroundColor: Colors.white,
        // A code carrying a pairing token is worth a moment of extra error
        // correction: a thumb over one corner should not cost a retry.
        errorCorrectionLevel: QrErrorCorrectLevel.M,
      ),
    );
  }
}
