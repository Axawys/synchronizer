import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

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

/// What the QR code says, in words, under the code itself.
///
/// The code is for the camera; this is for the person holding a device whose
/// camera will not focus, or who wants to know what they are about to hand
/// over. It is also the fallback path: everything here can be typed on the
/// other device by hand.
class QrDetails extends StatelessWidget {
  const QrDetails({super.key, required this.payload});

  final QrPayload payload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (payload.hasWifi) ...[
          _Line(label: l10n.qrNetwork, value: payload.wifiSsid!),
          if ((payload.wifiPassphrase ?? '').isNotEmpty)
            _Line(label: l10n.hotspotPassword, value: payload.wifiPassphrase!),
        ],
        if (payload.addresses.isNotEmpty)
          _Line(
            label: l10n.addressLabel,
            value: '${payload.addresses.first}:${payload.port}',
          ),
        const SizedBox(height: Layout.snug),
        Text(
          l10n.qrKeepOnScreen,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: colors.onSurfaceVariant, height: 1.4),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Layout.tight),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
