import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ActivePetsDialog extends StatefulWidget {
  final List<Map<String, dynamic>> pets;

  /// Optional: parent callback (we call after DB writes succeed).
  final void Function(String ownerId, String petId)? onFavoriteToggle;

  /// Initial favorites to paint hearts before the listener kicks in.
  final Set<String> favoritePetIds;
  final String? currentUserId;

  const ActivePetsDialog({
    Key? key,
    required this.pets,
    this.onFavoriteToggle,
    this.favoritePetIds = const {},
    this.currentUserId,
  }) : super(key: key);

  @override
  State<ActivePetsDialog> createState() => _ActivePetsDialogState();
}

class _ActivePetsDialogState extends State<ActivePetsDialog> {
  late Set<String> _favIds;
  bool _busy = false;
  StreamSubscription<QuerySnapshot>? _favSub;

  String? get _myUid =>
      widget.currentUserId ?? FirebaseAuth.instance.currentUser?.uid;

  CollectionReference<Map<String, dynamic>> _favPetsCol(String uid) =>
      FirebaseFirestore.instance
          .collection('favorites')
          .doc(uid)
          .collection('pets');

  DocumentReference<Map<String, dynamic>> _favPetRef(
          String uid, String petId) =>
      _favPetsCol(uid).doc(petId);

  @override
  void initState() {
    super.initState();
    _favIds = Set<String>.from(widget.favoritePetIds);

    // Live-sync hearts with Firestore (prevents “fills then empties” on rebuild)
    final uid = _myUid;
    if (uid != null) {
      _favSub = _favPetsCol(uid).snapshots().listen((qs) {
        final serverIds = qs.docs.map((d) => d.id).toSet();
        if (mounted) setState(() => _favIds = serverIds);
      });
    }
  }

  @override
  void dispose() {
    _favSub?.cancel();
    super.dispose();
  }

  Future<void> _toggleFavorite(String ownerId, String petId) async {
    if (_busy) return;
    final uid = _myUid;
    if (uid == null || petId.isEmpty || ownerId.isEmpty || ownerId == uid) {
      return; // invalid or trying to favorite yourself
    }

    setState(() => _busy = true);
    final favDoc = _favPetRef(uid, petId);
    try {
      final isFav = _favIds.contains(petId);

      if (isFav) {
        // Remove friend + favorite
        await _unfriend(ownerId, petId, uid);
      } else {
        // Add friend + favorite
        await _addFriend(ownerId, petId, uid);
      }

      // Trust the DB: read back the favorite doc and set local state accordingly
      final exists = (await favDoc.get()).exists;
      if (mounted) {
        setState(() {
          if (exists) {
            _favIds.add(petId);
          } else {
            _favIds.remove(petId);
          }
        });
      }

      // optional parent notify
      widget.onFavoriteToggle?.call(ownerId, petId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating favorite: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addFriend(
      String friendUserId, String petId, String currentUid) async {
    String ownerName = '';
    try {
      final profileDoc = await FirebaseFirestore.instance
          .collection('public_profiles')
          .doc(friendUserId)
          .get();
      if (profileDoc.exists) {
        final data = profileDoc.data() as Map<String, dynamic>;
        ownerName = (data['displayName'] ?? '').toString().trim();
      }
    } catch (_) {}
    if (ownerName.isEmpty) ownerName = friendUserId;

    final batch = FirebaseFirestore.instance.batch();

    final friendRef = FirebaseFirestore.instance
        .collection('friends')
        .doc(currentUid)
        .collection('userFriends')
        .doc(friendUserId);

    batch.set(friendRef, {
      'friendId': friendUserId,
      'ownerName': ownerName,
      'addedAt': FieldValue.serverTimestamp(),
    });

    if (petId.isNotEmpty) {
      final favRef = _favPetRef(currentUid, petId);
      batch.set(favRef, {
        'petId': petId,
        'addedAt': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();

    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Friend added!")));
    }
  }

  Future<void> _unfriend(
      String friendUserId, String petId, String currentUid) async {
    final batch = FirebaseFirestore.instance.batch();

    final friendRef = FirebaseFirestore.instance
        .collection('friends')
        .doc(currentUid)
        .collection('userFriends')
        .doc(friendUserId);
    batch.delete(friendRef);

    if (petId.isNotEmpty) {
      final favRef = _favPetRef(currentUid, petId);
      batch.delete(favRef);
    }

    await batch.commit();

    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Friend removed.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 24),
      title: const Text("Pets in Park"),
      content: SizedBox(
        width: 420,
        height: 500,
        child: widget.pets.isEmpty
            ? const Center(child: Text("No pets currently checked in."))
            : ListView.separated(
                itemCount: widget.pets.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (ctx, i) {
                  final pet = widget.pets[i];
                  final ownerId = (pet['ownerId'] as String? ?? '').trim();
                  final petId = (pet['petId'] as String? ?? '').trim();
                  final petName = (pet['petName'] as String? ?? '').trim();
                  final petPhoto = (pet['petPhotoUrl'] as String? ?? '').trim();
                  final checkIn = (pet['checkInTime'] as String? ?? '').trim();
                  final mine = (ownerId == _myUid);
                  final isFav = _favIds.contains(petId);

                  return ListTile(
                    leading: (petPhoto.isNotEmpty)
                        ? CircleAvatar(backgroundImage: NetworkImage(petPhoto))
                        : const CircleAvatar(child: Icon(Icons.pets)),
                    title: Text(petName.isEmpty ? 'Unknown Pet' : petName),
                    subtitle: Text(
                      mine
                          ? "Your pet – Checked in for $checkIn"
                          : (checkIn.isNotEmpty
                              ? "Checked in for $checkIn"
                              : " "),
                    ),
                    trailing: mine
                        ? null
                        : IconButton(
                            tooltip: isFav ? 'Remove Friend' : 'Add Friend',
                            icon: Icon(
                              isFav ? Icons.favorite : Icons.favorite_border,
                              color: Colors.red,
                            ),
                            onPressed: _busy
                                ? null
                                : () => _toggleFavorite(ownerId, petId),
                          ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text("Close"),
        ),
      ],
    );
  }
}
