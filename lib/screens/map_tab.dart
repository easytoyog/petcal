import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:location/location.dart' as loc;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geocoding/geocoding.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:inthepark/models/park_model.dart';
import 'package:inthepark/services/location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:inthepark/screens/chatroom_screen.dart';
import 'package:inthepark/services/firestore_service.dart';
import 'package:inthepark/utils/utils.dart'; // Import your utility
import 'package:inthepark/widgets/active_pets_dialog.dart';

class MapTab extends StatefulWidget {
  final void Function(String parkId) onShowEvents;
  const MapTab({Key? key, required this.onShowEvents}) : super(key: key);

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab>
    with AutomaticKeepAliveClientMixin<MapTab> {
  GoogleMapController? _mapController;
  final loc.Location _location = loc.Location();
  final LocationService _locationService = LocationService(
    dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '',
  );
  // Use default center if location is not yet loaded.
  LatLng? _finalPosition;
  final Set<String> _existingParkIds = {};
  // We no longer block the whole screen while loading location.
  bool _isLocationLoading = true;
  LatLng _currentMapCenter = const LatLng(43.7615, -79.4111);
  // Markers keyed by parkId.
  final Map<String, Marker> _markersMap = {};
  // List of favorite pet IDs.
  List<String> _favoritePetIds = [];
  final String? currentUserId = FirebaseAuth.instance.currentUser?.uid;
  // For search button loading state.
  bool _isSearching = false;
  bool _isMapReady = false;

  Timer? _locationSaveDebounce;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _isSearching = true;
    _fetchFavorites();
    _locationService.enableBackgroundLocation();
    _loadSavedLocationAndSetMap();
  }

  Future<void> _loadSavedLocationAndSetMap() async {
    final savedLocation = await _locationService.getSavedUserLocation();
    setState(() {
      _finalPosition = savedLocation ?? const LatLng(43.7615, -79.4111);
      _isMapReady = true;
    });
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  // --- Dialog to show active users, events, and add event ---
  void _showUsersPopup(BuildContext context) {
    showGeneralDialog(
      context: context,
      barrierLabel: "Users",
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.5),
      transitionDuration: Duration(milliseconds: 300),
      pageBuilder: (context, animation1, animation2) {
        return Align(
          alignment: Alignment.center,
          child: Material(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 300,
              height: 200,
              padding: EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Number of Users",
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 20),
                  Text(
                    "42",
                    style: TextStyle(fontSize: 20),
                  ),
                  SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text("Close"),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation1, animation2, child) {
        return FadeTransition(
          opacity: animation1,
          child: ScaleTransition(
            scale: CurvedAnimation(
              parent: animation1,
              curve: Curves.easeOutBack,
            ),
            child: child,
          ),
        );
      },
    );
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

  /// This method loads the user location and nearby parks,
  /// then updates the markers and (if applicable) triggers the check-in dialog.
  Future<void> _initLocationFlow() async {
    try {
      final userLocation = await _locationService.getUserLocationOrCached();
      if (userLocation != null) {
        setState(() {
          _finalPosition = userLocation;
          _isMapReady = true;
        });

        _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: userLocation,
              zoom: 18,
            ),
          ),
        );

        _loadNearbyParks(userLocation);
      } else {
        setState(() {
          _finalPosition = const LatLng(43.7615, -79.4111);
          _isMapReady = true;
          _isSearching = false;
        });
      }
    } catch (e) {
      print("Error in _initLocationFlow: $e");
      setState(() {
        _isSearching = false;
      });
    }
  }

  Future<void> _loadNearbyParks(LatLng position) async {
    try {
      // Set searching state to true
      setState(() {
        _isSearching = true;
      });

      // Clear previous markers
      _markersMap.clear();

      // Fetch nearby parks
      List<Park> nearbyParks = await _locationService.findNearbyParks(
        position.latitude,
        position.longitude,
      );

      // Create markers concurrently
      final markerFutures = nearbyParks.map((park) async {
        final marker = await _createParkMarker(park);
        return MapEntry(park.id, marker);
      }).toList();

      final markerEntries = await Future.wait(markerFutures);

      // Update markers in setState to trigger UI refresh
      setState(() {
        for (var entry in markerEntries) {
          _markersMap[entry.key] = entry.value;
        }
        _isSearching = false; // Reset searching state
      });

      // Check for check-in opportunity
      Park? currentPark = await _locationService.isUserAtPark(
        position.latitude,
        position.longitude,
      );
      print('Found currentPark: $currentPark');
      if (currentPark != null && mounted) {
        await _locationService.ensureParkExists(currentPark);

        // Check if the user is already checked in to this park
        final currentUser = FirebaseAuth.instance.currentUser;
        if (currentUser != null) {
          final parkId = generateParkID(
              currentPark.latitude, currentPark.longitude, currentPark.name);
          final activeDocRef = FirebaseFirestore.instance
              .collection('parks')
              .doc(parkId)
              .collection('active_users')
              .doc(currentUser.uid);
          final activeDoc = await activeDocRef.get();
          if (!activeDoc.exists) {
            _showCheckInDialog(currentPark);
          }
        }
      }
    } catch (e) {
      print("Error loading nearby parks: $e");
      if (mounted) {
        setState(() {
          _isSearching = false; // Reset searching state on error
        });
      }
    }
  }

  Future<int> _getUserCountInPark(String parkId) async {
    try {
      final parkRef =
          FirebaseFirestore.instance.collection('parks').doc(parkId);
      final usersSnapshot = await parkRef.collection('active_users').get();
      return usersSnapshot.size;
    } catch (e) {
      print("Error getting active user count for park $parkId: $e");
      return 0;
    }
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    // Initialize the current map center.
    _currentMapCenter = _finalPosition ?? const LatLng(43.7615, -79.4111);

    // If we already have the user's location, move the camera there
    if (_finalPosition != null) {
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _finalPosition!,
            zoom: 18,
          ),
        ),
      );
    }
    _initLocationFlow();
    _listenToParkUpdates();
  }

  void _onCameraMove(CameraPosition position) {
    _currentMapCenter = position.target;
    _locationSaveDebounce?.cancel();
    _locationSaveDebounce = Timer(const Duration(seconds: 2), () {
      _locationService.saveUserLocation(
          _currentMapCenter.latitude, _currentMapCenter.longitude);
    });
  }

  void _showCheckInDialog(Park park) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final parkId = generateParkID(park.latitude, park.longitude, park.name);

    DocumentReference activeDocRef = FirebaseFirestore.instance
        .collection('parks')
        .doc(parkId)
        .collection('active_users')
        .doc(currentUser.uid);
    DocumentSnapshot activeDoc = await activeDocRef.get();
    bool isCheckedIn = activeDoc.exists;
    if (isCheckedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("You are already checked in to this park.")),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        bool isProcessing = false;
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text("Check In"),
              content:
                  Text("You are at ${park.name}. Do you want to check in?"),
              actions: [
                TextButton(
                  onPressed:
                      isProcessing ? null : () => Navigator.of(context).pop(),
                  child: const Text("No"),
                ),
                ElevatedButton(
                  onPressed: isProcessing
                      ? null
                      : () async {
                          setStateDialog(() => isProcessing = true);
                          await _handleCheckIn(
                              park, park.latitude, park.longitude, context);
                          if (mounted) Navigator.of(context).pop();
                        },
                  child: isProcessing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text("Yes, Check In"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showUsersInPark(String parkId, String parkName,
      double parkLatitude, double parkLongitude) async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;

      // 1) Determine initial liked state once:
      final FirestoreService fs = FirestoreService();
      bool isLiked = await fs.isParkLiked(parkId);

      // 2) Check‑in/out state for this park (unchanged)
      DocumentReference activeDocRef = FirebaseFirestore.instance
          .collection('parks')
          .doc(parkId)
          .collection('active_users')
          .doc(currentUser.uid);
      DocumentSnapshot activeDoc = await activeDocRef.get();
      bool isCheckedIn = activeDoc.exists;
      DateTime? checkedInAt;
      if (isCheckedIn) {
        final data = activeDoc.data() as Map<String, dynamic>;
        if (data.containsKey('checkedInAt')) {
          checkedInAt = (data['checkedInAt'] as Timestamp).toDate();
          if (DateTime.now().difference(checkedInAt) >
              const Duration(minutes: 30)) {
            await activeDocRef.delete();
            isCheckedIn = false;
          }
        }
      }

      // 3) Build list of active users & their pets (unchanged)
      DocumentReference parkRef =
          FirebaseFirestore.instance.collection('parks').doc(parkId);
      QuerySnapshot usersSnapshot =
          await parkRef.collection('active_users').get();
      print('usersSnapshot.docs.length: ${usersSnapshot.docs.length}');
      for (var userDoc in usersSnapshot.docs) {
        print('userDoc.id: ${userDoc.id}');
        print('userDoc.data(): ${userDoc.data()}');
      }
      final userIds = usersSnapshot.docs.map((doc) => doc.id).toList();

      List<Map<String, dynamic>> userList = [];

      // Batch fetch all pets for these users
      if (userIds.isNotEmpty) {
        for (var i = 0; i < userIds.length; i += 10) {
          final batchIds = userIds.sublist(
              i, i + 10 > userIds.length ? userIds.length : i + 10);
          final petsSnapshot = await FirebaseFirestore.instance
              .collection('pets')
              .where('ownerId', whereIn: batchIds)
              .get();

          // Map ownerId to their pets
          Map<String, List<Map<String, dynamic>>> petsByOwner = {};
          for (var petDoc in petsSnapshot.docs) {
            final petData = petDoc.data();
            final ownerId = petData['ownerId'];
            petsByOwner.putIfAbsent(ownerId, () => []).add({
              ...petData,
              'petId': petDoc.id,
            });
          }
          ;

          for (var userDoc in usersSnapshot.docs) {
            final userId = userDoc.id;
            final checkInTime =
                (userDoc.data() as Map<String, dynamic>)['checkedInAt'];
            final ownerPets = petsByOwner[userId] ?? [];
            for (var pet in ownerPets) {
              userList.add({
                'petId': pet['petId'],
                'ownerId': userId,
                'petName': pet['name'] ?? 'Unknown Pet',
                'petPhotoUrl': pet['photoUrl'] ?? '',
                'ownerName':
                    '', // You can batch fetch owner names too if needed
                'checkInTime': checkInTime != null
                    ? DateFormat.jm()
                        .format((checkInTime as Timestamp).toDate())
                    : '',
              });
            }
          }
        }
      }

      if (!mounted) return;

      // 4) Show the dialog
      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 24), // Reduce horizontal padding
            title: Text("$parkName - Pets in Park"),
            content: SizedBox(
              width: 420, // Make the dialog wider
              height: 500, // Optionally make it taller
              child: Column(
                children: [
                  Expanded(
                    child: StatefulBuilder(
                      builder: (context, setStateDialog) {
                        return ListView.separated(
                          itemCount: userList.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 6),
                          itemBuilder: (ctx, i) {
                            final petData = userList[i];
                            final ownerId = petData['ownerId'] as String? ?? '';
                            final petId = petData['petId'] as String? ?? '';
                            final petName = petData['petName'] as String? ?? '';
                            final petPhoto =
                                petData['petPhotoUrl'] as String? ?? '';
                            final checkIn =
                                petData['checkInTime'] as String? ?? '';
                            bool mine = (ownerId == currentUser.uid);

                            return ListTile(
                              leading: (petPhoto.isNotEmpty)
                                  ? CircleAvatar(
                                      backgroundImage: NetworkImage(petPhoto))
                                  : const CircleAvatar(
                                      backgroundColor: Colors.brown,
                                      child:
                                          Icon(Icons.pets, color: Colors.white),
                                    ),
                              title: Text(petName),
                              subtitle: Text(mine
                                  ? "Your pet – Checked in at $checkIn"
                                  : "Checked in at $checkIn"),
                              trailing: mine
                                  ? null
                                  : IconButton(
                                      icon: Icon(
                                        _favoritePetIds.contains(petId)
                                            ? Icons.favorite
                                            : Icons.favorite_border,
                                        color: Colors.red,
                                      ),
                                      onPressed: () async {
                                        final currentUser =
                                            FirebaseAuth.instance.currentUser;
                                        if (currentUser == null) return;

                                        if (_favoritePetIds.contains(petId)) {
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
                                          if (mounted) {
                                            setState(() {
                                              _favoritePetIds.remove(petId);
                                            });
                                            setStateDialog(
                                                () {}); // <-- Update dialog UI
                                          }
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            const SnackBar(
                                                content:
                                                    Text("Friend removed.")),
                                          );
                                          _fetchFavorites();
                                        } else {
                                          // Add friend and favorite
                                          DocumentSnapshot ownerDoc =
                                              await FirebaseFirestore.instance
                                                  .collection('owners')
                                                  .doc(ownerId)
                                                  .get();
                                          String ownerName = "";
                                          if (ownerDoc.exists) {
                                            final data = ownerDoc.data()
                                                as Map<String, dynamic>;
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
                                            'addedAt':
                                                FieldValue.serverTimestamp(),
                                          });
                                          await FirebaseFirestore.instance
                                              .collection('favorites')
                                              .doc(currentUser.uid)
                                              .collection('pets')
                                              .doc(petId)
                                              .set({
                                            'petId': petId,
                                            'addedAt':
                                                FieldValue.serverTimestamp(),
                                          });
                                          if (mounted) {
                                            setState(() {
                                              _favoritePetIds.add(petId);
                                            });
                                            setStateDialog(
                                                () {}); // <-- Update dialog UI
                                          }
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            const SnackBar(
                                                content: Text("Friend added!")),
                                          );
                                          _fetchFavorites();
                                        }
                                      },
                                    ),
                            );
                          },
                        );
                      },
                    ),
                  ),

                  // 5) Check‑in / Chat / Events buttons (unchanged)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      StatefulBuilder(
                        builder: (context, setStateDialog) {
                          // Initialize isProcessing with false using a ValueNotifier for proper state management
                          final isProcessing = ValueNotifier<bool>(false);
                          return ValueListenableBuilder<bool>(
                            valueListenable: isProcessing,
                            builder: (context, processing, _) {
                              return ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      isCheckedIn ? Colors.red : Colors.green,
                                ),
                                onPressed: processing
                                    ? null
                                    : () async {
                                        isProcessing.value = true;
                                        if (isCheckedIn) {
                                          await activeDocRef.delete();
                                          await FirebaseFirestore.instance
                                              .collection('parks')
                                              .doc(parkId)
                                              .update({
                                            'userCount':
                                                FieldValue.increment(-1)
                                          });
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                                content: Text(
                                                    "Checked out of park")),
                                          );
                                        } else {
                                          await _locationService
                                              .uploadUserToActiveUsersTable(
                                            parkLatitude,
                                            parkLongitude,
                                            parkName,
                                          );
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                                content:
                                                    Text("Checked in to park")),
                                          );
                                        }
                                        isProcessing.value = false;
                                        if (mounted)
                                          Navigator.of(context,
                                                  rootNavigator: true)
                                              .pop();
                                      },
                                child: processing
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : Text(
                                        isCheckedIn ? "Check Out" : "Check In"),
                              );
                            },
                          );
                        },
                      ),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.of(context, rootNavigator: true).pop();
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatRoomScreen(parkId: parkId),
                            ),
                          );
                        },
                        child: const Text("Park Chat"),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          Navigator.of(context, rootNavigator: true).pop();
                          widget.onShowEvents(parkId);
                        },
                        child: const Text("Show Events"),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.of(context, rootNavigator: true).pop();
                          _addEvent(parkId, parkLatitude, parkLongitude);
                        },
                        child: const Text("Add Event"),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // 6) Actions: Like/Unlike + Close
            // … inside your AlertDialog’s actions:
            actions: [
              StatefulBuilder(builder: (ctx, setState) {
                return TextButton.icon(
                  onPressed: () async {
                    try {
                      if (isLiked) {
                        await fs.unlikePark(parkId);
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                              content: Text("Removed park from liked parks")),
                        );
                      } else {
                        await fs.likePark(parkId);
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text("Park liked!")),
                        );
                      }
                      setState(() => isLiked = !isLiked);
                    } catch (e) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text("Error updating like: $e")),
                      );
                    }
                  },
                  icon: Icon(
                    // hollow when not liked, filled when liked
                    isLiked ? Icons.thumb_up : Icons.thumb_up_outlined,
                    size: 16,
                    color: isLiked ? Colors.green : Colors.grey,
                  ),
                  label: Text(
                    isLiked ? "Liked" : "Like Park",
                    style: TextStyle(
                      fontSize: 12,
                      color: isLiked ? Colors.green : Colors.grey,
                    ),
                  ),
                );
              }),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text("Close", style: TextStyle(fontSize: 12)),
              ),
            ],
          );
        },
      );
    } catch (e) {
      print("Error showing users in park: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error loading active users: $e")),
      );
    }
  }

  Future<void> _handleCheckIn(Park park, double parkLatitude,
      double parkLongitude, BuildContext context) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      // First, check out from all other parks
      _checkOutFromAllParks();

      // Then check in to this park
      await _locationService.uploadUserToActiveUsersTable(
        parkLatitude,
        parkLongitude,
        park.name,
      );

      // Refresh the map
      if (_finalPosition != null) {
        await _loadNearbyParks(_finalPosition!);
      }

      // Show confirmation
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Checked in successfully")),
      );
    } catch (e) {
      print("Error checking in: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error checking in: $e")),
      );
    }
  }

  // Handle the check-out process
  Future<void> _handleCheckOut(String parkId, BuildContext context) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      // Check out from this park
      await FirebaseFirestore.instance
          .collection('parks')
          .doc(parkId)
          .collection('active_users')
          .doc(currentUser.uid)
          .delete();

      await FirebaseFirestore.instance
          .collection('parks')
          .doc(parkId)
          .update({'userCount': FieldValue.increment(-1)});

      // Refresh the map
      if (_finalPosition != null) {
        await _loadNearbyParks(_finalPosition!);
      }

      // Close the dialog
      Navigator.of(context, rootNavigator: true).pop();

      // Show confirmation
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Checked out successfully")),
      );
    } catch (e) {
      print("Error checking out: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error checking out: $e")),
      );
    }
  }

  // Check out from all parks the user is currently checked in to
  Future<void> _checkOutFromAllParks() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      // Query only parks where the user is checked in
      final activeUserSnaps = await FirebaseFirestore.instance
          .collectionGroup('active_users')
          .where(FieldPath.documentId, isEqualTo: currentUser.uid)
          .get();

      List<Future> futures = [];
      for (var doc in activeUserSnaps.docs) {
        final parkDocRef = doc.reference.parent.parent;
        if (parkDocRef != null) {
          futures.add(doc.reference.delete());
          futures
              .add(parkDocRef.update({'userCount': FieldValue.increment(-1)}));
        }
      }
      await Future.wait(futures);
    } catch (e) {
      print("Error checking out from all parks: $e");
    }
  }

  void _addEvent(String parkId, double parkLatitude, double parkLongitude) {
    final TextEditingController eventNameController = TextEditingController();
    final TextEditingController eventDescController = TextEditingController();
    String? selectedRecurrence = "One Time";
    DateTime? oneTimeDate;
    DateTime? monthlyDate;
    String? selectedWeekday;
    TimeOfDay? selectedStartTime;
    TimeOfDay? selectedEndTime;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return Scaffold(
          appBar: AppBar(
            title: const Text("Add Event"),
            backgroundColor: const Color(0xFF567D46),
            automaticallyImplyLeading: false,
            actions: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          body: StatefulBuilder(
            builder: (context, setState) {
              return Padding(
                padding: const EdgeInsets.all(24.0),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: eventNameController,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: "Event Name *",
                          hintText: "Enter event name",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: eventDescController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: "Description",
                          hintText: "Enter event description",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        value: selectedRecurrence,
                        decoration: const InputDecoration(
                          labelText: "Recurrence",
                          border: OutlineInputBorder(),
                        ),
                        items: ["One Time", "Daily", "Weekly", "Monthly"]
                            .map((String value) {
                          return DropdownMenuItem<String>(
                            value: value,
                            child: Text(value),
                          );
                        }).toList(),
                        onChanged: (String? newValue) {
                          setState(() {
                            selectedRecurrence = newValue;
                            oneTimeDate = null;
                            monthlyDate = null;
                            selectedWeekday = null;
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      if (selectedRecurrence == "One Time")
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                oneTimeDate == null
                                    ? "No date selected"
                                    : "Date: ${DateFormat.yMd().format(oneTimeDate!)}",
                              ),
                            ),
                            TextButton(
                              onPressed: () async {
                                DateTime? date = await showDatePicker(
                                  context: context,
                                  initialDate: DateTime.now(),
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime(2100),
                                );
                                setState(() {
                                  oneTimeDate = date;
                                });
                              },
                              child: const Text("Select Date"),
                            ),
                          ],
                        ),
                      if (selectedRecurrence == "Weekly")
                        DropdownButtonFormField<String>(
                          value: selectedWeekday,
                          decoration: const InputDecoration(
                            labelText: "Select Day of Week",
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            "Monday",
                            "Tuesday",
                            "Wednesday",
                            "Thursday",
                            "Friday",
                            "Saturday",
                            "Sunday"
                          ].map((String day) {
                            return DropdownMenuItem<String>(
                              value: day,
                              child: Text(day),
                            );
                          }).toList(),
                          onChanged: (String? newValue) {
                            setState(() {
                              selectedWeekday = newValue;
                            });
                          },
                        ),
                      if (selectedRecurrence == "Monthly")
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                monthlyDate == null
                                    ? "No date selected"
                                    : "Date: ${DateFormat.d().format(monthlyDate!)}",
                              ),
                            ),
                            TextButton(
                              onPressed: () async {
                                DateTime? date = await showDatePicker(
                                  context: context,
                                  initialDate: DateTime.now(),
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime(2100),
                                );
                                setState(() {
                                  monthlyDate = date;
                                });
                              },
                              child: const Text("Select Date"),
                            ),
                          ],
                        ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              selectedStartTime == null
                                  ? "No start time selected"
                                  : "Start: ${selectedStartTime!.format(context)}",
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              TimeOfDay? time = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.now(),
                              );
                              if (time != null) {
                                setState(() {
                                  selectedStartTime = time;
                                });
                              }
                            },
                            child: const Text("Select Start Time"),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              selectedEndTime == null
                                  ? "No end time selected"
                                  : "End: ${selectedEndTime!.format(context)}",
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              TimeOfDay? time = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.now(),
                              );
                              if (time != null) {
                                setState(() {
                                  selectedEndTime = time;
                                });
                              }
                            },
                            child: const Text("Select End Time"),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text("Cancel"),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton(
                            onPressed: () async {
                              String eventName =
                                  eventNameController.text.trim();
                              String eventDesc =
                                  eventDescController.text.trim();
                              if (eventName.isEmpty ||
                                  selectedStartTime == null ||
                                  selectedEndTime == null ||
                                  selectedRecurrence == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Please complete all required fields")),
                                );
                                return;
                              }
                              if (selectedRecurrence == "One Time" &&
                                  oneTimeDate == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Please select a date for a one-time event")),
                                );
                                return;
                              }
                              if (selectedRecurrence == "Weekly" &&
                                  selectedWeekday == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Please select a day for a weekly event")),
                                );
                                return;
                              }
                              if (selectedRecurrence == "Monthly" &&
                                  monthlyDate == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Please select a date for a monthly event")),
                                );
                                return;
                              }

                              DateTime? eventStartDateTime;
                              DateTime? eventEndDateTime;
                              DateTime now = DateTime.now();
                              if (selectedRecurrence == "One Time") {
                                eventStartDateTime = DateTime(
                                  oneTimeDate!.year,
                                  oneTimeDate!.month,
                                  oneTimeDate!.day,
                                  selectedStartTime!.hour,
                                  selectedStartTime!.minute,
                                );
                                eventEndDateTime = DateTime(
                                  oneTimeDate!.year,
                                  oneTimeDate!.month,
                                  oneTimeDate!.day,
                                  selectedEndTime!.hour,
                                  selectedEndTime!.minute,
                                );
                              } else if (selectedRecurrence == "Monthly") {
                                eventStartDateTime = DateTime(
                                  now.year,
                                  now.month,
                                  monthlyDate!.day,
                                  selectedStartTime!.hour,
                                  selectedStartTime!.minute,
                                );
                                eventEndDateTime = DateTime(
                                  now.year,
                                  now.month,
                                  monthlyDate!.day,
                                  selectedEndTime!.hour,
                                  selectedEndTime!.minute,
                                );
                              } else {
                                eventStartDateTime = DateTime(
                                  now.year,
                                  now.month,
                                  now.day,
                                  selectedStartTime!.hour,
                                  selectedStartTime!.minute,
                                );
                                eventEndDateTime = DateTime(
                                  now.year,
                                  now.month,
                                  now.day,
                                  selectedEndTime!.hour,
                                  selectedEndTime!.minute,
                                );
                              }

                              if (!eventEndDateTime
                                  .isAfter(eventStartDateTime)) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "End time must be after start time")),
                                );
                                return;
                              }

                              Map<String, dynamic> eventData = {
                                'parkId': parkId,
                                'parkLatitude': parkLatitude,
                                'parkLongitude': parkLongitude,
                                'name': eventName,
                                'description': eventDesc,
                                'startDateTime': eventStartDateTime,
                                'endDateTime': eventEndDateTime,
                                'recurrence': selectedRecurrence,
                                'likes': [],
                                'createdBy':
                                    FirebaseAuth.instance.currentUser?.uid ??
                                        "",
                                'createdAt': FieldValue.serverTimestamp(),
                              };

                              if (selectedRecurrence == "Weekly") {
                                eventData['weekday'] = selectedWeekday;
                              }
                              if (selectedRecurrence == "One Time") {
                                eventData['eventDate'] = oneTimeDate;
                              }
                              if (selectedRecurrence == "Monthly") {
                                eventData['eventDay'] = monthlyDate!.day;
                              }

                              await FirebaseFirestore.instance
                                  .collection('parks')
                                  .doc(parkId)
                                  .collection('events')
                                  .add(eventData);

                              Navigator.of(context).pop();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text("Event '$eventName' added")),
                              );
                            },
                            child: const Text("Add"),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<Marker> _createParkMarker(Park park) async {
    final firestore = FirebaseFirestore.instance;
    final parkId = generateParkID(park.latitude, park.longitude, park.name);

    // Only check Firestore if we haven't seen this parkId before
    if (!_existingParkIds.contains(parkId)) {
      final parkRef = firestore.collection('parks').doc(parkId);
      final parkSnap = await parkRef.get();
      if (!parkSnap.exists) {
        await parkRef.set({
          'id': parkId,
          'name': park.name,
          'latitude': park.latitude,
          'longitude': park.longitude,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      _existingParkIds.add(parkId);
    }

    return Marker(
      markerId: MarkerId(parkId),
      position: LatLng(park.latitude, park.longitude),
      onTap: () async {
        // No need to check Firestore again, just use the cache
        _showUsersInPark(parkId, park.name, park.latitude, park.longitude);
      },
      infoWindow: InfoWindow(
        title: park.name,
        onTap: () async {
          _showUsersInPark(parkId, park.name, park.latitude, park.longitude);
        },
      ),
    );
  }

  Future<void> _searchNearbyParks() async {
    setState(() {
      _isSearching = true;
    });
    try {
      List<Park> nearbyParks = await _locationService.findNearbyParks(
        _currentMapCenter.latitude,
        _currentMapCenter.longitude,
      );
      Map<String, Marker> newMarkersMap = {};
      for (var park in nearbyParks) {
        final marker = await _createParkMarker(park);
        newMarkersMap[park.id] = marker;
      }
      setState(() {
        _markersMap.addAll(newMarkersMap);
        _isSearching = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Found ${nearbyParks.length} parks nearby")),
      );
    } catch (e) {
      print("Error searching nearby parks: $e");
      setState(() {
        _isSearching = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error searching for parks: $e")),
      );
    }
  }

  void _addFriend(String friendUserId, String petId) async {
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
        ownerName =
            "${data['firstName'] ?? ''} ${data['lastName'] ?? ''}".trim();
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Friend added!")),
      );
      _fetchFavorites();
    } catch (e) {
      print("Error adding friend: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Error adding friend.")),
      );
    }
  }

  Future<void> _unfriend(String friendUserId, String petId) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('friends')
          .doc(currentUser.uid)
          .collection('userFriends')
          .doc(friendUserId)
          .delete();
      await FirebaseFirestore.instance
          .collection('favorites')
          .doc(currentUser.uid)
          .collection('pets')
          .doc(petId)
          .delete();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Friend removed.")),
      );
      _fetchFavorites();
    } catch (e) {
      print("Error unfriending: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Error removing friend.")),
      );
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
              },
              child: const Text("Yes"),
            ),
          ],
        );
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // If the tab is active and we're not already searching
    if (mounted && !_isSearching && _finalPosition != null) {
      setState(() {
        _isSearching = true;
      });
      _loadNearbyParks(_finalPosition!);
    }
  }

  void _listenToParkUpdates() {
    FirebaseFirestore.instance
        .collection('parks')
        .snapshots()
        .listen((snapshot) {
      for (var parkDoc in snapshot.docs) {
        final parkId = parkDoc.id;
        if (_markersMap.containsKey(parkId)) {
          _getUserCountInPark(parkId).then((count) {
            final oldMarker = _markersMap[parkId]!;
            final updatedMarker = oldMarker.copyWith(
              infoWindowParam: InfoWindow(
                title: oldMarker.infoWindow.title,
                snippet: 'Users: $count',
              ),
            );
            _markersMap[parkId] = updatedMarker;
            setState(() {});
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (!_isMapReady || _finalPosition == null) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF567D46), Color(0xFF365A38)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
      );
    }

    // Once location is ready, show the map
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF567D46), Color(0xFF365A38)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _finalPosition!,
              zoom: 18,
            ),
            mapType: MapType.normal,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            markers: _markersMap.values.toSet(),
            onMapCreated: _onMapCreated,
            onCameraMove: _onCameraMove,
          ),
          Positioned(
            bottom: 90,
            right: 10,
            child: FloatingActionButton.extended(
              onPressed: _isSearching ? null : _searchNearbyParks,
              label: _isSearching
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                        SizedBox(width: 10),
                        Text("Searching..."),
                      ],
                    )
                  : const Text("Search Nearby Parks"),
              icon: _isSearching ? null : const Icon(Icons.search),
              backgroundColor: const Color(0xFF567D46),
              foregroundColor: Colors.white,
              elevation: 4,
            ),
          ),
        ],
      ),
    );
  }
}
