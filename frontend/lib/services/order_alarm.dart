import 'dart:io';
import 'package:flutter/services.dart';

/// Controls the native incoming-order alarm service (Android only).
///
/// The service listens to Firestore itself and rings while any order is in the
/// "received" state — so it keeps working with the app minimized or closed. We
/// just start it when a staff member signs in and stop it when they sign out.
class OrderAlarm {
  static const _channel = MethodChannel('hamsa/order_alarm');
  static bool _active = false;

  /// Start the order-listening alarm service. No-op on iOS or if already on.
  static Future<void> startListening() async {
    if (!Platform.isAndroid || _active) return;
    _active = true;
    try {
      await _channel.invokeMethod('start');
    } catch (_) {
      _active = false;
    }
  }

  /// Stop the service entirely (sign-out). No-op on iOS or if already off.
  static Future<void> stopListening() async {
    if (!Platform.isAndroid || !_active) return;
    _active = false;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
