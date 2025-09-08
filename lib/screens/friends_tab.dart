import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:inthepark/widgets/ad_banner.dart';

class FriendsTab extends StatefulWidget {
  const FriendsTab({Key? key}) : super(key: key);

  @override
  State<FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends State<FriendsTab> {
  bool _isLoading = true;
  List<String> _friendIds = [];
  Map<String, List<Map<String, dynamic>>> _friendPets = {};
  Map<String, String> _activeParkMapping = {};
  Map<String, String> _friendOwnerNames = {};
  List<String> _favoritePetIds = [];

  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;

  final String? currentUserId = FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _fetchAllData();
  }

  Future<void> _fetchAllData() async {
    setState(() => _isLoading = true);
    await Future.wait([
      _fetchFriends(),
      _fetchActiveParksMapping(),
      _fetchFavorites(),
    ]);
    setState(() => _isLoading = false);
  }

  Future<void> _fetchFavorites() async {
    if (currentUserId == null) return;
    try {
      QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collection('favorites')
          .doc(currentUserId)
          .collection('pets')
          .get();
      List<String> favIds = snapshot.docs.map((doc) => doc.id).toList();
      setState(() {
        _favoritePetIds = favIds;
      });
    } catch (e) {
      print("Error fetching favorites: $e");
    }
  }

  Future<void> _fetchFriends() async {
    if (currentUserId == null) return;
    try {
      QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collection('friends')
          .doc(currentUserId)
          .collection('userFriends')
          .get();
      List<String> friendIds = snapshot.docs.map((doc) => doc.id).toList();
      setState(() {
        _friendIds = friendIds;
      });
      await Future.wait([
        _fetchFriendPetsBatch(friendIds),
        _fetchFriendOwnerNamesBatch(friendIds),
      ]);
    } catch (e) {
      print("Error fetching friends: $e");
    }
  }

  // Batch fetch all pets for all friends using whereIn (max 10 per batch)
  Future<void> _fetchFriendPetsBatch(List<String> friendIds) async {
    Map<String, List<Map<String, dynamic>>> friendPets = {};
    if (friendIds.isEmpty) {
      setState(() => _friendPets = {});
      return;
    }
    int chunkSize = 10;
    for (int i = 0; i < friendIds.length; i += chunkSize) {
      List<String> batch =
          friendIds.sublist(i, min(i + chunkSize, friendIds.length));
      QuerySnapshot petSnapshot = await FirebaseFirestore.instance
          .collection('pets')
          .where('ownerId', whereIn: batch)
          .get();
      for (var doc in petSnapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        String ownerId = data['ownerId'];
        data['petId'] = doc.id;
        data['name'] = data['name'] ?? 'Unknown Pet';
        data['photoUrl'] =
            data['photoUrl'] ?? 'https://via.placeholder.com/100';
        friendPets.putIfAbsent(ownerId, () => []).add(data);
      }
    }
    if (!mounted) return;
    setState(() {
      _friendPets = friendPets;
    });
  }

  // Batch fetch all owner names for friends using whereIn (max 10 per batch)
  Future<void> _fetchFriendOwnerNamesBatch(List<String> friendIds) async {
    Map<String, String> names = {};
    if (friendIds.isEmpty) {
      setState(() => _friendOwnerNames = {});
      return;
    }
    final idsToQuery = friendIds.where((id) => id != currentUserId).toList();
    const chunkSize = 10;
    for (int i = 0; i < idsToQuery.length; i += chunkSize) {
      final chunk = idsToQuery.sublist(i, min(i + chunkSize, idsToQuery.length));
      final snapshot = await FirebaseFirestore.instance
          .collection('public_profiles') // 👈 was 'owners'
          .where(FieldPath.documentId, whereIn: chunk)
          .get();

      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final dn = (data['displayName'] ?? '').toString().trim();
        names[doc.id] = dn.isEmpty ? 'Unknown' : dn;
      }
    }
    if (!mounted) return;
    setState(() => _friendOwnerNames = names);
  }


  // No major optimization here, but you could cache park names if needed
  Future<void> _fetchActiveParksMapping() async {
    Map<String, String> mapping = {};
    try {
      QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collectionGroup('active_users')
          .get();
      for (var doc in snapshot.docs) {
        String userId = doc.id;
        DocumentReference? parkRef = doc.reference.parent.parent;
        if (parkRef != null) {
          DocumentSnapshot parkSnapshot = await parkRef.get();
          if (parkSnapshot.exists) {
            Map<String, dynamic> parkData =
                parkSnapshot.data() as Map<String, dynamic>;
            String parkName = parkData['name'] ?? "Unknown Park";
            mapping[userId] = parkName;
          }
        }
      }
    } catch (e) {
      print("Error fetching active parks mapping: $e");
    }
    if (!mounted) return;
    setState(() {
      _activeParkMapping = mapping;
    });
  }

  Future<void> _searchPets(String query) async {
    if (query.length < 2) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() => _isSearching = true);

    try {
      final lowerQuery = query.toLowerCase();

      // 1) Read pets (now allowed by rules) and filter by name client-side
      final petSnapshot = await FirebaseFirestore.instance
          .collection('pets')
          .get();

      final pets = petSnapshot.docs.map((d) {
        final m = d.data() as Map<String, dynamic>;
        m['petId'] = d.id;
        return m;
      }).where((m) {
        final name = (m['name'] ?? '').toString().toLowerCase();
        return name.contains(lowerQuery);
      }).toList();

      // 2) Also search owner displayName in public_profiles to find their pets
      final profilesSnap = await FirebaseFirestore.instance
          .collection('public_profiles')
          .get();

      final matchingOwnerIds = <String>{};
      for (final d in profilesSnap.docs) {
        final dn = (d.data()['displayName'] ?? '').toString().toLowerCase();
        if (dn.contains(lowerQuery)) matchingOwnerIds.add(d.id);
      }

      final ownerPetResults = <Map<String, dynamic>>[];
      final ownerList = matchingOwnerIds.toList();
      for (int i = 0; i < ownerList.length; i += 10) {
        final chunk = ownerList.sublist(i, min(i + 10, ownerList.length));
        final ownerPetsSnap = await FirebaseFirestore.instance
            .collection('pets')
            .where('ownerId', whereIn: chunk)
            .limit(1)
            .get();

        for (final d in ownerPetsSnap.docs) {
          final m = d.data() as Map<String, dynamic>;
          m['petId'] = d.id;
          ownerPetResults.add(m);
        }
      }

      // 3) Merge and attach owner displayName from public_profiles
      final combined = <Map<String, dynamic>>[];
      final seen = <String>{};
      final ownerNameCache = <String, String>{};

      Future<String> ownerName(String ownerId) async {
        if (ownerNameCache.containsKey(ownerId)) return ownerNameCache[ownerId]!;
        final doc = await FirebaseFirestore.instance
            .collection('public_profiles')
            .doc(ownerId)
            .get();
        final dn = ((doc.data()?['displayName']) ?? 'Unknown').toString();
        ownerNameCache[ownerId] = dn;
        return dn;
      }

      for (final p in [...pets, ...ownerPetResults]) {
        final id = p['petId'] as String?;
        if (id == null || seen.contains(id)) continue;
        seen.add(id);
        final ownerId = (p['ownerId'] ?? '').toString();
        p['ownerName'] = ownerId.isEmpty ? 'Unknown' : await ownerName(ownerId);
        p['photoUrl'] = p['photoUrl'] ?? 'https://via.placeholder.com/100';
        combined.add(p);
      }

      setState(() => _searchResults = combined);
    } catch (e) {
      print("Error searching pets: $e");
    }

    setState(() => _isSearching = false);
  }


  Future<void> _addFriendFromSearch(Map<String, dynamic> petData) async {
    String friendId = petData['ownerId'];
    String ownerName = petData['ownerName'] ?? "Unknown";
    if (currentUserId == null) return;
    try {
      DocumentSnapshot friendDoc = await FirebaseFirestore.instance
          .collection('friends')
          .doc(currentUserId)
          .collection('userFriends')
          .doc(friendId)
          .get();
      if (friendDoc.exists) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Already friends.")));
        return;
      }
      await _addFriend(friendId, petData['petId']);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Friend added.")));
      await _fetchFavorites();
      await _fetchFriends();
    } catch (e) {
      print("Error adding friend from search: $e");
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Error adding friend.")));
    }
  }

  Future<void> _addFriend(String friendUserId, String petId) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    try {
      DocumentSnapshot ownerDoc = await FirebaseFirestore.instance
          .collection('owners')
          .doc(friendUserId)
          .get();
      String ownerName = "";
      if (ownerDoc.exists) {
        final data = ownerDoc.data() as Map<String, dynamic>;
        String firstName = data['firstName'] ?? data['first_name'] ?? '';
        String lastName = data['lastName'] ?? data['last_name'] ?? '';
        ownerName = "$firstName $lastName".trim();
      }
      if (ownerName.isEmpty) {
        ownerName = friendUserId;
      }
      await FirebaseFirestore.instance
          .collection('friends')
          .doc(currentUser.uid)
          .collection('userFriends')
          .doc(friendUserId)
          .set({
        'friendId': friendUserId,
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
    } catch (e) {
      print("Error adding friend: $e");
      rethrow;
    }
  }

  Future<void> _unfriend(String friendUserId, String petId) async {
    if (currentUserId == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('friends')
          .doc(currentUserId)
          .collection('userFriends')
          .doc(friendUserId)
          .delete();
      await FirebaseFirestore.instance
          .collection('favorites')
          .doc(currentUserId)
          .collection('pets')
          .doc(petId)
          .delete();
    } catch (e) {
      print("Error unfriending: $e");
      rethrow;
    }
  }

  void _confirmUnfriend(String friendUserId, String petId) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text("Unfriend"),
          content: const Text("Are you sure you want to unfriend?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("No"),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _unfriend(friendUserId, petId);
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Friend removed.")));
                _fetchFriends();
              },
              child: const Text("Yes"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredFriendIds =
        _friendIds.where((id) => id != currentUserId).toList();

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(6.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _searchController,
                        decoration: const InputDecoration(
                          hintText: "Search pet to add as friend",
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.search),
                          contentPadding:
                              EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                        ),
                        onChanged: (value) {
                          if (value.length >= 2) {
                            _searchPets(value);
                          } else {
                            setState(() {
                              _searchResults = [];
                            });
                          }
                        },
                      ),
                      if (_isSearching)
                        const LinearProgressIndicator()
                      else if (_searchResults.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Column(
                            children: _searchResults.map((petData) {
                              bool alreadyFriend =
                                  _favoritePetIds.contains(petData['petId']);
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundImage: NetworkImage(
                                    petData['photoUrl'] ??
                                        'https://via.placeholder.com/100',
                                  ),
                                  radius: 18,
                                ),
                                title: Text(petData['name'] ?? 'Unknown Pet',
                                    style: const TextStyle(fontSize: 12)),
                                subtitle: Text(
                                    "Owner: ${petData['ownerName'] ?? 'Unknown'}",
                                    style: const TextStyle(fontSize: 10)),
                                trailing: alreadyFriend
                                    ? const Icon(Icons.favorite,
                                        color: Colors.red, size: 18)
                                    : IconButton(
                                        icon: const Icon(Icons.favorite_border,
                                            color: Colors.red, size: 18),
                                        onPressed: () {
                                          _addFriendFromSearch(petData);
                                          setState(() {
                                            _searchResults = [];
                                            _searchController.clear();
                                          });
                                        },
                                      ),
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 70),
                          itemCount: filteredFriendIds.length,
                          itemBuilder: (context, index) {
                            String friendId = filteredFriendIds[index];
                            String ownerName =
                                _friendOwnerNames[friendId] ?? "Unknown";
                            final activePark = _activeParkMapping[friendId];
                            final pets = _friendPets[friendId] ?? [];
                            String petId = "";
                            String petName = "";
                            if (pets.isNotEmpty) {
                              petId = pets[0]['petId'] ?? "";
                              petName = pets[0]['name'] ?? "Unknown Pet";
                            }
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                  vertical: 2, horizontal: 4),
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundImage: NetworkImage(
                                        pets.isNotEmpty
                                            ? pets[0]['photoUrl'] ??
                                                'https://via.placeholder.com/100'
                                            : 'https://via.placeholder.com/100',
                                      ),
                                      radius: 30,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(petName,
                                              style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold)),
                                          Text("Owner: $ownerName",
                                              style: const TextStyle(
                                                  fontSize: 12)),
                                          if (activePark != null)
                                            Text("Active at: $activePark",
                                                style: const TextStyle(
                                                    fontSize: 10,
                                                    color: Colors.green)),
                                        ],
                                      ),
                                    ),
                                    _favoritePetIds.contains(petId)
                                        ? IconButton(
                                            icon: const Icon(Icons.favorite,
                                                color: Colors.red, size: 18),
                                            onPressed: () => _confirmUnfriend(
                                                friendId, petId),
                                          )
                                        : ElevatedButton(
                                            onPressed: () =>
                                                _addFriend(friendId, petId),
                                            child: const Text("Add Friend",
                                                style: TextStyle(fontSize: 10)),
                                          ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          const Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AdBanner(),
          ),
        ],
      ),
    );
  }
}
