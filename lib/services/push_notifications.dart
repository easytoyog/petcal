import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

final FlutterLocalNotificationsPlugin _local =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel _dmChannel = AndroidNotificationChannel(
  'dm_messages',
  'Direct Messages',
  description: 'Notifications for direct messages',
  importance: Importance.high,
);

Future<void> initPushNotifications({
  required GlobalKey<NavigatorState> navigatorKey,
}) async {
  // Local notifications init
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings();
  const initSettings =
      InitializationSettings(android: androidInit, iOS: iosInit);

  await _local.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (resp) {
      final payload = resp.payload;
      if (payload != null && payload.isNotEmpty) {
        _handlePayloadTap(payload, navigatorKey);
      }
    },
  );

  // Android channel
  await _local
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_dmChannel);

  // Foreground messages -> show LOCAL notification
  FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
    final data = message.data;
    final type = data['type'];

    if (type == 'dm') {
      final threadId = (data['threadId'] ?? '').toString();
      final senderId = (data['senderId'] ?? '').toString();
      final senderName = (data['senderName'] ?? '').toString();

      // Prefer notification title/body, fallback to data
      final title = message.notification?.title ??
          (senderName.isNotEmpty ? senderName : 'New message');
      final body = message.notification?.body ??
          (data['body'] ?? 'Tap to open').toString();

      // Encode payload safely (handles spaces, symbols, etc.)
      final payload = _encodePayload({
        'type': 'dm',
        'threadId': threadId,
        'senderId': senderId,
        'senderName': senderName,
      });

      await _local.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _dmChannel.id,
            _dmChannel.name,
            channelDescription: _dmChannel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: payload,
      );
    }
  });

  // App opened from PUSH notification (background)
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    _handleRemoteMessageTap(message, navigatorKey);
  });

  // App opened from PUSH notification (terminated)
  final initial = await FirebaseMessaging.instance.getInitialMessage();
  if (initial != null) {
    _handleRemoteMessageTap(initial, navigatorKey);
  }
}

void _handleRemoteMessageTap(
  RemoteMessage message,
  GlobalKey<NavigatorState> navKey,
) {
  final data = message.data;
  final type = data['type'];

  if (type == 'dm') {
    final threadId = (data['threadId'] ?? '').toString();
    final senderId = (data['senderId'] ?? '').toString();
    final senderName = (data['senderName'] ?? '').toString();

    _openDm(
      navKey,
      threadId: threadId,
      otherUserId: senderId,
      otherDisplayName: senderName.isNotEmpty ? senderName : 'Message',
    );
  }
}

void _handlePayloadTap(String payload, GlobalKey<NavigatorState> navKey) {
  final parts = _decodePayload(payload);

  if (parts['type'] == 'dm') {
    _openDm(
      navKey,
      threadId: parts['threadId'] ?? '',
      otherUserId: parts['senderId'] ?? '',
      otherDisplayName: (parts['senderName'] ?? '').isNotEmpty
          ? parts['senderName']!
          : 'Message',
    );
  }
}

void _openDm(
  GlobalKey<NavigatorState> navKey, {
  required String threadId,
  required String otherUserId,
  required String otherDisplayName,
}) {
  final ctx = navKey.currentContext;
  if (ctx == null) return;
  if (otherUserId.isEmpty) return;

  navKey.currentState?.pushNamed(
    '/dm',
    arguments: {
      'otherUserId': otherUserId,
      'otherDisplayName': otherDisplayName,
      'threadId': threadId, // optional if your screen doesn’t need it
    },
  );
}

/// Encode a small map into a compact payload string.
String _encodePayload(Map<String, String> map) {
  // payload -> base64(json) avoids issues with &, =, spaces, emojis
  final jsonStr = jsonEncode(map);
  return base64UrlEncode(utf8.encode(jsonStr));
}

/// Decode payload back to a map.
Map<String, String> _decodePayload(String payload) {
  try {
    final jsonStr = utf8.decode(base64Url.decode(payload));
    final obj = jsonDecode(jsonStr);
    if (obj is Map) {
      return obj.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
  } catch (_) {}
  return {};
}
