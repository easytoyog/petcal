// lib/screens/map_tab.dart
import 'dart:async';
import 'dart:ui'; // for BackdropFilter (frosted filter bar)
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:location/location.dart' as loc;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:inthepark/models/park_model.dart';
import 'package:inthepark/services/location_service.dart';
import 'package:inthepark/screens/chatroom_screen.dart';
import 'package:inthepark/services/firestore_service.dart';
import 'package:inthepark/utils/utils.dart';

// ---------- Moved out of the State class ----------
class _FilterOption {
  final String value; // exact service string in Firestore
  final String label; // short label to show
  final IconData icon;
  const _FilterOption(this.value, this.label, this.icon);
}

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
  final LocationService _locationService =
      LocationService(dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '');

  LatLng? _finalPosition;
  final Set<String> _existingParkIds = {};
  LatLng _currentMapCenter = const LatLng(43.7615, -79.4111);

  // Keyed by Firestore parkId (generateParkID)
  final Map<String, Marker> _markersMap = {};
  // Park data cache (by parkId)
  final Map<String, List<String>> _parkServicesById = {};

  List<Park> _allParks = []; // raw nearby parks
  final Set<String> _selectedFilters = {};

  List<String> _favoritePetIds = [];
  final String? currentUserId = FirebaseAuth.instance.currentUser?.uid;

  bool _isSearching = false;
  bool _isMapReady = false;

  Timer? _locationSaveDebounce;
  Timer? _filterDebounce;

  // Park snapshot listeners scoped to visible markers
  final List<StreamSubscription<QuerySnapshot>> _parksSubs = [];

  // ---------- Filter options ----------
  final List<_FilterOption> _filterOptions = const [
    _FilterOption('Off-leash Dog Park', 'Dog Park', Icons.pets),
    _FilterOption('Off-leash Trail', 'Off-leash Trail', Icons.terrain),
    _FilterOption('On-leash Trail', 'On-leash Trail', Icons.directions_walk),
    _FilterOption('Off-leash Beach', 'Beach', Icons.beach_access),
  ];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _isSearching = true;
    _fetchFavorites();
    _locationService.enableBackgroundLocation();
    _loadSavedLocationAndSetMap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initLocationFlow();
    });
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
    for (final s in _parksSubs) {
      s.cancel();
    }
    _locationSaveDebounce?.cancel();
    _filterDebounce?.cancel();
    _mapController?.dispose();
    super.dispose();
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
      setState(() {
        _favoritePetIds = favIds;
      });
    } catch (e) {
      debugPrint("Error fetching favorites: $e");
    }
  }

  /// Load user location and nearby parks, update markers, maybe prompt check-in.
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
            CameraPosition(target: userLocation, zoom: 17),
          ),
        );

        await _loadNearbyParks(userLocation);
      } else {
        setState(() {
          _finalPosition = const LatLng(43.7615, -79.4111);
          _isMapReady = true;
          _isSearching = false;
        });
      }
    } catch (e) {
      debugPrint("Error in _initLocationFlow: $e");
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _loadNearbyParks(LatLng position) async {
    try {
      setState(() => _isSearching = true);

      final nearbyParks = await _locationService.findNearbyParks(
        position.latitude,
        position.longitude,
      );
      _allParks = nearbyParks;

      // Apply markers keyed by Firestore parkId (generateParkID)
      await _applyMarkerDiff(nearbyParks);

      // Hydrate services for filters immediately
      await _hydrateServicesForParks(nearbyParks);

      // Scope snapshots to current markers (also keeps services up to date)
      _rebuildParksListeners();

      if (!mounted) return;
      setState(() => _isSearching = false);

      // Check for check-in opportunity
      final currentPark = await _locationService.isUserAtPark(
        position.latitude,
        position.longitude,
      );
      if (currentPark != null && mounted) {
        await _locationService.ensureParkExists(currentPark);

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
      debugPrint("Error loading nearby parks: $e");
      if (mounted) setState(() => _isSearching = false);
    }
  }

  // Fetch 'services' arrays for a given list of parks and cache them
  Future<void> _hydrateServicesForParks(List<Park> parks) async {
    final ids = parks
        .map((p) => generateParkID(p.latitude, p.longitude, p.name))
        .toList()
        .chunked(10);

    for (final chunk in ids) {
      final qs = await FirebaseFirestore.instance
          .collection('parks')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();

      for (final d in qs.docs) {
        final svcs =
            (d.data()['services'] as List?)?.cast<String>() ?? const [];
        _parkServicesById[d.id] = svcs;
      }
    }
  }

  // Apply minimal changes instead of clearing markers
  Future<void> _applyMarkerDiff(List<Park> parks) async {
    final next = <String, Marker>{};

    // build markers concurrently (keyed by Firestore parkId)
    final futures = parks.map((p) async {
      final m = await _createParkMarker(p);
      final parkId = generateParkID(p.latitude, p.longitude, p.name);
      return MapEntry(parkId, m);
    }).toList();

    for (final entry in await Future.wait(futures)) {
      next[entry.key] = entry.value;
    }

    final toRemove = _markersMap.keys.toSet().difference(next.keys.toSet());
    final toAdd = next.keys.toSet().difference(_markersMap.keys.toSet());
    final toUpdate = next.keys
        .where((k) => _markersMap.containsKey(k) && _markersMap[k] != next[k]);

    if (toRemove.isEmpty && toAdd.isEmpty && toUpdate.isEmpty) return;

    if (!mounted) return;
    setState(() {
      for (final k in toRemove) {
        _markersMap.remove(k);
      }
      for (final k in toAdd) {
        _markersMap[k] = next[k]!;
      }
      for (final k in toUpdate) {
        _markersMap[k] = next[k]!;
      }
    });
  }

  // Rebuild Firestore listeners to only watch parks currently on the map.
  // Also keep services live-updated so filters are accurate.
  void _rebuildParksListeners() {
    for (final s in _parksSubs) {
      s.cancel();
    }
    _parksSubs.clear();

    final ids = _markersMap.keys.toList();
    if (ids.isEmpty) return;

    // whereIn supports up to 10 per query – chunk them
    final chunks = ids.chunked(10);
    for (final chunk in chunks) {
      final sub = FirebaseFirestore.instance
          .collection('parks')
          .where(FieldPath.documentId, whereIn: chunk)
          .snapshots()
          .listen((snapshot) {
        bool changedInfo = false;
        bool servicesChanged = false;

        for (final parkDoc in snapshot.docs) {
          final parkId = parkDoc.id;
          if (_markersMap.containsKey(parkId)) {
            final data = parkDoc.data();
            final count = (data['userCount'] ?? 0) as int;
            final services =
                (data['services'] as List?)?.cast<String>() ?? const [];
            // update info window users
            final oldMarker = _markersMap[parkId]!;
            final updated = oldMarker.copyWith(
              infoWindowParam: InfoWindow(
                title: oldMarker.infoWindow.title,
                snippet: 'Users: $count',
              ),
            );
            if (updated != oldMarker) {
              _markersMap[parkId] = updated;
              changedInfo = true;
            }
            // update service cache
            final prevSvcs = _parkServicesById[parkId] ?? const [];
            if (!_listEquals(prevSvcs, services)) {
              _parkServicesById[parkId] = services;
              servicesChanged = true;
            }
          }
        }

        if (changedInfo && mounted) setState(() {});

        // if services changed AND a filter is active, reapply filters (debounced)
        if (servicesChanged && _selectedFilters.isNotEmpty) {
          _filterDebounce?.cancel();
          _filterDebounce = Timer(const Duration(milliseconds: 120), () {
            if (mounted) _applyFilters();
          });
        }
      });

      _parksSubs.add(sub);
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final sa = a.toSet();
    final sb = b.toSet();
    if (sa.length != sb.length) return false;
    for (final v in sa) {
      if (!sb.contains(v)) return false;
    }
    return true;
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    _currentMapCenter = _finalPosition ?? const LatLng(43.7615, -79.4111);

    if (_finalPosition != null) {
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _finalPosition!, zoom: 17),
        ),
      );
    }
    // init flow & listeners are handled in initState
  }

  void _onCameraMove(CameraPosition position) {
    _currentMapCenter = position.target;
    _locationSaveDebounce?.cancel();
    _locationSaveDebounce = Timer(const Duration(seconds: 2), () {
      final c = _currentMapCenter;
      _locationService.saveUserLocation(c.latitude, c.longitude);
    });
  }

  // ---- Center-on-me support ----
  Future<bool> _ensureLocationPermission() async {
    bool serviceEnabled = await _location.serviceEnabled();
    if (!serviceEnabled) {
      serviceEnabled = await _location.requestService();
      if (!serviceEnabled) return false;
    }

    var permissionGranted = await _location.hasPermission();
    if (permissionGranted == loc.PermissionStatus.denied) {
      permissionGranted = await _location.requestPermission();
      if (permissionGranted != loc.PermissionStatus.granted) return false;
    }
    if (permissionGranted == loc.PermissionStatus.deniedForever) {
      return false;
    }
    return true;
  }

  Future<void> _centerOnUser() async {
    try {
      if (!await _ensureLocationPermission()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Location permission is required.")),
        );
        return;
      }

      // Try service’s cached/fast path first
      LatLng? user = await _locationService.getUserLocationOrCached();

      // Fallback to direct GPS read
      if (user == null) {
        final l = await _location.getLocation();
        if (l.latitude != null && l.longitude != null) {
          user = LatLng(l.latitude!, l.longitude!);
        }
      }

      if (user == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Unable to get current location.")),
        );
        return;
      }

      _finalPosition = user;
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: user, zoom: 17),
        ),
      );
      await _loadNearbyParks(user);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error centering on your location: $e")),
      );
    }
  }
  // --------------------------------

  void _showCheckInDialog(Park park) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final parkId = generateParkID(park.latitude, park.longitude, park.name);

    final activeDocRef = FirebaseFirestore.instance
        .collection('parks')
        .doc(parkId)
        .collection('active_users')
        .doc(currentUser.uid);
    final activeDoc = await activeDocRef.get();
    bool isCheckedIn = activeDoc.exists;
    if (isCheckedIn) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You are already checked in to this park.")),
      );
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        bool isProcessing = false;
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text("Check In"),
              content: Text("You are at ${park.name}. Do you want to check in?"),
              actions: [
                TextButton(
                  onPressed: isProcessing ? null : () => Navigator.of(context).pop(),
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

  /// Batch-load public profile docs for the given UIDs.
  Future<Map<String, Map<String, dynamic>>> _loadPublicProfiles(
      Set<String> uids) async {
    final db = FirebaseFirestore.instance;
    final out = <String, Map<String, dynamic>>{};
    if (uids.isEmpty) return out;

    for (final chunk in uids.toList().chunked(10)) {
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

  // --------- FULL-SCREEN POPUP (unchanged logic, only UI container & button sizes) ---------
  Future<void> _showUsersInPark(String parkId, String parkName,
      double parkLatitude, double parkLongitude) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    final parkDoc =
        await FirebaseFirestore.instance.collection('parks').doc(parkId).get();
    List<String> services = [];
    if (parkDoc.exists &&
        parkDoc.data() != null &&
        parkDoc.data()!.containsKey('services')) {
      services = List<String>.from(parkDoc['services'] ?? []);
    }
    if (currentUser == null) return;

    if (!mounted) return;
    // quick loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return const AlertDialog(
          content: SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          ),
        );
      },
    );

    try {
      final fs = FirestoreService();
      bool isLiked = await fs.isParkLiked(parkId);

      final activeDocRef = FirebaseFirestore.instance
          .collection('parks')
          .doc(parkId)
          .collection('active_users')
          .doc(currentUser.uid);
      final activeDoc = await activeDocRef.get();
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

      final parkRef =
          FirebaseFirestore.instance.collection('parks').doc(parkId);
      final usersSnapshot = await parkRef.collection('active_users').get();
      final userIds = usersSnapshot.docs.map((doc) => doc.id).toList();

      // ⬇️ batch load public profiles
      final profiles = await _loadPublicProfiles(userIds.toSet());

      final List<Map<String, dynamic>> userList = [];
      if (userIds.isNotEmpty) {
        for (var i = 0; i < userIds.length; i += 10) {
          final batchIds =
              userIds.sublist(i, i + 10 > userIds.length ? userIds.length : i + 10);
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
            final userDoc =
                usersSnapshot.docs.firstWhere((d) => d.id == ownerId);
            final checkInTime =
                (userDoc.data() as Map<String, dynamic>)['checkedInAt'] as Timestamp?;
            final ownerPets = petsByOwner[ownerId] ?? [];

            // profile data (public & readable)
            final prof = profiles[ownerId];
            final ownerName = (prof?['displayName'] as String?)?.trim() ?? '';

            for (final pet in ownerPets) {
              userList.add({
                'petId': pet['petId'],
                'ownerId': ownerId,
                'ownerName': ownerName,
                'petName': pet['name'] ?? 'Unknown Pet',
                'petPhotoUrl': pet['photoUrl'] ?? '',
                'checkInTime': checkInTime != null
                    ? DateFormat.jm().format(checkInTime.toDate())
                    : '',
              });
            }
          }
        }
      }

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close loading spinner

      // ---- FULL SCREEN DIALOG (Scaffold inside showDialog) ----
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return StatefulBuilder(builder: (context, setStateDialog) {
            return Scaffold(
              appBar: AppBar(
                backgroundColor: const Color(0xFF567D46),
                title: Text(parkName),
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                actions: [
                  IconButton(
                    tooltip: isLiked ? 'Liked' : 'Like Park',
                    onPressed: () async {
                      try {
                        if (isLiked) {
                          await fs.unlikePark(parkId);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text("Removed park from liked parks")),
                            );
                          }
                        } else {
                          await fs.likePark(parkId);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("Park liked!")),
                            );
                          }
                        }
                        setStateDialog(() => isLiked = !isLiked);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Error updating like: $e")),
                          );
                        }
                      }
                    },
                    icon: Icon(
                      isLiked ? Icons.thumb_up : Icons.thumb_up_outlined,
                    ),
                  ),
                ],
              ),
              body: Column(
                children: [
                  // Services row (scrollable if long)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ...services.map((service) => Padding(
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
                                    label: Text(service,
                                        style: const TextStyle(fontSize: 12)),
                                    backgroundColor: Colors.green[50],
                                  ),
                                )),
                            // Add service (+) button
                            GestureDetector(
                              onTap: () async {
                                final all = const [
                                  "Off-leash Trail",
                                  "Off-leash Dog Park",
                                  "Off-leash Beach"
                                ];
                                final options =
                                    all.where((s) => !services.contains(s)).toList();

                                if (options.isEmpty) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content:
                                              Text("All services are already added.")),
                                    );
                                  }
                                  return;
                                }

                                final newService = await showDialog<String>(
                                  context: context,
                                  builder: (ctx) {
                                    String? selected = options.first; // prefill
                                    return StatefulBuilder(
                                      builder: (ctx, setState) {
                                        return AlertDialog(
                                          title: const Text("Add Service"),
                                          content: DropdownButtonFormField<String>(
                                            value: selected,
                                            items: options
                                                .map((s) => DropdownMenuItem(
                                                      value: s,
                                                      child: Text(s),
                                                    ))
                                                .toList(),
                                            onChanged: (val) =>
                                                setState(() => selected = val),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.of(ctx).pop(),
                                              child: const Text("Cancel"),
                                            ),
                                            ElevatedButton(
                                              onPressed: () =>
                                                  Navigator.of(ctx).pop(selected),
                                              child: const Text("Add"),
                                            ),
                                          ],
                                        );
                                      },
                                    );
                                  },
                                );

                                if (newService != null &&
                                    newService.isNotEmpty &&
                                    !services.contains(newService)) {
                                  services.add(newService);
                                  await FirebaseFirestore.instance
                                      .collection('parks')
                                      .doc(parkId)
                                      .update({
                                    'services': services,
                                    'updatedAt': FieldValue.serverTimestamp(),
                                  });

                                  // Update local cache so filters reflect immediately
                                  _parkServicesById[parkId] =
                                      List<String>.from(services);

                                  // Refresh full-screen UI
                                  setStateDialog(() {});

                                  if (_selectedFilters.isNotEmpty) {
                                    _applyFilters();
                                  }
                                }
                              },
                              child: Container(
                                margin: const EdgeInsets.only(left: 4),
                                decoration: BoxDecoration(
                                  color: Colors.green,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                padding: const EdgeInsets.all(6),
                                child: const Icon(Icons.add,
                                    color: Colors.white, size: 18),
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
                      itemCount: userList.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (ctx, i) {
                        final petData = userList[i];
                        final ownerId = petData['ownerId'] as String? ?? '';
                        final petId = petData['petId'] as String? ?? '';
                        final petName = petData['petName'] as String? ?? '';
                        final petPhoto = petData['petPhotoUrl'] as String? ?? '';
                        final checkIn = petData['checkInTime'] as String? ?? '';
                        final ownerName =
                            (petData['ownerName'] as String? ?? '').trim();
                        final mine = (ownerId == currentUser.uid);

                        return ListTile(
                          leading: (petPhoto.isNotEmpty)
                              ? CircleAvatar(backgroundImage: NetworkImage(petPhoto))
                              : const CircleAvatar(
                                  backgroundColor: Colors.brown,
                                  child: Icon(Icons.pets, color: Colors.white),
                                ),
                          title: Text(petName),
                          subtitle: Text(
                            [
                              if (ownerName.isNotEmpty && !mine) ownerName,
                              mine ? "Your pet" : null,
                              if (checkIn.isNotEmpty) "– Checked in at $checkIn",
                            ].whereType<String>().join(' '),
                          ),
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
                                      }
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                              content: Text("Friend removed.")),
                                        );
                                      }
                                      _fetchFavorites();
                                    } else {
                                      // Use public_profiles mirror for display name
                                      String ownerDisplay =
                                          ownerName.isNotEmpty
                                              ? ownerName
                                              : (await FirebaseFirestore.instance
                                                      .collection('public_profiles')
                                                      .doc(ownerId)
                                                      .get())
                                                  .data()
                                                  ?.let((d) =>
                                                      (d['displayName'] ?? '')
                                                          .toString()
                                                          .trim()) ??
                                                  ownerId;

                                      await FirebaseFirestore.instance
                                          .collection('friends')
                                          .doc(currentUser.uid)
                                          .collection('userFriends')
                                          .doc(ownerId)
                                          .set({
                                        'friendId': ownerId,
                                        'ownerName': ownerDisplay,
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
                                      }
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                              content: Text("Friend added!")),
                                        );
                                      }
                                      _fetchFavorites();
                                    }
                                  },
                                ),
                        );
                      },
                    ),
                  ),

                  // Big buttons (row 1): Check In/Out + Park Chat
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: _BigActionButton(
                            label: isCheckedIn ? "Check Out" : "Check In",
                            backgroundColor:
                                isCheckedIn ? Colors.red : const Color(0xFF567D46),
                            onPressed: () async {
                              // keep identical behavior
                              final processing = ValueNotifier<bool>(true);
                              showDialog(
                                  context: context,
                                  barrierDismissible: false,
                                  builder: (_) {
                                    return const AlertDialog(
                                      content: SizedBox(
                                        height: 120,
                                        child: Center(
                                            child: CircularProgressIndicator()),
                                      ),
                                    );
                                  });
                              if (isCheckedIn) {
                                await activeDocRef.delete();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text("Checked out of park")),
                                  );
                                }
                              } else {
                                await _locationService
                                    .uploadUserToActiveUsersTable(
                                  parkLatitude,
                                  parkLongitude,
                                  parkName,
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text("Checked in to park")),
                                  );
                                }
                              }
                              processing.value = false;
                              if (mounted) {
                                Navigator.of(context, rootNavigator: true).pop();
                                Navigator.of(context).pop(); // close full-screen
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _BigActionButton(
                            label: "Park Chat",
                            onPressed: () {
                              Navigator.of(context).pop();
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatRoomScreen(parkId: parkId),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Big buttons (row 2): Show Events + Add Event
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: _BigActionButton(
                            label: "Show Events",
                            onPressed: () {
                              Navigator.of(context).pop();
                              widget.onShowEvents(parkId);
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _BigActionButton(
                            label: "Add Event",
                            onPressed: () {
                              Navigator.of(context).pop();
                              _addEvent(parkId, parkLatitude, parkLongitude);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Error loading active users: $e")));
    }
  }
  // -----------------------------------------------------------------------------------------

  Future<void> _handleCheckIn(Park park, double parkLatitude,
      double parkLongitude, BuildContext context) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      await _checkOutFromAllParks(); // batched

      await _locationService.uploadUserToActiveUsersTable(
        parkLatitude,
        parkLongitude,
        park.name,
      );

      if (_finalPosition != null) {
        await _loadNearbyParks(_finalPosition!);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Checked in successfully")));
      }
    } catch (e) {
      debugPrint("Error checking in: $e");
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Error checking in: $e")));
      }
    }
  }

  Future<void> _handleCheckOut(String parkId, BuildContext context) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('parks')
          .doc(parkId)
          .collection('active_users')
          .doc(currentUser.uid)
          .delete();

      if (_finalPosition != null) {
        await _loadNearbyParks(_finalPosition!);
      }

      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Checked out successfully")),
        );
      }
    } catch (e) {
      debugPrint("Error checking out: $e");
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Error checking out: $e")));
      }
    }
  }

  Future<void> _checkOutFromAllParks() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      final snaps = await FirebaseFirestore.instance
          .collectionGroup('active_users')
          .where('uid', isEqualTo: currentUser.uid)
          .get();

      final wb = FirebaseFirestore.instance.batch();
      for (final doc in snaps.docs) {
        wb.delete(doc.reference);
      }
      await wb.commit();
    } catch (e) {
      debugPrint('Error checking out from all parks: $e');
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
                        items: const ["One Time", "Daily", "Weekly", "Monthly"]
                            .map((String value) => DropdownMenuItem(
                                value: value, child: Text(value)))
                            .toList(),
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
                                final date = await showDatePicker(
                                  context: context,
                                  initialDate: DateTime.now(),
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime(2100),
                                );
                                setState(() => oneTimeDate = date);
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
                          items: const [
                            "Monday",
                            "Tuesday",
                            "Wednesday",
                            "Thursday",
                            "Friday",
                            "Saturday",
                            "Sunday"
                          ]
                              .map((String day) => DropdownMenuItem(
                                  value: day, child: Text(day)))
                              .toList(),
                          onChanged: (String? newValue) {
                            setState(() => selectedWeekday = newValue);
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
                                final date = await showDatePicker(
                                  context: context,
                                  initialDate: DateTime.now(),
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime(2100),
                                );
                                setState(() => monthlyDate = date);
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
                              final time = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.now(),
                              );
                              if (time != null) {
                                setState(() => selectedStartTime = time);
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
                              final time = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.now(),
                              );
                              if (time != null) {
                                setState(() => selectedEndTime = time);
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
                              final eventName = eventNameController.text.trim();
                              final eventDesc = eventDescController.text.trim();
                              if (eventName.isEmpty ||
                                  selectedStartTime == null ||
                                  selectedEndTime == null ||
                                  selectedRecurrence == null) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Please complete all required fields")),
                                );
                                return;
                              }
                              if (selectedRecurrence == "One Time" &&
                                  oneTimeDate == null) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Please select a date for a one-time event")),
                                );
                                return;
                              }
                              if (selectedRecurrence == "Weekly" &&
                                  selectedWeekday == null) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Please select a day for a weekly event")),
                                );
                                return;
                              }
                              if (selectedRecurrence == "Monthly" &&
                                  monthlyDate == null) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Please select a date for a monthly event")),
                                );
                                return;
                              }

                              DateTime? eventStartDateTime;
                              DateTime? eventEndDateTime;
                              final now = DateTime.now();
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

                              if (!eventEndDateTime.isAfter(eventStartDateTime)) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content:
                                          Text("End time must be after start time")),
                                );
                                return;
                              }

                              final eventData = <String, dynamic>{
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
                                    FirebaseAuth.instance.currentUser?.uid ?? "",
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

                              if (!mounted) return;
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

    // Create park doc once if missing (guarded by in-memory set)
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
      onTap: () {
        _showUsersInPark(parkId, park.name, park.latitude, park.longitude);
      },
      infoWindow: InfoWindow(
        title: park.name,
        onTap: () {
          _showUsersInPark(parkId, park.name, park.latitude, park.longitude);
        },
      ),
    );
  }

  Future<void> _searchNearbyParks() async {
    setState(() => _isSearching = true);
    try {
      final nearbyParks = await _locationService.findNearbyParks(
        _currentMapCenter.latitude,
        _currentMapCenter.longitude,
      );
      _allParks = nearbyParks;

      await _applyMarkerDiff(nearbyParks);
      await _hydrateServicesForParks(nearbyParks);
      _rebuildParksListeners();

      if (!mounted) return;
      setState(() => _isSearching = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Found ${nearbyParks.length} parks nearby")),
      );
    } catch (e) {
      debugPrint("Error searching nearby parks: $e");
      if (mounted) {
        setState(() => _isSearching = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error searching for parks: $e")));
      }
    }
  }

  void _addFriend(String friendUserId, String petId) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    try {
      final ownerDoc = await FirebaseFirestore.instance
          .collection('public_profiles')
          .doc(friendUserId)
          .get();
      String ownerName = "";
      if (ownerDoc.exists) {
        final data = ownerDoc.data() as Map<String, dynamic>;
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
      await FirebaseFirestore.instance
          .collection('favorites')
          .doc(currentUser.uid)
          .collection('pets')
          .doc(petId)
          .set({
        'petId': petId,
        'addedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Friend added!")));
      }
      _fetchFavorites();
    } catch (e) {
      debugPrint("Error adding friend: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Error adding friend.")));
      }
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Friend removed.")));
      }
      _fetchFavorites();
    } catch (e) {
      debugPrint("Error unfriending: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Error removing friend.")));
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF567D46), Color(0xFF365A38)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        children: [
          // Map + controls
          Expanded(
            child: Stack(
              children: [
                GoogleMap(
                  onMapCreated: _onMapCreated,
                  onCameraMove: _onCameraMove,
                  initialCameraPosition: CameraPosition(
                    target: _currentMapCenter,
                    zoom: 14,
                  ),
                  markers: _markersMap.values.toSet(),
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  compassEnabled: true,
                ),
                // Floating modern filter bar
                _buildFilterBar(),

                if (_isSearching)
                  const Center(child: CircularProgressIndicator()),
                // Center-on-me button
                Positioned(
                  bottom: 150,
                  right: 16,
                  child: FloatingActionButton(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.green,
                    heroTag: 'center_me',
                    onPressed: _centerOnUser,
                    child: const Icon(Icons.my_location),
                  ),
                ),
                // Search button
                Positioned(
                  bottom: 80,
                  right: 16,
                  child: FloatingActionButton(
                    backgroundColor: Colors.green,
                    heroTag: 'search_map',
                    onPressed: _searchNearbyParks,
                    child: const Icon(Icons.search, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Modern floating filter bar ----------
  Widget _buildFilterBar() {
    final hasSelection = _selectedFilters.isNotEmpty;

    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ..._filterOptions.map(_modernFilterChip),
                      if (hasSelection) ...[
                        const SizedBox(width: 6),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.green.shade800,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            shape: const StadiumBorder(),
                          ),
                          onPressed: () {
                            setState(() => _selectedFilters.clear());
                            _applyFilters();
                          },
                          icon: const Icon(Icons.close_rounded, size: 16),
                          label: const Text('Clear'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _modernFilterChip(_FilterOption opt) {
    final selected = _selectedFilters.contains(opt.value);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FilterChip(
        label: Text(opt.label),
        avatar: Icon(
          opt.icon,
          size: 18,
          color: selected ? Colors.white : Colors.green.shade700,
        ),
        selected: selected,
        onSelected: (val) {
          setState(() {
            if (val) {
              _selectedFilters.add(opt.value);
            } else {
              _selectedFilters.remove(opt.value);
            }
          });
          _applyFilters();
        },
        showCheckmark: false,
        labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: selected ? Colors.white : Colors.green.shade900,
        ),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? Colors.green.shade600 : Colors.green.shade200,
            width: 1.2,
          ),
        ),
        selectedColor: Colors.green.shade600,
        backgroundColor: Colors.white,
        elevation: 0,
        pressElevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
  }

  void _applyFilters() async {
    // Determine which parks match the active filters using the service cache
    final filtered = _selectedFilters.isEmpty
        ? _allParks
        : _allParks.where((p) {
            final parkId = generateParkID(p.latitude, p.longitude, p.name);
            final svcs = _parkServicesById[parkId] ?? p.services ?? const [];
            return svcs.any((s) => _selectedFilters.contains(s));
          }).toList();

    await _applyMarkerDiff(filtered);
    _rebuildParksListeners();
  }
}

// -------- Helpers --------

class _BigActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final Color? backgroundColor;
  const _BigActionButton({
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
        minimumSize: const Size.fromHeight(56), // bigger tap target
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

extension _ChunkExt<T> on List<T> {
  List<List<T>> chunked(int size) {
    final out = <List<T>>[];
    for (var i = 0; i < length; i += size) {
      out.add(sublist(i, i + size > length ? length : i + size));
    }
    return out;
  }
}

// Small nullable helper to keep null-aware mapping tidy
extension _LetExt<T> on T? {
  R? let<R>(R Function(T it) f) => this == null ? null : f(this as T);
}
