// lib/features/park_users_dialog.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:inthepark/screens/chatroom_screen.dart';
import 'package:inthepark/services/firestore_service.dart';
import 'package:inthepark/services/location_service.dart';

typedef ShowEventsCallback = void Function(String parkId);
typedef AddEventCallback = void Function(
  String parkId,
  double parkLat,
  double parkLng,
);
typedef AddFriendCallback = Future<void> Function(String ownerId, String petId);
typedef UnfriendCallback = Future<void> Function(String ownerId, String petId);
typedef CheckedInFormatter = String Function(DateTime since);
typedef LikeChangedCallback = void Function(String parkId, bool isLiked);
typedef ServicesUpdatedCallback = void Function(
  String parkId,
  List<String> newServices,
);
typedef CheckInXpCallback = Future<void> Function();

Future<void> showUsersInParkDialog({
  required BuildContext context,
  required String parkId,
  required String parkName,
  required double parkLatitude,
  required double parkLongitude,

  // dependencies from MapTab:
  required FirestoreService firestoreService,
  required LocationService locationService,
  required List<String> favoritePetIds,
  required ShowEventsCallback onShowEvents,
  required AddEventCallback onAddEvent,
  required AddFriendCallback onAddFriend,
  required UnfriendCallback onUnfriend,
  required CheckedInFormatter checkedInForSince,
  LikeChangedCallback? onLikeChanged,
  ServicesUpdatedCallback? onServicesUpdated,
  CheckInXpCallback? onCheckInXp,
}) async {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) return;

  // Loading dialog
  if (context.mounted) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }

  try {
    final parkRef = FirebaseFirestore.instance.collection('parks').doc(parkId);

    // Single read + create-if-missing
    final parkSnap = await parkRef.get();
    if (!parkSnap.exists) {
      await parkRef.set({
        'id': parkId,
        'name': parkName,
        'latitude': parkLatitude,
        'longitude': parkLongitude,
        'services': <String>[],
        'createdAt': Timestamp.now(),
      }, SetOptions(merge: true));
    }

    // Services (no second get needed – new parks just have empty services)
    List<String> services = [];
    if (parkSnap.exists) {
      final data = parkSnap.data();
      if (data != null && data.containsKey('services')) {
        services = List<String>.from(data['services'] ?? []);
      }
    }

    // Likes
    final likesCol = parkRef.collection('likes');
    bool isLiked = await firestoreService.isParkLiked(parkId);

    // Check-in status
    final activeDocRef =
        parkRef.collection('active_users').doc(currentUser.uid);
    final activeDoc = await activeDocRef.get();
    bool isCheckedIn = activeDoc.exists;

    if (isCheckedIn) {
      final data = activeDoc.data() as Map<String, dynamic>;
      if (data.containsKey('checkedInAt')) {
        final checkedInAt = (data['checkedInAt'] as Timestamp).toDate();
        if (DateTime.now().difference(checkedInAt) >
            const Duration(minutes: 30)) {
          await activeDocRef.delete();
          isCheckedIn = false;
        }
      }
    }

    // Active users + pets
    final usersSnapshot = await parkRef.collection('active_users').get();
    final userIds = usersSnapshot.docs.map((d) => d.id).toList();
    final profiles = await _loadPublicProfiles(userIds.toSet());
    final userList = await _buildPetUserList(
      userIds: userIds,
      usersSnapshot: usersSnapshot,
      profiles: profiles,
      checkedInForSince: checkedInForSince,
    );

    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close spinner

    // Show full dialog as a scaffold
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return _UsersInParkScaffold(
          parkId: parkId,
          parkName: parkName,
          parkLatitude: parkLatitude,
          parkLongitude: parkLongitude,
          services: services,
          isLikedInit: isLiked,
          isCheckedInInit: isCheckedIn,
          likesCol: likesCol,
          currentUser: currentUser,
          favoritePetIds: favoritePetIds,
          userList: userList,
          onShowEvents: onShowEvents,
          onAddEvent: onAddEvent,
          onAddFriend: onAddFriend,
          onUnfriend: onUnfriend,
          onLikeChanged: onLikeChanged,
          onServicesUpdated: onServicesUpdated,
          locationService: locationService,
          firestoreService: firestoreService,
          onCheckInXp: onCheckInXp,
        );
      },
    );
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Error loading active users: $e")),
    );
  }
}

// ---------- Helpers ----------

Future<Map<String, Map<String, dynamic>>> _loadPublicProfiles(
  Set<String> uids,
) async {
  final db = FirebaseFirestore.instance;
  final out = <String, Map<String, dynamic>>{};
  if (uids.isEmpty) return out;

  final ids = uids.toList();
  for (var i = 0; i < ids.length; i += 10) {
    final chunk = ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10);
    final snap = await db
        .collection('public_profiles')
        .where(FieldPath.documentId, whereIn: chunk)
        .get();
    for (final d in snap.docs) {
      final data = d.data();
      out[d.id] = {
        'displayName': (data['displayName'] ?? '') as String,
        'photoUrl': (data['photoUrl'] ?? '') as String,
      };
    }
  }
  return out;
}

Future<List<Map<String, dynamic>>> _buildPetUserList({
  required List<String> userIds,
  required QuerySnapshot usersSnapshot,
  required Map<String, Map<String, dynamic>> profiles,
  required CheckedInFormatter checkedInForSince,
}) async {
  final List<Map<String, dynamic>> userList = [];
  if (userIds.isEmpty) return userList;

  // Index active_users docs by uid for O(1) lookup
  final userDataById = <String, Map<String, dynamic>>{};
  for (final doc in usersSnapshot.docs) {
    userDataById[doc.id] = doc.data() as Map<String, dynamic>;
  }

  for (var i = 0; i < userIds.length; i += 10) {
    final batchIds = userIds.sublist(
      i,
      i + 10 > userIds.length ? userIds.length : i + 10,
    );

    final petsSnapshot = await FirebaseFirestore.instance
        .collection('pets')
        .where('ownerId', whereIn: batchIds)
        .get();

    final Map<String, List<Map<String, dynamic>>> petsByOwner = {};
    for (final petDoc in petsSnapshot.docs) {
      final petData = petDoc.data();
      final ownerId = petData['ownerId'] as String;
      (petsByOwner[ownerId] ??= []).add({
        ...petData,
        'petId': petDoc.id,
      });
    }

    for (final ownerId in batchIds) {
      final data = userDataById[ownerId];
      if (data == null) continue;

      final Timestamp? checkedInAtTs = data['checkedInAt'] as Timestamp?;
      final String checkInTime = checkedInAtTs != null
          ? checkedInForSince(checkedInAtTs.toDate())
          : '';

      final ownerPets = petsByOwner[ownerId] ?? [];
      final prof = profiles[ownerId];
      final ownerName = (prof?['displayName'] as String? ?? '').trim();

      for (final pet in ownerPets) {
        userList.add({
          'petId': pet['petId'],
          'ownerId': ownerId,
          'ownerName': ownerName,
          'petName': pet['name'] ?? 'Unknown Pet',
          'petPhotoUrl': pet['photoUrl'] ?? '',
          'checkInTime': checkInTime,
        });
      }
    }
  }

  return userList;
}

// ---------- Dialog Scaffold ----------

class _UsersInParkScaffold extends StatefulWidget {
  final String parkId;
  final String parkName;
  final double parkLatitude;
  final double parkLongitude;
  final List<String> services;
  final bool isLikedInit;
  final bool isCheckedInInit;
  final CollectionReference likesCol;
  final User currentUser;
  final List<String> favoritePetIds;
  final List<Map<String, dynamic>> userList;
  final ShowEventsCallback onShowEvents;
  final AddEventCallback onAddEvent;
  final AddFriendCallback onAddFriend;
  final UnfriendCallback onUnfriend;
  final LikeChangedCallback? onLikeChanged;
  final ServicesUpdatedCallback? onServicesUpdated;
  final LocationService locationService;
  final FirestoreService firestoreService;
  final CheckInXpCallback? onCheckInXp;

  const _UsersInParkScaffold({
    Key? key,
    required this.parkId,
    required this.parkName,
    required this.parkLatitude,
    required this.parkLongitude,
    required this.services,
    required this.isLikedInit,
    required this.isCheckedInInit,
    required this.likesCol,
    required this.currentUser,
    required this.favoritePetIds,
    required this.userList,
    required this.onShowEvents,
    required this.onAddEvent,
    required this.onAddFriend,
    required this.onUnfriend,
    required this.locationService,
    required this.firestoreService,
    this.onLikeChanged,
    this.onServicesUpdated,
    this.onCheckInXp,
  }) : super(key: key);

  @override
  State<_UsersInParkScaffold> createState() => _UsersInParkScaffoldState();
}

class _UsersInParkScaffoldState extends State<_UsersInParkScaffold> {
  late bool _isLiked;
  late bool _isCheckedIn;
  late List<String> _services;
  late List<String> _favoritePetIds;

  @override
  void initState() {
    super.initState();
    _isLiked = widget.isLikedInit;
    _isCheckedIn = widget.isCheckedInInit;
    _services = List<String>.from(widget.services);
    _favoritePetIds = List<String>.from(widget.favoritePetIds);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF567D46),
        title: Text(widget.parkName),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          StreamBuilder<QuerySnapshot>(
            stream: widget.likesCol.snapshots(),
            builder: (context, snap) {
              final likeCount = snap.hasData ? snap.data!.docs.length : 0;

              return Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 2.0),
                    child: Text(
                      '$likeCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _isLiked ? 'Unlike' : 'Like Park',
                    onPressed: _toggleLike,
                    icon: Icon(
                      _isLiked ? Icons.thumb_up : Icons.thumb_up_outlined,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Services chips + Add Activity
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ..._services.map(
                      (service) => Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: Chip(
                          avatar: Icon(
                            service == "Off-leash Dog Park"
                                ? Icons.pets
                                : service == "Off-leash Trail"
                                    ? Icons.terrain
                                    : service == "Off-leash Beach"
                                        ? Icons.beach_access
                                        : Icons.park,
                            size: 18,
                            color: Colors.green,
                          ),
                          label: Text(
                            service,
                            style: const TextStyle(fontSize: 12),
                          ),
                          backgroundColor: Colors.green[50],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.green.shade800,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                      ),
                      onPressed: _addActivity,
                      child: const Text(
                        "Add Activity",
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Users list
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: widget.userList.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (ctx, i) {
                final petData = widget.userList[i];
                final ownerId = petData['ownerId'] as String? ?? '';
                final petId = petData['petId'] as String? ?? '';
                final petName = petData['petName'] as String? ?? '';
                final petPhoto = petData['petPhotoUrl'] as String? ?? '';
                final checkIn = petData['checkInTime'] as String? ?? '';
                final ownerName =
                    (petData['ownerName'] as String? ?? '').trim();
                final mine = (ownerId == widget.currentUser.uid);

                return ListTile(
                  leading: (petPhoto.isNotEmpty)
                      ? ClipOval(
                          child: Image.network(
                            petPhoto,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.low,
                            cacheWidth: 120,
                          ),
                        )
                      : const CircleAvatar(
                          backgroundColor: Colors.brown,
                          child: Icon(Icons.pets, color: Colors.white),
                        ),
                  title: Text(petName),
                  subtitle: Text(
                    [
                      if (ownerName.isNotEmpty && !mine) ownerName,
                      if (mine) "Your pet",
                      if (checkIn.isNotEmpty) "– Checked in for $checkIn",
                    ].whereType<String>().join(' '),
                  ),
                  trailing: _favoritePetIds.contains(petId)
                      ? IconButton(
                          tooltip: "Remove Favorite",
                          onPressed: () => _unfriend(ownerId, petId),
                          icon: const Icon(
                            Icons.favorite,
                            color: Colors.redAccent,
                          ),
                        )
                      : IconButton(
                          tooltip: "Add Favorite",
                          onPressed: () => _addFriend(ownerId, petId),
                          icon: const Icon(Icons.favorite_border),
                        ),
                );
              },
            ),
          ),

          // Row 1: Check In/Out + Park Chat
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: _DialogBigActionButton(
                    label: _isCheckedIn ? "Check Out" : "Check In",
                    backgroundColor:
                        _isCheckedIn ? Colors.red : const Color(0xFF567D46),
                    onPressed: _toggleCheckInOut,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _DialogBigActionButton(
                    label: "Park Chat",
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChatRoomScreen(parkId: widget.parkId),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // Row 2: Show Events + Add Event
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Row(
              children: [
                Expanded(
                  child: _DialogBigActionButton(
                    label: "Show Events",
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onShowEvents(widget.parkId);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _DialogBigActionButton(
                    label: "Add Event",
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onAddEvent(
                        widget.parkId,
                        widget.parkLatitude,
                        widget.parkLongitude,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleLike() async {
    try {
      if (_isLiked) {
        await widget.firestoreService.unlikePark(widget.parkId);
        await widget.likesCol.doc(widget.currentUser.uid).delete();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Removed park like")),
          );
        }
      } else {
        await widget.firestoreService.likePark(widget.parkId);
        await widget.likesCol.doc(widget.currentUser.uid).set({
          'uid': widget.currentUser.uid,
          'createdAt': FieldValue.serverTimestamp(),
        });
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Park liked!")),
          );
        }
      }
      setState(() {
        _isLiked = !_isLiked;
      });
      widget.onLikeChanged?.call(widget.parkId, _isLiked);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error updating like: $e")),
      );
    }
  }

  Future<void> _addActivity() async {
    const all = <String>[
      "Off-leash Trail",
      "Off-leash Dog Park",
      "Off-leash Beach",
      "On-leash Trail",
    ];

    final options = all.where((s) => !_services.contains(s)).toList();

    if (options.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("All activities are already added."),
        ),
      );
      return;
    }

    final newService = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? selected = options.first;
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: const Text("Add activity"),
              content: DropdownButtonFormField<String>(
                value: selected,
                items: options
                    .map(
                      (s) => DropdownMenuItem(
                        value: s,
                        child: Text(s),
                      ),
                    )
                    .toList(),
                onChanged: (val) => setState(() => selected = val),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(selected),
                  child: const Text("Add"),
                ),
              ],
            );
          },
        );
      },
    );

    if (newService == null || newService.isEmpty) return;

    try {
      await FirebaseFirestore.instance
          .collection('parks')
          .doc(widget.parkId)
          .update({
        'services': FieldValue.arrayUnion([newService]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _services.add(newService);
      });

      widget.onServicesUpdated?.call(
        widget.parkId,
        List<String>.from(_services),
      );

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Added: $newService")),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn’t add activity: $e")),
      );
    }
  }

  Future<void> _toggleCheckInOut() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );

    try {
      final activeDocRef = FirebaseFirestore.instance
          .collection('parks')
          .doc(widget.parkId)
          .collection('active_users')
          .doc(widget.currentUser.uid);

      if (_isCheckedIn) {
        // --- CHECK OUT ---
        await activeDocRef.delete();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Checked out of park")),
          );
        }
      } else {
        // --- CHECK IN ---
        await widget.locationService.uploadUserToActiveUsersTable(
          widget.parkLatitude,
          widget.parkLongitude,
          widget.parkName,
        );

        // ⭐ AWARD XP (if hooked) – only on check-in
        if (widget.onCheckInXp != null) {
          try {
            await widget.onCheckInXp!();
          } catch (e) {
            // best-effort: don't block UX if XP fails
            debugPrint('onCheckInXp failed: $e');
          }
        }

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Checked in to park")),
          );
        }
      }

      setState(() {
        _isCheckedIn = !_isCheckedIn;
      });
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e")),
        );
      }
    } finally {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close spinner
      Navigator.of(context).pop(); // close users-in-park dialog
    }
  }

  Future<void> _addFriend(String ownerId, String petId) async {
    await widget.onAddFriend(ownerId, petId);
    setState(() {
      if (!_favoritePetIds.contains(petId)) {
        _favoritePetIds.add(petId);
      }
    });
  }

  Future<void> _unfriend(String ownerId, String petId) async {
    await widget.onUnfriend(ownerId, petId);
    setState(() {
      _favoritePetIds.remove(petId);
    });
  }
}

class _DialogBigActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final Color? backgroundColor;

  const _DialogBigActionButton({
    Key? key,
    required this.label,
    required this.onPressed,
    this.backgroundColor,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor ?? const Color(0xFF567D46),
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}
