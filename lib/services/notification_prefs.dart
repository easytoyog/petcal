import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

Map<String, int> _dailyStepsUtcSlot() {
  final nowLocal = DateTime.now();
  final localRecapTime = DateTime(
    nowLocal.year,
    nowLocal.month,
    nowLocal.day,
    21,
  );
  final recapUtc = localRecapTime.toUtc();

  return {
    'dailyStepsHourUtc': recapUtc.hour,
    'dailyStepsMinuteBucketUtc': (recapUtc.minute ~/ 5) * 5,
  };
}

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

  final recapSlot = _dailyStepsUtcSlot();

  await FirebaseFirestore.instance.collection('owners').doc(uid).set({
    'tz': tz,
    'dailyStepsOptIn': true, // toggle later in Settings
    'dailyStepsHourUtc': recapSlot['dailyStepsHourUtc'],
    'dailyStepsMinuteBucketUtc': recapSlot['dailyStepsMinuteBucketUtc'],
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}
