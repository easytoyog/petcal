import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

Future<void> upsertNotificationPrefs() async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;

  String tz = 'UTC';
  try {
    final info = await FlutterTimezone.getLocalTimezone(); // TimezoneInfo
    tz = info.identifier; // e.g., "America/Toronto"
  } catch (_) {
    // keep 'UTC' fallback
  }

  await FirebaseFirestore.instance
      .collection('owners')
      .doc(uid)
      .set({
        'tz': tz,
        'dailyStepsOptIn': true, // toggle later in Settings
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
}
