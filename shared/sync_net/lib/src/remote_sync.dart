import 'dart:async';

import 'connection.dart';
import 'device_info.dart';
import 'session.dart';
import 'trust.dart';

/// A sync another device is running, and this one is part of.
///
/// The device that was tapped is not the only one taking part: its folder is
/// being read and written too, and the person standing in front of it should
/// see the same thing the person who tapped sees - the devices folding into
/// squares and rolling at each other - rather than a list that sits there as
/// if nothing were happening. This is what the server hands the screen for
/// that, and [ended] is when it stops.
class RemoteSync {
  RemoteSync({required this.from, required this.participants});

  /// Read from what the running device sent. The device it came from is the
  /// one that authenticated, whatever the list says, and it heads the list:
  /// it is the one the sync is with.
  factory RemoteSync.fromHeader(
    Map<String, Object?> header, {
    required TrustedPeer from,
    String? address,
  }) {
    final listed = <DeviceInfo>[];
    final raw = header['participants'];
    if (raw is List) {
      // A screen's worth. A list longer than this is not a sync anyone runs.
      for (final entry in raw.take(_maxParticipants)) {
        try {
          listed.add(DeviceInfo.fromAnnouncement(
              (entry as Map).cast<String, Object?>()));
        } catch (_) {
          // Not a device. The rest of the list is still worth showing.
        }
      }
    }

    final announced = [for (final d in listed) if (d.id == from.id) d];
    final sender = DeviceInfo(
      id: from.id,
      name: from.name,
      platform: from.platform,
      port: announced.isEmpty ? 0 : announced.first.port,
      address: address,
    );
    final seen = <String>{sender.id};
    return RemoteSync(
      from: sender,
      participants: [
        sender,
        for (final d in listed)
          if (seen.add(d.id)) d,
      ],
    );
  }

  static const _maxParticipants = 16;

  /// The device running the sync.
  final DeviceInfo from;

  /// Everyone in it, [from] first. This device is among them.
  final List<DeviceInfo> participants;

  final _ended = Completer<void>();

  /// Completes when the running device says it is done, hangs up, or goes
  /// quiet for long enough to be taken for gone.
  Future<void> get ended => _ended.future;
  bool get isOver => _ended.isCompleted;

  /// Whether the running device said the sync went through: everything that
  /// was going to move moved, and something did. Worth the same celebration
  /// here as there. False for a sync that ended without saying - a dropped
  /// link is not news of success.
  bool get succeeded => _succeeded;
  bool _succeeded = false;

  void end({bool succeeded = false}) {
    if (_ended.isCompleted) return;
    _succeeded = succeeded;
    _ended.complete();
  }
}

/// Tells one paired device it is part of a sync, for as long as the sync lasts.
///
/// A connection of its own, held open from the start of the run to the end of
/// it. The run itself is a string of short sessions - one per question, and
/// with several devices, gaps while the others are being talked to - so none
/// of those can stand for "this is still going". This can: the far end shows
/// the sync while it is open, and closing it is the end.
class SyncAnnouncement {
  SyncAnnouncement._(this._client) {
    // Well inside the silence the far end waits through before giving up.
    _pulse = Timer.periodic(kSilenceTimeout ~/ 4, (_) => _client.keepAlive());
  }

  final SyncClient _client;
  late final Timer _pulse;

  /// Connects and announces. Null where nothing will be shown - a device that
  /// does not answer, or one too old to know what this is - and neither is a
  /// reason for the sync itself to stop.
  static Future<SyncAnnouncement?> open(
    String host,
    int port, {
    required DeviceInfo self,
    required TrustedPeer trusted,
    required List<DeviceInfo> participants,
  }) async {
    final SyncClient client;
    try {
      client = await SyncClient.connect(host, port,
          self: self, trusted: trusted);
    } catch (_) {
      return null;
    }
    try {
      if (await client.announceSync(participants)) {
        return SyncAnnouncement._(client);
      }
    } catch (_) {
      // Answered the handshake and not this. Nothing to show, then.
    }
    await client.close();
    return null;
  }

  /// Ends the announcement, saying how the sync went. [succeeded] is what
  /// lets the other device celebrate along with this one.
  Future<void> close({bool succeeded = false}) async {
    _pulse.cancel();
    _client.endSync(succeeded: succeeded);
    await _client.close();
  }
}
