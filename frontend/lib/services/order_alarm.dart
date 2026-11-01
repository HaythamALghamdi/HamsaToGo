import 'dart:io';
import 'package:flutter/services.dart';

/// Controls the native incoming-order alarm (Android only).
///
/// The alarm is a foreground service that loops a sound until staff accept the
/// order. We start it when there is at least one order still in the "received"
/// state and stop it once they've all been moved to "preparing".
class OrderAlarm {
  static const _channel = MethodChannel('hamsa/order_alarm');
  static bool _ringing = false;

  /// Start ringing if not already. No-op on iOS.
  static Future<void> start() async {
    if (!Platform.isAndroid || _ringing) return;
    _ringing = true;
    try {
      await _channel.invokeMethod('start');
    } catch (_) {
      _ringing = false;
    }
  }

  /// Stop ringing if currently ringing. No-op on iOS.
  static Future<void> stop() async {
    if (!Platform.isAndroid || !_ringing) return;
    _ringing = false;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  /// Ring while [receivedCount] > 0, otherwise silence.
  static void sync(int receivedCount) {
    if (receivedCount > 0) {
      start();
    } else {
      stop();
    }
  }
}
