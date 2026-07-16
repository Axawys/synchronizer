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

    var name = prefs.getString('device_name');
    if (name == null) {
      name = _defaultName();
      await prefs.setString('device_name', name);
    }

    return DeviceInfo(
      id: id,
      name: name,
      platform: DevicePlatform.linux,
      port: kSyncServicePort,
    );
  }

  /// The hostname identifies the machine well on a desktop; only if there is no
  /// usable one do we fall back to a generated name.
  static String _defaultName() {
    final host = Platform.localHostname.trim();
    if (host.isEmpty || host == 'localhost') {
      return DeviceInfo.randomFriendlyName();
    }
    return host;
  }
}
