import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:http/http.dart' as http;
import 'package:location/location.dart' as loc;

import 'package:inthepark/models/group.dart';
import 'package:inthepark/widgets/ad_banner.dart';
import 'package:inthepark/screens/group_chat_screen.dart';

class PlaceResult {
  final String id;
  final String name;
  final double latitude;
  final double longitude;

  PlaceResult({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });
}

class GroupPersonOption {
  final String uid;
  final String ownerName;
  final String petName;
  final String petPhotoUrl;

  GroupPersonOption({
    required this.uid,
    required this.ownerName,
    required this.petName,
    required this.petPhotoUrl,
  });
}

class GroupsTab extends StatefulWidget {
  const GroupsTab({Key? key}) : super(key: key);

  @override
  State<GroupsTab> createState() => _GroupsTabState();
}

class _GroupsTabState extends State<GroupsTab>
    with AutomaticKeepAliveClientMixin<GroupsTab> {
  final String? _currentUserId = FirebaseAuth.instance.currentUser?.uid;
  final FirebaseFirestore _fs = FirebaseFirestore.instance;

  List<Group> _myGroups = [];
  List<Group> _localPublicGroups = [];
  Map<String, DateTime> _groupLastReadAt = {};

  bool _isLoading = true;
  bool _showingLocalGroups = false;
  LatLng? _userLocation;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _groupReadsSub;

  @override
  void initState() {
    super.initState();
    _listenToGroupReads();
    _init();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _groupReadsSub?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    await Future.wait([
      _fetchUserLocation(),
      _fetchMyGroups(),
    ]);

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshCurrentView() async {
    await _fetchMyGroups();
    if (_showingLocalGroups) {
      await _fetchLocalPublicGroups(showSnackOnNoLocation: false);
    }
    if (mounted) setState(() {});
  }

  void _listenToGroupReads() {
    final uid = _currentUserId;
    if (uid == null) return;

    _groupReadsSub = _fs
        .collection('owners')
        .doc(uid)
        .collection('group_chat_reads')
        .snapshots()
        .listen((snapshot) {
      final next = <String, DateTime>{};
      for (final doc in snapshot.docs) {
        final raw = doc.data()['lastReadAt'];
        if (raw is Timestamp) {
          next[doc.id] = raw.toDate();
        }
      }
      if (!mounted) return;
      setState(() => _groupLastReadAt = next);
    });
  }

  Future<void> _fetchUserLocation() async {
    try {
      final location = loc.Location();

      bool serviceEnabled = await location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await location.requestService();
        if (!serviceEnabled) return;
      }

      loc.PermissionStatus permissionGranted = await location.hasPermission();
      if (permissionGranted == loc.PermissionStatus.denied) {
        permissionGranted = await location.requestPermission();
      }

      if (permissionGranted != loc.PermissionStatus.granted &&
          permissionGranted != loc.PermissionStatus.grantedLimited) {
        return;
      }

      final user = await location.getLocation();
      if (user.latitude != null && user.longitude != null) {
        _userLocation = LatLng(user.latitude!, user.longitude!);
      }
    } catch (e) {
      debugPrint('Error fetching user location: $e');
    }
  }

  Future<void> _fetchMyGroups() async {
    if (_currentUserId == null) return;

    try {
      final query = await _fs
          .collection('groups')
          .where('members', arrayContains: _currentUserId)
          .get();

      final groups = query.docs.map((doc) => Group.fromFirestore(doc)).toList();

      groups.sort((a, b) {
        final aCreator = a.createdBy == _currentUserId ? 1 : 0;
        final bCreator = b.createdBy == _currentUserId ? 1 : 0;
        if (aCreator != bCreator) return bCreator.compareTo(aCreator);

        final aAdmin = a.admins.contains(_currentUserId) ? 1 : 0;
        final bAdmin = b.admins.contains(_currentUserId) ? 1 : 0;
        if (aAdmin != bAdmin) return bAdmin.compareTo(aAdmin);

        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      _myGroups = groups;
    } catch (e) {
      debugPrint('Error fetching groups: $e');
    }
  }

  Future<void> _fetchLocalPublicGroups({
    bool showSnackOnNoLocation = true,
  }) async {
    if (_userLocation == null) {
      if (showSnackOnNoLocation && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location not available')),
        );
      }
      return;
    }

    try {
      final query = await _fs
          .collection('groups')
          .where('isPublic', isEqualTo: true)
          .get();

      final groups = query.docs
          .map((doc) => Group.fromFirestore(doc))
          .where((g) => g.latitude != null && g.longitude != null)
          .toList();

      groups.sort((a, b) {
        final distA =
            _distance(_userLocation!, LatLng(a.latitude!, a.longitude!));
        final distB =
            _distance(_userLocation!, LatLng(b.latitude!, b.longitude!));
        return distA.compareTo(distB);
      });

      _localPublicGroups = groups;

      if (mounted) {
        setState(() => _showingLocalGroups = true);
      }
    } catch (e) {
      debugPrint('Error fetching local groups: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading local groups: $e')),
        );
      }
    }
  }

  double _distance(LatLng a, LatLng b) {
    const earthRadiusKm = 6371.0;
    final dLat = _toRad(b.latitude - a.latitude);
    final dLng = _toRad(b.longitude - a.longitude);
    final lat1 = _toRad(a.latitude);
    final lat2 = _toRad(b.latitude);

    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);

    final c = 2 * math.asin(math.sqrt(h));
    return earthRadiusKm * c;
  }

  double _toRad(double deg) => deg * math.pi / 180.0;

  Future<List<PlaceResult>> _searchPlaces(
    String query,
    LatLng location,
  ) async {
    try {
      final apiKey = dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '';
      if (apiKey.isEmpty) {
        debugPrint('Google Maps API key not found');
        return [];
      }

      final encodedQuery = Uri.encodeComponent(query.trim());
      final predictionsUrl =
          'https://maps.googleapis.com/maps/api/place/autocomplete/json'
          '?input=$encodedQuery'
          '&key=$apiKey'
          '&location=${location.latitude},${location.longitude}'
          '&radius=50000'
          '&language=en'
          '&types=establishment';

      final predictionsResponse = await http.get(Uri.parse(predictionsUrl));
      if (predictionsResponse.statusCode != 200) {
        debugPrint(
          'Autocomplete HTTP error: ${predictionsResponse.statusCode}',
        );
        return [];
      }

      final predictionsJson = jsonDecode(predictionsResponse.body);
      final status = predictionsJson['status'];

      if (status != 'OK' && status != 'ZERO_RESULTS') {
        debugPrint('Autocomplete status: $status');
        debugPrint('Autocomplete response: ${predictionsResponse.body}');
        return [];
      }

      final predictions = predictionsJson['predictions'] as List? ?? [];
      if (predictions.isEmpty) return [];

      final results = <PlaceResult>[];
      final seenIds = <String>{};

      for (final pred in predictions.take(6)) {
        try {
          final placeId = pred['place_id']?.toString();
          final mainText =
              pred['structured_formatting']?['main_text']?.toString() ?? '';
          final secondaryText =
              pred['structured_formatting']?['secondary_text']?.toString() ??
                  '';
          final combined = '$mainText $secondaryText'.toLowerCase();

          if (placeId == null || placeId.isEmpty || mainText.isEmpty) {
            continue;
          }

          if (seenIds.contains(placeId)) continue;

          final looksLikePark = combined.contains('park') ||
              combined.contains('dog') ||
              combined.contains('off leash') ||
              combined.contains('off-leash') ||
              mainText.toLowerCase().contains('park');

          if (!looksLikePark) continue;

          seenIds.add(placeId);

          final detailsUrl =
              'https://maps.googleapis.com/maps/api/place/details/json'
              '?place_id=$placeId'
              '&fields=place_id,name,geometry'
              '&key=$apiKey';

          final detailsResponse = await http.get(Uri.parse(detailsUrl));
          if (detailsResponse.statusCode != 200) continue;

          final detailsJson = jsonDecode(detailsResponse.body);
          if (detailsJson['status'] != 'OK') {
            debugPrint('Place details status: ${detailsJson['status']}');
            continue;
          }

          final result = detailsJson['result'];
          if (result == null) continue;

          final lat = result['geometry']?['location']?['lat'] as num?;
          final lng = result['geometry']?['location']?['lng'] as num?;
          final name = (result['name'] ?? mainText).toString();

          if (lat != null && lng != null) {
            results.add(
              PlaceResult(
                id: placeId,
                name: name,
                latitude: lat.toDouble(),
                longitude: lng.toDouble(),
              ),
            );
          }
        } catch (e) {
          debugPrint('Error processing place result: $e');
        }
      }

      results.sort((a, b) {
        final distA = _distance(location, LatLng(a.latitude, a.longitude));
        final distB = _distance(location, LatLng(b.latitude, b.longitude));
        return distA.compareTo(distB);
      });

      return results;
    } catch (e) {
      debugPrint('Error searching places: $e');
      return [];
    }
  }

  Future<PlaceResult?> _showPlaceResultsModal(List<PlaceResult> results) async {
    return showModalBottomSheet<PlaceResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (modalCtx) {
        final maxHeight = MediaQuery.of(modalCtx).size.height * 0.65;

        return SafeArea(
          child: SizedBox(
            height: maxHeight,
            child: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 20),
              child: Column(
                children: [
                  Container(
                    width: 42,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Select a Park',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.separated(
                      itemCount: results.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, idx) {
                        final place = results[idx];
                        return ListTile(
                          leading: const Icon(
                            Icons.location_on,
                            color: Color(0xFF567D46),
                          ),
                          title: Text(place.name),
                          subtitle: Text(
                            '${place.latitude.toStringAsFixed(4)}, ${place.longitude.toStringAsFixed(4)}',
                          ),
                          onTap: () => Navigator.pop(ctx, place),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showCreateGroupDialog() {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final spotCtrl = TextEditingController();

    bool isPublic = false;
    bool isSaving = false;

    final Map<String, TimeOfDay?> meetingTimes = {
      'Monday': null,
      'Tuesday': null,
      'Wednesday': null,
      'Thursday': null,
      'Friday': null,
      'Saturday': null,
      'Sunday': null,
    };

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return Dialog(
          insetPadding: EdgeInsets.zero,
          child: SizedBox(
            width: double.infinity,
            height: MediaQuery.of(dialogCtx).size.height,
            child: StatefulBuilder(
              builder: (ctx, setLocalState) {
                return Scaffold(
                  appBar: AppBar(
                    elevation: 0,
                    backgroundColor: Colors.transparent,
                    title: const Text('Create A Group'),
                    leading: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(dialogCtx),
                    ),
                  ),
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionTitle('Group Name'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: nameCtrl,
                          decoration: _inputDecoration(
                            hint: 'Enter group name',
                            icon: Icons.groups,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _sectionTitle('Description'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: descCtrl,
                          maxLines: 4,
                          decoration: _inputDecoration(
                            hint: 'What is this group about?',
                            icon: Icons.description,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _sectionTitle('Frequent Meeting Spot'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: spotCtrl,
                          decoration: _inputDecoration(
                            hint: 'e.g., Ellerslie Park',
                            icon: Icons.location_on,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _sectionTitle('Meeting Schedule'),
                        const SizedBox(height: 8),
                        ...meetingTimes.keys.map((day) {
                          final time = meetingTimes[day];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () async {
                                final selectedTime = await showTimePicker(
                                  context: context,
                                  initialTime: time ?? TimeOfDay.now(),
                                );
                                if (selectedTime != null) {
                                  setLocalState(() {
                                    meetingTimes[day] = selectedTime;
                                  });
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                decoration: BoxDecoration(
                                  color: time != null
                                      ? const Color(0xFFEAF6E7)
                                      : const Color(0xFFF6F7F5),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: time != null
                                        ? const Color(0xFF567D46)
                                        : Colors.transparent,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      time != null
                                          ? Icons.check_circle
                                          : Icons.add_circle_outline,
                                      color: time != null
                                          ? const Color(0xFF567D46)
                                          : Colors.grey,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        time == null
                                            ? day
                                            : '$day · ${time.format(context)}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }),
                        const SizedBox(height: 24),
                        _sectionTitle('Privacy'),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF6F7F5),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isPublic ? Icons.public : Icons.lock,
                                color: const Color(0xFF567D46),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  isPublic ? 'Public Group' : 'Private Group',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Switch(
                                value: isPublic,
                                activeThumbColor: const Color(0xFF567D46),
                                onChanged: (v) {
                                  setLocalState(() => isPublic = v);
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 30),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: isSaving
                                ? null
                                : () async {
                                    if (nameCtrl.text.trim().isEmpty) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content:
                                              Text('Please enter a group name'),
                                        ),
                                      );
                                      return;
                                    }

                                    setLocalState(() => isSaving = true);

                                    TimeOfDay? frequentTime;
                                    for (final t in meetingTimes.values) {
                                      if (t != null) {
                                        frequentTime = t;
                                        break;
                                      }
                                    }

                                    await _createGroup(
                                      name: nameCtrl.text.trim(),
                                      description: descCtrl.text.trim(),
                                      isPublic: isPublic,
                                      frequentTime: frequentTime,
                                      frequentPlaceName: spotCtrl.text.trim(),
                                      selectedPlace: null,
                                    );

                                    if (!mounted) return;
                                    if (Navigator.canPop(dialogCtx)) {
                                      Navigator.pop(dialogCtx);
                                    }
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF567D46),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: isSaving
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  )
                                : const Text(
                                    'Create Group',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(dialogCtx),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF567D46),
                              side: const BorderSide(
                                color: Color(0xFF567D46),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: const Text(
                              'Cancel',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: const Color(0xFFF6F7F5),
      prefixIcon: Icon(icon, color: const Color(0xFF567D46)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
    );
  }

  Future<void> _createGroup({
    required String name,
    String? description,
    required bool isPublic,
    TimeOfDay? frequentTime,
    String? frequentPlaceName,
    PlaceResult? selectedPlace,
  }) async {
    if (_currentUserId == null) return;

    try {
      final groupRef = _fs.collection('groups').doc();
      final now = Timestamp.now();

      await groupRef.set({
        'name': name,
        'description': (description ?? '').trim(),
        'createdBy': _currentUserId,
        'admins': [_currentUserId],
        'members': [_currentUserId],
        'frequentPlace': selectedPlace?.id ?? '',
        'frequentPlaceName': selectedPlace?.name ?? (frequentPlaceName ?? ''),
        'frequentTime':
            frequentTime != null ? Group.timeOfDayToString(frequentTime) : null,
        'isPublic': isPublic,
        'latitude': selectedPlace?.latitude,
        'longitude': selectedPlace?.longitude,
        'createdAt': now,
        'updatedAt': now,
      });

      await _fetchMyGroups();
      if (_showingLocalGroups) {
        await _fetchLocalPublicGroups(showSnackOnNoLocation: false);
      }

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Group created!')),
        );
      }
    } catch (e) {
      debugPrint('Error creating group: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating group: $e')),
        );
      }
    }
  }

  Future<void> _joinGroup(Group group) async {
    if (_currentUserId == null) return;

    try {
      await _fs.collection('groups').doc(group.id).update({
        'members': FieldValue.arrayUnion([_currentUserId]),
        'updatedAt': Timestamp.now(),
      });

      await _fetchMyGroups();
      await _fetchLocalPublicGroups(showSnackOnNoLocation: false);

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Joined group!')),
        );
      }
    } catch (e) {
      debugPrint('Error joining group: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error joining group: $e')),
        );
      }
    }
  }

  Future<void> _leaveGroup(String groupId) async {
    if (_currentUserId == null) return;

    try {
      await _fs.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayRemove([_currentUserId]),
        'admins': FieldValue.arrayRemove([_currentUserId]),
        'updatedAt': Timestamp.now(),
      });

      await _fetchMyGroups();
      if (_showingLocalGroups) {
        await _fetchLocalPublicGroups(showSnackOnNoLocation: false);
      }

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Left group')),
        );
      }
    } catch (e) {
      debugPrint('Error leaving group: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error leaving group: $e')),
        );
      }
    }
  }

  Future<void> _deleteGroup(String groupId) async {
    try {
      await _fs.collection('groups').doc(groupId).delete();

      await _fetchMyGroups();
      if (_showingLocalGroups) {
        await _fetchLocalPublicGroups(showSnackOnNoLocation: false);
      }

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Group deleted')),
        );
      }
    } catch (e) {
      debugPrint('Error deleting group: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting group: $e')),
        );
      }
    }
  }

  void _confirmDeleteGroup(String groupId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Group?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _deleteGroup(groupId);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  String _currentUserDisplayName() {
    final user = FirebaseAuth.instance.currentUser;
    final displayName = user?.displayName?.trim() ?? '';
    if (displayName.isNotEmpty) return displayName;
    return 'Unknown';
  }

  void _openGroupChat(Group group) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupChatScreen(
          groupId: group.id,
          groupName: group.name,
          currentUserName: _currentUserDisplayName(),
        ),
      ),
    );
  }

  bool _hasUnread(Group group) {
    final me = _currentUserId;
    final lastMessageAt = group.lastMessageAt;
    final lastSenderId = group.lastMessageSenderId ?? '';

    if (me == null || lastMessageAt == null) return false;
    if (lastSenderId.isEmpty || lastSenderId == me) return false;

    final lastReadAt = _groupLastReadAt[group.id];
    if (lastReadAt == null) return true;

    return lastMessageAt.isAfter(lastReadAt);
  }

  void _openGroupDetailsPage(Group group) {
    if (_currentUserId == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupDetailsPage(
          groupId: group.id,
          currentUserId: _currentUserId!,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _showingLocalGroups
                  ? _buildLocalGroupsList()
                  : _buildMyGroupsList(),
            ),
            _buildBottomActionBar(),
            const AdBanner(),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomActionBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xFFF2F7EE),
        border: Border(
          top: BorderSide(color: Color(0xFFDCE7D6)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _showCreateGroupDialog,
              icon: const Icon(Icons.add),
              label: const Text('Create Group'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF567D46),
                backgroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFF567D46)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () {
                if (!_showingLocalGroups) {
                  _fetchLocalPublicGroups();
                } else {
                  setState(() => _showingLocalGroups = false);
                }
              },
              icon: Icon(
                _showingLocalGroups ? Icons.arrow_back : Icons.location_on,
              ),
              label: Text(
                _showingLocalGroups ? 'My Groups' : 'Local Groups',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF567D46),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMyGroupsList() {
    if (_myGroups.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refreshCurrentView,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 130),
            Icon(Icons.groups, size: 68, color: Colors.grey),
            SizedBox(height: 16),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 30),
              child: Text(
                'You are not in any groups yet.\nCreate one or join a local group to get started.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshCurrentView,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 12, bottom: 12),
        itemCount: _myGroups.length,
        itemBuilder: (ctx, idx) =>
            _buildGroupCard(_myGroups[idx], isMyGroup: true),
      ),
    );
  }

  Widget _buildLocalGroupsList() {
    if (_localPublicGroups.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refreshCurrentView,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 130),
            Icon(Icons.location_searching, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 30),
              child: Text(
                'No public groups nearby',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshCurrentView,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 12, bottom: 12),
        itemCount: _localPublicGroups.length,
        itemBuilder: (ctx, idx) =>
            _buildGroupCard(_localPublicGroups[idx], isMyGroup: false),
      ),
    );
  }

  Widget _buildGroupCard(Group group, {required bool isMyGroup}) {
    final isCreator = group.createdBy == _currentUserId;
    final isAdmin = group.admins.contains(_currentUserId);
    final isMember = group.members.contains(_currentUserId);
    final hasUnread = _hasUnread(group);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white,
        border: Border.all(
          color: const Color(0xFFDCE7D6),
          width: 1.2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF4E5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.groups_rounded,
                    color: Color(0xFF567D46),
                    size: 28,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              group.name,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1E1E1E),
                              ),
                            ),
                          ),
                          if (hasUnread) _buildUnreadChip(),
                        ],
                      ),
                      if ((group.lastMessage ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          group.lastMessage!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[700],
                            fontWeight:
                                hasUnread ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildInfoChip(
                            group.isPublic ? 'Public' : 'Private',
                            group.isPublic ? Icons.public : Icons.lock,
                          ),
                          if (isCreator)
                            _buildRoleChip('Creator', const Color(0xFF2E7D32)),
                          if (!isCreator && isAdmin)
                            _buildRoleChip('Admin', const Color(0xFF567D46)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if ((group.description ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                group.description!,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.4,
                  color: Colors.grey[700],
                ),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                _buildMetaItem(Icons.people, '${group.members.length} members'),
                if (group.frequentTime != null)
                  _buildMetaItem(
                    Icons.access_time,
                    'Meet up time: ${group.frequentTime!.format(context)}',
                  ),
                if ((group.frequentPlaceName ?? '').trim().isNotEmpty)
                  _buildMetaItem(
                    Icons.location_on,
                    group.frequentPlaceName!,
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // Not a member yet, browsing local groups
            if (!isMember && !isMyGroup)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _joinGroup(group),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF567D46),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Join'),
                ),
              ),

            // Member actions
            if (isMember) ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _openGroupChat(group),
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text('Chat'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF567D46),
                        side: const BorderSide(color: Color(0xFF567D46)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _openGroupDetailsPage(group),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF567D46),
                        side: const BorderSide(color: Color(0xFF567D46)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Details'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: isAdmin
                    ? ElevatedButton.icon(
                        onPressed: () => _confirmDeleteGroup(group.id),
                        icon: const Icon(Icons.delete, size: 18),
                        label: const Text('Delete'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      )
                    : ElevatedButton(
                        onPressed: () => _leaveGroup(group.id),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Leave'),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoChip(String label, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5EF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF567D46)),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF567D46),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnreadChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFD32F2F),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        'New',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildRoleChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _buildMetaItem(IconData icon, String value) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.grey[700]),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12.5,
                color: Colors.grey[800],
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class GroupDetailsPage extends StatefulWidget {
  final String groupId;
  final String currentUserId;

  const GroupDetailsPage({
    Key? key,
    required this.groupId,
    required this.currentUserId,
  }) : super(key: key);

  @override
  State<GroupDetailsPage> createState() => _GroupDetailsPageState();
}

class _GroupDetailsPageState extends State<GroupDetailsPage> {
  final FirebaseFirestore _fs = FirebaseFirestore.instance;
  LatLng? _userLocation;

  Future<void> _fetchUserLocation() async {
    try {
      final location = loc.Location();

      bool serviceEnabled = await location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await location.requestService();
        if (!serviceEnabled) return;
      }

      loc.PermissionStatus permissionGranted = await location.hasPermission();
      if (permissionGranted == loc.PermissionStatus.denied) {
        permissionGranted = await location.requestPermission();
      }

      // If your location package does not support grantedLimited,
      // change this back to only check for granted.
      if (permissionGranted != loc.PermissionStatus.granted &&
          permissionGranted != loc.PermissionStatus.grantedLimited) {
        return;
      }

      final user = await location.getLocation();
      if (user.latitude != null && user.longitude != null) {
        _userLocation = LatLng(user.latitude!, user.longitude!);
      }
    } catch (e) {
      debugPrint('Error fetching user location in details page: $e');
    }
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: const Color(0xFFF6F7F5),
      prefixIcon: Icon(icon, color: const Color(0xFF567D46)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
    );
  }

  Future<List<PlaceResult>> _searchPlaces(
    String query,
    LatLng location,
  ) async {
    try {
      final apiKey = dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '';
      if (apiKey.isEmpty) {
        debugPrint('Google Maps API key not found');
        return [];
      }

      final encodedQuery = Uri.encodeComponent(query.trim());
      final predictionsUrl =
          'https://maps.googleapis.com/maps/api/place/autocomplete/json'
          '?input=$encodedQuery'
          '&key=$apiKey'
          '&location=${location.latitude},${location.longitude}'
          '&radius=50000'
          '&language=en'
          '&types=establishment';

      final predictionsResponse = await http.get(Uri.parse(predictionsUrl));
      if (predictionsResponse.statusCode != 200) {
        debugPrint(
          'Autocomplete HTTP error: ${predictionsResponse.statusCode}',
        );
        return [];
      }

      final predictionsJson = jsonDecode(predictionsResponse.body);
      final status = predictionsJson['status'];

      if (status != 'OK' && status != 'ZERO_RESULTS') {
        debugPrint('Autocomplete status: $status');
        debugPrint('Autocomplete response: ${predictionsResponse.body}');
        return [];
      }

      final predictions = predictionsJson['predictions'] as List? ?? [];
      if (predictions.isEmpty) return [];

      final results = <PlaceResult>[];
      final seenIds = <String>{};

      for (final pred in predictions.take(6)) {
        try {
          final placeId = pred['place_id']?.toString();
          final mainText =
              pred['structured_formatting']?['main_text']?.toString() ?? '';
          final secondaryText =
              pred['structured_formatting']?['secondary_text']?.toString() ??
                  '';
          final combined = '$mainText $secondaryText'.toLowerCase();

          if (placeId == null || placeId.isEmpty || mainText.isEmpty) {
            continue;
          }

          if (seenIds.contains(placeId)) continue;

          final looksLikePark = combined.contains('park') ||
              combined.contains('dog') ||
              combined.contains('off leash') ||
              combined.contains('off-leash') ||
              mainText.toLowerCase().contains('park');

          if (!looksLikePark) continue;

          seenIds.add(placeId);

          final detailsUrl =
              'https://maps.googleapis.com/maps/api/place/details/json'
              '?place_id=$placeId'
              '&fields=place_id,name,geometry'
              '&key=$apiKey';

          final detailsResponse = await http.get(Uri.parse(detailsUrl));
          if (detailsResponse.statusCode != 200) continue;

          final detailsJson = jsonDecode(detailsResponse.body);
          if (detailsJson['status'] != 'OK') {
            debugPrint('Place details status: ${detailsJson['status']}');
            continue;
          }

          final result = detailsJson['result'];
          if (result == null) continue;

          final lat = result['geometry']?['location']?['lat'] as num?;
          final lng = result['geometry']?['location']?['lng'] as num?;
          final name = (result['name'] ?? mainText).toString();

          if (lat != null && lng != null) {
            results.add(
              PlaceResult(
                id: placeId,
                name: name,
                latitude: lat.toDouble(),
                longitude: lng.toDouble(),
              ),
            );
          }
        } catch (e) {
          debugPrint('Error processing place result: $e');
        }
      }

      results.sort((a, b) {
        final distA = _distance(location, LatLng(a.latitude, a.longitude));
        final distB = _distance(location, LatLng(b.latitude, b.longitude));
        return distA.compareTo(distB);
      });

      return results;
    } catch (e) {
      debugPrint('Error searching places: $e');
      return [];
    }
  }

  Future<PlaceResult?> _showPlaceResultsModal(List<PlaceResult> results) async {
    return showModalBottomSheet<PlaceResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (modalCtx) {
        final maxHeight = MediaQuery.of(modalCtx).size.height * 0.65;

        return SafeArea(
          child: SizedBox(
            height: maxHeight,
            child: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 20),
              child: Column(
                children: [
                  Container(
                    width: 42,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Select a Park',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.separated(
                      itemCount: results.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, idx) {
                        final place = results[idx];
                        return ListTile(
                          leading: const Icon(
                            Icons.location_on,
                            color: Color(0xFF567D46),
                          ),
                          title: Text(place.name),
                          subtitle: Text(
                            '${place.latitude.toStringAsFixed(4)}, ${place.longitude.toStringAsFixed(4)}',
                          ),
                          onTap: () => Navigator.pop(ctx, place),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  double _distance(LatLng a, LatLng b) {
    const earthRadiusKm = 6371.0;
    final dLat = _toRad(b.latitude - a.latitude);
    final dLng = _toRad(b.longitude - a.longitude);
    final lat1 = _toRad(a.latitude);
    final lat2 = _toRad(b.latitude);

    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);

    final c = 2 * math.asin(math.sqrt(h));
    return earthRadiusKm * c;
  }

  double _toRad(double deg) => deg * math.pi / 180.0;

  Iterable<List<String>> _chunkIds(List<String> ids, {int size = 10}) sync* {
    for (var i = 0; i < ids.length; i += size) {
      final end = i + size > ids.length ? ids.length : i + size;
      yield ids.sublist(i, end);
    }
  }

  Future<Map<String, String>> _loadOwnerNamesByUid(List<String> uids) async {
    final names = <String, String>{};
    if (uids.isEmpty) return names;

    for (final chunk in _chunkIds(uids)) {
      final snap = await _fs
          .collection('public_profiles')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();

      for (final doc in snap.docs) {
        final data = doc.data();
        names[doc.id] = (data['displayName'] ??
                data['name'] ??
                data['firstName'] ??
                data['username'] ??
                'User')
            .toString();
      }
    }

    return names;
  }

  Future<Map<String, Map<String, String>>> _loadPrimaryPetsByOwnerId(
    List<String> ownerIds,
  ) async {
    final petsByOwner =
        <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
    if (ownerIds.isEmpty) return {};

    for (final chunk in _chunkIds(ownerIds)) {
      final snap =
          await _fs.collection('pets').where('ownerId', whereIn: chunk).get();

      for (final doc in snap.docs) {
        final ownerId = (doc.data()['ownerId'] ?? '').toString();
        if (ownerId.isEmpty) continue;
        (petsByOwner[ownerId] ??= []).add(doc);
      }
    }

    final out = <String, Map<String, String>>{};
    for (final ownerId in ownerIds) {
      final petDocs = petsByOwner[ownerId] ?? const [];
      if (petDocs.isEmpty) continue;

      var chosen = petDocs.first;
      for (final doc in petDocs) {
        if (doc.data()['isMain'] == true) {
          chosen = doc;
          break;
        }
      }

      final petData = chosen.data();
      out[ownerId] = {
        'petName': (petData['name'] ?? 'Pet').toString(),
        'photoUrl': (petData['photoUrl'] ?? petData['photo'] ?? '').toString(),
      };
    }

    return out;
  }

  Future<List<Map<String, dynamic>>> _loadGroupMemberProfiles(
    List<String> memberIds,
  ) async {
    final uniqueIds = memberIds.toSet().toList();
    final ownerNames = await _loadOwnerNamesByUid(uniqueIds);
    final petsByOwner = await _loadPrimaryPetsByOwnerId(uniqueIds);

    final results = uniqueIds.map((uid) {
      final pet = petsByOwner[uid] ?? const {};
      return {
        'uid': uid,
        'name': ownerNames[uid] ?? 'User',
        'petName': pet['petName'] ?? 'Pet',
        'photoUrl': pet['photoUrl'] ?? '',
      };
    }).toList();

    results.sort((a, b) {
      final aName = (a['name'] ?? '').toString().toLowerCase();
      final bName = (b['name'] ?? '').toString().toLowerCase();
      return aName.compareTo(bName);
    });

    return results;
  }

  Future<List<GroupPersonOption>> _loadAddablePeople(Group group) async {
    try {
      final friendsSnap = await _fs
          .collection('friends')
          .doc(widget.currentUserId)
          .collection('userFriends')
          .get();

      final friendIds = friendsSnap.docs.map((d) => d.id).toList();
      final availableIds =
          friendIds.where((id) => !group.members.contains(id)).toList();
      final ownerNames = await _loadOwnerNamesByUid(availableIds);
      final petsByOwner = await _loadPrimaryPetsByOwnerId(availableIds);

      final results = availableIds.map((uid) {
        final pet = petsByOwner[uid] ?? const {};
        return GroupPersonOption(
          uid: uid,
          ownerName: ownerNames[uid] ?? 'User',
          petName: pet['petName'] ?? 'Pet',
          petPhotoUrl: pet['photoUrl'] ?? '',
        );
      }).toList();

      results.sort((a, b) {
        final aName = '${a.ownerName} ${a.petName}'.toLowerCase();
        final bName = '${b.ownerName} ${b.petName}'.toLowerCase();
        return aName.compareTo(bName);
      });

      return results;
    } catch (e) {
      debugPrint('Error loading addable people: $e');
      return [];
    }
  }

  Future<void> _showAddPeopleDialog(Group group) async {
    final people = await _loadAddablePeople(group);

    if (!mounted) return;

    if (people.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No available people to add')),
      );
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.72,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Add People',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView.separated(
                    itemCount: people.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, idx) {
                      final person = people[idx];

                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        leading: CircleAvatar(
                          radius: 26,
                          backgroundColor: const Color(0xFFEAF4E5),
                          backgroundImage: person.petPhotoUrl.isNotEmpty
                              ? NetworkImage(person.petPhotoUrl)
                              : null,
                          child: person.petPhotoUrl.isEmpty
                              ? const Icon(
                                  Icons.pets,
                                  color: Color(0xFF567D46),
                                )
                              : null,
                        ),
                        title: Text(
                          person.ownerName,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text('Pet: ${person.petName}'),
                        trailing: ElevatedButton(
                          onPressed: () async {
                            try {
                              await _fs
                                  .collection('groups')
                                  .doc(group.id)
                                  .update({
                                'members': FieldValue.arrayUnion([person.uid]),
                                'updatedAt': Timestamp.now(),
                              });

                              if (!mounted) return;

                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${person.ownerName} and ${person.petName} added',
                                  ),
                                ),
                              );
                            } catch (e) {
                              debugPrint('Error adding member: $e');
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Error adding member: $e'),
                                  ),
                                );
                              }
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF567D46),
                            foregroundColor: Colors.white,
                            elevation: 0,
                          ),
                          child: const Text('Add'),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showEditGroupDialog(
    Group group, {
    String? existingFrequentPlaceId,
  }) async {
    final nameCtrl = TextEditingController(text: group.name);
    final descCtrl = TextEditingController(text: group.description ?? '');
    final spotCtrl = TextEditingController(text: group.frequentPlaceName ?? '');

    bool isPublic = group.isPublic;
    bool isSaving = false;

    TimeOfDay? selectedTime = group.frequentTime;
    double? selectedLatitude = group.latitude;
    double? selectedLongitude = group.longitude;
    String selectedPlaceId = existingFrequentPlaceId ?? '';

    await showDialog(
      context: context,
      builder: (dialogCtx) {
        return Dialog(
          insetPadding: EdgeInsets.zero,
          child: SizedBox(
            width: double.infinity,
            height: MediaQuery.of(dialogCtx).size.height,
            child: StatefulBuilder(
              builder: (ctx, setLocalState) {
                return Scaffold(
                  appBar: AppBar(
                    elevation: 0,
                    backgroundColor: Colors.transparent,
                    title: const Text('Edit Group Details'),
                    leading: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(dialogCtx),
                    ),
                  ),
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionTitle('Group Name'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: nameCtrl,
                          decoration: _inputDecoration(
                            hint: 'Enter group name',
                            icon: Icons.groups,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _sectionTitle('Description'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: descCtrl,
                          maxLines: 4,
                          decoration: _inputDecoration(
                            hint: 'What is this group about?',
                            icon: Icons.description,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _sectionTitle('Frequent Meeting Spot'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: spotCtrl,
                          onChanged: (_) {
                            setLocalState(() {
                              selectedPlaceId = '';
                              selectedLatitude = null;
                              selectedLongitude = null;
                            });
                          },
                          decoration: _inputDecoration(
                            hint: 'e.g., Ellerslie Park',
                            icon: Icons.location_on,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _sectionTitle('Meet Up Time'),
                        const SizedBox(height: 8),
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () async {
                            final picked = await showTimePicker(
                              context: context,
                              initialTime: selectedTime ?? TimeOfDay.now(),
                            );
                            if (picked != null) {
                              setLocalState(() {
                                selectedTime = picked;
                              });
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: selectedTime != null
                                  ? const Color(0xFFEAF6E7)
                                  : const Color(0xFFF6F7F5),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: selectedTime != null
                                    ? const Color(0xFF567D46)
                                    : Colors.transparent,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  selectedTime != null
                                      ? Icons.check_circle
                                      : Icons.access_time,
                                  color: selectedTime != null
                                      ? const Color(0xFF567D46)
                                      : Colors.grey,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    selectedTime == null
                                        ? 'Pick meet up time'
                                        : 'Meet up time: ${selectedTime!.format(context)}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        _sectionTitle('Privacy'),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF6F7F5),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isPublic ? Icons.public : Icons.lock,
                                color: const Color(0xFF567D46),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  isPublic ? 'Public Group' : 'Private Group',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Switch(
                                value: isPublic,
                                activeThumbColor: const Color(0xFF567D46),
                                onChanged: (v) {
                                  setLocalState(() => isPublic = v);
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 30),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: isSaving
                                ? null
                                : () async {
                                    if (nameCtrl.text.trim().isEmpty) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Please enter a group name',
                                          ),
                                        ),
                                      );
                                      return;
                                    }

                                    setLocalState(() => isSaving = true);

                                    try {
                                      await _fs
                                          .collection('groups')
                                          .doc(group.id)
                                          .update({
                                        'name': nameCtrl.text.trim(),
                                        'description': descCtrl.text.trim(),
                                        'frequentPlace': selectedPlaceId,
                                        'frequentPlaceName':
                                            spotCtrl.text.trim(),
                                        'frequentTime': selectedTime != null
                                            ? Group.timeOfDayToString(
                                                selectedTime!)
                                            : null,
                                        'isPublic': isPublic,
                                        'latitude': selectedLatitude,
                                        'longitude': selectedLongitude,
                                        'updatedAt': Timestamp.now(),
                                      });

                                      if (!mounted) return;

                                      Navigator.pop(dialogCtx);
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content:
                                              Text('Group details updated'),
                                        ),
                                      );
                                    } catch (e) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Error updating group: $e',
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF567D46),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: isSaving
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  )
                                : const Text(
                                    'Save Changes',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(dialogCtx),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF567D46),
                              side: const BorderSide(
                                color: Color(0xFF567D46),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: const Text(
                              'Cancel',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _promoteToAdmin(Group group, String uid) async {
    try {
      await _fs.collection('groups').doc(group.id).update({
        'admins': FieldValue.arrayUnion([uid]),
        'updatedAt': Timestamp.now(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('User promoted to admin')),
        );
      }
    } catch (e) {
      debugPrint('Error promoting admin: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error promoting admin: $e')),
        );
      }
    }
  }

  Future<void> _revokeAdmin(Group group, String uid) async {
    try {
      await _fs.collection('groups').doc(group.id).update({
        'admins': FieldValue.arrayRemove([uid]),
        'updatedAt': Timestamp.now(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Admin access removed')),
        );
      }
    } catch (e) {
      debugPrint('Error removing admin: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error removing admin: $e')),
        );
      }
    }
  }

  Future<void> _removeMember(Group group, String uid) async {
    try {
      await _fs.collection('groups').doc(group.id).update({
        'members': FieldValue.arrayRemove([uid]),
        'admins': FieldValue.arrayRemove([uid]),
        'updatedAt': Timestamp.now(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Member removed')),
        );
      }
    } catch (e) {
      debugPrint('Error removing member: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error removing member: $e')),
        );
      }
    }
  }

  Widget _detailsChip(String text, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5EF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF567D46)),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF567D46),
            ),
          ),
        ],
      ),
    );
  }

  Widget _memberTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Group Details'),
        actions: [
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _fs.collection('groups').doc(widget.groupId).snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData || !snapshot.data!.exists) {
                return const SizedBox.shrink();
              }

              final group = Group.fromFirestore(snapshot.data!);
              final isAdmin = group.admins.contains(widget.currentUserId);
              final rawData = snapshot.data!.data() ?? {};
              final existingFrequentPlaceId =
                  (rawData['frequentPlace'] ?? '').toString();

              if (!isAdmin) return const SizedBox.shrink();

              return IconButton(
                icon: const Icon(Icons.edit),
                tooltip: 'Edit Details',
                onPressed: () => _showEditGroupDialog(
                  group,
                  existingFrequentPlaceId: existingFrequentPlaceId,
                ),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _fs.collection('groups').doc(widget.groupId).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }

          final group = Group.fromFirestore(snapshot.data!);
          final isCreator = group.createdBy == widget.currentUserId;
          final isAdmin = group.admins.contains(widget.currentUserId);

          return FutureBuilder<List<Map<String, dynamic>>>(
            future: _loadGroupMemberProfiles(group.members),
            builder: (context, memberSnapshot) {
              final members = memberSnapshot.data ?? [];

              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    group.name,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _detailsChip(
                        group.isPublic ? 'Public' : 'Private',
                        group.isPublic ? Icons.public : Icons.lock,
                      ),
                      _detailsChip(
                        '${group.members.length} members',
                        Icons.people,
                      ),
                      if ((group.frequentPlaceName ?? '').trim().isNotEmpty)
                        _detailsChip(
                          group.frequentPlaceName!,
                          Icons.location_on,
                        ),
                      if (group.frequentTime != null)
                        _detailsChip(
                          'Meet up time: ${group.frequentTime!.format(context)}',
                          Icons.access_time,
                        ),
                    ],
                  ),
                  if ((group.description ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      group.description!,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[700],
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Text(
                        'Members',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      if (isAdmin)
                        ElevatedButton.icon(
                          onPressed: () => _showAddPeopleDialog(group),
                          icon: const Icon(Icons.person_add_alt_1),
                          label: const Text('Add People'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF567D46),
                            foregroundColor: Colors.white,
                            elevation: 0,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (memberSnapshot.connectionState == ConnectionState.waiting)
                    const Center(child: CircularProgressIndicator())
                  else
                    ...members.map((member) {
                      final uid = member['uid'].toString();
                      final name = member['name'].toString();
                      final petName = (member['petName'] ?? 'Pet').toString();
                      final photoUrl = member['photoUrl'].toString();

                      final memberIsCreator = uid == group.createdBy;
                      final memberIsAdmin = group.admins.contains(uid);

                      final canPromote = isAdmin && !memberIsAdmin;
                      final canRevokeAdmin =
                          isCreator && memberIsAdmin && !memberIsCreator;
                      final canRemove = isAdmin &&
                          !memberIsCreator &&
                          (!memberIsAdmin || isCreator);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAF7),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFE3E9DF)),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 24,
                              backgroundColor: const Color(0xFFE6F0E1),
                              backgroundImage: photoUrl.isNotEmpty
                                  ? NetworkImage(photoUrl)
                                  : null,
                              child: photoUrl.isEmpty
                                  ? Text(
                                      name.isNotEmpty
                                          ? name[0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                        color: Color(0xFF567D46),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    uid == widget.currentUserId
                                        ? '$name (You)'
                                        : name,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Pet: $petName',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Colors.grey[700],
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: [
                                          if (memberIsCreator)
                                            _memberTag(
                                              'Creator',
                                              const Color(0xFF2E7D32),
                                            ),
                                          if (memberIsAdmin && !memberIsCreator)
                                            _memberTag(
                                              'Admin',
                                              const Color(0xFF567D46),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (value) async {
                                if (value == 'promote') {
                                  await _promoteToAdmin(group, uid);
                                } else if (value == 'revoke_admin') {
                                  await _revokeAdmin(group, uid);
                                } else if (value == 'remove_member') {
                                  await _removeMember(group, uid);
                                }
                              },
                              itemBuilder: (_) {
                                final items = <PopupMenuEntry<String>>[];

                                if (canPromote) {
                                  items.add(
                                    const PopupMenuItem(
                                      value: 'promote',
                                      child: Text('Make Admin'),
                                    ),
                                  );
                                }

                                if (canRevokeAdmin) {
                                  items.add(
                                    const PopupMenuItem(
                                      value: 'revoke_admin',
                                      child: Text('Remove Admin'),
                                    ),
                                  );
                                }

                                if (canRemove) {
                                  items.add(
                                    const PopupMenuItem(
                                      value: 'remove_member',
                                      child: Text('Remove From Group'),
                                    ),
                                  );
                                }

                                if (items.isEmpty) {
                                  items.add(
                                    const PopupMenuItem(
                                      enabled: false,
                                      value: 'none',
                                      child: Text('No actions available'),
                                    ),
                                  );
                                }

                                return items;
                              },
                            ),
                          ],
                        ),
                      );
                    }),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
