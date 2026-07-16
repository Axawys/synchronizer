import 'package:flutter/services.dart';
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
  static const _channel = MethodChannel('synchronizer/device');

  static Future<DeviceInfo> load() async {
    final prefs = await SharedPreferences.getInstance();

    var id = prefs.getString('device_id');
    if (id == null) {
      id = DeviceInfo.generateId();
      await prefs.setString('device_id', id);
    }

    var name = prefs.getString('device_name');
    if (name == null) {
      name = await _hardwareName() ?? DeviceInfo.randomFriendlyName();
      await prefs.setString('device_name', name);
    }

    return DeviceInfo(
      id: id,
      name: name,
      platform: DevicePlatform.android,
      port: kSyncServicePort,
    );
  }

  /// The phone's brand and model, so it shows up in the list as the actual
  /// device. Null if the platform will not say, in which case the caller falls
  /// back to a generated name.
  static Future<String?> _hardwareName() async {
    try {
      final name = await _channel.invokeMethod<String>('name');
      final trimmed = name?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
