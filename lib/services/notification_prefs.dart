import 'package:flutter_native_timezone/flutter_native_timezone.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

Future<void> upsertNotificationPrefs() async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;

  String tz;
  try {
    tz = await FlutterNativeTimezone.getLocalTimezone(); // e.g. America/Toronto
  } catch (_) {
    tz = 'UTC';
  }

  await FirebaseFirestore.instance.collection('owners').doc(uid).set({
    'tz': tz,
    'dailyStepsOptIn': true, // toggleable later in Settings
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}
