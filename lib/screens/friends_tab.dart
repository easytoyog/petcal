import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:pet_calendar/widgets/ad_banner.dart';

class FriendsTab extends StatefulWidget {
  const FriendsTab({Key? key}) : super(key: key);

  @override
  State<FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends State<FriendsTab> {
  bool _isLoading = true;
  List<String> _friendIds = [];
  // Mapping: friendId -> list of pet data.
  Map<String, List<Map<String, dynamic>>> _friendPets = {};
  // Mapping: friendId -> active park name (if any).
  Map<String, String> _activeParkMapping = {};
  // Mapping: friendId -> owner name.
  Map<String, String> _friendOwnerNames = {};
  // List of favorite pet IDs (from favorites collection).
  List<String> _favoritePetIds = [];

  // Search functionality.
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;

  final String? currentUserId = FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _fetchFriends();
    _fetchActiveParksMapping();
    _fetchFavorites();
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
    setState(() {
      _isLoading = true;
    });
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
      await _fetchFriendPets();
      await _fetchFriendOwnerNames();
    } catch (e) {
      print("Error fetching friends: $e");
    }
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _fetchFriendPets() async {
    Map<String, List<Map<String, dynamic>>> friendPets = {};
    for (String friendId in _friendIds) {
      try {
        QuerySnapshot petSnapshot = await FirebaseFirestore.instance
            .collection('pets')
            .where('ownerId', isEqualTo: friendId)
            .get();
        List<Map<String, dynamic>> petsData = petSnapshot.docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          data['petId'] = doc.id;
          data['ownerId'] = friendId;
          data['name'] = data['name'] ?? 'Unknown Pet';
          data['photoUrl'] =
              data['photoUrl'] ?? 'https://via.placeholder.com/100';
          return data;
        }).toList();
        friendPets[friendId] = petsData;
      } catch (e) {
        print("Error fetching pets for friend $friendId: $e");
      }
    }
    setState(() {
      _friendPets = friendPets;
    });
  }

  Future<void> _fetchFriendOwnerNames() async {
    Map<String, String> names = {};
    try {
      if (_friendIds.isNotEmpty) {
        List<String> idsToQuery = _friendIds.where((id) => id != currentUserId).toList();
        int chunkSize = 10;
        for (int i = 0; i < idsToQuery.length; i += chunkSize) {
          List<String> chunk = idsToQuery.sublist(
              i, min(i + chunkSize, idsToQuery.length));
          QuerySnapshot snapshot = await FirebaseFirestore.instance
              .collection('owners')
              .where(FieldPath.documentId, whereIn: chunk)
              .get();
          for (var doc in snapshot.docs) {
            final data = doc.data() as Map<String, dynamic>;
            String firstName = data['firstName'] ?? data['first_name'] ?? '';
            String lastName = data['lastName'] ?? data['last_name'] ?? '';
            String name = "$firstName $lastName".trim();
            if (name.isEmpty) name = "Unknown";
            names[doc.id] = name;
          }
        }
      }
    } catch (e) {
      print("Error fetching owner names: $e");
    }
    setState(() {
      _friendOwnerNames = names;
    });
  }

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
    setState(() {
      _activeParkMapping = mapping;
    });
  }

  /// Search for pets and owners.
  /// Starts after 2 characters; performs client-side filtering (case-insensitive).
  Future<void> _searchPets(String query) async {
    if (query.length < 2) {
      setState(() {
        _searchResults = [];
      });
      return;
    }
    setState(() {
      _isSearching = true;
    });
    try {
      String lowerQuery = query.toLowerCase();

      // Query 1: Fetch all pets.
      QuerySnapshot petSnapshot =
          await FirebaseFirestore.instance.collection('pets').get();
      List<Map<String, dynamic>> petResults = petSnapshot.docs.map((doc) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        data['petId'] = doc.id;
        return data;
      }).toList();
      // Filter pets by pet name.
      petResults = petResults.where((pet) {
        String petName = (pet['name'] ?? '').toString().toLowerCase();
        return petName.contains(lowerQuery);
      }).toList();

      // Query 2: Fetch all owners.
      QuerySnapshot ownersSnapshot =
          await FirebaseFirestore.instance.collection('owners').get();
      Set<String> matchingOwnerIds = {};
      for (var doc in ownersSnapshot.docs) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        String firstName = data['firstName'] ?? data['first_name'] ?? '';
        String lastName = data['lastName'] ?? data['last_name'] ?? '';
        String fullName = "$firstName $lastName".toLowerCase();
        if (fullName.contains(lowerQuery)) {
          matchingOwnerIds.add(doc.id);
        }
      }
      // For each matching owner, get one pet.
      List<Map<String, dynamic>> ownerPetResults = [];
      for (String ownerId in matchingOwnerIds) {
        QuerySnapshot ownerPetSnapshot = await FirebaseFirestore.instance
            .collection('pets')
            .where('ownerId', isEqualTo: ownerId)
            .limit(1)
            .get();
        if (ownerPetSnapshot.docs.isNotEmpty) {
          Map<String, dynamic> data =
              ownerPetSnapshot.docs.first.data() as Map<String, dynamic>;
          data['petId'] = ownerPetSnapshot.docs.first.id;
          data['ownerId'] = ownerId;
          // Fetch owner's name.
          DocumentSnapshot ownerDoc = await FirebaseFirestore.instance
              .collection('owners')
              .doc(ownerId)
              .get();
          if (ownerDoc.exists) {
            Map<String, dynamic> ownerData = ownerDoc.data() as Map<String, dynamic>;
            String firstName = ownerData['firstName'] ?? ownerData['first_name'] ?? '';
            String lastName = ownerData['lastName'] ?? ownerData['last_name'] ?? '';
            data['ownerName'] = "$firstName $lastName".trim();
          } else {
            data['ownerName'] = "Unknown";
          }
          ownerPetResults.add(data);
        }
      }
      // Combine results and deduplicate by petId.
      List<Map<String, dynamic>> combinedResults = [];
      Set<String> seen = {};
      for (var pet in petResults) {
        if (pet.containsKey('petId')) {
          seen.add(pet['petId']);
          combinedResults.add(pet);
        }
      }
      for (var pet in ownerPetResults) {
        if (pet.containsKey('petId') && !seen.contains(pet['petId'])) {
          combinedResults.add(pet);
        }
      }
      // For any pet without an ownerName, fetch owner's name.
      for (var pet in combinedResults) {
        if (pet['ownerName'] == null ||
            pet['ownerName'].toString().trim().isEmpty) {
          String ownerId = pet['ownerId'];
          DocumentSnapshot ownerDoc = await FirebaseFirestore.instance
              .collection('owners')
              .doc(ownerId)
              .get();
          if (ownerDoc.exists) {
            Map<String, dynamic> ownerData = ownerDoc.data() as Map<String, dynamic>;
            String firstName = ownerData['firstName'] ?? ownerData['first_name'] ?? '';
            String lastName = ownerData['lastName'] ?? ownerData['last_name'] ?? '';
            pet['ownerName'] = "$firstName $lastName".trim();
            if (pet['ownerName'].toString().isEmpty) {
              pet['ownerName'] = "Unknown";
            }
          } else {
            pet['ownerName'] = "Unknown";
          }
        }
      }
      setState(() {
        _searchResults = combinedResults;
      });
    } catch (e) {
      print("Error searching pets: $e");
    }
    setState(() {
      _isSearching = false;
    });
  }

  /// Add a pet's owner as a friend based on a search result.
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

  /// Add friend function: saves friend and marks pet as favorite.
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

  /// Remove friend.
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
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text("Friend removed.")));
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
  final filteredFriendIds = _friendIds.where((id) => id != currentUserId).toList();

  return Scaffold(
    body: Stack(
      children: [
        SafeArea(
          child: Column(
            children: [
              // Search field
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
                        contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 6),
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
                            bool alreadyFriend = _favoritePetIds.contains(petData['petId']);
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundImage: NetworkImage(
                                  petData['photoUrl'] ?? 'https://via.placeholder.com/100',
                                ),
                                radius: 18,
                              ),
                              title: Text(petData['name'] ?? 'Unknown Pet', style: const TextStyle(fontSize: 12)),
                              subtitle: Text("Owner: ${petData['ownerName'] ?? 'Unknown'}", style: const TextStyle(fontSize: 10)),
                              trailing: alreadyFriend
                                  ? const Icon(Icons.favorite, color: Colors.red, size: 18)
                                  : IconButton(
                                      icon: const Icon(Icons.favorite_border, color: Colors.red, size: 18),
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
              // Friend list
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 70), // leave space for banner
                        itemCount: filteredFriendIds.length,
                        itemBuilder: (context, index) {
                          String friendId = filteredFriendIds[index];
                          String ownerName = _friendOwnerNames[friendId] ?? "Unknown";
                          final activePark = _activeParkMapping[friendId];
                          final pets = _friendPets[friendId] ?? [];
                          String petId = "";
                          String petName = "";
                          if (pets.isNotEmpty) {
                            petId = pets[0]['petId'] ?? "";
                            petName = pets[0]['name'] ?? "Unknown Pet";
                          }
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    backgroundImage: NetworkImage(
                                      pets.isNotEmpty
                                          ? pets[0]['photoUrl'] ?? 'https://via.placeholder.com/100'
                                          : 'https://via.placeholder.com/100',
                                    ),
                                    radius: 30,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(petName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                                        Text("Owner: $ownerName", style: const TextStyle(fontSize: 12)),
                                        if (activePark != null)
                                          Text("Active at: $activePark", style: const TextStyle(fontSize: 10, color: Colors.green)),
                                      ],
                                    ),
                                  ),
                                  _favoritePetIds.contains(petId)
                                      ? IconButton(
                                          icon: const Icon(Icons.favorite, color: Colors.red, size: 18),
                                          onPressed: () => _confirmUnfriend(friendId, petId),
                                        )
                                      : ElevatedButton(
                                          onPressed: () => _addFriend(friendId, petId),
                                          child: const Text("Add Friend", style: TextStyle(fontSize: 10)),
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
