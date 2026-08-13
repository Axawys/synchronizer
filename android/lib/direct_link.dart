import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sync_ui/sync_ui.dart';

/// Android's half of making a direct link: hosting a local-only hotspot, and
/// opening the system screens for tethering and for joining a network.
///
/// The native side lives in MainActivity. Everything here degrades to "no":
/// hosting needs Android 8, a permission the user can refuse, and an OEM that
/// implemented it, and none of that is worth an error message - the screen has
/// a hand-typed address to fall back on regardless.
class AndroidDirectLink implements DirectLinkControls {
  static const _channel = MethodChannel('synchronizer/direct');

  /// What the system said the last time it was asked, so the permission is not
  /// re-derived on every call.
  Map<String, Object?>? _support;

  Future<Map<String, Object?>> _supported() async =>
      _support ??= await _callMap('hotspot.supported') ?? const {};

  @override
  Future<bool> canHostHotspot() async =>
      (await _supported())['supported'] == true;

  @override
  Future<HotspotCredentials?> startHotspot() async {
    final support = await _supported();
    if (support['supported'] != true) return null;
    if (!await _grantHotspotPermission(support['permission'])) return null;

    final started = await _callMap('hotspot.start');
    final ssid = started?['ssid'];
    final passphrase = started?['passphrase'];
    if (ssid is! String || passphrase is! String) return null;
    return HotspotCredentials(ssid: ssid, passphrase: passphrase);
  }

  @override
  Future<void> stopHotspot() => _call<void>('hotspot.stop');

  @override
  Future<bool> openTetheringSettings() async =>
      await _call<bool>('settings.tethering') ?? false;

  @override
  Future<bool> openWifiSettings() async =>
      await _call<bool>('settings.wifi') ?? false;

  @override
  Future<bool> joinWifi(String ssid, String passphrase) async {
    try {
      final joined = await _channel.invokeMethod<bool>('wifi.join', {
        'ssid': ssid,
        'passphrase': passphrase,
      });
      return joined ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> leaveWifi() => _call<void>('wifi.leave');

  @override
  Future<String?> bindToLocalNetwork() => _call<String>('network.bindLocal');

  @override
  Future<void> releaseNetwork() => _call<void>('network.unbind');

  @override
  Future<bool> vpnActive() async =>
      await _call<bool>('network.vpnActive') ?? false;

  /// Android will not raise a hotspot without this, and which one it wants
  /// changed in 13: nearby-devices where it used to be location. The native
  /// side says which, so the version check stays in one place.
  Future<bool> _grantHotspotPermission(Object? which) async {
    final permission = which == 'nearby'
        ? Permission.nearbyWifiDevices
        : Permission.locationWhenInUse;
    if (await permission.isGranted) return true;
    return (await permission.request()).isGranted;
  }

  /// A channel call that answers with a map. Kept apart because the platform
  /// hands back `Map<Object?, Object?>` and only [invokeMapMethod] retypes it.
  Future<Map<String, Object?>?> _callMap(String method) async {
    try {
      return await _channel.invokeMapMethod<String, Object?>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<T?> _call<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
