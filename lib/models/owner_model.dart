import 'package:cloud_firestore/cloud_firestore.dart';

class Owner {
  final String uid;
  final String firstName;
  final String lastName;
  final String phone;
  final String email;
  final List<String> pets; // List of pet IDs
  final Address address;
  final int locationType; // 1: Automatic, 2: App Open, 3: Manual
  final String? fcmToken; // <-- Add this line

  Owner({
    required this.uid,
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.email,
    required this.pets,
    required this.address,
    required this.locationType,
    this.fcmToken, // <-
  });

  /// Create an Owner from a Firestore [DocumentSnapshot].
  factory Owner.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Owner(
      uid: doc.id, // Use the document ID as the owner's UID
      firstName: data['firstName'] ?? '',
      lastName: data['lastName'] ?? '',
      phone: data['phone'] ?? '',
      email: data['email'] ?? '',
      pets: List<String>.from(data['pets'] ?? []),
      address: Address.fromMap(data['address'] ?? {}),
      locationType: data['locationType'] ?? 1, // Default to 1
      fcmToken: data['fcmToken'], // <-- Add this line
    );
  }

  /// Convert Owner instance to a Firestore-friendly map.
  Map<String, dynamic> toMap() {
    return {
      'firstName': firstName,
      'lastName': lastName,
      'phone': phone,
      'email': email,
      'pets': pets,
      'address': address.toMap(),
      'locationType': locationType,
      'fcmToken': fcmToken, // <-- Add this line
    };
  }
}

class Address {
  final String street;
  final String city;
  final String state;
  final String country;
  final String postalCode;

  Address({
    required this.street,
    required this.city,
    required this.state,
    required this.country,
    required this.postalCode,
  });

  /// Factory method to create an Address from a [Map].
  factory Address.fromMap(Map<String, dynamic> data) {
    return Address(
      street: data['street'] ?? '',
      city: data['city'] ?? '',
      state: data['state'] ?? '',
      country: data['country'] ?? '',
      postalCode: data['postalCode'] ?? '',
    );
  }

  /// Convert Address instance to a Firestore-friendly map.
  Map<String, dynamic> toMap() {
    return {
      'street': street,
      'city': city,
      'state': state,
      'country': country,
      'postalCode': postalCode,
    };
  }
}

class OwnerModel {
  final String uid;
  final String email;
  final String firstName;
  final String lastName;
  final String phone;
  final Map<String, dynamic> address;
  final bool active;

  OwnerModel({
    required this.uid,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.address,
    this.active = true, // <-- Default to true
  });

  factory OwnerModel.fromMap(String uid, Map<String, dynamic> data) {
    return OwnerModel(
      uid: uid,
      email: data['email'] ?? '',
      firstName: data['firstName'] ?? '',
      lastName: data['lastName'] ?? '',
      phone: data['phone'] ?? '',
      address: data['address'] ?? {},
      active: data['active'] ?? true, // <-- Default to true if missing
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'email': email,
      'firstName': firstName,
      'lastName': lastName,
      'phone': phone,
      'address': address,
      'active': active,
    };
  }
}
