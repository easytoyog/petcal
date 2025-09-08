import 'package:cloud_firestore/cloud_firestore.dart';

class ServiceAd {
  final String id;
  final String ownerId;            // <-- use ownerId (rules/UI rely on this)
  final String type;               // Walker/Groomer/...
  final String title;
  final String description;
  final double latitude;
  final double longitude;
  final List<String> images;
  final String? postalCode;
  final Timestamp? createdAt;      // keep as Timestamp to match Firestore
  final Timestamp? updatedAt;

  // Not stored; computed client-side
  double? distanceFromUser;

  ServiceAd({
    required this.id,
    required this.ownerId,
    required this.type,
    required this.title,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.images,
    this.postalCode,
    this.createdAt,
    this.updatedAt,
    this.distanceFromUser,
  });

  factory ServiceAd.fromFirestore(DocumentSnapshot doc) {
    final data = (doc.data() ?? {}) as Map<String, dynamic>;

    double _asDouble(dynamic v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0.0;
      return 0.0;
    }

    final List<String> imgs =
        (data['images'] as List?)?.whereType<String>().toList() ?? <String>[];

    return ServiceAd(
      id: doc.id,
      ownerId: (data['ownerId'] ?? data['userId'] ?? '') as String, // fallback
      type: (data['type'] ?? '') as String,
      title: (data['title'] ?? '') as String,
      description: (data['description'] ?? '') as String,
      latitude: _asDouble(data['latitude']),
      longitude: _asDouble(data['longitude']),
      images: imgs,
      postalCode: data['postalCode'] as String?,
      createdAt: data['createdAt'] is Timestamp ? data['createdAt'] as Timestamp : null,
      updatedAt: data['updatedAt'] is Timestamp ? data['updatedAt'] as Timestamp : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'ownerId': ownerId,          // <-- write ownerId
      'type': type,
      'title': title,
      'description': description,
      'latitude': latitude,
      'longitude': longitude,
      'images': images,
      if (postalCode != null) 'postalCode': postalCode,
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }
}
