/// What a sync is doing while the screen waits for it.
///
/// The work between tapping a folder and seeing what will change is several
/// seconds of network and disk on a real vault, and every part of it can be the
/// slow one: a phone with a thousand notes takes its time scanning, a busy
/// Wi-Fi takes its time answering, and reading the changed files back to build
/// a diff takes as long as the files are big. A screen that says nothing for
/// all of that is a screen that looks broken, so each stage says which it is.
enum SyncPhase {
  /// Asking the other device for its manifest.
  asking,

  /// Hashing this device's copy of the folder.
  scanning,

  /// Working out what changed on each side.
  comparing,

  /// Reading the versions the diff is built from, file by file.
  reading,

  /// Writing the agreed result, file by file.
  applying,
}

/// Where a sync has got to. [total] is zero for a stage with nothing to count,
/// which is the signal to show motion rather than a proportion.
class SyncProgress {
  const SyncProgress(this.phase, {this.done = 0, this.total = 0});

  final SyncPhase phase;
  final int done;
  final int total;

  bool get isCountable => total > 0;
  double? get fraction => isCountable ? done / total : null;

  @override
  String toString() => 'SyncProgress(${phase.name} $done/$total)';
}

/// Called as a sync moves through its stages. Always from the same isolate the
/// caller is on, so a screen can setState straight from it.
typedef SyncProgressCallback = void Function(SyncProgress progress);
