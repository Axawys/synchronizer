import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';
import 'fireworks.dart';
import 'syncing_devices.dart';

/// The devices a run is telling about itself, from the moment it starts to the
/// moment it is over.
///
/// Every device in a sync has its folder read and written, and every one of
/// them should look like it: the same squares rolling at each other that the
/// device that was tapped shows. Telling them is this device's job, because
/// only this one knows when the run starts and when it stops.
class SyncAnnouncements {
  SyncAnnouncements({required this.self, required this.participants});

  final DeviceInfo self;

  /// Everyone in the run, this device included: what each of them shows.
  final List<DeviceInfo> participants;

  final Map<String, Future<SyncAnnouncement?>> _open = {};

  /// Tells [device], unless it has been told already. Not waited on: a device
  /// that is slow to answer this should not hold the sync up.
  void tell(DeviceInfo device, TrustedPeer trusted) {
    final address = device.address;
    if (address == null || _open.containsKey(device.id)) return;
    _open[device.id] = SyncAnnouncement.open(
      address,
      device.port,
      self: self,
      trusted: trusted,
      participants: participants,
    );
  }

  /// Tells every one of [devices] that is paired.
  Future<void> tellAll(List<DeviceInfo> devices, TrustStore trust) async {
    for (final device in devices) {
      if (_open.containsKey(device.id)) continue;
      final trusted = await trust.get(device.id);
      if (trusted != null) tell(device, trusted);
    }
  }

  /// The run is over: every device told about it hears so, and whether it
  /// [succeeded] - the moment this device celebrates is theirs as well.
  Future<void> end({bool succeeded = false}) async {
    final told = _open.values.toList();
    _open.clear();
    for (final announcement in told) {
      await (await announcement)?.close(succeeded: succeeded);
    }
  }
}

/// A sync another device is running, as this device shows it: the same
/// squares, folding out of the same cards, for as long as it lasts, and back
/// into the list once it is over.
///
/// Nothing to press. The run belongs to the device it was started on, and
/// that is where it is decided and where it can be called off.
///
/// A run that went through ends in the same fireworks there and here: the
/// folders that agree now are this device's as much as that one's. They go up
/// as the squares unfold, as they do there, and the list comes back once both
/// are over.
class RemoteSyncing extends StatefulWidget {
  const RemoteSyncing({
    super.key,
    required this.self,
    required this.sync,
    required this.onDone,
  });

  final DeviceInfo self;
  final RemoteSync sync;

  /// Called once the squares are devices again.
  final VoidCallback onDone;

  @override
  State<RemoteSyncing> createState() => _RemoteSyncingState();
}

class _RemoteSyncingState extends State<RemoteSyncing> {
  bool _over = false;
  bool _celebrating = false;
  bool _unfolded = false;
  bool _told = false;

  @override
  void initState() {
    super.initState();
    if (widget.sync.isOver) {
      _over = true;
    } else {
      widget.sync.ended.then((_) {
        if (!mounted) return;
        setState(() {
          _over = true;
          _celebrating = widget.sync.succeeded;
        });
      });
    }
  }

  void _onUnfolded() {
    _unfolded = true;
    _finish();
  }

  /// The last spark has faded. After the frame, not during it: with the system
  /// asking for less motion this comes back from inside the build.
  void _celebrated() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _celebrating = false);
      _finish();
    });
  }

  /// Whichever of the two ends second takes the screen down.
  void _finish() {
    if (_celebrating || !_unfolded || _told) return;
    _told = true;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final from = widget.sync.from;
    // This device on the left as everywhere else, and the one running the sync
    // nearest it: it is the one this device is actually talking to.
    final peers = [
      for (final device in widget.sync.participants)
        if (device.id != widget.self.id) device,
    ];
    return Stack(
      children: [
        SyncingDevices(
          self: widget.self,
          peers: peers,
          caption: peers.length > 1
              ? l10n.remoteLevelBy(from.name)
              : l10n.remoteSyncWith(from.name),
          unfold: _over,
          onUnfolded: _onUnfolded,
        ),
        if (_celebrating)
          Positioned.fill(child: Fireworks(onDone: _celebrated)),
      ],
    );
  }
}
