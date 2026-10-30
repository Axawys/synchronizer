/// Shared Flutter UI for the desktop and mobile applications.
///
/// Exposes the app shell and the screens (device list and pairing, shared
/// folders, and the sync/diff view) so both platforms show the same thing;
/// per-platform concerns (like Android's multicast lock) are injected as hooks
/// rather than duplicated.
library;

export 'l10n/gen/app_localizations.dart';
export 'src/app_settings.dart';
export 'src/app_shell.dart';
export 'src/autostart.dart';
export 'src/direct_connect_page.dart';
export 'src/direct_link.dart';
export 'src/fireworks.dart';
export 'src/folder_choice.dart';
export 'src/home.dart';
export 'src/layout.dart';
export 'src/merge_preview_page.dart';
export 'src/multi_sync_page.dart';
export 'src/prefs_trust_store.dart';
export 'src/qr_pairing.dart';
export 'src/remote_sync_view.dart';
export 'src/rename_dialog.dart';
export 'src/rolling_circuit.dart';
export 'src/rolling_square.dart';
export 'src/settings_page.dart';
export 'src/sync_folder_page.dart';
export 'src/storage.dart';
export 'src/sync_log_page.dart';
export 'src/sync_page.dart';
export 'src/syncing_devices.dart';
export 'src/theme.dart';
