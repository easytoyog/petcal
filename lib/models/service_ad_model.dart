import 'package:cloud_firestore/cloud_firestore.dart';

class ServiceAd {
  final String id;
  final String userId;
  final String type; // e.g., dog_walker, groomer, vet
  final String title;
  final String description;
  final double latitude;
  final double longitude;
  final Timestamp createdAt;
  final List<String> images;
  final String? postalCode; // <-- Added field

  double? distanceFromUser; // Optional: used at runtime for sorting

  ServiceAd({
    required this.id,
    required this.userId,
    required this.type,
    required this.title,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.createdAt,
    required this.images,
    this.postalCode, // <-- Added parameter
    this.distanceFromUser,
  });

  factory ServiceAd.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ServiceAd(
      id: doc.id,
      userId: data['userId'] ?? '',
      type: data['type'] ?? '',
      title: data['title'] ?? '',
      description: data['description'] ?? '',
      latitude: (data['latitude'] is int)
          ? (data['latitude'] as int).toDouble()
          : (data['latitude'] ?? 0.0),
      longitude: (data['longitude'] is int)
          ? (data['longitude'] as int).toDouble()
          : (data['longitude'] ?? 0.0),
      createdAt:
          data['createdAt'] is Timestamp ? data['createdAt'] : Timestamp.now(),
      images: List<String>.from(data['images'] ?? []),
      postalCode: data['postalCode'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'type': type,
      'title': title,
      'description': description,
      'latitude': latitude,
      'longitude': longitude,
      'createdAt': createdAt,
      'images': images,
      'postalCode': postalCode, // <-- Include in map
    };
  }
}
