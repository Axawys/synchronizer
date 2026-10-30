import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

import 'fireworks.dart';
import 'folder_choice.dart';
import 'layout.dart';
import 'merge_preview_page.dart';
import 'storage.dart';
import 'syncing_devices.dart';

/// One device's copy of a file that several devices changed.
class ConflictVariant {
  ConflictVariant({
    required this.sourceId,
    required this.sourceName,
    required this.entry,
  });

  /// `local` for this device, otherwise the device's id. It is what decides
  /// where the winning copy is taken from.
  static const localSource = 'local';

  final String sourceId;
  final String sourceName;

  /// The file as that device has it, or null where that device deleted it.
  final FileEntry? entry;

  /// What this copy actually says, once it has been read.
  ///
  /// A size and a timestamp do not answer the question people are actually
  /// asked here - which of these two is the paragraph I wrote - and choosing
  /// by the newer date is guessing with extra steps. Null while it has not
  /// been read, or when there is nothing to read: too big for a screen, not
  /// text, or a copy that no longer exists.
  String? text;

  /// Whether the reading has been done, however it went.
  bool read = false;

  bool get isLocal => sourceId == localSource;
  DateTime? get modified => entry?.modified;
}

/// One file that came back different from more than one device, with every
/// version of it there is.
///
/// This is what "which device is right" actually looks like once there are
/// three of them: not a question per pair, asked while files are being written,
/// but one question per file with every copy laid out - because the answer is
/// about the file, not about the device that happens to be syncing at the time.
class PathConflict {
  PathConflict(this.path, this.variants);

  final String path;
  final List<ConflictVariant> variants;

  /// The copy to start with: the one changed most recently. It is a default,
  /// not a decision - the whole point of the screen is that the user can say
  /// otherwise before anything is written.
  String get newestSource {
    ConflictVariant? best;
    for (final variant in variants) {
      final at = variant.modified;
      if (at == null) continue;
      if (best?.modified == null || at.isAfter(best!.modified!)) best = variant;
    }
    return (best ?? variants.first).sourceId;
  }
}

/// How one device is getting on in a levelling run.
enum LevelState {
  waiting,
  checking,
  needsFolder,
  working,
  done,
  skipped,
  failed,
}

/// One device's place in the run: what it is doing and what came of it.
class LevelEntry {
  LevelEntry(this.device, this.trusted);

  final DeviceInfo device;
  final TrustedPeer trusted;

  LevelState state = LevelState.waiting;

  /// What the run found waiting for this device, before anything was written.
  /// Null until it has been worked out.
  MergeResult? pending;

  /// Changes applied across all passes, so the report says what actually moved.
  int changes = 0;
  String? error;

  int get comingHere =>
      pending?.items.where((i) => i.kind == MergeKind.pullToLocal).length ?? 0;
  int get goingThere =>
      pending?.items.where((i) => i.kind == MergeKind.pushToRemote).length ?? 0;
  int get conflicts => pending?.conflicts.length ?? 0;

  /// Files this will delete on that device, which is the part that cannot be
  /// taken back.
  int get deletesThere => pending?.items
          .where((i) => i.kind == MergeKind.pushToRemote && i.local == null)
          .length ??
      0;
}

/// Brings one folder to the same state on several devices at once.
///
/// Syncing is a conversation between two devices, and three copies of a vault
/// take three of them - done by hand that is three trips through the same
/// screen, and getting the order wrong leaves one device a version behind
/// without saying so. This drives the whole thing from one place.
///
/// It works as a hub: this device's copy of the folder is the meeting point,
/// and each of the others is synced against it in turn. Two passes, because one
/// is not enough - the first collects everyone's changes here, the second
/// carries the collected result back out. If the first pass moves nothing at
/// all, everyone already agreed and the second is skipped.
///
/// Every pass is an ordinary two-way sync with the ordinary three-way merge:
/// nothing here overwrites a device wholesale. What it cannot do is ask about
/// conflicts - a question per device per file is not a thing anyone would sit
/// through - so it merges what merges and settles the rest the way plain mode
/// does, taking the more recently edited side. The screen says so before it
/// starts.
class MultiSyncPage extends StatefulWidget {
  const MultiSyncPage({
    super.key,
    required this.self,
    required this.devices,
    required this.trust,
    required this.folders,
    this.gather = true,
    this.embedded = false,
    this.onDone,
  });

  final DeviceInfo self;

  /// The paired devices on the network right now.
  final List<DeviceInfo> devices;

  final TrustStore trust;

  /// This device's own shared folders: the run levels one of them, because the
  /// hub has to have the folder to be the meeting point for it.
  final SharedFolders folders;

  /// Whether to ask every device what it holds when the screen opens. Off in
  /// widget tests, which have no devices to ask.
  ///
  /// It also means this is a real run, started by a tap: asking is followed by
  /// working out what would change, without waiting to be told twice.
  final bool gather;

  /// Runs inside the device list rather than as a screen of its own, the same
  /// way syncing with one device does. Levelling several is the same request -
  /// "bring these into line" - and it should not cost an extra room either.
  final bool embedded;

  /// How the host is told there is nothing left to show: everything already
  /// agreed, so the squares unfold and the list comes back.
  final VoidCallback? onDone;

  @override
  State<MultiSyncPage> createState() => _MultiSyncPageState();
}

class _MultiSyncPageState extends State<MultiSyncPage> {
  static const _passes = 2;

  String? _folder;
  final Map<String, LevelEntry> _entries = {};

  /// What each device offers, by device id then folder name. Gathered when the
  /// screen opens, so the table can say where every copy stands before anything
  /// is started.
  final Map<String, Map<String, SharedDir>> _listings = {};

  /// What this device holds in each of its shared folders.
  final Map<String, FolderSize> _here = {};

  /// Shown for a moment when a run ends with everything in line.
  bool _celebrating = false;

  bool _gathering = false;
  bool _previewing = false;
  bool _previewed = false;

  /// Whether the working-out started by itself, off the back of the tap that
  /// opened this. Only then is "everyone already agrees" a reason to leave: a
  /// run the user asked for again by hand is a run they are watching.
  bool _autoRun = false;

  /// On the way out with nothing to show for it, and whether that has been
  /// acted on.
  bool _leaving = false;
  bool _left = false;
  bool _running = false;
  bool _finished = false;
  bool _cancelled = false;
  int _pass = 0;

  /// Which side won the last conflict, when the user said to keep using it.
  /// Null means every conflict is still a question, which is the default.
  bool? _preferLocal;

  /// Every file that came back different from more than one place, and which
  /// copy of it the user settled on. Worked out by the preview, decided before
  /// the run, applied by it.
  List<PathConflict> _conflicts = const [];
  final Map<String, String> _winner = {};

  /// Whether the preview found nothing to do anywhere.
  bool get _allSame =>
      _previewed &&
      _entries.values.every((e) =>
          e.state == LevelState.skipped ||
          (e.pending?.isEmpty ?? true) && e.state != LevelState.failed);

  @override
  void initState() {
    super.initState();
    final shared = widget.folders.folders;
    if (shared.isNotEmpty) _folder = shared.first.name;
    if (widget.gather) _gather();
  }

  /// Asks every device what folders it has and how much is in them, and counts
  /// this device's own. Nothing is synced by asking; it is what turns the
  /// screen from a list of names into a picture of where each copy stands.
  Future<void> _gather() async {
    setState(() => _gathering = true);

    for (final folder in widget.folders.folders) {
      _here[folder.name] = await Manifest.measure(Directory(folder.path));
    }

    for (final device in widget.devices) {
      final trusted = await widget.trust.get(device.id);
      if (trusted == null || device.address == null) continue;
      SyncClient? client;
      try {
        client = await SyncClient.connect(
          device.address!,
          device.port,
          self: widget.self,
          trusted: trusted,
        );
        final dirs = await client.listDirectories();
        _listings[device.id] = {for (final d in dirs) d.name: d};
      } catch (_) {
        // It answered discovery a moment ago and does not answer now. The
        // table shows it as having nothing rather than pretending to know.
      } finally {
        await client?.close();
      }
      if (!mounted) return;
      setState(() {});
    }

    if (mounted) setState(() => _gathering = false);

    // Straight on with it. The tap that opened this said what to do, and every
    // answer it would have asked for is already the obvious one: the folder
    // this device shares, and all the devices there are. A screen of defaults
    // with a button under it is a step that asks nothing.
    if (mounted && _folder != null && widget.devices.isNotEmpty &&
        !_previewed) {
      _autoRun = true;
      await _preview();
    }
  }

  String? _pathOf(String folder) {
    for (final shared in widget.folders.folders) {
      if (shared.name == folder) return shared.path;
    }
    return null;
  }

  /// Every folder anyone here knows about.
  List<String> get _allFolders {
    final names = <String>{
      for (final folder in widget.folders.folders) folder.name,
      for (final listing in _listings.values) ...listing.keys,
    };
    final sorted = names.toList()..sort();
    return sorted;
  }

  /// Picks a folder on this device for a name only the others have, and shares
  /// it under that name - the same question this device puts to the others.
  Future<void> _chooseHere(String folder) async {
    final path = await pickFolder(context);
    if (path == null || !mounted) return;
    await widget.folders.chooseAs(folder, path);
    _here[folder] = await Manifest.measure(Directory(path));
    if (mounted) setState(() => _folder = folder);
  }

  /// Works out what a run would do, and writes nothing.
  ///
  /// Sweeping several devices used to start the moment the button was pressed,
  /// which for a folder full of changes meant finding out what it did by
  /// watching it happen. Two devices get a preview screen before anything is
  /// written; several should not get less.
  Future<void> _preview() async {
    final folder = _folder;
    if (folder == null || _previewing || _running) return;

    final path = _pathOf(folder);
    if (path == null) return;
    final root = Directory(path);

    final entries = <LevelEntry>[];
    for (final device in widget.devices) {
      final trusted = await widget.trust.get(device.id);
      if (trusted != null) entries.add(LevelEntry(device, trusted));
    }
    if (entries.isEmpty || !mounted) return;

    setState(() {
      _previewing = true;
      _previewed = false;
      _finished = false;
      _cancelled = false;
      _entries
        ..clear()
        ..addEntries(entries.map((e) => MapEntry(e.device.id, e)));
    });

    // One folder for the whole run, and the same check that the run does: a
    // device with nowhere to put this is asked before anything is counted.
    for (final entry in entries) {
      if (_cancelled) break;
      await alignSyncTarget(entry.device.id, folder, root.path);
      await _ensureFolder(entry, folder);
      if (!mounted) return;
      if (entry.state == LevelState.needsFolder) continue;
      await _previewOne(entry, folder, root);
      if (!mounted) return;
    }

    // Worked out before the screen settles, so a conflict arrives as something
    // to read rather than something to guess at.
    final conflicts =
        mounted ? await _studyConflicts(folder, root) : <PathConflict>[];
    if (!mounted) return;

    if (mounted) {
      setState(() {
        _conflicts = conflicts;
        for (final conflict in _conflicts) {
          _winner[conflict.path] ??= conflict.newestSource;
        }
        _previewing = false;
        _previewed = true;
        // Nothing anywhere. There is no table worth reading for that and no
        // button worth pressing, so the squares unfold and this steps aside -
        // the same answer the two-device sync gives to the same question.
        if (_autoRun && _allSame) _leaving = true;
      });
    }
  }

  /// Back to the list, once the squares have grown into devices again.
  void _leave() {
    if (_left || !mounted) return;
    _left = true;
    final messenger = ScaffoldMessenger.of(context);
    final message = AppLocalizations.of(context).levelAllSame;
    if (widget.embedded) {
      widget.onDone?.call();
    } else {
      Navigator.of(context).maybePop();
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Works out which of the files that came back different are actually
  /// questions, and reads the copies of the ones that are.
  ///
  /// Not everything the merge calls a conflict is one to put to a person. Two
  /// devices that edited different paragraphs of the same file have not
  /// disagreed about anything: the edits combine, both survive, and the run
  /// does it without asking. What is left - the same lines, changed two ways,
  /// or a file that cannot be merged at all - is a real either/or, and those
  /// are the ones laid out on the screen.
  ///
  /// Drawing that line here is what makes the answer mean something. While
  /// every difference was listed, every one of them arrived with a copy
  /// preselected, and honouring those would have turned off the merging
  /// altogether.
  ///
  /// One session per device, however many of its files are in question: the
  /// conversation is the expensive part, not the files - they are the ones
  /// somebody edited by hand in two places.
  Future<List<PathConflict>> _studyConflicts(
    String folder,
    Directory root,
  ) async {
    final byPath = <String, Map<String, ConflictVariant>>{};
    final here = AppLocalizations.of(context).conflictSideHere;

    for (final entry in _entries.values) {
      final items = entry.pending?.conflicts ?? const <MergeItem>[];
      if (items.isEmpty || entry.device.address == null) continue;

      SyncClient? client;
      try {
        client = await SyncClient.connect(
          entry.device.address!,
          entry.device.port,
          self: widget.self,
          trusted: entry.trusted,
        );
        for (final item in items) {
          final merged = await mergeConflict(client, folder, root, item);
          // Settled by merging, so there is nothing to ask and nothing to
          // show. The run does the same thing again when it gets there.
          if (merged.isClean) continue;

          // The merge has already read both copies to reach that verdict, so
          // the text is here for the asking rather than a second download.
          final readable = merged.isMergeable;
          final variants = byPath.putIfAbsent(item.path, () => {});
          variants[ConflictVariant.localSource] ??= ConflictVariant(
            sourceId: ConflictVariant.localSource,
            sourceName: here,
            entry: item.local,
          )
            ..text = readable ? joinLines(merged.ourLines) : null
            ..read = readable;
          variants[entry.device.id] = ConflictVariant(
            sourceId: entry.device.id,
            sourceName: entry.device.name,
            entry: item.remote,
          )
            ..text = readable ? joinLines(merged.theirLines) : null
            ..read = readable;
        }
      } catch (_) {
        // It answered a moment ago and does not now. Its files stay off the
        // list, and the run falls back to asking about them one at a time.
      } finally {
        await client?.close();
      }
    }

    return [
      for (final path in byPath.keys.toList()..sort())
        PathConflict(path, byPath[path]!.values.toList()),
    ];
  }

  Future<void> _previewOne(
      LevelEntry entry, String folder, Directory root) async {
    setState(() => entry.state = LevelState.checking);

    SyncClient? client;
    try {
      client = await SyncClient.connect(
        entry.device.address!,
        entry.device.port,
        self: widget.self,
        trusted: entry.trusted,
      );
      final dirs = await client.listDirectories();
      if (!dirs.any((d) => d.name == folder)) {
        setState(() => entry.state = LevelState.skipped);
        return;
      }

      final base = await BaseManifests.load(entry.device.id, folder);
      final merge = await computeMerge(client, folder, root, base);
      setState(() {
        entry.pending = merge;
        entry.state = LevelState.waiting;
      });
      // Those files sit out every sync with this device until renamed, which
      // is worth saying once, here, rather than leaving the sizes to disagree.
      if (merge.skipped.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).skippedWindowsNames(
              merge.skipped.length, merge.skipped.first)),
        ));
      }
    } catch (e) {
      setState(() {
        entry.state = LevelState.failed;
        entry.error = '$e';
      });
    } finally {
      await client?.close();
    }
  }

  /// Opens what is waiting for one device, line by line.
  ///
  /// A list of file names cannot answer the question people actually open this
  /// with - is the paragraph I wrote last night the one arriving, or the one
  /// about to be overwritten - so this fetches the changed files from that
  /// device and shows the same diff the two-device screen shows, with nothing
  /// to press: conflicts are settled on the screen below, for all the devices
  /// at once.
  ///
  /// The contents are fetched when asked for rather than during the sweep. It
  /// is a download either way, and doing it for every device up front would be
  /// a download before anybody has decided to look.
  Future<void> _openChanges(LevelEntry entry) async {
    final folder = _folder;
    final merge = entry.pending;
    final path = folder == null ? null : _pathOf(folder);
    if (folder == null || merge == null || path == null) return;

    final l10n = AppLocalizations.of(context);
    final progress = ValueNotifier<SyncProgress>(
        SyncProgress(SyncPhase.reading, total: merge.items.length));
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ReadingDialog(progress: progress),
    ));

    SyncClient? client;
    SyncPreview? preview;
    String? failure;
    try {
      client = await SyncClient.connect(
        entry.device.address!,
        entry.device.port,
        self: widget.self,
        trusted: entry.trusted,
      );
      preview = await buildPreview(
        client,
        folder,
        Directory(path),
        merge,
        onProgress: (value) => progress.value = value,
      );
    } catch (e) {
      failure = '$e';
    } finally {
      await client?.close();
    }

    if (!mounted) {
      progress.dispose();
      return;
    }
    Navigator.of(context).pop(); // the reading dialog
    progress.dispose();

    if (preview == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.couldNotPreparePreview('$failure'))),
      );
      return;
    }

    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MergePreviewPage(
        folderName: folder,
        deviceName: entry.device.name,
        preview: preview!,
        readOnly: true,
        title: l10n.levelChangesOn(entry.device.name),
      ),
    ));
  }

  Future<void> _run() async {
    final folder = _folder;
    if (folder == null || _running) return;

    final path = _pathOf(folder);
    if (path == null) return; // nothing here to be the meeting point
    final root = Directory(path);

    final entries = _entries.values.toList();
    if (entries.isEmpty || !mounted) return;

    setState(() {
      _running = true;
      _finished = false;
      _cancelled = false;
      _preferLocal = null;
    });

    // A device whose copy won a conflict has to be synced before the rest:
    // this device is the meeting point, so the winning copy has to arrive here
    // first for everyone else to receive it.
    final sources = _winner.values.toSet();
    entries.sort((a, b) {
      final aFirst = sources.contains(a.device.id) ? 0 : 1;
      final bFirst = sources.contains(b.device.id) ? 0 : 1;
      return aFirst.compareTo(bFirst);
    });

    for (var pass = 1; pass <= _passes; pass++) {
      if (_cancelled) break;
      setState(() => _pass = pass);
      var moved = 0;
      for (final entry in entries) {
        if (_cancelled) break;
        if (entry.state == LevelState.skipped ||
            entry.state == LevelState.needsFolder) {
          continue;
        }
        moved += await _syncOne(entry, folder, root);
        if (!mounted) return;
      }
      // Nothing changed anywhere on the first pass: the devices already agree,
      // and a second trip round would be the same conversation twice.
      if (moved == 0) break;
    }

    // Once round, and only then: the texts behind every ancestor still in use
    // are worth keeping, and which those are is only known here, where all the
    // devices are. A pass that pruned to its own pair would throw away what
    // the next device in the round is about to merge against.
    await pruneBaseStore(root, await BaseManifests.forFolder(folder));

    if (mounted) {
      final worked = _entries.values.every((e) => e.state != LevelState.failed);
      setState(() {
        _running = false;
        _finished = true;
        // Several devices that disagreed now hold the same thing, and somebody
        // waited through a network round of it. Worth a moment.
        _celebrating = worked && !_cancelled;
      });
    }
  }

  /// Makes sure one device has a place for the folder, asking it to choose one
  /// if it has not, and waiting a while for the answer.
  Future<void> _ensureFolder(LevelEntry entry, String folder) async {
    setState(() => entry.state = LevelState.checking);

    SyncClient? client;
    try {
      client = await SyncClient.connect(
        entry.device.address!,
        entry.device.port,
        self: widget.self,
        trusted: entry.trusted,
      );

      if (await client.prepareDirectory(folder)) {
        setState(() => entry.state = LevelState.waiting);
        return;
      }

      // The question is now on that device's screen. Watch for the folder
      // appearing rather than asking the person to come back and press this
      // again; give up after a while so a run cannot hang on a device nobody
      // is holding.
      setState(() {
        entry.state = LevelState.needsFolder;
        entry.error = null;
      });

      final deadline = DateTime.now().add(_folderWait);
      while (DateTime.now().isBefore(deadline) && !_cancelled) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        final dirs = await client.listDirectories();
        if (dirs.any((d) => d.name == folder)) {
          setState(() => entry.state = LevelState.waiting);
          return;
        }
      }
    } catch (e) {
      setState(() {
        entry.state = LevelState.failed;
        entry.error = '$e';
      });
    } finally {
      await client?.close();
    }
  }

  /// How long a device gets to have a folder chosen on it before the run gives
  /// up on it: long enough to walk to the other room, short enough not to hang.
  static const _folderWait = Duration(minutes: 3);

  /// One device, one pass. Returns how many changes it applied.
  Future<int> _syncOne(LevelEntry entry, String folder, Directory root) async {
    setState(() => entry.state = LevelState.working);

    SyncClient? client;
    try {
      client = await SyncClient.connect(
        entry.device.address!,
        entry.device.port,
        self: widget.self,
        trusted: entry.trusted,
      );

      final dirs = await client.listDirectories();
      if (!dirs.any((d) => d.name == folder)) {
        // It does not offer this folder, so there is nothing here to reconcile
        // against. Said plainly rather than counted as a failure: it is a
        // setting on that device, not a fault.
        setState(() => entry.state = LevelState.skipped);
        return 0;
      }

      final base = await BaseManifests.load(entry.device.id, folder);
      final merge = await computeMerge(client, folder, root, base);
      if (merge.isEmpty) {
        setState(() => entry.state = LevelState.done);
        return 0;
      }

      final resolved = <ResolvedMerge>[];
      for (final item in merge.items) {
        if (item.kind != MergeKind.conflict) {
          resolved.add(ResolvedMerge.natural(item));
          continue;
        }
        // Decided before the run, on the screen where every copy was laid out
        // side by side - and that decision is the answer, not a hint.
        //
        // Merging was tried first here once, and it is how a chosen copy could
        // be quietly thrown away: the second device's merge sees the copy the
        // first pass just brought in as the ancestor, concludes that only the
        // other side changed anything, and takes that side. The run then
        // reported success over a file that says what nobody picked.
        final winner = _winner[item.path];
        if (winner != null) {
          // Take this device's copy when it is the one that won; otherwise the
          // meeting point already holds the winner, or is about to.
          resolved.add(
              ResolvedMerge(item, toLocal: winner == entry.device.id));
          continue;
        }

        // Not asked about, which means the working-out found the two edits
        // could be combined. Anything that appeared since - the files are
        // live - falls back to asking.
        final merged = await mergeConflict(client, folder, root, item);
        if (merged.isClean) {
          // Edits in different places: both survive, and nobody needs asking.
          resolved.add(ResolvedMerge.merged(item, merged.merge!.clean!));
          continue;
        }
        final keepLocal = await _whichDevice(item, entry);
        if (!mounted) return 0;
        resolved.add(ResolvedMerge(item, toLocal: !keepLocal));
      }

      final outcome = await runSync(client, folder, root, base, resolved);
      if (outcome.newBase != null) {
        await BaseManifests.save(entry.device.id, folder, outcome.newBase!);
      }
      await SyncLog.add(SyncLogEntry(
        at: DateTime.now(),
        peerName: entry.device.name,
        folder: folder,
        downloaded: resolved.where((r) => r.toLocal).length,
        uploaded: resolved.where((r) => !r.toLocal).length,
        conflicts:
            resolved.where((r) => r.item.kind == MergeKind.conflict).length,
        failed: outcome.report.failures.length,
      ));

      final applied = outcome.report.applied;
      setState(() {
        entry.changes += applied;
        entry.state = outcome.report.ok ? LevelState.done : LevelState.failed;
        if (!outcome.report.ok) {
          entry.error = outcome.report.failures.first.toString();
        }
      });
      return applied;
    } catch (e) {
      setState(() {
        entry.state = LevelState.failed;
        entry.error = '$e';
      });
      return 0;
    } finally {
      await client?.close();
    }
  }

  /// Asks which device's copy of one file to keep. Remembers the answer for
  /// the rest of the run if the user says so - a vault that diverged in fifty
  /// files should not be fifty dialogs.
  Future<bool> _whichDevice(MergeItem item, LevelEntry entry) async {
    final remembered = _preferLocal;
    if (remembered != null) return remembered;

    final choice = await showDialog<ConflictChoice>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          ConflictChoiceDialog(item: item, peer: entry.device),
    );
    // Backing out of the question keeps what is here: the copy on the device
    // in front of the user is the one they can still see.
    final keepLocal = choice?.keepLocal ?? true;
    if (choice?.remember ?? false) _preferLocal = keepLocal;
    return keepLocal;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shared = widget.folders.folders;

    final body = Stack(
      children: [
        // Asking round and working out what would change takes a network
        // round-trip per device, and it is the same wait as a two-device sync -
        // so it is the same picture: this device on the left, everyone else
        // rolling at it, which is also what a hub run does.
        if (_waiting)
          SyncingDevices(
            self: widget.self,
            peers: _inRun,
            caption: _waitCaption(l10n),
            unfold: _leaving,
            onUnfolded: _leave,
          )
        else
          _content(context, l10n, shared),
        if (_celebrating)
          Positioned.fill(
            child: Fireworks(
              // After the frame, not during it: with the system asking for
              // less motion this comes back immediately, from inside the
              // build that put it on screen.
              onDone: () =>
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() => _celebrating = false);
              }),
            ),
          ),
      ],
    );

    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.allPairedDevices)),
      body: body,
    );
  }

  /// Whether there is nothing to read yet: still asking, still working it out,
  /// or on the way back out with nothing to show.
  bool get _waiting => _gathering || _previewing || _leaving;

  /// The devices this run is about, which is what the animation shows: all of
  /// them that are present.
  List<DeviceInfo> get _inRun => widget.devices;

  String _waitCaption(AppLocalizations l10n) {
    if (_leaving) return l10n.levelAllSame;
    return _gathering ? l10n.gatheringFolders : l10n.levelPreviewing;
  }

  Widget _content(
    BuildContext context,
    AppLocalizations l10n,
    List<SharedFolder> shared,
  ) {
    return ContentPane(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Layout.gutter, Layout.gutter,
              Layout.gutter, Layout.section),
          children: [
            Text(l10n.bringInLineSubtitle,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: Layout.section),
            if (shared.isEmpty) ...[
              _Note(text: l10n.levelNoFolders),
              const SizedBox(height: Layout.gutter),
              // Saying what is missing without offering to fix it is how the
              // old folders tab worked, and it is why nobody found it.
              FilledButton.icon(
                onPressed: () async {
                  final path = await chooseSyncFolder(context);
                  if (path == null || !mounted) return;
                  await widget.folders.choose(path);
                  if (mounted) setState(() {});
                  await _gather();
                },
                icon: const Icon(Icons.create_new_folder),
                label: Text(l10n.syncFolderChoose),
              ),
            ]
            else ...[
              _Heading(l10n.chooseFolderToLevel),
              if (_gathering)
                Padding(
                  padding: const EdgeInsets.only(bottom: Layout.gap),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: Layout.gap),
                      Text(l10n.gatheringFolders,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              RadioGroup<String>(
                groupValue: _folder,
                onChanged: (value) {
                  // What was worked out was worked out about the old folder.
                  if (!_running) {
                    setState(() {
                      _folder = value;
                      _previewed = false;
                    });
                  }
                },
                child: Column(
                  children: [
                    for (final name in _allFolders)
                      FolderAcrossDevices(
                        folder: name,
                        pathHere: _pathOf(name),
                        bytesHere: _here[name]?.bytes,
                        devices: [
                          for (final device in widget.devices)
                            (device, _listings[device.id]?[name]),
                        ],
                        selected: _folder == name,
                        onChooseHere:
                            _pathOf(name) == null && !_running
                                ? () => _chooseHere(name)
                                : null,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Layout.gutter),
              // No list of devices to tick here. Every paired device present is
              // in it: the folder is the same folder on all of them, and a run
              // that leaves one out puts that one a version behind without
              // saying so. What each of them is doing is said below, where the
              // changes are.
              _Note(text: l10n.levelPlainNote),
              const SizedBox(height: Layout.gutter),
              // Devices with what is waiting for each, once it is known: the
              // list is what the button is about to do.
              if (_previewed)
                for (final entry in _entries.values)
                  DeviceChanges(
                    entry: entry,
                    onOpen: entry.pending == null || entry.pending!.isEmpty
                        ? null
                        : () => _openChanges(entry),
                  ),
              // Everything that came back different from more than one place,
              // with every copy of it - decided here, before anything is
              // written, rather than one pair at a time while it is.
              if (_previewed && _conflicts.isNotEmpty) ...[
                const SizedBox(height: Layout.snug),
                _Heading(l10n.conflictsAcross),
                Padding(
                  padding: const EdgeInsets.only(bottom: Layout.gap),
                  child: Text(
                    l10n.conflictsAcrossBody,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                for (final conflict in _conflicts)
                  ConflictAcrossDevices(
                    conflict: conflict,
                    chosen: _winner[conflict.path],
                    onChoose: _running
                        ? null
                        : (source) =>
                            setState(() => _winner[conflict.path] = source),
                  ),
              ],
              if (_previewed && _allSame)
                _Note(text: l10n.levelAllSame),
              if (_previewed) const SizedBox(height: Layout.gutter),
              if (_running)
                Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: Layout.gap),
                    Expanded(
                      child: Text(_pass == 0
                          ? l10n.levelCheckingFolders
                          : l10n.levelRound(_pass, _passes)),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _cancelled = true),
                      child: Text(l10n.levelCancel),
                    ),
                  ],
                )
              else if (_previewing)
                Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: Layout.gap),
                    Expanded(child: Text(l10n.levelPreviewing)),
                    TextButton(
                      onPressed: () => setState(() => _cancelled = true),
                      child: Text(l10n.levelCancel),
                    ),
                  ],
                )
              else if (!_previewed)
                // Nothing is written until this has been pressed and read.
                FilledButton.icon(
                  onPressed:
                      widget.devices.isEmpty || _folder == null
                          ? null
                          : _preview,
                  icon: const Icon(Icons.difference_outlined),
                  label: Text(l10n.levelPreview),
                )
              // Nothing to level: no button to press. A run that would write
              // nothing is not something to offer.
              else if (!_allSame)
                FilledButton.icon(
                  onPressed:
                      widget.devices.isEmpty || _folder == null ? null : _run,
                  icon: const Icon(Icons.hub),
                  label: Text(l10n.levelStart),
                ),
              if (_finished) ...[
                const SizedBox(height: Layout.gutter),
                _Outcome(entries: _entries.values.toList()),
              ],
            ],
          ],
        ),
    );
  }

}

/// One folder, and where every device stands on it.
///
/// The two-device screen answers "how many files here, how many there", which
/// is what makes a sync explicable. With several devices the same question has
/// several answers, and they belong in one row: a folder full on two devices
/// and empty on a third is the whole story of what is about to happen, and it
/// is invisible if each device is only ever looked at on its own.
class FolderAcrossDevices extends StatelessWidget {
  const FolderAcrossDevices({
    super.key,
    required this.folder,
    required this.pathHere,
    required this.bytesHere,
    required this.devices,
    this.selected = false,
    this.onChooseHere,
  });

  final String folder;

  /// Where it lives on this device, or null if this device has no such folder.
  final String? pathHere;

  /// What it weighs here. Weight rather than a count: it is the number that
  /// says which copy is the vault and which is a stub.
  final int? bytesHere;

  /// Each device and what it said about this folder, or null if it does not
  /// offer it at all.
  final List<(DeviceInfo, SharedDir?)> devices;

  final bool selected;

  /// Offered when this device has no folder of that name: the same question it
  /// puts to the others, put to whoever is holding this one.
  final VoidCallback? onChooseHere;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: Layout.gap),
      child: AppCard(
        accented: selected,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (pathHere != null)
                  Radio<String>(value: folder)
                else
                  const SizedBox(width: 40),
                Expanded(
                  child: Text(
                    folder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (onChooseHere != null)
                  TextButton(
                    onPressed: onChooseHere,
                    child: Text(l10n.chooseFolderHere),
                  ),
              ],
            ),
            const SizedBox(height: Layout.snug),
            _Where(
              title: l10n.conflictSideHere,
              detail: pathHere == null
                  ? l10n.folderHereMissing
                  : bytesHere == null
                      ? prettyPath(pathHere!)
                      : '${prettyPath(pathHere!)} · '
                          '${formatSize(l10n, bytesHere!)}',
              missing: pathHere == null,
            ),
            for (final (device, dir) in devices)
              _Where(
                // What each of them holds under this name. Not where they keep
                // it: the row is here to be compared with the one above it, and
                // the weights are what compare.
                title: device.name,
                detail: dir == null
                    ? l10n.folderNotOffered
                    : dir.missing
                        ? l10n.folderMissingThere
                        : formatSize(l10n, dir.bytes ?? 0),
                missing: dir == null || dir.missing,
              ),
          ],
        ),
      ),
    );
  }
}

class _Where extends StatelessWidget {
  const _Where({
    required this.title,
    required this.detail,
    this.missing = false,
  });

  final String title;
  final String detail;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: missing ? colors.error : colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One conflicting file, with what every device claims it says, side by side.
///
/// A file changed in two places is not a question about sizes and timestamps,
/// which is what this used to offer: two lines of metadata and a radio button.
/// The question is which of these two is the paragraph you wrote, and the only
/// thing that answers it is the text. So the block splits - a column per
/// device, each with what that copy says and a button under it to keep it.
class ConflictAcrossDevices extends StatelessWidget {
  const ConflictAcrossDevices({
    super.key,
    required this.conflict,
    required this.chosen,
    this.onChoose,
  });

  final PathConflict conflict;
  final String? chosen;
  final void Function(String sourceId)? onChoose;

  /// Under this the columns go one above the other: two columns of text on a
  /// phone are two columns of nothing.
  static const double splitAt = 520;

  /// How much of a long file to show before it has to be scrolled. Enough to
  /// see which one it is; the rest is a swipe away.
  static const double paneHeight = 220;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: Layout.gap),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              conflict.path,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: Layout.gap),
            LayoutBuilder(
              builder: (context, box) {
                final panes = [
                  for (final variant in conflict.variants)
                    _pane(context, variant),
                ];
                if (box.maxWidth < splitAt) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < panes.length; i++) ...[
                        if (i > 0) const SizedBox(height: Layout.gap),
                        panes[i],
                      ],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < panes.length; i++) ...[
                      if (i > 0) const SizedBox(width: Layout.gap),
                      Expanded(child: panes[i]),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// One device's claim: whose it is, what it says, and the way to keep it.
  Widget _pane(BuildContext context, ConflictVariant variant) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final picked = variant.sourceId == chosen;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Name over detail rather than beside it: a column of a pane is narrow,
        // and a device name pushed into an ellipsis by a timestamp is the one
        // thing on it that has to stay readable.
        Text(
          variant.sourceName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: picked ? colours.primary : null,
          ),
        ),
        Text(
          _describe(l10n, variant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: colours.onSurfaceVariant),
        ),
        const SizedBox(height: Layout.snug),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: paneHeight),
          padding: const EdgeInsets.all(Layout.gap),
          decoration: BoxDecoration(
            color: colours.surfaceContainerHighest,
            borderRadius: Layout.badgeCorners,
            border: Border.all(
              color: picked ? colours.primary : colours.outlineVariant,
              width: picked ? 1.5 : 1,
            ),
          ),
          child: _body(context, variant),
        ),
        const SizedBox(height: Layout.snug),
        // Under the text it belongs to, not at the bottom of the card: with two
        // columns of writing on screen, a button anywhere else is a button
        // about neither of them.
        SizedBox(
          width: double.infinity,
          child: picked
              ? FilledButton.tonalIcon(
                  onPressed: null,
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(l10n.conflictChosen),
                )
              : FilledButton(
                  onPressed: onChoose == null
                      ? null
                      : () => onChoose!(variant.sourceId),
                  child: Text(l10n.conflictApply),
                ),
        ),
      ],
    );
  }

  /// The text itself, or why there is none to show.
  Widget _body(BuildContext context, ConflictVariant variant) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    final text = variant.text;
    String? note;
    if (variant.entry == null) {
      note = l10n.conflictDeletedHere;
    } else if (text == null) {
      // Read and found to be something else, or not read at all: two different
      // things, and only one of them is worth trying again for.
      note = variant.read ? l10n.conflictNotText : l10n.conflictCouldNotRead;
    } else if (text.trim().isEmpty) {
      note = l10n.sizeEmpty;
    }

    if (note != null) {
      return Text(
        note,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colours.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    return SingleChildScrollView(
      child: Text(
        text!,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          height: 1.35,
        ),
      ),
    );
  }

  /// The line beside the name: how big, when, and whether it is the newest or
  /// simply the same file under another name.
  String _describe(AppLocalizations l10n, ConflictVariant variant) {
    if (variant.entry == null) return l10n.conflictMissing;

    final local = conflict.variants
        .where((v) => v.isLocal)
        .map((v) => v.entry?.hash)
        .firstOrNull;
    if (!variant.isLocal && variant.entry!.hash == local) {
      return l10n.variantSameAsHere;
    }

    final when = variant.entry!.modified.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${two(when.day)}.${two(when.month)} '
        '${two(when.hour)}:${two(when.minute)}';
    final size = formatSize(l10n, variant.entry!.size);
    return variant.sourceId == conflict.newestSource
        ? '$size, $stamp · ${l10n.variantNewest}'
        : '$size, $stamp';
  }
}

/// One device and what is waiting for it, before anything is written.
class DeviceChanges extends StatelessWidget {
  const DeviceChanges({super.key, required this.entry, this.onOpen});

  final LevelEntry entry;

  /// Opens the list of files. Null when there is nothing to look at.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final merge = entry.pending;

    final detail = switch (entry.state) {
      LevelState.skipped => l10n.levelSkipped,
      LevelState.needsFolder =>
        l10n.levelNeedsFolderAsked(entry.device.name, ''),
      LevelState.failed => l10n.levelFailed(entry.error ?? ''),
      _ => merge == null
          ? l10n.levelWaiting
          : merge.isEmpty
              ? l10n.levelNothingToDo
              : l10n.levelSummary(entry.comingHere, entry.goingThere),
    };
    final trouble = entry.state == LevelState.failed ||
        entry.state == LevelState.skipped ||
        entry.state == LevelState.needsFolder;

    return Padding(
      padding: const EdgeInsets.only(bottom: Layout.gap),
      child: AppCard(
        onTap: onOpen,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 2,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: trouble
                            ? colours.error
                            : colours.onSurfaceVariant),
                  ),
                  // The part that cannot be taken back gets its own line, in
                  // the colour it deserves.
                  if (entry.deletesThere > 0)
                    Text(
                      l10n.levelDeletesThere(entry.deletesThere),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colours.error),
                    ),
                  if (entry.conflicts > 0)
                    Text(
                      l10n.levelConflictsCount(entry.conflicts),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colours.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            if (onOpen != null)
              Icon(Icons.chevron_right, color: colours.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// What the app is doing while it fetches a device's changed files: the same
/// count the sync itself reports, because this is the same reading.
class _ReadingDialog extends StatelessWidget {
  const _ReadingDialog({required this.progress});

  final ValueListenable<SyncProgress> progress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      content: ValueListenableBuilder<SyncProgress>(
        valueListenable: progress,
        builder: (context, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: value.fraction),
            const SizedBox(height: Layout.gap),
            Text(l10n.syncReading(value.done, value.total)),
          ],
        ),
      ),
    );
  }
}


/// The answer to one conflict: whose copy, and whether to stop asking.
class ConflictChoice {
  const ConflictChoice({required this.keepLocal, required this.remember});

  final bool keepLocal;
  final bool remember;
}

/// Which device is right about this file.
///
/// Two-device syncing settles conflicts hunk by hunk on the preview screen,
/// which is the better tool when there is one other device and time to look.
/// Across several devices that screen would appear once per device per file, so
/// the question here is the coarser one people actually mean: which copy is the
/// good one. Both sides are described - size and when they changed - because
/// "which is right" is unanswerable without them.
class ConflictChoiceDialog extends StatefulWidget {
  const ConflictChoiceDialog({
    super.key,
    required this.item,
    required this.peer,
  });

  final MergeItem item;
  final DeviceInfo peer;

  @override
  State<ConflictChoiceDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<ConflictChoiceDialog> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final local = widget.item.local;
    final remote = widget.item.remote;

    String describe(FileEntry? entry) => entry == null
        ? l10n.conflictMissing
        : l10n.conflictDetail(entry.size, _when(entry.modified));

    return AlertDialog(
      title: Text(l10n.conflictWhichDevice(widget.item.path)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Side(title: l10n.conflictSideHere, detail: describe(local)),
          const SizedBox(height: Layout.gap),
          _Side(
            title: l10n.conflictSideThere(widget.peer.name),
            detail: describe(remote),
          ),
          const SizedBox(height: Layout.gap),
          CheckboxListTile(
            value: _remember,
            onChanged: (on) => setState(() => _remember = on ?? false),
            title: Text(l10n.conflictRememberDevice,
                style: theme.textTheme.bodySmall),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
              context, ConflictChoice(keepLocal: false, remember: _remember)),
          child: Text(l10n.conflictSideThere(widget.peer.name)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
              context, ConflictChoice(keepLocal: true, remember: _remember)),
          child: Text(l10n.conflictSideHere),
        ),
      ],
    );
  }

  String _when(DateTime at) {
    final local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        Text(detail,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Layout.snug),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Layout.gutter),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: Layout.cardCorners,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.45),
      ),
    );
  }
}

/// What the run came to, once it is over.
class _Outcome extends StatelessWidget {
  const _Outcome({required this.entries});

  final List<LevelEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final failed = entries.where((e) => e.state == LevelState.failed).length;

    return Container(
      padding: const EdgeInsets.all(Layout.gutter),
      decoration: BoxDecoration(
        color: failed == 0 ? colors.primaryContainer : colors.errorContainer,
        borderRadius: Layout.cardCorners,
      ),
      child: Row(
        children: [
          Icon(
            failed == 0 ? Icons.check_circle : Icons.error_outline,
            color: failed == 0
                ? colors.onPrimaryContainer
                : colors.onErrorContainer,
          ),
          const SizedBox(width: Layout.gap),
          Expanded(
            child: Text(
              failed == 0 ? l10n.levelAllDone : l10n.levelSomeFailed(failed),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: failed == 0
                    ? colors.onPrimaryContainer
                    : colors.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
