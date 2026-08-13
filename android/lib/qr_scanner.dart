import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sync_ui/sync_ui.dart';

/// Android's camera, reading the code shown on the other device.
///
/// The scanner lives in the phone app rather than the shared UI because it is
/// the only part of this that needs a camera, and the desktop has no answer for
/// it - the shared screen asks for a scanner and does without one when there is
/// none.
class AndroidQrScanner implements QrScanner {
  @override
  Future<String?> scan(BuildContext context) async {
    // Asked for before the camera view opens, and answered for. The scanner
    // plugin will ask on its own when it starts, but if that is refused - or
    // was refused once before, when Android stops asking at all - its preview
    // is simply black, which looks like a broken app rather than a decision the
    // user made.
    if (!await _cameraAllowed(context)) return null;
    if (!context.mounted) return null;

    return Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _ScannerPage()),
    );
  }

  Future<bool> _cameraAllowed(BuildContext context) async {
    if (await Permission.camera.isGranted) return true;

    final status = await Permission.camera.request();
    if (status.isGranted) return true;
    if (!context.mounted) return false;

    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          status.isPermanentlyDenied ? l10n.cameraDenied : l10n.cameraNeeded),
      action: status.isPermanentlyDenied
          ? SnackBarAction(
              label: l10n.cameraSettings,
              onPressed: openAppSettings,
            )
          : null,
    ));
    return false;
  }
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  final _controller = MobileScannerController(
    // One code is all this screen wants; the first good read closes it.
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final code = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .firstWhere((value) => value != null && value.isNotEmpty,
            orElse: () => null);
    if (code == null) return;

    _done = true;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.qrScanTitle)),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            // Both of these default to a plain black rectangle, which is
            // indistinguishable from a camera that is simply not working. A
            // screen that cannot show the camera has to say so.
            placeholderBuilder: (context, _) =>
                _Message(text: l10n.cameraStarting, spinner: true),
            errorBuilder: (context, error, _) => _Message(
              text: l10n.cameraFailed(_describe(error, l10n)),
              onRetry: _controller.start,
              retryLabel: l10n.tryAgain,
            ),
          ),
          // A frame to aim with, and a line saying what to aim at: a camera
          // view with no target is a camera view people hold at arm's length.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 3),
                borderRadius: const BorderRadius.all(Radius.circular(24)),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Text(
                l10n.qrScanHint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Turns the plugin's failure into something worth reading. The one that
  /// actually happens is a refused permission, so it gets its own words.
  String _describe(MobileScannerException error, AppLocalizations l10n) {
    return switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied => l10n.cameraDenied,
      _ => error.errorDetails?.message ?? error.errorCode.name,
    };
  }
}

/// What the camera view shows when there is no camera view: never a black
/// rectangle with nothing in it.
class _Message extends StatelessWidget {
  const _Message({
    required this.text,
    this.spinner = false,
    this.onRetry,
    this.retryLabel,
  });

  final String text;
  final bool spinner;
  final VoidCallback? onRetry;
  final String? retryLabel;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (spinner)
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                      strokeWidth: 3, color: Colors.white70),
                )
              else
                const Icon(Icons.videocam_off, color: Colors.white70, size: 32),
              const SizedBox(height: 20),
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 20),
                FilledButton.tonal(
                  onPressed: onRetry,
                  child: Text(retryLabel ?? ''),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
