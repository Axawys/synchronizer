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
export 'src/home.dart';
export 'src/merge_preview_page.dart';
export 'src/prefs_trust_store.dart';
export 'src/settings_page.dart';
export 'src/shared_folders_page.dart';
export 'src/storage.dart';
export 'src/sync_log_page.dart';
export 'src/sync_page.dart';
export 'src/theme.dart';
