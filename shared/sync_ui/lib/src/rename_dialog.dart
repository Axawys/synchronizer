import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';

/// Asks for a new name for this device.
///
/// The name is not a private label: it is what every other device shows for
/// this one, and it travels in the next announcement, so the field says so
/// rather than leaving the user to find out by looking at the other screen.
Future<void> renameDeviceDialog(
  BuildContext context, {
  required String current,
  required Future<void> Function(String name)? onRename,
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (context) => _RenameDialog(current: current),
  );

  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty || trimmed == current) return;

  await onRename?.call(trimmed);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(AppLocalizations.of(context).deviceRenamed(trimmed)),
  ));
}

/// The dialog itself, holding its own field.
///
/// A controller created around `showDialog` and disposed when it returns is
/// disposed while the closing animation is still painting the field, which
/// Flutter rightly complains about. Owning it here ties its life to the widget
/// that uses it.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current});

  final String current;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      icon: const Icon(Icons.badge_outlined),
      title: Text(l10n.deviceName),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 64,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          helperText: l10n.deviceNameHint,
          helperMaxLines: 2,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(l10n.deviceNameSave),
        ),
      ],
    );
  }
}
