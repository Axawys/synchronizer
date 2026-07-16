/// Shared synchronization engine used by both the desktop and mobile apps.
///
/// The public surface here is intentionally small and platform-neutral: it
/// scans directories into manifests and diffs manifests into reviewable change
/// sets. Transport (device discovery, the socket protocol, applying changes to
/// disk) is layered on top of these primitives by each application.
library;

export 'src/file_entry.dart';
export 'src/manifest.dart';
export 'src/diff.dart';
export 'src/apply.dart';
export 'src/merge.dart';
export 'src/text_diff.dart';
export 'src/text_merge.dart';
