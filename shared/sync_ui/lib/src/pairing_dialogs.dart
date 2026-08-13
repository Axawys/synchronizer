import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

/// Shown on the device that receives a pairing request. The user compares the
/// code with the other screen before accepting.
class ConfirmPairingDialog extends StatelessWidget {
  const ConfirmPairingDialog({super.key, required this.request});

  final IncomingPairing request;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.pairRequest(request.peer.name)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.checkCodeMatches),
          const SizedBox(height: 16),
          Center(child: PairingCodeText(request.code)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.reject),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.accept),
        ),
      ],
    );
  }
}

/// Shown on the device that initiates pairing. It first waits for the code,
/// displays it while the other side decides, then reports the outcome.
///
/// [name] is whatever the initiator knows the far end by: the name from the
/// discovery list, or - when dialling an address directly - the address itself,
/// since there is nothing else to call it until it answers.
class OutgoingPairingDialog extends StatelessWidget {
  const OutgoingPairingDialog({
    super.key,
    required this.name,
    required this.code,
    required this.result,
    this.onCancel,
  });

  final String name;
  final ValueListenable<String?> code;
  final Future<PairingResult> result;

  /// Calls the attempt off. The wait here is on a person at the other device,
  /// who may be nowhere near it, so there has to be a way out that is not
  /// closing the app.
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FutureBuilder<PairingResult>(
      future: result,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return AlertDialog(
            title: Text(l10n.pairingWith(name)),
            content: ValueListenableBuilder<String?>(
              valueListenable: code,
              builder: (context, value, _) {
                if (value == null) {
                  return PairingWaitingRow(l10n.contactingDevice);
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.confirmCodeOnOther),
                    const SizedBox(height: 16),
                    PairingCodeText(value),
                    const SizedBox(height: 16),
                    PairingWaitingRow(l10n.waitingForConfirmation),
                  ],
                );
              },
            ),
            actions: [
              if (onCancel != null)
                TextButton(
                  onPressed: () {
                    onCancel!();
                    Navigator.pop(context);
                  },
                  child: Text(l10n.connectCancel),
                ),
            ],
          );
        }

        final outcome = snapshot.data ??
            PairingResult(PairingStatus.failed, error: l10n.noResult);
        final peerName = outcome.peer?.name ?? name;
        // Called off from here: the dialog has already gone, and there is
        // nothing to report about a thing the user decided not to do.
        if (outcome.status == PairingStatus.cancelled) {
          return const SizedBox.shrink();
        }

        final message = switch (outcome.status) {
          PairingStatus.paired => l10n.pairedWith(peerName),
          PairingStatus.rejected => l10n.pairingDeclined(peerName),
          PairingStatus.cancelled => '',
          PairingStatus.failed => l10n.couldNotPair('${outcome.error}'),
        };
        return AlertDialog(
          title: Text(l10n.pairingTitle),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.ok),
            ),
          ],
        );
      },
    );
  }
}

/// The six digits both devices must show. Large, spaced and tabular, because
/// the whole point is comparing it with another screen at a glance.
class PairingCodeText extends StatelessWidget {
  const PairingCodeText(this.code, {super.key});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Text(
      code,
      style: const TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.bold,
        letterSpacing: 8,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

class PairingWaitingRow extends StatelessWidget {
  const PairingWaitingRow(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Flexible(child: Text(label)),
      ],
    );
  }
}
