import 'package:cloud_firestore/cloud_firestore.dart';

class Pet {
  final String id; // Firestore doc id (not stored in map)
  final String ownerId; // required
  final String name; // required, non-empty
  final String? photoUrl; // optional
  final String? breed; // optional
  final String? sex; // optional
  final String? size; // optional
  final String? temperament; // optional
  final double? weight; // optional
  final DateTime? birthday; // optional
  final String? energyLevel; // optional
  final bool? isSpayedOrNeutered; // optional
  final String? friendlyWithDogs; // optional

  Pet({
    required this.id,
    required this.ownerId,
    required this.name,
    this.photoUrl,
    this.breed,
    this.sex,
    this.size,
    this.temperament,
    this.weight,
    this.birthday,
    this.energyLevel,
    this.isSpayedOrNeutered,
    this.friendlyWithDogs,
  });

  /// Robust factory from Firestore
  factory Pet.fromFirestore(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>? ?? {});
    return Pet(
      id: doc.id,
      ownerId: (data['ownerId'] ?? '') as String,
      name: (data['name'] ?? '') as String,
      photoUrl: data['photoUrl'] as String?,
      breed: data['breed'] as String?,
      sex: data['sex'] as String?,
      size: data['size'] as String?,
      temperament: data['temperament'] as String?,
      weight:
          (data['weight'] is num) ? (data['weight'] as num).toDouble() : null,
      birthday: (data['birthday'] is Timestamp)
          ? (data['birthday'] as Timestamp).toDate()
          : null,
      energyLevel: data['energyLevel'] as String?,
      isSpayedOrNeutered: data['isSpayedOrNeutered'] is bool
          ? data['isSpayedOrNeutered'] as bool
          : null,
      friendlyWithDogs: data['friendlyWithDogs'] as String?,
    );
  }

  /// Firestore map: OMIT optional nulls so rules don’t see null values
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'ownerId': ownerId,
      'name': name,
    };
    if (photoUrl != null) map['photoUrl'] = photoUrl;
    if (breed != null) map['breed'] = breed;
    if (sex != null) map['sex'] = sex;
    if (size != null) map['size'] = size;
    if (temperament != null) map['temperament'] = temperament;
    if (weight != null) map['weight'] = weight;
    if (birthday != null) map['birthday'] = Timestamp.fromDate(birthday!);
    if (energyLevel != null) map['energyLevel'] = energyLevel;
    if (isSpayedOrNeutered != null) {
      map['isSpayedOrNeutered'] = isSpayedOrNeutered;
    }
    if (friendlyWithDogs != null) {
      map['friendlyWithDogs'] = friendlyWithDogs;
    }
    return map;
  }

  Pet copyWith({
    String? id,
    String? ownerId,
    String? name,
    String? photoUrl,
    String? breed,
    String? sex,
    String? size,
    String? temperament,
    double? weight,
    DateTime? birthday,
    String? energyLevel,
    bool? isSpayedOrNeutered,
    String? friendlyWithDogs,
  }) {
    return Pet(
      id: id ?? this.id,
      ownerId: ownerId ?? this.ownerId,
      name: name ?? this.name,
      photoUrl: photoUrl ?? this.photoUrl,
      breed: breed ?? this.breed,
      sex: sex ?? this.sex,
      size: size ?? this.size,
      temperament: temperament ?? this.temperament,
      weight: weight ?? this.weight,
      birthday: birthday ?? this.birthday,
      energyLevel: energyLevel ?? this.energyLevel,
      isSpayedOrNeutered: isSpayedOrNeutered ?? this.isSpayedOrNeutered,
      friendlyWithDogs: friendlyWithDogs ?? this.friendlyWithDogs,
    );
  }
}
