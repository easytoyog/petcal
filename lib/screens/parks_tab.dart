import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:location/location.dart' as loc;
import 'package:pet_calendar/models/park_model.dart';
import 'package:pet_calendar/screens/chatroom_screen.dart';
import 'package:pet_calendar/services/location_service.dart';
import 'package:pet_calendar/services/firestore_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:pet_calendar/widgets/ad_banner.dart';

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
    // ...your existing dialog code...
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
                        .doc(park.id)
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
                          final ref = FirebaseFirestore.instance
                              .collection('parks')
                              .doc(park.id)
                              .collection('active_users')
                              .doc(_currentUserId);

                          if (checkedIn) {
                            await ref.delete();
                          } else {
                            await _checkOutFromAllParks();
                            await ref.set({
                              'checkedInAt': FieldValue.serverTimestamp(),
                            });
                          }
                          _updateActiveUserCount(park.id);
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
