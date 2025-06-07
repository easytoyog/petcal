import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:inthepark/utils/utils.dart';
import 'package:location/location.dart' as loc;
import 'package:inthepark/models/park_model.dart';
import 'package:inthepark/screens/chatroom_screen.dart';
import 'package:inthepark/services/location_service.dart';
import 'package:inthepark/services/firestore_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:inthepark/widgets/ad_banner.dart';
import 'package:inthepark/widgets/active_pets_dialog.dart';
import 'package:intl/intl.dart';

class ParksTab extends StatefulWidget {
  final void Function(String parkId) onShowEvents;
  const ParksTab({Key? key, required this.onShowEvents}) : super(key: key);

  @override
  State<ParksTab> createState() => _ParksTabState();
}

class _ParksTabState extends State<ParksTab> {
  final _locationService =
      LocationService(dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '');
  final String? _currentUserId = FirebaseAuth.instance.currentUser?.uid;
  final FirestoreService _fs = FirestoreService();

  List<Park> _favoriteParks = [];
  Set<String> _favoriteParkIds = {};
  List<Park> _nearbyParks = [];
  bool _hasFetchedNearby = false;
  bool _isSearching = false;
  final Map<String, int> _activeUserCounts = {};

  @override
  void initState() {
    super.initState();
    _fetchFavoriteParks();
  }

  // --- Ensure a park doc exists in Firestore before any action ---
  Future<void> _ensureParkExists(Park park) async {
    final ref = FirebaseFirestore.instance.collection('parks').doc(park.id);
    final snap = await ref.get();
    if (!snap.exists) {
      await ref.set({
        'name': park.name,
        'latitude': park.latitude,
        'longitude': park.longitude,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> _fetchFavoriteParks() async {
    if (_currentUserId == null) return;
    try {
      final likedSnapshot = await FirebaseFirestore.instance
          .collection('owners')
          .doc(_currentUserId)
          .collection('likedParks')
          .get();

      List<Park> parks = [];
      for (var doc in likedSnapshot.docs) {
        final parkDoc = await FirebaseFirestore.instance
            .collection('parks')
            .doc(doc.id)
            .get();
        if (parkDoc.exists) {
          final park = Park.fromFirestore(parkDoc);
          parks.add(park);
          _updateActiveUserCount(park.id);
        }
      }

      if (!mounted) return;
      setState(() {
        _favoriteParks = parks;
        _favoriteParkIds = parks.map((p) => p.id).toSet();
      });

      if (parks.isEmpty) _fetchNearbyParks();
    } catch (e) {
      print("Error fetching favorite parks: $e");
    }
  }

  Future<void> _fetchNearbyParks() async {
    setState(() => _isSearching = true);
    try {
      final locData = await loc.Location().getLocation();
      final parks = await _locationService.findNearbyParks(
        locData.latitude!,
        locData.longitude!,
      );
      for (var park in parks) {
        _updateActiveUserCount(park.id);
      }

      if (!mounted) return;
      setState(() {
        _nearbyParks = parks;
        _hasFetchedNearby = true;
        _isSearching = false;
      });
    } catch (e) {
      print("Error fetching nearby parks: $e");
      if (!mounted) return;
      setState(() => _isSearching = false);
    }
  }

  Future<void> _updateActiveUserCount(String parkId) async {
    final snap = await FirebaseFirestore.instance
        .collection('parks')
        .doc(parkId)
        .collection('active_users')
        .get();
    if (!mounted) return;
    setState(() {
      _activeUserCounts[parkId] = snap.size;
    });
  }

  Future<void> _checkOutFromAllParks() async {
    if (_currentUserId == null) return;
    final parksSnap =
        await FirebaseFirestore.instance.collection('parks').get();
    for (var parkDoc in parksSnap.docs) {
      final ref = FirebaseFirestore.instance
          .collection('parks')
          .doc(parkDoc.id)
          .collection('active_users')
          .doc(_currentUserId);
      final ds = await ref.get();
      if (ds.exists) {
        await ref.delete();
        _updateActiveUserCount(parkDoc.id);
      }
    }
  }

  Future<void> _showActiveUsersDialog(String parkId) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    // Fetch user's favorite pet IDs
    final favPetsSnap = await FirebaseFirestore.instance
        .collection('favorites')
        .doc(currentUser.uid)
        .collection('pets')
        .get();
    final Set<String> favoritePetIds =
        favPetsSnap.docs.map((doc) => doc.id).toSet();

    final activeUsersSnapshot = await FirebaseFirestore.instance
        .collection('parks')
        .doc(parkId)
        .collection('active_users')
        .get();

    List<Map<String, dynamic>> activePets = [];

    for (var userDoc in activeUsersSnapshot.docs) {
      final userId = userDoc.id;
      final petsSnapshot = await FirebaseFirestore.instance
          .collection('pets')
          .where('ownerId', isEqualTo: userId)
          .get();

      for (var petDoc in petsSnapshot.docs) {
        final petData = petDoc.data();
        final checkedInAt = userDoc.data()['checkedInAt'];
        String checkInTime = '';
        if (checkedInAt != null) {
          final dt = checkedInAt.toDate();
          checkInTime = DateFormat.jm().format(dt); // e.g., 2:30 PM
        }
        activePets.add({
          'petName': petData['name'] ?? 'Unknown Pet',
          'petPhotoUrl': petData['photoUrl'] ?? '',
          'ownerId': userId,
          'petId': petDoc.id,
          'checkInTime': checkInTime,
        });
      }
    }

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return ActivePetsDialog(
              pets: activePets,
              favoritePetIds: favoritePetIds,
              currentUserId: currentUser.uid,
              onFavoriteToggle: (ownerId, petId) async {
                if (favoritePetIds.contains(petId)) {
                  // Unfriend and unfavorite
                  await FirebaseFirestore.instance
                      .collection('friends')
                      .doc(currentUser.uid)
                      .collection('userFriends')
                      .doc(ownerId)
                      .delete();
                  await FirebaseFirestore.instance
                      .collection('favorites')
                      .doc(currentUser.uid)
                      .collection('pets')
                      .doc(petId)
                      .delete();
                  setStateDialog(() {
                    favoritePetIds.remove(petId);
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Friend removed.")),
                  );
                } else {
                  // Add friend and favorite
                  DocumentSnapshot ownerDoc = await FirebaseFirestore.instance
                      .collection('owners')
                      .doc(ownerId)
                      .get();
                  String ownerName = "";
                  if (ownerDoc.exists) {
                    final data = ownerDoc.data() as Map<String, dynamic>;
                    ownerName =
                        "${data['firstName'] ?? ''} ${data['lastName'] ?? ''}"
                            .trim();
                  }
                  if (ownerName.isEmpty) {
                    ownerName = ownerId;
                  }
                  await FirebaseFirestore.instance
                      .collection('friends')
                      .doc(currentUser.uid)
                      .collection('userFriends')
                      .doc(ownerId)
                      .set({
                    'friendId': ownerId,
                    'ownerName': ownerName,
                    'addedAt': FieldValue.serverTimestamp(),
                  });
                  await FirebaseFirestore.instance
                      .collection('favorites')
                      .doc(currentUser.uid)
                      .collection('pets')
                      .doc(petId)
                      .set({
                    'petId': petId,
                    'addedAt': FieldValue.serverTimestamp(),
                  });
                  setStateDialog(() {
                    favoritePetIds.add(petId);
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Friend added!")),
                  );
                }
              },
            );
          },
        );
      },
    );
  }

  Widget _buildParkCard(Park park, {required bool isFavorite}) {
    final userCount = _activeUserCounts[park.id] ?? 0;
    final liked = _favoriteParkIds.contains(park.id);
    final bgColor = isFavorite ? Colors.green.shade50 : null;

    return Card(
      color: bgColor,
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: InkWell(
        onTap: () async {
          await _ensureParkExists(park);
          _showActiveUsersDialog(park.id);
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // name + favorite toggle
              Row(
                children: [
                  Expanded(
                    child: Text(
                      park.name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: Icon(liked ? Icons.favorite : Icons.favorite_border),
                    color: liked ? Colors.green : Colors.grey,
                    onPressed: () async {
                      await _ensureParkExists(park);
                      if (liked) {
                        await _fs.unlikePark(park.id);
                        setState(() {
                          _favoriteParkIds.remove(park.id);
                          _favoriteParks.removeWhere((p) => p.id == park.id);
                        });
                      } else {
                        await _fs.likePark(park.id);
                        setState(() {
                          _favoriteParkIds.add(park.id);
                          _favoriteParks.add(park);
                        });
                      }
                    },
                  ),
                ],
              ),

              // active users count
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text("Active Users: $userCount"),
              ),

              // buttons: Chat, Events, CheckIn/Out
              Row(
                children: [
                  ElevatedButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => ChatRoomScreen(parkId: park.id)),
                    ),
                    child:
                        const Text("Park Chat", style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => widget.onShowEvents(park.id),
                    child: const Text("Park Events",
                        style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  FutureBuilder<DocumentSnapshot>(
                    future: FirebaseFirestore.instance
                        .collection('parks')
                        .doc(generateParkID(
                            park.latitude, park.longitude, park.name))
                        .collection('active_users')
                        .doc(_currentUserId)
                        .get(),
                    builder: (ctx, snap) {
                      final checkedIn = snap.hasData && snap.data!.exists;
                      return ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              checkedIn ? Colors.red : Colors.green,
                        ),
                        onPressed: () async {
                          final parkId = generateParkID(
                              park.latitude, park.longitude, park.name);
                          final ref = FirebaseFirestore.instance
                              .collection('parks')
                              .doc(parkId)
                              .collection('active_users')
                              .doc(_currentUserId);

                          if (checkedIn) {
                            await ref.delete();
                            await FirebaseFirestore.instance
                                .collection('parks')
                                .doc(parkId)
                                .update(
                                    {'userCount': FieldValue.increment(-1)});
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text("Checked out of park")),
                            );
                          } else {
                            await _checkOutFromAllParks();
                            await _locationService.uploadUserToActiveUsersTable(
                              park.latitude,
                              park.longitude,
                              park.name,
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text("Checked in to park")),
                            );
                          }
                          _updateActiveUserCount(parkId);
                          setState(() {});
                        },
                        child: Text(
                          checkedIn ? "Check Out" : "Check In",
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(bottom: 70),
            children: [
              // --- Favourite parks ---
              if (_favoriteParks.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text("Favourite Parks",
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                ..._favoriteParks
                    .map((p) => _buildParkCard(p, isFavorite: true))
                    .toList(),
              ],

              // --- Nearby Parks header ---
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Text("Nearby Parks",
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),

              // Find Nearby button below the heading
              if (!_hasFetchedNearby && !_isSearching)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: ElevatedButton(
                    onPressed: _fetchNearbyParks,
                    child: const Text("Find Nearby Parks"),
                  ),
                ),

              if (_isSearching)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: CircularProgressIndicator()),
                ),

              // --- Nearby parks list ---
              ..._nearbyParks
                  .map((p) => _buildParkCard(p, isFavorite: false))
                  .toList(),
            ],
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AdBanner(),
          ),
        ],
      ),
    );
  }
}
