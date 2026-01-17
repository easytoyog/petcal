import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:inthepark/widgets/ad_banner.dart';

// ✅ ADD: import your DM screen
import 'package:inthepark/screens/dm_chat_screen.dart';

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

  // friend level info: friendId -> { 'level': int, 'description': String }
  Map<String, Map<String, dynamic>> _friendLevels = {};

  List<String> _favoritePetIds = [];

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;
  int _searchEpoch = 0;

  final String? currentUserId = FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _fetchAllData();
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchAllData() async {
    setState(() => _isLoading = true);
    await Future.wait([
      _fetchFriends(),
      _fetchActiveParksMapping(),
      _fetchFavorites(),
    ]);
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _fetchFavorites() async {
    if (currentUserId == null) return;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('favorites')
          .doc(currentUserId)
          .collection('pets')
          .get();
      final favIds = snapshot.docs.map((doc) => doc.id).toList();
      if (!mounted) return;
      setState(() => _favoritePetIds = favIds);
    } catch (_) {}
  }

  Future<void> _fetchFriends() async {
    if (currentUserId == null) return;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('friends')
          .doc(currentUserId)
          .collection('userFriends')
          .get();

      final friendIds = snapshot.docs.map((doc) => doc.id).toList();
      if (!mounted) return;
      setState(() => _friendIds = friendIds);

      await Future.wait([
        _fetchFriendPetsBatch(friendIds),
        _fetchFriendOwnerNamesBatch(friendIds),
        _fetchFriendLevelsBatch(friendIds),
      ]);
    } catch (_) {}
  }

  // Batch fetch pets for all friends using whereIn (max 10)
  Future<void> _fetchFriendPetsBatch(List<String> friendIds) async {
    final friendPets = <String, List<Map<String, dynamic>>>{};

    if (friendIds.isEmpty) {
      if (!mounted) return;
      setState(() => _friendPets = {});
      return;
    }

    const chunkSize = 10;
    for (int i = 0; i < friendIds.length; i += chunkSize) {
      final batch = friendIds.sublist(i, min(i + chunkSize, friendIds.length));

      final petSnapshot = await FirebaseFirestore.instance
          .collection('pets')
          .where('ownerId', whereIn: batch)
          .get();

      for (var doc in petSnapshot.docs) {
        final data = doc.data();
        final ownerId = (data['ownerId'] ?? '').toString();
        data['petId'] = doc.id;
        data['name'] = data['name'] ?? 'Unknown Pet';
        data['photoUrl'] =
            data['photoUrl'] ?? 'https://via.placeholder.com/100';
        friendPets.putIfAbsent(ownerId, () => []).add(data);
      }
    }

    if (!mounted) return;
    setState(() => _friendPets = friendPets);
  }

  // Batch fetch owner display names from public_profiles using whereIn (max 10)
  Future<void> _fetchFriendOwnerNamesBatch(List<String> friendIds) async {
    final names = <String, String>{};

    if (friendIds.isEmpty) {
      if (!mounted) return;
      setState(() => _friendOwnerNames = {});
      return;
    }

    final idsToQuery = friendIds.where((id) => id != currentUserId).toList();
    if (idsToQuery.isEmpty) {
      if (!mounted) return;
      setState(() => _friendOwnerNames = {});
      return;
    }

    const chunkSize = 10;
    for (int i = 0; i < idsToQuery.length; i += chunkSize) {
      final chunk =
          idsToQuery.sublist(i, min(i + chunkSize, idsToQuery.length));

      final snapshot = await FirebaseFirestore.instance
          .collection('public_profiles')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final dn = (data['displayName'] ?? '').toString().trim();
        names[doc.id] = dn.isEmpty ? 'Unknown' : dn;
      }
    }

    if (!mounted) return;
    setState(() => _friendOwnerNames = names);
  }

  // Fetch friend levels from owners/{uid}/stats/level
  Future<void> _fetchFriendLevelsBatch(List<String> friendIds) async {
    final levels = <String, Map<String, dynamic>>{};

    if (friendIds.isEmpty) {
      if (!mounted) return;
      setState(() => _friendLevels = {});
      return;
    }

    final idsToQuery = friendIds.where((id) => id != currentUserId).toList();
    if (idsToQuery.isEmpty) {
      if (!mounted) return;
      setState(() => _friendLevels = {});
      return;
    }

    try {
      for (final uid in idsToQuery) {
        final levelDoc = await FirebaseFirestore.instance
            .collection('owners')
            .doc(uid)
            .collection('stats')
            .doc('level')
            .get();

        if (!levelDoc.exists) continue;

        final data = levelDoc.data() as Map<String, dynamic>? ?? {};
        final rawLevel = data['level'];

        int level;
        if (rawLevel is int) {
          level = rawLevel;
        } else if (rawLevel is num) {
          level = rawLevel.toInt();
        } else {
          level = 1;
        }

        levels[uid] = {
          'level': level,
          'description': _levelDescription(level),
        };
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() => _friendLevels = levels);
  }

  String _levelDescription(int level) {
    if (level <= 1) return "New Pup";
    if (level <= 3) return "Neighborhood Explorer";
    if (level <= 5) return "Trail Trooper";
    if (level <= 8) return "Park Pro";
    if (level <= 12) return "Pack Leader";
    return "Legendary Walker";
  }

  // Map active users to park names
  Future<void> _fetchActiveParksMapping() async {
    final mapping = <String, String>{};
    try {
      final snapshot = await FirebaseFirestore.instance
          .collectionGroup('active_users')
          .get();

      for (var doc in snapshot.docs) {
        final userId = doc.id;
        final parkRef = doc.reference.parent.parent;
        if (parkRef != null) {
          final parkSnapshot = await parkRef.get();
          if (parkSnapshot.exists) {
            final parkData = parkSnapshot.data() as Map<String, dynamic>;
            final parkName = (parkData['name'] ?? 'Unknown Park').toString();
            mapping[userId] = parkName;
          }
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _activeParkMapping = mapping);
  }

  void _closeSearchDropdown() {
    setState(() {
      _searchEpoch++;
      _searchResults = [];
      _isSearching = false;
      _searchController.clear();
    });
    _searchFocusNode.unfocus();
  }

  Future<void> _searchPets(String query) async {
    if (query.length < 2) {
      setState(() => _searchResults = []);
      return;
    }

    final epoch = ++_searchEpoch;
    setState(() => _isSearching = true);

    try {
      final lowerQuery = query.toLowerCase();

      // 1) Search pets by name client-side
      final petSnapshot =
          await FirebaseFirestore.instance.collection('pets').get();

      final pets = petSnapshot.docs.map((d) {
        final m = d.data();
        m['petId'] = d.id;
        return m;
      }).where((m) {
        final name = (m['name'] ?? '').toString().toLowerCase();
        return name.contains(lowerQuery);
      }).toList();

      // 2) Search owners by public_profiles displayName client-side
      final profilesSnap =
          await FirebaseFirestore.instance.collection('public_profiles').get();

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
          final m = d.data();
          m['petId'] = d.id;
          ownerPetResults.add(m);
        }
      }

      // 3) Merge and attach ownerName
      final combined = <Map<String, dynamic>>[];
      final seen = <String>{};
      final ownerNameCache = <String, String>{};

      Future<String> ownerName(String ownerId) async {
        if (ownerNameCache.containsKey(ownerId))
          return ownerNameCache[ownerId]!;
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

      if (!mounted || epoch != _searchEpoch) return;
      setState(() => _searchResults = combined);
    } catch (_) {
      if (!mounted || epoch != _searchEpoch) return;
    }

    if (!mounted || epoch != _searchEpoch) return;
    setState(() => _isSearching = false);
  }

  Future<void> _addFriendFromSearch(Map<String, dynamic> petData) async {
    final friendId = (petData['ownerId'] ?? '').toString();
    if (currentUserId == null || friendId.isEmpty) return;

    try {
      final friendDoc = await FirebaseFirestore.instance
          .collection('friends')
          .doc(currentUserId)
          .collection('userFriends')
          .doc(friendId)
          .get();

      if (friendDoc.exists) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Already friends.")));
        return;
      }

      await _addFriend(friendId, (petData['petId'] ?? '').toString());

      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Friend added.")));

      _closeSearchDropdown();
      await Future.wait([_fetchFavorites(), _fetchFriends()]);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Error adding friend.")));
    }
  }

  Future<void> _addFriend(String friendUserId, String petId) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      String ownerName = '';
      final profileDoc = await FirebaseFirestore.instance
          .collection('public_profiles')
          .doc(friendUserId)
          .get();

      if (profileDoc.exists) {
        final data = profileDoc.data() as Map<String, dynamic>;
        ownerName = (data['displayName'] ?? '').toString().trim();
      }
      if (ownerName.isEmpty) ownerName = friendUserId;

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

      if (petId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('favorites')
            .doc(currentUser.uid)
            .collection('pets')
            .doc(petId)
            .set({
          'petId': petId,
          'addedAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (_) {
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

      if (petId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('favorites')
            .doc(currentUserId)
            .collection('pets')
            .doc(petId)
            .delete();
      }
    } catch (_) {
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
                  const SnackBar(content: Text("Friend removed.")),
                );
                _fetchFriends();
              },
              child: const Text("Yes"),
            ),
          ],
        );
      },
    );
  }

  // ✅ NEW: open DM chat
  void _openDm(String friendId, String ownerName) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DmChatScreen(
          otherUserId: friendId,
          otherDisplayName: ownerName,
        ),
      ),
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
                        focusNode: _searchFocusNode,
                        decoration: InputDecoration(
                          hintText: "Search pet to add as friend",
                          prefixIcon: const Icon(Icons.search),
                          filled: true,
                          fillColor: Colors.white,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              vertical: 10, horizontal: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(
                              color: Colors.black.withOpacity(0.15),
                              width: 1.2,
                            ),
                          ),
                          focusedBorder: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(14)),
                            borderSide: BorderSide(
                              color: Colors.tealAccent,
                              width: 2,
                            ),
                          ),
                        ),
                        onChanged: (value) {
                          if (value.length >= 2) {
                            _searchPets(value);
                          } else {
                            setState(() => _searchResults = []);
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
                              final alreadyFriend = _favoritePetIds
                                  .contains(petData['petId'] as String? ?? "");
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundImage: NetworkImage(
                                    (petData['photoUrl'] ??
                                            'https://via.placeholder.com/100')
                                        .toString(),
                                  ),
                                  radius: 18,
                                ),
                                title: Text(
                                  (petData['name'] ?? 'Unknown Pet').toString(),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                subtitle: Text(
                                  "Owner: ${(petData['ownerName'] ?? 'Unknown').toString()}",
                                  style: const TextStyle(fontSize: 10),
                                ),
                                trailing: alreadyFriend
                                    ? const Icon(Icons.favorite,
                                        color: Colors.red, size: 18)
                                    : IconButton(
                                        icon: const Icon(Icons.favorite_border,
                                            color: Colors.red, size: 18),
                                        onPressed: () async {
                                          await _addFriendFromSearch(petData);
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
                      : filteredFriendIds.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 24.0),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.pets,
                                      size: 52,
                                      color: Colors.grey,
                                    ),
                                    const SizedBox(height: 12),
                                    const Text(
                                      "No paw friends yet 🐾",
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      "Search for a pet above and add them as a friend.\n"
                                      "Build your park pack and see where your friends are hanging out!",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: Colors.black.withOpacity(0.7),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(bottom: 70),
                              itemCount: filteredFriendIds.length,
                              itemBuilder: (context, index) {
                                final friendId = filteredFriendIds[index];
                                final ownerName =
                                    _friendOwnerNames[friendId] ?? "Unknown";
                                final activePark = _activeParkMapping[friendId];
                                final pets = _friendPets[friendId] ?? [];

                                String petId = "";
                                String petName = "";
                                if (pets.isNotEmpty) {
                                  petId = (pets[0]['petId'] ?? "").toString();
                                  petName = (pets[0]['name'] ?? "Unknown Pet")
                                      .toString();
                                }

                                final levelInfo = _friendLevels[friendId];
                                final int? friendLevel =
                                    levelInfo?['level'] as int?;
                                final String? friendLevelDesc =
                                    levelInfo?['description'] as String?;

                                // ✅ CHANGE: tappable card opens DM
                                return InkWell(
                                  onTap: () => _openDm(friendId, ownerName),
                                  child: Card(
                                    margin: const EdgeInsets.symmetric(
                                        vertical: 2, horizontal: 4),
                                    child: Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            backgroundImage: NetworkImage(
                                              pets.isNotEmpty
                                                  ? (pets[0]['photoUrl'] ??
                                                          'https://via.placeholder.com/100')
                                                      .toString()
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
                                                Text(
                                                  petName,
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                                Text(
                                                  "Owner: $ownerName",
                                                  style: const TextStyle(
                                                      fontSize: 12),
                                                ),
                                                if (friendLevel != null &&
                                                    friendLevelDesc != null)
                                                  Text(
                                                    "Level $friendLevel – $friendLevelDesc",
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color: Colors.deepPurple,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                if (activePark != null)
                                                  Text(
                                                    "Active at: $activePark",
                                                    style: const TextStyle(
                                                      fontSize: 10,
                                                      color: Colors.green,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),

                                          // ✅ NEW: explicit message icon (WhatsApp style)
                                          IconButton(
                                            tooltip: "Message",
                                            icon: const Icon(Icons.chat_bubble,
                                                color: Colors.green),
                                            onPressed: () =>
                                                _openDm(friendId, ownerName),
                                          ),

                                          // existing favorite/unfriend logic
                                          _favoritePetIds.contains(petId)
                                              ? IconButton(
                                                  icon: const Icon(
                                                    Icons.favorite,
                                                    color: Colors.red,
                                                    size: 18,
                                                  ),
                                                  onPressed: () =>
                                                      _confirmUnfriend(
                                                          friendId, petId),
                                                )
                                              : const SizedBox.shrink(),
                                        ],
                                      ),
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
