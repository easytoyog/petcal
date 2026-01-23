import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:inthepark/models/owner_model.dart';
import 'package:inthepark/models/pet_model.dart';
import 'package:inthepark/models/park_event.dart';

class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Get current user's UID
  String? getCurrentUserId() {
    return _auth.currentUser?.uid;
  }

  /// Create/Update an owner document for current user
  Future<void> createOwner(Owner owner) async {
    final uid = getCurrentUserId();
    if (uid == null) {
      throw Exception("User not authenticated.");
    }
    await _firestore.collection('owners').doc(uid).set(owner.toMap());
  }

  /// Add (or update) a pet document
  Future<void> addPet(Pet pet) async {
    try {
      await _firestore.collection('pets').doc(pet.id).set({
        ...pet.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (e) {
      debugPrint('Firestore error [${e.code}] ${e.message}');
      rethrow;
    }
  }

  /// Delete a pet document
  Future<void> deletePet(String petId) async {
    await _firestore.collection('pets').doc(petId).delete();
  }

  /// Fetch owner details for the current user
  Future<Owner?> getOwner() async {
    final uid = getCurrentUserId();
    if (uid == null) return null;
    final doc = await _firestore.collection('owners').doc(uid).get();
    if (!doc.exists) {
      // Don't throw, just return null
      return null;
    }
    return Owner.fromFirestore(doc);
  }

  /// Fetch all pets for the specified owner ID
  Future<List<Pet>> getPetsForOwner(String ownerId) async {
    final querySnapshot = await _firestore
        .collection('pets')
        .where('ownerId', isEqualTo: ownerId)
        .get();

    return querySnapshot.docs.map((doc) => Pet.fromFirestore(doc)).toList();
  }

  Future<void> updateOwner(Owner updatedOwner) async {
    final uid = getCurrentUserId();
    if (uid == null) {
      throw Exception("User not authenticated.");
    }
    // We'll use .update(...) so we don't accidentally overwrite fields we might add later
    await _firestore.collection('owners').doc(uid).update(updatedOwner.toMap());
  }

  Future<void> updatePet(Pet pet) async {
    await _firestore.collection('pets').doc(pet.id).update({
      ...pet.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> addEventToPark(String parkId, ParkEvent event) async {
    await FirebaseFirestore.instance
        .collection('parks')
        .doc(parkId)
        .collection('events')
        .doc(event.id)
        .set(event.toMap());
  }

  Future<void> likeEvent(String parkId, String eventId, String userId) async {
    final eventRef = FirebaseFirestore.instance
        .collection('parks')
        .doc(parkId)
        .collection('events')
        .doc(eventId);

    await eventRef.update({
      'likes': FieldValue.arrayUnion([userId]),
    });
  }

  Future<void> unlikeEvent(String parkId, String eventId, String userId) async {
    final eventRef = FirebaseFirestore.instance
        .collection('parks')
        .doc(parkId)
        .collection('events')
        .doc(eventId);

    await eventRef.update({
      'likes': FieldValue.arrayRemove([userId]),
    });
  }

  Future<void> updateEvent(String parkId, ParkEvent event) async {
    await FirebaseFirestore.instance
        .collection('parks')
        .doc(parkId)
        .collection('events')
        .doc(event.id)
        .update(event.toMap());
  }

  /// Check if the current user has liked the park
  Future<bool> isParkLiked(String parkId) async {
    final uid = getCurrentUserId();
    if (uid == null) return false;

    final doc = await _firestore
        .collection('owners')
        .doc(uid)
        .collection('likedParks')
        .doc(parkId)
        .get();

    return doc.exists;
  }

  Future<void> likePark(String parkId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final likeRef = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('likedParks')
        .doc(parkId);

    final subRef = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('chat_subscriptions')
        .doc(parkId);

    final batch = FirebaseFirestore.instance.batch();

    batch.set(
      likeRef,
      {
        'uid': uid,
        'parkId': parkId,
        'createdAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    batch.set(
      subRef,
      {
        'enabled': true,
        'parkId': parkId,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    await batch.commit();
  }

  Future<void> unlikePark(String parkId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final likeRef = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('likedParks')
        .doc(parkId);

    final subRef = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('chat_subscriptions')
        .doc(parkId);

    final batch = FirebaseFirestore.instance.batch();

    batch.delete(likeRef);

    batch.set(
      subRef,
      {
        'enabled': false,
        'parkId': parkId,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    await batch.commit();
  }

  Future<List<String>> getLikedParkIds() async {
    final uid = getCurrentUserId();
    if (uid == null) throw Exception("User not authenticated.");

    final snapshot = await _firestore
        .collection('owners')
        .doc(uid)
        .collection('likedParks')
        .get();

    return snapshot.docs.map((doc) => doc.id).toList();
  }

  /// Mark the current user's account as inactive (soft delete)
  Future<void> markAccountInactive() async {
    final uid = getCurrentUserId();
    if (uid == null) throw Exception("User not authenticated.");
    await _firestore
        .collection('owners')
        .doc(uid)
        .set({'active': false}, SetOptions(merge: true));
  }
}
