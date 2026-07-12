import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_net/sync_net.dart';

/// TCP port this device will accept pairing and sync connections on. The
/// transport that listens here is built in a later stage; for now the value is
/// only advertised in discovery so peers already know where to reach us.
const int kSyncServicePort = 47800;

/// Loads this device's stable identity, creating and persisting one on first
/// run. The id survives restarts so a paired peer keeps recognising us; the
/// name is a human label the user can later change.
class DeviceIdentity {
  static Future<DeviceInfo> load() async {
    final prefs = await SharedPreferences.getInstance();

    var id = prefs.getString('device_id');
    if (id == null) {
      id = DeviceInfo.generateId();
      await prefs.setString('device_id', id);
    }

    final name = prefs.getString('device_name') ?? _defaultName();

    return DeviceInfo(
      id: id,
      name: name,
      platform: DevicePlatform.linux,
      port: kSyncServicePort,
    );
  }

  static String _defaultName() {
    final host = Platform.localHostname;
    return host.isEmpty ? 'Linux device' : host;
  }
}
