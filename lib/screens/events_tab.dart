// events_tab.dart (optimized)
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:inthepark/models/park_event.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:location/location.dart' as loc;
import 'package:intl/intl.dart';
import 'package:inthepark/screens/chatroom_screen.dart';
import 'package:inthepark/widgets/ad_banner.dart';

class EventsTab extends StatefulWidget {
  final String? parkIdFilter;
  const EventsTab({Key? key, this.parkIdFilter}) : super(key: key);

  @override
  State<EventsTab> createState() => _EventsTabState();
}

class _EventsTabState extends State<EventsTab> {
  // UI / state
  bool _isLoading = true;
  bool _isPaging = false;
  bool _hasMore = true;
  final int _pageSize = 40;

  // Data
  final List<ParkEvent> _allEvents = [];
  List<ParkEvent> _filteredEvents = [];
  String _searchQuery = "";
  String _filterMode = "All"; // or 'Liked'

  // Location
  loc.LocationData? _userLocation;

  // Scrolling / pagination
  final ScrollController _scrollController = ScrollController();
  DocumentSnapshot? _lastDoc;

  // Debounce search / park query lists
  Timer? _searchDebounce;

  // “Other nearby” anchor
  final GlobalKey otherEventsKey = GlobalKey();
  bool _showOtherEventsClicked = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _init();
  }

  Future<void> _init() async {
    await _fetchUserLocation();
    await _fetchEvents(reset: true);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  // ---------- Location ----------
  Future<void> _fetchUserLocation() async {
    try {
      final location = loc.Location();
      bool serviceEnabled = await location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await location.requestService();
        if (!serviceEnabled) return;
      }
      var permissionGranted = await location.hasPermission();
      if (permissionGranted == loc.PermissionStatus.denied) {
        permissionGranted = await location.requestPermission();
        if (permissionGranted != loc.PermissionStatus.granted) return;
      }
      final locData = await location.getLocation();
      if (!mounted) return;
      setState(() => _userLocation = locData);
    } catch (e) {
      debugPrint("Error fetching user location in EventsTab: $e");
    }
  }

  // ---------- Distance ----------
  double _computeDistanceKm(
      double lat1, double lng1, double lat2, double lng2) {
    // Haversine (km)
    const earth = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLng = _degToRad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degToRad(lat1)) *
            cos(_degToRad(lat2)) *
            sin(dLng / 2) *
            sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earth * c;
  }

  double _degToRad(double deg) => deg * (pi / 180);

  // ---------- Firestore fetch (paged) ----------
  Future<void> _fetchEvents({bool reset = false}) async {
    if (_isPaging || (!_hasMore && !reset)) return;

    if (reset) {
      setState(() {
        _isLoading = true;
        _isPaging = false;
        _hasMore = true;
        _lastDoc = null;
        _allEvents.clear();
      });
    } else {
      setState(() => _isPaging = true);
    }

    try {
      final now = DateTime.now();

      Query baseQuery;
      if (widget.parkIdFilter != null) {
        baseQuery = FirebaseFirestore.instance
            .collection('parks')
            .doc(widget.parkIdFilter)
            .collection('events');
      } else {
        baseQuery = FirebaseFirestore.instance.collectionGroup('events');
      }

      // We page by createdAt for consistency and speed. (Make sure you write createdAt when adding)
      Query q =
          baseQuery.orderBy('createdAt', descending: true).limit(_pageSize);
      if (_lastDoc != null) q = q.startAfterDocument(_lastDoc!);

      final snap = await q.get();
      if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;

      // Map -> model
      final fetched =
          snap.docs.map((d) => ParkEvent.fromFirestore(d)).where((e) {
        // Keep recurring; keep one-time if in the future
        final keepRecurring = e.recurrence != "One Time";
        final keepUpcoming = e.endDateTime.isAfter(now);
        return keepRecurring || keepUpcoming;
      }).toList();

      // If no park filter and we have a user location, keep only within 1km
      if (widget.parkIdFilter == null && _userLocation != null) {
        final ulat = _userLocation!.latitude!, ulng = _userLocation!.longitude!;
        _allEvents.addAll(fetched.where((e) =>
            _computeDistanceKm(ulat, ulng, e.parkLatitude, e.parkLongitude) <=
            1.0));
      } else {
        _allEvents.addAll(fetched);
      }

      // De-dupe if any accidental repeats across pages (by composite key)
      final seen = <String>{};
      _allEvents.retainWhere((e) {
        final key = "${e.parkId}_${e.id}";
        if (seen.contains(key)) return false;
        seen.add(key);
        return true;
      });

      _applySearchFilter();
      setState(() {
        _isLoading = false;
        _isPaging = false;
        _hasMore = snap.docs.length == _pageSize;
      });
    } catch (e) {
      debugPrint("Error fetching events: $e");
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isPaging = false;
      });
    }
  }

  void _onScroll() {
    if (!_hasMore || _isPaging || _isLoading) return;
    if (_scrollController.position.pixels >
        _scrollController.position.maxScrollExtent - 400) {
      _fetchEvents();
    }
  }

  // ---------- Client filter / search ----------
  void _applySearchFilter() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final q = _searchQuery.trim().toLowerCase();

    Iterable<ParkEvent> list = _allEvents;
    if (q.isNotEmpty) {
      list = list.where((e) => e.name.toLowerCase().contains(q));
    }
    if (_filterMode == "Liked" && uid != null) {
      list = list.where((e) => e.likes.contains(uid));
    }

    // Sort: liked first (if signed in), then by start time ascending
    final likedSet = <String>{};
    if (uid != null) likedSet.add(uid);

    final sorted = list.toList()
      ..sort((a, b) {
        final aLiked = uid != null && a.likes.contains(uid);
        final bLiked = uid != null && b.likes.contains(uid);
        if (aLiked != bLiked) return aLiked ? -1 : 1;
        return a.startDateTime.compareTo(b.startDateTime);
      });

    if (!mounted) return;
    setState(() => _filteredEvents = sorted);
  }

  // ---------- Likes ----------
  Future<void> _toggleLike(ParkEvent event) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final nestedRef = FirebaseFirestore.instance
        .collection('parks')
        .doc(event.parkId)
        .collection('events')
        .doc(event.id);

    try {
      final liked = event.likes.contains(uid);
      await nestedRef.update({
        'likes':
            liked ? FieldValue.arrayRemove([uid]) : FieldValue.arrayUnion([uid])
      });
      setState(() => liked ? event.likes.remove(uid) : event.likes.add(uid));
      _applySearchFilter();
    } catch (_) {
      // Fallback: in case some old events live in root 'events' (legacy)
      final rootRef =
          FirebaseFirestore.instance.collection('events').doc(event.id);
      try {
        final liked = event.likes.contains(uid);
        await rootRef.update({
          'likes': liked
              ? FieldValue.arrayRemove([uid])
              : FieldValue.arrayUnion([uid])
        });
        setState(() => liked ? event.likes.remove(uid) : event.likes.add(uid));
        _applySearchFilter();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Unable to update like: $e")),
        );
      }
    }
  }

  Future<void> _showLikesDialog(ParkEvent event) async {
    final userIds = event.likes;
    final petList = <Map<String, dynamic>>[];
    try {
      // Firestore whereIn cap: 10 per query — chunk it
      for (var i = 0; i < userIds.length; i += 10) {
        final chunk = userIds.sublist(i, (i + 10).clamp(0, userIds.length));
        final snapshots = await FirebaseFirestore.instance
            .collection('pets')
            .where('ownerId', whereIn: chunk)
            .get();
        petList.addAll(snapshots.docs.map((d) => d.data()));
      }
    } catch (e) {
      debugPrint("Error loading likes pets: $e");
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Liked by'),
        content: SizedBox(
          width: double.maxFinite,
          child: petList.isEmpty
              ? const Text('No likes yet.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: petList.length,
                  itemBuilder: (_, i) {
                    final pet = petList[i];
                    final photo = (pet['photoUrl'] ?? '') as String;
                    return ListTile(
                      leading: (photo.isNotEmpty)
                          ? CircleAvatar(backgroundImage: NetworkImage(photo))
                          : const CircleAvatar(
                              child: Icon(Icons.pets),
                            ),
                      title: Text((pet['name'] ?? 'Unknown') as String),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'))
        ],
      ),
    );
  }

  // ---------- Add Event ----------
  void _showAddEventDialog() async {
    final TextEditingController eventNameController = TextEditingController();
    final TextEditingController eventDescController = TextEditingController();
    final TextEditingController parkSearchController = TextEditingController();
    String? selectedRecurrence = "One Time";
    DateTime? oneTimeDate;
    DateTime? monthlyDate;
    String? selectedWeekday;
    TimeOfDay? selectedStartTime;
    TimeOfDay? selectedEndTime;

    Map<String, dynamic>? selectedPark;
    List<Map<String, dynamic>> parkResults = [];
    Timer? parkSearchDebounce;
    bool isSearchingParks = false;

    Future<void> searchParks(String query) async {
      if (query.isEmpty) {
        parkResults = [];
        return;
      }
      isSearchingParks = true;
      final qs = await FirebaseFirestore.instance
          .collection('parks')
          .where('name', isGreaterThanOrEqualTo: query)
          .where('name', isLessThanOrEqualTo: '$query\uf8ff')
          .limit(20)
          .get();

      final userLat = _userLocation?.latitude;
      final userLng = _userLocation?.longitude;

      parkResults = qs.docs.map((d) {
        final data = d.data();
        data['id'] = d.id;
        return data;
      }).toList();

      // Sort by distance if we have location
      if (userLat != null && userLng != null) {
        parkResults.sort((a, b) {
          final da = sqrt(pow((a['latitude'] - userLat), 2) +
              pow((a['longitude'] - userLng), 2));
          final db = sqrt(pow((b['latitude'] - userLat), 2) +
              pow((b['longitude'] - userLng), 2));
          return da.compareTo(db);
        });
      }

      isSearchingParks = false;
    }

    if (!mounted) return;
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text("Select Park *",
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: parkSearchController,
                        decoration: const InputDecoration(
                          labelText: "Search for a park",
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        onChanged: (value) {
                          parkSearchDebounce?.cancel();
                          parkSearchDebounce = Timer(
                              const Duration(milliseconds: 300), () async {
                            setState(() => isSearchingParks = true);
                            await searchParks(value);
                            if (context.mounted) setState(() {});
                          });
                        },
                      ),
                      if (parkSearchController.text.isNotEmpty)
                        Container(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: isSearchingParks
                              ? const Center(
                                  child: Padding(
                                  padding: EdgeInsets.all(8.0),
                                  child: CircularProgressIndicator(),
                                ))
                              : ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: parkResults.length,
                                  itemBuilder: (ctx, idx) {
                                    final park = parkResults[idx];
                                    return ListTile(
                                      title: Text(park['name'] ?? ''),
                                      subtitle: park['address'] != null
                                          ? Text(park['address'])
                                          : null,
                                      selected:
                                          selectedPark?['id'] == park['id'],
                                      onTap: () {
                                        setState(() {
                                          selectedPark = park;
                                          parkSearchController.text =
                                              park['name'];
                                          parkResults = [];
                                        });
                                      },
                                    );
                                  },
                                ),
                        ),
                      if (selectedPark != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 8),
                          child: Row(
                            children: [
                              const Icon(Icons.park,
                                  color: Colors.green, size: 18),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  selectedPark!['name'] ?? '',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 16),
                      const Text("Event Name *",
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: eventNameController,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: "Event Name",
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text("Description",
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: eventDescController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: "Description",
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        value: selectedRecurrence,
                        decoration: const InputDecoration(
                          labelText: "Recurrence",
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        items: const ["One Time", "Daily", "Weekly", "Monthly"]
                            .map((v) =>
                                DropdownMenuItem(value: v, child: Text(v)))
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
                            alignLabelWithHint: true,
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
                              .map((day) => DropdownMenuItem(
                                  value: day, child: Text(day)))
                              .toList(),
                          onChanged: (String? v) =>
                              setState(() => selectedWeekday = v),
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
                              final t = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.now(),
                              );
                              if (t != null) {
                                setState(() => selectedStartTime = t);
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
                              final t = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.now(),
                              );
                              if (t != null) {
                                setState(() => selectedEndTime = t);
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

                              if (selectedPark == null ||
                                  eventName.isEmpty ||
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

                              final now = DateTime.now();
                              late DateTime eventStartDateTime;
                              late DateTime eventEndDateTime;

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
                                // Daily / Weekly base time for today
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

                              final eventData = <String, dynamic>{
                                'parkId': selectedPark!['id'],
                                'parkLatitude': selectedPark!['latitude'],
                                'parkLongitude': selectedPark!['longitude'],
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

                              // Write under parks/{parkId}/events for consistency
                              await FirebaseFirestore.instance
                                  .collection('parks')
                                  .doc(selectedPark!['id'])
                                  .collection('events')
                                  .add(eventData);

                              if (!mounted) return;
                              Navigator.of(context).pop();
                              await _fetchEvents(reset: true);
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

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final likedEvents = _filteredEvents
        .where((e) => uid != null && e.likes.contains(uid))
        .toList();
    final otherEvents = _filteredEvents
        .where((e) => uid == null || !e.likes.contains(uid))
        .toList();

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            hintText: 'Search by event name',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) {
                            _searchDebounce?.cancel();
                            _searchDebounce =
                                Timer(const Duration(milliseconds: 200), () {
                              _searchQuery = v;
                              _applySearchFilter();
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.filter_list),
                        onSelected: (v) {
                          _filterMode = v;
                          _applySearchFilter();
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'All', child: Text('All Events')),
                          PopupMenuItem(
                              value: 'Liked', child: Text('Liked Events')),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : RefreshIndicator(
                          onRefresh: () => _fetchEvents(reset: true),
                          child: ListView(
                            controller: _scrollController,
                            padding: const EdgeInsets.only(
                                bottom: 120, left: 8, right: 8, top: 8),
                            children: [
                              if (likedEvents.isNotEmpty) ...[
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 8),
                                  child: Text('Liked Events',
                                      style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold)),
                                ),
                                ...likedEvents.map(
                                  (e) => _eventCard(e, isFavorite: true),
                                ),
                                const Divider(),
                              ],
                              Padding(
                                key: otherEventsKey,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                child: const Text('Other Nearby Events',
                                    style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold)),
                              ),
                              ...otherEvents.map((e) => _eventCard(e)),
                              if (_isPaging) ...[
                                const SizedBox(height: 12),
                                const Center(
                                    child: CircularProgressIndicator()),
                                const SizedBox(height: 12),
                              ],
                              if (!_isPaging &&
                                  !_hasMore &&
                                  _filteredEvents.isNotEmpty)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: Center(child: Text("No more events")),
                                ),
                              if (likedEvents.isEmpty && otherEvents.isEmpty)
                                Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 32),
                                    child: Text(
                                      _userLocation != null
                                          ? "There are no events within 1 km from you."
                                          : "No events found.",
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(fontSize: 16),
                                    ),
                                  ),
                                ),
                              if (likedEvents.isNotEmpty) ...[
                                Center(
                                  child: TextButton(
                                    child:
                                        const Text("Show Other Nearby Events"),
                                    onPressed: () {
                                      setState(() {
                                        _showOtherEventsClicked = true;
                                      });
                                      final ctx = otherEventsKey.currentContext;
                                      if (ctx != null) {
                                        Scrollable.ensureVisible(ctx,
                                            duration: const Duration(
                                                milliseconds: 400));
                                      }
                                    },
                                  ),
                                ),
                              ],
                              if (_showOtherEventsClicked &&
                                  otherEvents.isEmpty)
                                const Center(
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(vertical: 32),
                                    child: Text(
                                      "There are no other events within 1 km. Use the + button to add one.",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(fontSize: 16),
                                    ),
                                  ),
                                ),
                            ],
                          ),
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

  // ---------- Widgets ----------
  Widget _eventCard(ParkEvent event, {bool isFavorite = false}) {
    final start = DateFormat('h:mm a').format(event.startDateTime);
    final end = DateFormat('h:mm a').format(event.endDateTime);
    final currentUser = FirebaseAuth.instance.currentUser;
    final liked = currentUser != null && event.likes.contains(currentUser.uid);
    final cardColor = isFavorite ? Colors.green.shade50 : null;
    final isCreator = currentUser != null && event.createdBy == currentUser.uid;

    return Card(
      color: cardColor,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(event.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.bold)),
                      ),
                      if (isFavorite)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child:
                              Icon(Icons.star, size: 16, color: Colors.amber),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(liked ? Icons.favorite : Icons.favorite_border),
                  color: liked ? Colors.green : Colors.grey,
                  onPressed: () => _toggleLike(event),
                ),
                if (isCreator)
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    tooltip: "Delete Event",
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text("Delete Event"),
                          content: const Text(
                              "Are you sure you want to delete this event?"),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text("Cancel"),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text("Delete"),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        // Try nested path first, fallback to root (legacy)
                        try {
                          await FirebaseFirestore.instance
                              .collection('parks')
                              .doc(event.parkId)
                              .collection('events')
                              .doc(event.id)
                              .delete();
                        } catch (_) {
                          await FirebaseFirestore.instance
                              .collection('events')
                              .doc(event.id)
                              .delete();
                        }
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Event deleted")),
                        );
                        _fetchEvents(reset: true);
                      }
                    },
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Time: $start - $end', style: const TextStyle(fontSize: 12)),
            Text('Recurrence: ${event.recurrence}',
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ChatRoomScreen(parkId: event.parkId)),
                  ),
                  icon: const Icon(Icons.chat, size: 14),
                  label:
                      const Text('Park Chat', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: () => _showLikesDialog(event),
                  child: Text('${event.likes.length} likes',
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
