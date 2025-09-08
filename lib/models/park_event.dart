import 'package:cloud_firestore/cloud_firestore.dart';

class ParkEvent {
  final String id;
  final String parkId;
  final String name;
  final String description;            // NEW
  final DateTime startDateTime;
  final DateTime endDateTime;
  final List<String> likes;
  final String createdBy;
  final double parkLatitude;
  final double parkLongitude;
  final String recurrence;             // "none", "daily", "weekly", "monthly", "One Time"
  final String? weekday;               // for weekly
  final int? eventDay;                 // for monthly (1–31)
  final DateTime? eventDate;           // for one-time
  final DateTime? createdAt;           // optional (server timestamp on write)

  ParkEvent({
    required this.id,
    required this.parkId,
    required this.name,
    this.description = '',
    required this.startDateTime,
    required this.endDateTime,
    this.likes = const [],
    required this.createdBy,
    required this.parkLatitude,
    required this.parkLongitude,
    this.recurrence = "none",
    this.weekday,
    this.eventDay,
    this.eventDate,
    this.createdAt,
  });

  factory ParkEvent.fromFirestore(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>?) ?? {};
    return ParkEvent(
      id: doc.id,
      parkId: (data['parkId'] ?? '') as String,
      name: (data['name'] ?? '') as String,
      description: (data['description'] ?? '') as String, // NEW
      startDateTime: data['startDateTime'] is Timestamp
          ? (data['startDateTime'] as Timestamp).toDate()
          : DateTime.now(),
      endDateTime: data['endDateTime'] is Timestamp
          ? (data['endDateTime'] as Timestamp).toDate()
          : DateTime.now(),
      likes: (data['likes'] as List?)?.cast<String>() ?? const [],
      createdBy: (data['createdBy'] ?? '') as String,
      parkLatitude: (data['parkLatitude'] as num?)?.toDouble() ?? 0.0,
      parkLongitude: (data['parkLongitude'] as num?)?.toDouble() ?? 0.0,
      recurrence: (data['recurrence'] ?? 'none') as String,
      weekday: data['weekday'] as String?,
      eventDay: data['eventDay'] as int?,
      eventDate: data['eventDate'] is Timestamp
          ? (data['eventDate'] as Timestamp).toDate()
          : null,
      createdAt: data['createdAt'] is Timestamp
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'parkId': parkId,
      'name': name,
      'description': description, // NEW
      'startDateTime': Timestamp.fromDate(startDateTime),
      'endDateTime': Timestamp.fromDate(endDateTime),
      'likes': likes,
      'createdBy': createdBy,
      'parkLatitude': parkLatitude,
      'parkLongitude': parkLongitude,
      'recurrence': recurrence,
      if (weekday != null) 'weekday': weekday,
      if (eventDay != null) 'eventDay': eventDay,
      if (eventDate != null) 'eventDate': Timestamp.fromDate(eventDate!),
      // NOTE: you’re already setting createdAt with FieldValue.serverTimestamp() at write time,
      // so we usually omit it here to avoid mixing DateTime/Timestamp/FieldValue.
    };
  }
}
