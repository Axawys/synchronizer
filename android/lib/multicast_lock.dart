import 'package:flutter/services.dart';

/// Android filters inbound multicast and broadcast UDP unless the app holds a
/// WifiManager multicast lock. Without it, [DiscoveryService] can send
/// announcements but never receives any, so no peers ever appear. This is the
/// Dart side of a small platform channel that acquires and releases that lock;
/// the native half lives in MainActivity.
class MulticastLock {
  static const _channel = MethodChannel('synchronizer/multicast');

  /// Starts holding the lock. Safe to call more than once.
  static Future<void> acquire() => _channel.invokeMethod<void>('acquire');

  /// Releases the lock, letting the system go back to filtering multicast.
  static Future<void> release() => _channel.invokeMethod<void>('release');
}
