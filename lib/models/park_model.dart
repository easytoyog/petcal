import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';

class Park {
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  int userCount; // Number of users currently in the park
  double? distance; // Distance from the user (optional)

  Park({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.userCount = 0,
    this.distance,
  });

  factory Park.fromJson(Map<String, dynamic> json) {
    return Park(
      id: json['id'],
      name: json['name'],
      latitude: json['latitude'],
      longitude: json['longitude'],
      userCount: json['userCount'] ?? 0,
      distance: json['distance'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'userCount': userCount,
      'distance': distance,
    };
  }

  factory Park.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Park(
      id: doc.id,
      name: data['name'] ?? 'Unnamed Park',
      latitude: data['latitude']?.toDouble() ?? 0.0,
      longitude: data['longitude']?.toDouble() ?? 0.0,
    );
  }

  double calculateDistance(double userLat, double userLng) {
    const double earthRadius = 6371;
    double dLat = (latitude - userLat) * (pi / 180);
    double dLng = (longitude - userLng) * (pi / 180);
    double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(userLat * (pi / 180)) * cos(latitude * (pi / 180)) * sin(dLng / 2) * sin(dLng / 2);
    double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  bool isWithinRadius(double userLat, double userLng, double radius) {
    return calculateDistance(userLat, userLng) <= radius;
  }

  Future<void> updateUserCount(FirebaseFirestore firestore) async {
    final parkRef = firestore.collection('parks').doc(id);
    final activeUsersSnapshot = await parkRef.collection('active_users').get();
    userCount = activeUsersSnapshot.size;
  }
}
