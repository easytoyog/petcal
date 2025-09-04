import 'dart:async';
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

  // UI/state
  bool _isSearching = false;
  bool _hasFetchedNearby = false;
  String? _mutatingParkId; // for check-in/out spinner

  // Data
  List<Park> _favoriteParks = [];
  Set<String> _favoriteParkIds = {};
  List<Park> _nearbyParks = [];

  // Cached park meta
  final Map<String, int> _activeUserCounts = {}; // parkId -> count
  final Map<String, List<String>> _parkServices = {}; // parkId -> services[]
  final Set<String> _checkedInParkIds = {}; // where current user is checked-in

  // ---------- Helpers ----------
  String _parkIdOf(Park p) => generateParkID(p.latitude, p.longitude, p.name);

  Future<void> _ensureParkDoc(Park p) async {
    final parkId = _parkIdOf(p);
    final ref = FirebaseFirestore.instance.collection('parks').doc(parkId);
    final snap = await ref.get();
    if (!snap.exists) {
      await ref.set({
        'id': parkId,
        'name': p.name,
        'latitude': p.latitude,
        'longitude': p.longitude,
        'createdAt': FieldValue.serverTimestamp(),
        'userCount': 0,
        'services': [],
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await Future.wait([
      _fetchFavoriteParks(),
      _refreshCheckedInSet(),
    ]);
  }

  // ---------- Favorites ----------
  Future<void> _fetchFavoriteParks() async {
    if (_currentUserId == null) return;
    try {
      final likedSnapshot = await FirebaseFirestore.instance
          .collection('owners')
          .doc(_currentUserId)
          .collection('likedParks')
          .get();

      final parkIds = likedSnapshot.docs.map((d) => d.id).toList();
      _favoriteParkIds = parkIds.toSet();

      // Fetch park docs in chunks
      final List<Park> parks = [];
      for (var i = 0; i < parkIds.length; i += 10) {
        final chunk = parkIds.sublist(i, (i + 10).clamp(0, parkIds.length));
        final qs = await FirebaseFirestore.instance
            .collection('parks')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        parks.addAll(qs.docs.map((d) => Park.fromFirestore(d)));
        _hydrateMetaFromDocs(qs.docs);
      }

      if (!mounted) return;
      setState(() {
        _favoriteParks = parks;
      });

      if (parks.isEmpty) {
        // No favorites — pre-fill nearby for UX
        _fetchNearbyParks();
      }
    } catch (e) {
      // debugPrint("Error fetching favorite parks: $e");
    }
  }

  // ---------- Nearby ----------
  Future<void> _fetchNearbyParks() async {
    setState(() => _isSearching = true);
    try {
      final l = await loc.Location().getLocation();
      final parks = await _locationService.findNearbyParks(
        l.latitude!,
        l.longitude!,
      );

      // Ensure docs exist (safe, idempotent)
      await Future.wait(parks.map(_ensureParkDoc));

      // Hydrate meta for all these parks
      final ids = parks.map(_parkIdOf).toList();
      await _hydrateMetaForIds(ids);

      if (!mounted) return;
      setState(() {
        _nearbyParks = parks;
        _hasFetchedNearby = true;
      });
    } catch (e) {
      // debugPrint("Error fetching nearby parks: $e");
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  // ---------- Meta (userCount + services) ----------
  void _hydrateMetaFromDocs(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    for (final d in docs) {
      final data = d.data();
      _activeUserCounts[d.id] = (data['userCount'] ?? 0) as int;
      final svcs = (data['services'] as List?)?.cast<String>() ?? const [];
      _parkServices[d.id] = svcs;
    }
  }

  Future<void> _hydrateMetaForIds(List<String> parkIds) async {
    for (var i = 0; i < parkIds.length; i += 10) {
      final chunk = parkIds.sublist(i, (i + 10).clamp(0, parkIds.length));
      final qs = await FirebaseFirestore.instance
          .collection('parks')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      _hydrateMetaFromDocs(qs.docs);
    }
    if (mounted) setState(() {});
  }

  // ---------- Checked-in set ----------
  Future<void> _refreshCheckedInSet() async {
    _checkedInParkIds.clear();
    if (_currentUserId == null) return;
    try {
      final snaps = await FirebaseFirestore.instance
          .collectionGroup('active_users')
          .where(FieldPath.documentId, isEqualTo: _currentUserId)
          .get();
      for (final doc in snaps.docs) {
        final parkRef = doc.reference.parent.parent; // parks/{parkId}
        if (parkRef != null) _checkedInParkIds.add(parkRef.id);
      }
      if (mounted) setState(() {});
    } catch (_) {
      // ignore
    }
  }

  // ---------- Transactions: make negatives impossible ----------
  Future<void> _txCheckOut(String parkId) async {
    final db = FirebaseFirestore.instance;
    final parkRef = db.collection('parks').doc(parkId);
    final userRef = parkRef.collection('active_users').doc(_currentUserId);

    await db.runTransaction((tx) async {
      final userSnap = await tx.get(userRef);
      if (!userSnap.exists) return; // nothing to do

      final parkSnap = await tx.get(parkRef);
      final cur = (parkSnap.data()?['userCount'] ?? 0) as int;

      tx.delete(userRef);
      final next = cur > 0 ? cur - 1 : 0; // floor at 0
      tx.update(parkRef, {'userCount': next});
    });
  }

  Future<void> _txCheckIn(String parkId) async {
    final db = FirebaseFirestore.instance;
    final parkRef = db.collection('parks').doc(parkId);
    final userRef = parkRef.collection('active_users').doc(_currentUserId);

    await db.runTransaction((tx) async {
      final userSnap = await tx.get(userRef);
      if (userSnap.exists) return; // already checked in

      final parkSnap = await tx.get(parkRef);
      final cur = (parkSnap.data()?['userCount'] ?? 0) as int;

      tx.set(userRef, {'checkedInAt': FieldValue.serverTimestamp()});
      tx.update(parkRef, {'userCount': cur + 1});
    });
  }

  Future<void> _checkOutFromAllParks() async {
    if (_currentUserId == null) return;
    try {
      final snaps = await FirebaseFirestore.instance
          .collectionGroup('active_users')
          .where(FieldPath.documentId, isEqualTo: _currentUserId)
          .get();

      for (final doc in snaps.docs) {
        final parkRef = doc.reference.parent.parent; // parks/{parkId}
        if (parkRef == null) continue;

        await FirebaseFirestore.instance.runTransaction((tx) async {
          final userSnap = await tx.get(doc.reference);
          if (!userSnap.exists) return;

          final parkSnap = await tx.get(parkRef);
          final cur = (parkSnap.data()?['userCount'] ?? 0) as int;

          tx.delete(doc.reference);
          tx.update(parkRef, {'userCount': cur > 0 ? cur - 1 : 0});
        });

        _checkedInParkIds.remove(parkRef.id);
        _activeUserCounts.update(
          parkRef.id,
          (v) => (v - 1).clamp(0, 1 << 30),
          ifAbsent: () => 0,
        );
      }
    } catch (_) {
      // ignore
    }
  }

  // ---------- Active pets dialog (optimized) ----------
  Future<void> _showActiveUsersDialog(String parkId) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    // Load favorites once
    final favPetsSnap = await FirebaseFirestore.instance
        .collection('favorites')
        .doc(currentUser.uid)
        .collection('pets')
        .get();
    final favoritePetIds = favPetsSnap.docs.map((d) => d.id).toSet();

    // Who's active?
    final activeUsersSnapshot = await FirebaseFirestore.instance
        .collection('parks')
        .doc(parkId)
        .collection('active_users')
        .get();
    final userIds = activeUsersSnapshot.docs.map((d) => d.id).toList();

    // Load all pets for these owners in chunks of 10
    final List<Map<String, dynamic>> activePets = [];
    for (var i = 0; i < userIds.length; i += 10) {
      final chunk = userIds.sublist(i, (i + 10).clamp(0, userIds.length));
      final petsSnapshot = await FirebaseFirestore.instance
          .collection('pets')
          .where('ownerId', whereIn: chunk)
          .get();

      // index check-in times by owner
      final checkInByOwner = <String, String>{};
      for (final u in activeUsersSnapshot.docs) {
        final ts = (u.data()['checkedInAt']);
        String timeStr = '';
        if (ts != null) {
          final dt = (ts as Timestamp).toDate();
          timeStr = DateFormat.jm().format(dt);
        }
        checkInByOwner[u.id] = timeStr;
      }

      for (final petDoc in petsSnapshot.docs) {
        final pet = petDoc.data();
        final ownerId = pet['ownerId'] as String? ?? '';
        activePets.add({
          'petName': pet['name'] ?? 'Unknown Pet',
          'petPhotoUrl': pet['photoUrl'] ?? '',
          'ownerId': ownerId,
          'petId': petDoc.id,
          'checkInTime': checkInByOwner[ownerId] ?? '',
        });
      }
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) {
        return ActivePetsDialog(
          pets: activePets,
          favoritePetIds: favoritePetIds,
          currentUserId: currentUser.uid,
          onFavoriteToggle: (ownerId, petId) async {
            if (favoritePetIds.contains(petId)) {
              // Unfriend/unfavorite
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
              favoritePetIds.remove(petId);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Friend removed.")),
                );
              }
            } else {
              // Friend/favorite
              final ownerDoc = await FirebaseFirestore.instance
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
              if (ownerName.isEmpty) ownerName = ownerId;

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
              favoritePetIds.add(petId);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Friend added!")),
                );
              }
            }
          },
        );
      },
    );
  }

  // ---------- Like / unlike ----------
  Future<void> _toggleLike(Park park) async {
    final parkId = _parkIdOf(park);
    await _ensureParkDoc(park);
    if (_favoriteParkIds.contains(parkId)) {
      await _fs.unlikePark(parkId);
      _favoriteParkIds.remove(parkId);
      _favoriteParks.removeWhere((p) => _parkIdOf(p) == parkId);
    } else {
      await _fs.likePark(parkId);
      _favoriteParkIds.add(parkId);
      if (!_favoriteParks.any((p) => _parkIdOf(p) == parkId)) {
        _favoriteParks.add(park);
      }
    }
    if (mounted) setState(() {});
  }

  // ---------- Check-in / out (uses transactions) ----------
  Future<void> _toggleCheckIn(Park park) async {
    if (_currentUserId == null) return;
    final parkId = _parkIdOf(park);
    setState(() => _mutatingParkId = parkId);

    try {
      final isCheckedIn = _checkedInParkIds.contains(parkId);

      if (isCheckedIn) {
        // Out (transactional)
        await _txCheckOut(parkId);
        _checkedInParkIds.remove(parkId);
        _activeUserCounts.update(
          parkId,
          (v) => (v - 1).clamp(0, 1 << 30),
          ifAbsent: () => 0,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Checked out of park")),
          );
        }
      } else {
        // First clear any other check-ins (transactional per park)
        await _checkOutFromAllParks();

        // In (transactional)
        await _txCheckIn(parkId);

        _checkedInParkIds
          ..clear()
          ..add(parkId);
        _activeUserCounts.update(
          parkId,
          (v) => v + 1,
          ifAbsent: () => 1,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Checked in to park")),
          );
        }
      }
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _mutatingParkId = null);
    }
  }

  // ---------- UI ----------
  Widget _buildParkCard(Park park, {required bool isFavorite}) {
    final parkId = _parkIdOf(park);
    final liked = _favoriteParkIds.contains(parkId);
    final userCount = _activeUserCounts[parkId] ?? 0;
    final services = _parkServices[parkId] ?? park.services ?? const <String>[];
    final isCheckedIn = _checkedInParkIds.contains(parkId);
    final isBusy = _mutatingParkId == parkId;

    return Card(
      color: isFavorite ? Colors.green.shade50 : null,
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: InkWell(
        onTap: () async {
          await _ensureParkDoc(park);
          _showActiveUsersDialog(parkId);
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title + like toggle
              Row(
                children: [
                  Expanded(
                    child: Text(
                      park.name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: Icon(liked ? Icons.favorite : Icons.favorite_border),
                    color: liked ? Colors.green : Colors.grey,
                    onPressed: () => _toggleLike(park),
                  ),
                ],
              ),

              // Services chips
              if (services.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: -6,
                  children: services.map((s) {
                    final icon = s == "Off-leash Dog Park"
                        ? Icons.pets
                        : s == "Off-leash Trail"
                            ? Icons.terrain
                            : s == "Off-leash Beach"
                                ? Icons.beach_access
                                : Icons.park;
                    return Chip(
                      avatar: Icon(icon, size: 16, color: Colors.green),
                      label: Text(s, style: const TextStyle(fontSize: 12)),
                      backgroundColor: Colors.green[50],
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity:
                          const VisualDensity(horizontal: -4, vertical: -4),
                    );
                  }).toList(),
                ),
              ],

              const SizedBox(height: 6),

              // Active users count
              Text("Active Users: $userCount"),

              const SizedBox(height: 8),

              // Actions
              Row(
                children: [
                  ElevatedButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatRoomScreen(parkId: parkId),
                      ),
                    ),
                    child:
                        const Text("Park Chat", style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => widget.onShowEvents(parkId),
                    child: const Text("Park Events",
                        style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isCheckedIn ? Colors.red : Colors.green,
                    ),
                    onPressed: isBusy ? null : () => _toggleCheckIn(park),
                    child: isBusy
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
                            isCheckedIn ? "Check Out" : "Check In",
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(bottom: 70),
            children: [
              // Favorites
              if (_favoriteParks.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text("Favourite Parks",
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                ..._favoriteParks
                    .map((p) => _buildParkCard(p, isFavorite: true)),
              ],

              // Nearby header
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Text("Nearby Parks",
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),

              // CTA to fetch nearby
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

              // Nearby list
              ..._nearbyParks.map((p) => _buildParkCard(p, isFavorite: false)),
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
