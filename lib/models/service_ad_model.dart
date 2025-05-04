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
  final List<String> images; // Add this field for storing image URLs

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
    required this.images, // Add this parameter
    this.distanceFromUser,
  });

  factory ServiceAd.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ServiceAd(
      id: doc.id,
      userId: data['userId'],
      type: data['type'],
      title: data['title'],
      description: data['description'],
      latitude: data['latitude'],
      longitude: data['longitude'],
      createdAt: data['createdAt'],
      images: List<String>.from(data['images'] ?? []), // Parse images from Firestore
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
      'images': images, // Include images in map
    };
  }
}