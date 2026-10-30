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
import 'remote_sync_view.dart';
import 'storage.dart';
import 'syncing_devices.dart';

/// Screen for a paired device: connects a session, lists the folders it shares,
/// and reconciles a chosen folder in both directions with a three-way merge.
class SyncPage extends StatefulWidget {
  const SyncPage({
    super.key,
    required this.self,
    required this.trusted,
    required this.device,
    this.folders,
    this.presence,
    this.autoSync = false,
    this.embedded = false,
    this.onDone,
    this.onNeedsChoice,
  });

  final DeviceInfo self;
  final TrustedPeer trusted;
  final DeviceInfo device;

  /// What this device shares. A folder the peer offers under a name this device
  /// already shares needs no chooser: it has been chosen, on this device, and
  /// asking again is asking a question that was answered before the tap.
  final SharedFolders? folders;

  /// Whether to start on the folder as soon as there is one to start on.
  ///
  /// Tapping a paired device is how a sync is asked for; what it used to open
  /// was a list with a single row in it, which had to be tapped as well. The
  /// list still stands where there is a choice to make - several folders, or a
  /// folder with nowhere to go yet - but one folder is not a choice.
  final bool autoSync;

  /// Where to watch this device's comings and goings, when there is one. A
  /// screen held open on a device that has left the network should say so
  /// rather than fail at the next tap, and a device that comes back at a
  /// different address - a phone that rejoined the Wi-Fi, a lease that expired
  /// - should be followed there instead of leaving the user to go back and
  /// tap it again. Null for a device dialled directly, which discovery has
  /// nothing to say about.
  final DiscoveryService? presence;

  /// Runs inside the screen the device was tapped on, rather than as a screen
  /// of its own.
  ///
  /// A sync is not a place to be. It was a screen with the device's name at the
  /// top, which meant a tap opened a room, the room played an animation, the
  /// answer opened a second room on top of it, and coming back out of that one
  /// landed in the first - a room with nothing in it, which had to be left as
  /// well. Embedded, the waiting happens where the tap happened, the answer is
  /// the only thing that opens, and backing out of it lands on the list.
  final bool embedded;

  /// How the host is told the run is over, embedded. The screen has nothing
  /// left to show by then and should be taken down.
  final VoidCallback? onDone;

  /// Asked when the run turns out to need a screen after all: the other device
  /// offers several folders, or one this device has nowhere to put yet. Both
  /// are questions, and a question needs somewhere to be asked.
  final VoidCallback? onNeedsChoice;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  SyncClient? _client;
  List<SharedDir> _dirs = const [];
  String? _error;
  bool _connecting = true;

  /// The device as currently known: the address can change under us.
  late DeviceInfo _device = widget.device;

  /// Fires when the user gives up on a connection that is still being made.
  /// A device that is off, asleep or on another network takes the full connect
  /// timeout to fail, and there is no reason to sit through it.
  Completer<void>? _cancelConnect;

  /// Whether discovery can still see it. Only meaningful with [presence].
  bool _online = true;
  StreamSubscription<List<DeviceInfo>>? _presence;

  /// Where each folder currently syncs to, so the screen can show it and let
  /// the user change it. A folder with no entry has never been synced here.
  final Map<String, String> _targets = {};

  /// The folder being worked on and how far it has got, or null when the screen
  /// is idle. Between a tap and the preview there are several seconds of
  /// network and disk, and this is what the screen says during them.
  String? _workingOn;
  SyncProgress? _progress;

  /// Set when the run is over and there is nothing left to show for it: a sync
  /// that found the two sides already alike, or an embedded run that has been
  /// through the whole thing and come back.
  ///
  /// There is no screen to show for that. Opening the folder list would be
  /// answering a question nobody asked - the tap said "sync with that device",
  /// and the answer is "done". So the waiting animation runs backwards, the
  /// squares become the two devices again, and this steps aside, saying what
  /// it found if there is anything to say.
  bool _leaving = false;
  String? _partingMessage;
  String? _inSyncFolder;
  bool _left = false;

  /// Whether the fireworks are up.
  ///
  /// Two devices that disagreed now hold the same thing, and somebody waited
  /// through a network round of it - which is the same moment the levelling
  /// screen celebrates, and there is no reason it should be worth marking with
  /// three devices and not with two. The screen holds still until they have
  /// burnt out: leaving mid-firework would be the app cutting off its own
  /// applause.
  bool _celebrating = false;

  /// What this device holds in each folder's target, measured when the screen
  /// loads. The other side's measurement comes with the folder list, and the
  /// two together are what make "nothing to do" something the user can check
  /// rather than take on faith.
  final Map<String, FolderSize> _localSize = {};

  /// The other device, told that it is being synced with, so it shows the
  /// same two squares this one does instead of sitting there as a list.
  late final SyncAnnouncements _announcements = SyncAnnouncements(
    self: widget.self,
    participants: [widget.self, widget.device],
  );

  void _announce() => _announcements.tell(_device, widget.trusted);

  void _report(SyncProgress progress) {
    if (mounted) setState(() => _progress = progress);
  }

  @override
  void initState() {
    super.initState();
    _connect();
    _watchPresence();
  }

  /// Follows the device on the network for as long as this screen is open.
  void _watchPresence() {
    final discovery = widget.presence;
    if (discovery == null) return;

    _onPeers(discovery.current);
    _presence = discovery.peers.listen(_onPeers);
  }

  void _onPeers(List<DeviceInfo> devices) {
    if (!mounted) return;
    DeviceInfo? found;
    for (final device in devices) {
      if (device.id == _device.id) found = device;
    }

    if (found == null) {
      // Gone quiet. The session may still look alive - TCP does not notice a
      // device that walked out of range - so say so before a tap discovers it.
      if (_online) setState(() => _online = false);
      return;
    }

    final moved = found.address != null && found.address != _device.address;
    final wasOffline = !_online;
    setState(() {
      _online = true;
      _device = found!;
    });

    // A new address means the old connection, if any, leads nowhere. Coming
    // back at the same address after a blip does not need anything doing:
    // either the session survived, or the next action reports it did not.
    if (moved || (wasOffline && _client == null)) {
      _reconnect(announce: moved);
    }
  }

  /// Drops any existing session and dials the device where it is now.
  Future<void> _reconnect({bool announce = false}) async {
    if (announce && mounted) {
      _toast(AppLocalizations.of(context).deviceMoved(_device.name));
    }
    final old = _client;
    setState(() {
      _client = null;
      _dirs = const [];
      _error = null;
      _connecting = true;
    });
    await old?.close();
    await _connect();
  }

  Future<void> _loadTargets() async {
    final folders = widget.folders;
    for (final dir in _dirs) {
      final path = folders == null
          ? await SyncTargets.localPath(widget.device.id, dir.name)
          : await resolveSyncTarget(widget.device.id, dir.name, folders);
      if (path == null) continue;
      _targets[dir.name] = path;
      _localSize[dir.name] = await Manifest.measure(Directory(path));
    }
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    final address = _device.address;
    if (address == null) {
      final gone = AppLocalizations.of(context).deviceLeftNetwork(_device.name);
      setState(() {
        _connecting = false;
        if (widget.embedded) {
          _leaving = true;
          _partingMessage = gone;
        } else {
          _error = gone;
        }
      });
      return;
    }
    final cancel = Completer<void>();
    _cancelConnect = cancel;
    try {
      final client = await SyncClient.connect(
        address,
        _device.port,
        self: widget.self,
        trusted: widget.trusted,
        cancel: cancel.future,
      );
      final dirs = await client.listDirectories();
      if (!mounted) {
        await client.close();
        return;
      }
      setState(() {
        _client = client;
        _dirs = dirs;
        _connecting = false;
      });
      // A tap is a sync from here on, so the other device hears of it now -
      // as close to when the squares start folding here as can be managed.
      if (widget.autoSync) _announce();
      await _loadTargets();
      await _autoStart();
    } on SyncCancelled {
      // Asked for, so nothing to report and nothing to play out: back to where
      // the device was tapped, at once.
      _leave();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          if (widget.embedded) {
            // Embedded there is no room for a dead end. The device list is a
            // better place to be told this: the device may well have gone from
            // it by now, and if it has not, tapping it again is the retry.
            _leaving = true;
            _partingMessage =
                AppLocalizations.of(context).couldNotConnect('$e');
          } else {
            _error = '$e';
          }
        });
      }
    } finally {
      if (identical(_cancelConnect, cancel)) _cancelConnect = null;
    }
  }

  /// Whether the screen has already got on with it, so a reconnect - a device
  /// that moved, a network that blinked - does not start a second sync behind
  /// the first.
  bool _autoSynced = false;

  /// Gets on with the one folder there is.
  ///
  /// Only when there is exactly one, and only when it has somewhere to go: with
  /// several the user has to say which, and with nowhere to put it the first
  /// thing to happen would be a folder chooser, which is not what tapping a
  /// device asks for.
  Future<void> _autoStart() async {
    if (!widget.autoSync || _autoSynced || !mounted) return;

    if (_dirs.isEmpty) {
      unawaited(_announcements.end());
      // Nothing on the other side to sync with. That is one sentence, and it
      // does not need a screen of its own to be read on.
      if (widget.embedded) {
        setState(() {
          _leaving = true;
          _partingMessage = AppLocalizations.of(context).notSharingFolders;
        });
        return;
      }
      return;
    }

    final folder = _dirs.length == 1 ? _dirs.single : null;
    if (folder == null || folder.missing || _targets[folder.name] == null) {
      // Something to decide - which folder, or where to put one - and no room
      // to decide it here. The host opens a screen where it can be asked, and
      // the sync starts again from there once it has been.
      unawaited(_announcements.end());
      if (widget.embedded) widget.onNeedsChoice?.call();
      return;
    }

    _autoSynced = true;
    await _sync(folder.name);
  }

  void _cancelConnecting() {
    if (_cancelConnect?.isCompleted == false) _cancelConnect!.complete();
  }

  @override
  void dispose() {
    _cancelConnecting();
    unawaited(_announcements.end());
    _presence?.cancel();
    _client?.close();
    super.dispose();
  }

  /// Resolves where [name] lives locally - from the folder this device already
  /// shares under that name, or from this pair's history - and asks only when
  /// neither has an answer. The chosen folder is the sync target itself.
  Future<String?> _resolveTarget(String name) async {
    final folders = widget.folders;
    final known = folders == null
        ? await SyncTargets.localPath(widget.device.id, name)
        : await resolveSyncTarget(widget.device.id, name, folders);
    if (known != null) return known;
    return _pickTarget(name);
  }

  /// Asks the user for a folder and records it as where [name] syncs to.
  ///
  /// Changing the folder drops the recorded ancestor: it describes the old
  /// place, and against a different folder it would read as a pile of
  /// deletions. Without it the next sync is simply a first sync, which is the
  /// truth of the matter.
  ///
  /// The answer is also shared under that name, so it counts for everyone: the
  /// question "where does this folder go on this device" has one answer, and a
  /// second device asking it later should get that one rather than another
  /// chooser. It is the same thing that happens when a peer asks for a folder
  /// this device has no place for yet.
  Future<String?> _pickTarget(String name) async {
    // Read before the first await: after one, this State may be gone and the
    // context with it.
    final l10n = AppLocalizations.of(context);

    final picked = await pickFolder(
      context,
      confirmLabel: l10n.syncIntoThisFolder(name),
    );
    if (picked == null) return null;

    final previous = _targets[name];
    await SyncTargets.setLocalPath(widget.device.id, name, picked);
    if (previous != null && previous != picked) {
      await BaseManifests.clear(widget.device.id, name);
    }
    await widget.folders?.chooseAs(name, picked);
    if (mounted) setState(() => _targets[name] = picked);
    return picked;
  }

  /// The "change folder" action: pick a new one and say what happened.
  Future<void> _changeTarget(String name) async {
    final l10n = AppLocalizations.of(context);
    final picked = await _pickTarget(name);
    if (picked != null) _toast(l10n.folderNowSyncsTo(name, picked));
  }

  Future<void> _sync(String name) async {
    final client = _client;
    if (client == null || _workingOn != null) return;
    final l10n = AppLocalizations.of(context);

    final localPath = await _resolveTarget(name);
    if (localPath == null || !mounted) return;
    final root = Directory(localPath);

    setState(() {
      _workingOn = name;
      _progress = const SyncProgress(SyncPhase.asking);
    });
    _announce();
    try {
      await _runSyncFor(name, client, root, l10n);
    } finally {
      // Over, however it ended: the other device goes back to its list as
      // this one does - with fireworks, if this one has them.
      unawaited(_announcements.end(succeeded: _celebrating));
      if (mounted) {
        setState(() {
          _workingOn = null;
          _progress = null;
          // Embedded, this run was the whole of what the tap asked for -
          // however it ended, including backed out of. What is behind it is
          // the device list, which is where the user was going anyway.
          if (widget.embedded && _autoSynced) _leaving = true;
        });
      }
    }
  }

  /// The body of a sync, so the screen can be sure to stop showing itself busy
  /// however this ends.
  Future<void> _runSyncFor(
    String name,
    SyncClient client,
    Directory root,
    AppLocalizations l10n,
  ) async {
    final base = await BaseManifests.load(widget.device.id, name);
    final MergeResult merge;
    try {
      merge = await computeMerge(client, name, root, base,
          onProgress: _report);
    } on MissingRootException {
      // The folder was deleted, moved, or its drive is not mounted. Syncing
      // would read that as "delete everything", so ask instead of guessing.
      await _offerNewFolder(name, root.path);
      return;
    } catch (e) {
      _toast(l10n.couldNotReadChanges('$e'));
      return;
    }

    // Said before anything else: those files stay out of every sync with this
    // device until they are renamed, and the sizes shown next would otherwise
    // disagree with no reason given.
    if (merge.skipped.isNotEmpty) {
      _toast(l10n.skippedWindowsNames(
          merge.skipped.length, merge.skipped.first));
    }

    if (merge.isEmpty) {
      // Not just "nothing to do": how many files each side was found to have.
      // A folder full on one device and empty on the other, reported as in
      // sync, means the wrong folder is shared - and that is invisible without
      // the counts.
      final here = await Manifest.measure(root);
      final there = _dirs
          .firstWhere((d) => d.name == name, orElse: () => SharedDir(name))
          .bytes;
      final message = l10n.alreadyInSyncDetail(
        name,
        l10n.sizeHere(formatSize(l10n, here.bytes)),
        there == null ? '' : l10n.sizeThere(formatSize(l10n, there)),
      );
      if (!mounted) return;
      // Only for the sync that was started on its own. Where the user picked a
      // folder off the list, the list is where they were and where they should
      // stay - and it is worth their while to see the counts on it.
      final parting = widget.autoSync || widget.embedded;
      setState(() {
        _localSize[name] = here;
        if (parting) {
          _leaving = true;
          _partingMessage = message;
          _inSyncFolder = name;
        }
      });
      if (!parting) _toast(message);
      return;
    }

    final List<ResolvedMerge> resolved;
    if (await SyncSettings.lightMode()) {
      resolved = await _resolveWithoutAsking(client, name, root, merge);
    } else {
      final SyncPreview preview;
      try {
        preview = await buildPreview(client, name, root, merge,
            onProgress: _report);
      } catch (e) {
        _toast(l10n.couldNotPreparePreview('$e'));
        return;
      }
      if (!mounted) return;
      final choice = await Navigator.of(context).push<List<ResolvedMerge>>(
        MaterialPageRoute(
          builder: (_) => MergePreviewPage(
            folderName: name,
            deviceName: widget.device.name,
            preview: preview,
          ),
        ),
      );
      if (choice == null) return; // backed out
      resolved = choice;
    }

    await _apply(client, name, root, resolved, base);
  }

  /// Plain mode: merge what merges, and settle the rest by taking whichever
  /// side was edited more recently, since there is nobody to ask.
  Future<List<ResolvedMerge>> _resolveWithoutAsking(
    SyncClient client,
    String name,
    Directory root,
    MergeResult merge,
  ) async {
    final resolved = <ResolvedMerge>[];
    for (final item in merge.items) {
      if (item.kind != MergeKind.conflict) {
        resolved.add(ResolvedMerge.natural(item));
        continue;
      }
      final merged = await mergeConflict(client, name, root, item);
      resolved.add(merged.isClean
          ? ResolvedMerge.merged(item, merged.merge!.clean!)
          : ResolvedMerge(item, toLocal: conflictResolvesToLocal(item)));
    }
    return resolved;
  }

  Future<void> _apply(SyncClient client, String name, Directory root,
      List<ResolvedMerge> resolved, Manifest base) async {
    final l10n = AppLocalizations.of(context);
    final progress = ValueNotifier<int>(0);
    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) =>
            _ApplyingDialog(total: resolved.length, applied: progress),
      );
    }
    try {
      final outcome = await runSync(
        client,
        name,
        root,
        base,
        resolved,
        onProgress: (done, total) {
          progress.value = done;
          // The dialog is the one to watch, but the bar along the bottom is
          // the screen's own account of what it is doing, and this is still
          // part of it.
          _report(SyncProgress(SyncPhase.applying, done: done, total: total));
        },
      );
      final report = outcome.report;

      // Set only when the sync finished, in which case both sides now match and
      // this is the ancestor the next merge works from.
      if (outcome.newBase != null) {
        await BaseManifests.save(widget.device.id, name, outcome.newBase!);
        // And the texts behind every ancestor still in use are worth keeping,
        // while the ones nobody refers to are not.
        await pruneBaseStore(root, await BaseManifests.forFolder(name));
      }
      await _log(name, resolved, report);

      if (mounted) Navigator.of(context).pop(); // close applying dialog
      _toast(report.ok
          ? l10n.syncedChanges(report.applied, name)
          : l10n.syncedPartly(report.applied, report.failures.length));

      // Everything that was going to move moved. A run that failed halfway,
      // or that turned out to have nothing to carry, is not that.
      if (mounted && report.ok && report.applied > 0) {
        setState(() => _celebrating = true);
      }
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast(l10n.syncFailed('$e'));
    } finally {
      progress.dispose();
    }
  }

  /// Tells the user their folder is gone and offers to point the sync
  /// somewhere else. Nothing is synced either way until they decide.
  Future<void> _offerNewFolder(String name, String path) async {
    final l10n = AppLocalizations.of(context);
    final change = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.folder_off),
        title: Text(l10n.folderGoneTitle),
        content: Text(l10n.folderGoneBody(name, path)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.chooseFolder),
          ),
        ],
      ),
    );
    if (change ?? false) await _changeTarget(name);
  }

  /// Records what this sync actually achieved. Files that failed are counted
  /// only as failures, not as transferred.
  Future<void> _log(
      String name, List<ResolvedMerge> resolved, MergeReport report) async {
    final failed = report.failures.map((f) => f.path).toSet();
    final done = resolved.where((r) => !failed.contains(r.item.path));

    await SyncLog.add(SyncLogEntry(
      at: DateTime.now(),
      peerName: widget.device.name,
      folder: name,
      downloaded: done.where((r) => r.toLocal).length,
      uploaded: done.where((r) => !r.toLocal).length,
      conflicts:
          resolved.where((r) => r.item.kind == MergeKind.conflict).length,
      failed: failed.length,
    ));
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // A strip along the bottom while a sync is working itself out: which stage
    // it is in, and how far through it is where that can be counted.
    final status = _progress == null
        ? null
        : SyncStatusBar(folder: _workingOn ?? '', progress: _progress!);

    final content = Stack(
      children: [
        Column(
          children: [
            if (!_online) _OfflineBanner(name: _device.name),
            Expanded(child: _buildBody(l10n)),
          ],
        ),
        if (_celebrating)
          Positioned.fill(child: Fireworks(onDone: _celebrated)),
      ],
    );

    // Embedded there is no bar of its own to hang a title on, and none is
    // wanted: the screen is the device list, and what is happening on it is
    // said by the two devices in the middle of it.
    if (widget.embedded) {
      return Column(children: [Expanded(child: content), ?status]);
    }

    return Scaffold(
      appBar: AppBar(title: Text(_device.name)),
      body: content,
      bottomNavigationBar: status,
    );
  }

  /// What the waiting screen says, in the order the states can be in.
  String _waitCaption(AppLocalizations l10n) {
    if (_inSyncFolder != null) return l10n.alreadyInSync(_inSyncFolder!);
    // On the way out with something else to report - a device that went, a
    // connection that failed - the line fades out as the squares unfold and is
    // said properly in a message a moment later.
    if (_leaving) return _partingMessage ?? '';
    if (_connecting) return l10n.connectingTo(_device.name);
    if (_progress == null) return l10n.syncAsking;
    return syncPhaseLabel(l10n, _progress!, _workingOn ?? '');
  }

  /// The last spark has faded, and with it the reason to stay.
  void _celebrated() {
    // Called from the animation's own frame - and straight away, where the
    // system asks for less motion - so the screen changes after that frame
    // rather than in the middle of building it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _celebrating = false);
      if (_leaving) _leave();
    });
  }

  /// Steps aside the way it came - back to the device list, whether that is a
  /// route to pop or a host to tell - and says what was found on the way out.
  void _leave() {
    // The squares finish unfolding a good second before the last spark fades.
    // Whichever ends second calls this again.
    if (_celebrating || _left || !mounted) return;
    _left = true;
    // Taken first: afterwards this screen's context is on its way out, and the
    // message belongs to the list underneath anyway.
    final messenger = ScaffoldMessenger.of(context);
    final message = _partingMessage;
    if (widget.embedded) {
      widget.onDone?.call();
    } else {
      Navigator.of(context).maybePop();
    }
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Widget _buildBody(AppLocalizations l10n) {
    // Everything from the tap to the answer is one wait, and it looks like one:
    // the two devices, shrunk to squares, rolling at each other. What was here
    // before was a spinner, and then - for the several seconds that a sync
    // actually takes - a screen holding one folder row, with the work happening
    // out of sight in a bar at the bottom.
    //
    // One widget for the whole wait, connecting and syncing alike: two of them
    // in two branches would be two animations, and the second would start from
    // the beginning just as the first had finished folding.
    //
    // Embedded, this is the only thing there is to show. Everything below lays
    // out a list or a dead end, and neither belongs on someone else's screen:
    // by the time either would be reached, the host has been told and is
    // taking this down or opening a screen where the question can be asked.
    if (_connecting || _workingOn != null || _leaving || widget.embedded) {
      return SyncingDevices(
        self: widget.self,
        peers: [_device],
        caption: _waitCaption(l10n),
        onCancel: _connecting && !_leaving ? _cancelConnecting : null,
        unfold: _leaving,
        onUnfolded: _leave,
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Layout.section),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.couldNotConnect('$_error'),
                  textAlign: TextAlign.center),
              const SizedBox(height: 20),
              // The usual reason is a device that moved or a network that
              // blinked, and both are fixed by dialling again - which should
              // not cost the user their place on this screen.
              FilledButton.tonalIcon(
                onPressed: _reconnect,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.reconnect),
              ),
            ],
          ),
        ),
      );
    }
    if (_dirs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child:
              Text(l10n.notSharingFolders, textAlign: TextAlign.center),
        ),
      );
    }
    return ContentPane(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(
            Layout.gutter, Layout.gap, Layout.gutter, Layout.section),
        itemCount: _dirs.length,
        separatorBuilder: (_, _) => const SizedBox(height: Layout.gap),
        itemBuilder: (context, i) {
          final dir = _dirs[i];
          return SyncFolderCard(
            name: dir.name,
            localPath: _targets[dir.name],
            bytesThere: dir.bytes,
            missingThere: dir.missing,
            bytesHere: _localSize[dir.name]?.bytes,
            syncing: _workingOn == dir.name,
            // One at a time: the session is one connection, and two syncs down
            // it would be two halves of two folders.
            enabled: _workingOn == null,
            onSync: () => _sync(dir.name),
            onChangeFolder: () => _changeTarget(dir.name),
          );
        },
      ),
    );
  }
}

/// One shared folder on the sync screen: what it is called, where it lands on
/// this device, and the two things that can be done with it.
///
/// The path used to be a subtitle spanning the whole window, with the button
/// that changes it pinned to the far right - so on a desktop the name and the
/// control that belongs to it ended up hand-widths apart, with a line of text
/// between them. Here the control sits against the name it acts on, the path
/// reads as one line under both, and the card stops at a readable width.
class SyncFolderCard extends StatelessWidget {
  const SyncFolderCard({
    super.key,
    required this.name,
    required this.localPath,
    this.bytesThere,
    this.bytesHere,
    this.missingThere = false,
    this.syncing = false,
    this.enabled = true,
    this.onSync,
    this.onChangeFolder,
  });

  final String name;

  /// Where this folder syncs to on this device, or null before it is chosen.
  final String? localPath;

  /// What each side weighs. Null where it is not known: an older device does
  /// not say, and a folder with no local place yet has nothing to measure.
  final int? bytesThere;
  final int? bytesHere;

  /// The other device still shares this folder but no longer has it.
  final bool missingThere;

  /// Whether this is the folder currently being worked on.
  final bool syncing;

  /// False while another folder is busy: one session, one sync at a time.
  final bool enabled;

  final VoidCallback? onSync;
  final VoidCallback? onChangeFolder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final chosen = localPath != null;

    return Opacity(
      opacity: enabled || syncing ? 1 : 0.5,
      child: AppCard(
      accented: syncing,
      onTap: enabled ? onSync : null,
      child: Row(
        children: [
          IconBadge(icon: Icons.folder_shared, accented: chosen || syncing),
          const SizedBox(width: Layout.gap),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // A fixed line, so a folder with a button and one without are
                // the same height and the list keeps its rhythm.
                SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (chosen)
                      // Next to the name, not across the window: it changes
                      // where this one folder goes.
                      IconButton(
                        icon: const Icon(Icons.drive_file_move_outline),
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.only(left: Layout.snug),
                        constraints: const BoxConstraints(),
                        tooltip: l10n.changeFolder,
                        onPressed: onChangeFolder,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Layout.tight),
                // Where it lands is not something to have to remember, and it
                // is the first thing worth knowing when a sync goes somewhere
                // unexpected. Shortened to read at a glance; the whole of it is
                // a hover away.
                Tooltip(
                  message: localPath ?? '',
                  child: Text(
                    chosen ? prettyPath(localPath!) : l10n.folderNotChosenYet,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontStyle: chosen ? null : FontStyle.italic,
                    ),
                  ),
                ),
                // What each side actually holds. It is the line that would have
                // answered "it says synced, but one of them is empty" without
                // anyone having to guess.
                if (missingThere || bytesThere != null || bytesHere != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      missingThere
                          ? l10n.folderMissingThere
                          : [
                              if (bytesHere != null)
                                l10n.sizeHere(formatSize(l10n, bytesHere!)),
                              if (bytesThere != null)
                                l10n.sizeThere(formatSize(l10n, bytesThere!)),
                            ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: missingThere
                            ? colors.error
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Layout.snug),
          // The same icon either way, turning while there is something to wait
          // for: a tap that starts several seconds of work should show that it
          // did something.
          _SyncMark(spinning: syncing, color: colors.primary),
        ],
      ),
      ),
    );
  }
}

/// The sync arrows, turning while a sync is under way.
class _SyncMark extends StatefulWidget {
  const _SyncMark({required this.spinning, required this.color});

  final bool spinning;
  final Color color;

  @override
  State<_SyncMark> createState() => _SyncMarkState();
}

class _SyncMarkState extends State<_SyncMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_SyncMark old) {
    super.didUpdateWidget(old);
    if (old.spinning != widget.spinning) _sync();
  }

  void _sync() {
    final wanted =
        widget.spinning && !MediaQuery.disableAnimationsOf(context);
    if (wanted == _turn.isAnimating) return;
    if (wanted) {
      _turn.repeat();
    } else {
      _turn.stop();
      _turn.value = 0;
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _turn,
      child: Icon(Icons.sync, color: widget.color),
    );
  }
}

/// What a sync is doing right now, in one line.
///
/// Said in two places - across the middle of the screen while the two devices
/// roll, and along the bottom where the proportion is - so it is worked out
/// once.
String syncPhaseLabel(
  AppLocalizations l10n,
  SyncProgress progress,
  String folder,
) =>
    switch (progress.phase) {
      SyncPhase.asking => l10n.syncAsking,
      SyncPhase.scanning => l10n.syncScanning(folder),
      SyncPhase.comparing => l10n.syncComparing,
      SyncPhase.reading => l10n.syncReading(progress.done, progress.total),
      SyncPhase.applying => l10n.syncApplying(progress.done, progress.total),
    };

/// What the sync is doing, along the bottom of the screen.
///
/// A bar rather than a dialog on purpose: nothing here needs deciding, the
/// screen behind it is still worth reading, and the work can be watched or
/// ignored. It says which stage, and shows a proportion where there is one to
/// show - a bar creeping along a made-up estimate is worse than an honest
/// indeterminate one.
class SyncStatusBar extends StatelessWidget {
  const SyncStatusBar({
    super.key,
    required this.folder,
    required this.progress,
  });

  final String folder;
  final SyncProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    final label = syncPhaseLabel(l10n, progress, folder);

    return Material(
      color: colors.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress.fraction,
              minHeight: 3,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Layout.gutter, Layout.gap, Layout.gutter, Layout.gap),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(width: Layout.gap),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Says the device has left the network, without taking the screen away: what
/// is on it is still true, and the device may well come back in a moment.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.wifi_off, size: 18, color: colors.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                AppLocalizations.of(context).deviceLeftNetwork(name),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: colors.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApplyingDialog extends StatelessWidget {
  const _ApplyingDialog({required this.total, required this.applied});

  final int total;
  final ValueListenable<int> applied;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.syncingTitle),
      content: ValueListenableBuilder<int>(
        valueListenable: applied,
        builder: (context, value, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                  value: total == 0 ? null : value / total),
              const SizedBox(height: 12),
              Text(l10n.progressOf(value, total)),
            ],
          );
        },
      ),
    );
  }
}
