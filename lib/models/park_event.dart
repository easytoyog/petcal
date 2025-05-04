import 'package:cloud_firestore/cloud_firestore.dart';

class ParkEvent {
  final String id;
  final String parkId;
  final String name;
  final DateTime startDateTime;
  final DateTime endDateTime;
  final List<String> likes;
  final String createdBy;
  final double parkLatitude;
  final double parkLongitude;
  final String recurrence; // "none", "daily", "weekly", "monthly", or "one time"
  final String? weekday;  // For weekly events, e.g., "Monday"
  final int? eventDay;    // For monthly events (day of month)
  final DateTime? eventDate; // For one-time events (the specific date)

  ParkEvent({
    required this.id,
    required this.parkId,
    required this.name,
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
  });

  factory ParkEvent.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ParkEvent(
      id: doc.id,
      parkId: data['parkId'] ?? '',
      name: data['name'] ?? '',
      // If these fields are null, we fallback to DateTime.now() (or handle as needed)
      startDateTime: data['startDateTime'] != null 
          ? (data['startDateTime'] as Timestamp).toDate() 
          : DateTime.now(),
      endDateTime: data['endDateTime'] != null 
          ? (data['endDateTime'] as Timestamp).toDate() 
          : DateTime.now(),
      likes: data['likes'] != null ? List<String>.from(data['likes']) : [],
      createdBy: data['createdBy'] ?? '',
      parkLatitude: (data['parkLatitude'] as num?)?.toDouble() ?? 0.0,
      parkLongitude: (data['parkLongitude'] as num?)?.toDouble() ?? 0.0,
      recurrence: data['recurrence'] ?? "none",
      weekday: data['weekday'],
      eventDay: data['eventDay'],
      eventDate: data['eventDate'] != null 
          ? (data['eventDate'] as Timestamp).toDate() 
          : null,
    );
  }


  Map<String, dynamic> toMap() {
    return {
      'parkId': parkId,
      'name': name,
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
    };
  }
}
