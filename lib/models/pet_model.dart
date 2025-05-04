import 'package:cloud_firestore/cloud_firestore.dart';

class Pet {
  final String id;
  final String ownerId;
  final String name;
  final String photoUrl;
  final String? breed;        // Optional
  final String? temperament;  // Optional
  final double? weight;       // Optional
  final DateTime? birthday;   // Optional

  Pet({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.photoUrl,
    this.breed,
    this.temperament,
    this.weight,
    this.birthday,
  });

  // Factory method to create a Pet instance from Firestore document
  factory Pet.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Pet(
      id: doc.id,
      ownerId: data['ownerId'] ?? '',
      name: data['name'] ?? '',
      photoUrl: data['photoUrl'] ?? '',
      breed: data['breed'],
      temperament: data['temperament'],
      weight: data['weight'] != null ? (data['weight'] as num).toDouble() : null,
      birthday: data['birthday'] != null
          ? (data['birthday'] as Timestamp).toDate()
          : null,
    );
  }

  // Convert Pet instance to Firestore-friendly map
  Map<String, dynamic> toMap() {
    return {
      'ownerId': ownerId,
      'name': name,
      'photoUrl': photoUrl,
      'breed': breed,
      'temperament': temperament,
      'weight': weight,
      'birthday': birthday != null ? Timestamp.fromDate(birthday!) : null,
    };
  }
}
