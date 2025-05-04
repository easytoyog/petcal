import 'package:cloud_firestore/cloud_firestore.dart';

class Owner {
  final String id;
  final String firstName;
  final String lastName;
  final String email;
  final Map<String, dynamic> address;
  final String phone;
  final DateTime? createdAt;

  Owner({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.address,
    required this.phone,
    this.createdAt,
  });

  // Convert Owner object to Firestore document
  Map<String, dynamic> toFirestore() {
    return {
      'firstName': firstName,
      'lastName': lastName,
      'email': email,
      'address': address,
      'phone': phone,
      'createdAt': createdAt != null ? Timestamp.fromDate(createdAt!) : null,
    };
  }

  // Create Owner object from Firestore document
  factory Owner.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Owner(
      id: doc.id,
      firstName: data['firstName'] ?? '',
      lastName: data['lastName'] ?? '',
      email: data['email'] ?? '',
      address: data['address'] ?? {},
      phone: data['phone'] ?? '',
      createdAt: data['createdAt'] != null
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
    );
  }
}

class Pet {
  final String id;
  final String ownerId;
  final String name;
  final String photoUrl;
  final String? breed;
  final String? temperament;
  final double? weight;
  final DateTime? birthday;
  final bool isPrimary;
  final DateTime? createdAt;

  Pet({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.photoUrl,
    this.breed,
    this.temperament,
    this.weight,
    this.birthday,
    this.isPrimary = false,
    this.createdAt,
  });

  // Convert Pet object to Firestore document
  Map<String, dynamic> toFirestore() {
    return {
      'ownerId': ownerId,
      'name': name,
      'photoUrl': photoUrl,
      'breed': breed,
      'temperament': temperament,
      'weight': weight,
      'birthday': birthday != null ? Timestamp.fromDate(birthday!) : null,
      'isPrimary': isPrimary,
      'createdAt': createdAt != null ? Timestamp.fromDate(createdAt!) : null,
    };
  }

  // Create Pet object from Firestore document (single argument)
  factory Pet.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Pet(
      id: doc.id,
      ownerId: data['ownerId'] ?? '',
      name: data['name'] ?? '',
      photoUrl: data['photoUrl'] ?? '',
      breed: data['breed'],
      temperament: data['temperament'],
      weight: (data['weight'] as num?)?.toDouble(),
      birthday: data['birthday'] != null
          ? (data['birthday'] as Timestamp).toDate()
          : null,
      isPrimary: data['isPrimary'] ?? false,
      createdAt: data['createdAt'] != null
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
    );
  }
}

class FirestoreDatabase {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Add Owner
  Future<void> addOwner(Owner owner) async {
    try {
      await _firestore.collection('owners').doc(owner.id).set(owner.toFirestore());
    } catch (e) {
      throw Exception('Error adding owner: $e');
    }
  }

  // Add Pet
  Future<void> addPet(Pet pet) async {
    try {
      await _firestore.collection('pets').doc(pet.id).set(pet.toFirestore());
    } catch (e) {
      throw Exception('Error adding pet: $e');
    }
  }

  // Get Pets by Owner ID
  Future<List<Pet>> getPetsByOwner(String ownerId) async {
    try {
      final querySnapshot = await _firestore
          .collection('pets')
          .where('ownerId', isEqualTo: ownerId)
          .get();

      // We can call Pet.fromFirestore(doc) because now it only needs one argument
      return querySnapshot.docs.map((doc) => Pet.fromFirestore(doc)).toList();
    } catch (e) {
      throw Exception('Error fetching pets: $e');
    }
  }
}
