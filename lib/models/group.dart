import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class Group {
  final String id;
  final String name;
  final String? description;
  final String createdBy;
  final List<String> admins;
  final List<String> members;
  final String frequentPlace; // park ID
  final String? frequentPlaceName;
  final TimeOfDay? frequentTime;
  final bool isPublic;
  final DateTime createdAt;
  final DateTime updatedAt;
  final double? latitude;
  final double? longitude;
  final String? lastMessage;
  final DateTime? lastMessageAt;
  final String? lastMessageSenderId;

  Group({
    required this.id,
    required this.name,
    this.description,
    required this.createdBy,
    required this.admins,
    required this.members,
    required this.frequentPlace,
    this.frequentPlaceName,
    this.frequentTime,
    required this.isPublic,
    required this.createdAt,
    required this.updatedAt,
    this.latitude,
    this.longitude,
    this.lastMessage,
    this.lastMessageAt,
    this.lastMessageSenderId,
  });

  factory Group.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Group(
      id: doc.id,
      name: data['name'] ?? '',
      description: data['description'],
      createdBy: data['createdBy'] ?? '',
      admins: List<String>.from(data['admins'] ?? []),
      members: List<String>.from(data['members'] ?? []),
      frequentPlace: data['frequentPlace'] ?? '',
      frequentPlaceName: data['frequentPlaceName'],
      frequentTime: data['frequentTime'] != null
          ? _timeOfDayFromString(data['frequentTime'])
          : null,
      isPublic: data['isPublic'] ?? false,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
      latitude: (data['latitude'] as num?)?.toDouble(),
      longitude: (data['longitude'] as num?)?.toDouble(),
      lastMessage: (data['lastMessage'] as String?)?.trim(),
      lastMessageAt: data['lastMessageAt'] is Timestamp
          ? (data['lastMessageAt'] as Timestamp).toDate()
          : null,
      lastMessageSenderId: (data['lastMessageSenderId'] as String?)?.trim(),
    );
  }

  static TimeOfDay _timeOfDayFromString(String time) {
    final parts = time.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  static String timeOfDayToString(TimeOfDay time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
