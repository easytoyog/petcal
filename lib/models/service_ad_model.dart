import 'package:cloud_firestore/cloud_firestore.dart';

class ServiceAd {
  final String id;
  final String ownerId; // <-- use ownerId (rules/UI rely on this)
  final String type; // Walker/Groomer/...
  final String title;
  final String description;
  final double latitude;
  final double longitude;
  final List<String> images;
  final String? postalCode;
  final Timestamp? createdAt; // keep as Timestamp to match Firestore
  final Timestamp? updatedAt;

  // NEW: Contact info stored on the service doc
  final String? contactPhone;
  final String? contactEmail;
  final String? contactAddress;

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

    // NEW
    this.contactPhone,
    this.contactEmail,
    this.contactAddress,
    this.distanceFromUser,
  });

  factory ServiceAd.fromFirestore(DocumentSnapshot doc) {
    final data = (doc.data() ?? {}) as Map<String, dynamic>;

    double asDouble(dynamic v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0.0;
      return 0.0;
    }

    String? asNullableTrimmedString(dynamic v) {
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    final List<String> imgs =
        (data['images'] as List?)?.whereType<String>().toList() ?? <String>[];

    return ServiceAd(
      id: doc.id,
      ownerId: (data['ownerId'] ?? data['userId'] ?? '') as String, // fallback
      type: (data['type'] ?? '') as String,
      title: (data['title'] ?? '') as String,
      description: (data['description'] ?? '') as String,
      latitude: asDouble(data['latitude']),
      longitude: asDouble(data['longitude']),
      images: imgs,
      postalCode: data['postalCode'] as String?,
      createdAt: data['createdAt'] is Timestamp
          ? data['createdAt'] as Timestamp
          : null,
      updatedAt: data['updatedAt'] is Timestamp
          ? data['updatedAt'] as Timestamp
          : null,

      // NEW (backwards compatible: missing fields => null)
      contactPhone: asNullableTrimmedString(data['contactPhone']),
      contactEmail: asNullableTrimmedString(data['contactEmail']),
      contactAddress: asNullableTrimmedString(data['contactAddress']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'ownerId': ownerId, // <-- write ownerId
      'type': type,
      'title': title,
      'description': description,
      'latitude': latitude,
      'longitude': longitude,
      'images': images,
      if (postalCode != null) 'postalCode': postalCode,
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,

      // NEW (store empty-string-free values)
      if (contactPhone != null) 'contactPhone': contactPhone,
      if (contactEmail != null) 'contactEmail': contactEmail,
      if (contactAddress != null) 'contactAddress': contactAddress,
    };
  }
}
