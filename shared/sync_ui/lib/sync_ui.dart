/// Shared Flutter UI for the desktop and mobile applications.
///
/// Exposes the app shell and the device/pairing screen so both platforms show
/// the same thing; per-platform concerns (like Android's multicast lock) are
/// injected as hooks rather than duplicated.
library;

export 'src/home.dart';
export 'src/prefs_trust_store.dart';
