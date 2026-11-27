import 'package:flutter/services.dart';

import 'linux_notifications.dart';

class AndroidNotifications implements NativeNotificationBridge {
  const AndroidNotifications();
  static const _channel = MethodChannel('securemesh/message_notifications');
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('enable') == true;
  Future<void> systemSettings() => _channel.invokeMethod<void>('settings');
  @override
  Future<bool> available() async =>
      await _channel.invokeMethod<bool>('available') == true;
  @override
  Future<bool> show(bool russian) async =>
      await _channel.invokeMethod<bool>('show', russian) == true;
  @override
  Future<void> clear() => _channel.invokeMethod<void>('clear');
}
