import 'package:cloud_firestore/cloud_firestore.dart';

class Friend {
  final String friendId;
  final String ownerName; // New field for owner's name.
  final DateTime addedAt;

  Friend({
    required this.friendId,
    required this.ownerName,
    required this.addedAt,
  });

  factory Friend.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Friend(
      friendId: data['friendId'] ?? '',
      ownerName: data['ownerName'] ?? '', // Read ownerName from data.
      addedAt: data['addedAt'] != null
          ? (data['addedAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'friendId': friendId,
      'ownerName': ownerName, // Write ownerName into Firestore.
      'addedAt': Timestamp.fromDate(addedAt),
    };
  }
}
