// events_tab.dart
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
  _EventsTabState createState() => _EventsTabState();
}

class _EventsTabState extends State<EventsTab> {
  bool _isLoading = true;
  List<ParkEvent> _allEvents = [];
  List<ParkEvent> _filteredEvents = [];
  String _searchQuery = "";
  String _filterMode = "All";
  loc.LocationData? _userLocation;

  @override
  void initState() {
    super.initState();
    _fetchUserLocation().then((_) => _fetchEvents());
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
        if (permissionGranted != loc.PermissionStatus.granted) return;
      }
      final locData = await location.getLocation();
      setState(() => _userLocation = locData);
    } catch (e) {
      print("Error fetching user location in EventsTab: $e");
    }
  }

  double _computeDistance(double lat1, double lng1, double lat2, double lng2) {
    const earthRadius = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLng = _degToRad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degToRad(lat1)) *
            cos(_degToRad(lat2)) *
            sin(dLng / 2) *
            sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  double _degToRad(double deg) => deg * (pi / 180);

  Future<void> _fetchEvents() async {
    setState(() => _isLoading = true);
    try {
      Query query;
      if (widget.parkIdFilter != null) {
        query = FirebaseFirestore.instance
            .collection('parks')
            .doc(widget.parkIdFilter)
            .collection('events');
      } else {
        query = FirebaseFirestore.instance.collectionGroup('events');
      }
      final snapshot = await query.get();
      final now = DateTime.now();
      final events = snapshot.docs
          .map((doc) => ParkEvent.fromFirestore(doc))
          .where(
              (e) => e.recurrence != "One Time" || e.endDateTime.isAfter(now))
          .toList();

      if (widget.parkIdFilter == null && _userLocation != null) {
        _allEvents = events
            .where((e) =>
                _computeDistance(
                    _userLocation!.latitude!,
                    _userLocation!.longitude!,
                    e.parkLatitude,
                    e.parkLongitude) <=
                1.0)
            .toList();
      } else {
        _allEvents = events;
      }

      _applySearchFilter();
    } catch (e) {
      print("Error fetching events: $e");
      setState(() => _isLoading = false);
    }
    setState(() => _isLoading = false);
  }

  void _applySearchFilter() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    var list = _allEvents.where(
        (e) => e.name.toLowerCase().contains(_searchQuery.toLowerCase()));
    if (_filterMode == "Liked" && uid != null) {
      list = list.where((e) => e.likes.contains(uid));
    }
    list = list.toList()
      ..sort((a, b) {
        final aLiked = uid != null && a.likes.contains(uid);
        final bLiked = uid != null && b.likes.contains(uid);
        if (aLiked && !bLiked) return -1;
        if (!aLiked && bLiked) return 1;
        return a.startDateTime.compareTo(b.startDateTime);
      });
    setState(() => _filteredEvents = list.toList());
  }

  Future<void> _toggleLike(ParkEvent event) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final ref = FirebaseFirestore.instance
        .collection('parks')
        .doc(event.parkId)
        .collection('events')
        .doc(event.id);
    final liked = event.likes.contains(uid);
    await ref.update({
      'likes':
          liked ? FieldValue.arrayRemove([uid]) : FieldValue.arrayUnion([uid])
    });
    setState(() => liked ? event.likes.remove(uid) : event.likes.add(uid));
    _applySearchFilter();
  }

  void _showLikesDialog(ParkEvent event) async {
    final userIds = event.likes;
    final petList = <Map<String, dynamic>>[];
    if (userIds.isNotEmpty) {
      final snapshots = await FirebaseFirestore.instance
          .collection('pets')
          .where('ownerId', whereIn: userIds)
          .get();
      petList.addAll(snapshots.docs.map((d) => d.data()));
    }
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
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: NetworkImage(pet['photoUrl']),
                      ),
                      title: Text(pet['name']),
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
    bool isSearchingParks = false;

    Future<void> searchParks(String query) async {
      if (query.isEmpty) {
        parkResults = [];
        return;
      }
      isSearchingParks = true;
      final snapshot = await FirebaseFirestore.instance
          .collection('parks')
          .where('name', isGreaterThanOrEqualTo: query)
          .where('name', isLessThanOrEqualTo: query + '\uf8ff')
          .limit(10)
          .get();
      parkResults = snapshot.docs.map((d) {
        final data = d.data();
        data['id'] = d.id;
        return data;
      }).toList();
      isSearchingParks = false;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return Scaffold(
          /*   appBar: AppBar(
            title: const Text("Add Event"),
            backgroundColor: const Color(0xFF567D46),
            automaticallyImplyLeading: false,
            actions: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),*/
          body: StatefulBuilder(
            builder: (context, setState) {
              return Padding(
                padding: const EdgeInsets.all(24.0),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start, // <-- left align labels
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "Select Park *",
                        style: TextStyle(fontWeight: FontWeight.w600),
                        textAlign: TextAlign.left,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: parkSearchController,
                        decoration: const InputDecoration(
                          labelText: "Search for a park",
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        onChanged: (value) async {
                          setState(() => isSearchingParks = true);
                          await searchParks(value);
                          setState(() {});
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
                      const Text(
                        "Event Name *",
                        style: TextStyle(fontWeight: FontWeight.w600),
                        textAlign: TextAlign.left,
                      ),
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
                      const Text(
                        "Description",
                        style: TextStyle(fontWeight: FontWeight.w600),
                        textAlign: TextAlign.left,
                      ),
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
                            alignLabelWithHint: true,
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

                              await FirebaseFirestore.instance
                                  .collection('events')
                                  .add(eventData);

                              Navigator.of(context).pop();
                              _fetchEvents();
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
                          onChanged: (v) => setState(() {
                            _searchQuery = v;
                            _applySearchFilter();
                          }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.filter_list),
                        onSelected: (v) => setState(() {
                          _filterMode = v;
                          _applySearchFilter();
                        }),
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
                          onRefresh: _fetchEvents,
                          child: ListView(
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
                                    (e) => _eventCard(e, isFavorite: true)),
                                const Divider(),
                              ],
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text('Other Nearby Events',
                                    style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold)),
                              ),
                              ...otherEvents.map((e) => _eventCard(e)),
                              if (likedEvents.isEmpty && otherEvents.isEmpty)
                                const Center(child: Text('No events found.'))
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
          // Add Event Button above the ad
          /*  Positioned(
            bottom: 72, // Height of AdBanner + some spacing
            left: 16,
            right: 16,
            child: ElevatedButton.icon(
              onPressed: _showAddEventDialog,
              icon: const Icon(Icons.add),
              label: const Text("Add Event"),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 4,
              ),
            ),
          ), */
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

  Widget _eventCard(ParkEvent event, {bool isFavorite = false}) {
    final start = DateFormat('h:mm a').format(event.startDateTime);
    final end = DateFormat('h:mm a').format(event.endDateTime);
    final liked = FirebaseAuth.instance.currentUser != null &&
        event.likes.contains(FirebaseAuth.instance.currentUser!.uid);
    final cardColor = isFavorite ? Colors.green.shade50 : null;

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
                      Text(event.name,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.bold)),
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
