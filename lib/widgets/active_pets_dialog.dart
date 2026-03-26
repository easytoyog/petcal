import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ActivePetsDialog extends StatefulWidget {
  final List<Map<String, dynamic>> pets;
  final String parkName;
  final bool isCheckedIn;
  final Future<void> Function()? onCheckInToggle;
  final VoidCallback? onOpenParkChat;

  /// Optional: parent callback (we call after DB writes succeed).
  final void Function(String ownerId, String petId)? onFavoriteToggle;

  /// Initial favorites to paint hearts before the listener kicks in.
  final Set<String> favoritePetIds;
  final String? currentUserId;

  const ActivePetsDialog({
    Key? key,
    required this.pets,
    required this.parkName,
    required this.isCheckedIn,
    this.onCheckInToggle,
    this.onOpenParkChat,
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
  bool _checkInBusy = false;
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

  Future<void> _handleCheckInToggle() async {
    final action = widget.onCheckInToggle;
    if (action == null || _checkInBusy) return;

    setState(() => _checkInBusy = true);
    try {
      await action();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _checkInBusy = false);
    }
  }

  void _handleOpenParkChat() {
    final action = widget.onOpenParkChat;
    if (action == null || _busy || _checkInBusy) return;
    Navigator.of(context).pop();
    action();
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
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.pets_outlined,
                          size: 36,
                          color: Colors.green.shade700,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        "No pups checked in yet",
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Looks quiet right now. Swing by and be the first to check in at ${widget.parkName}.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              )
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
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actions: [
        SizedBox(
          width: double.infinity,
          child: Row(
            children: [
              TextButton(
                onPressed: (_busy || _checkInBusy) ? null : _handleOpenParkChat,
                child: const Text("Park Chat"),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      widget.isCheckedIn ? Colors.red : Colors.green,
                ),
                onPressed:
                    (_busy || _checkInBusy) ? null : _handleCheckInToggle,
                child: _checkInBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Text(
                        widget.isCheckedIn ? "Check Out" : "Check In",
                        style: const TextStyle(color: Colors.white),
                      ),
              ),
              const Spacer(),
              TextButton(
                onPressed: (_busy || _checkInBusy)
                    ? null
                    : () => Navigator.of(context).pop(),
                child: const Text("Close"),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
