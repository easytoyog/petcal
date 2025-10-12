// events_tab.dart
import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:location/location.dart' as loc;

import 'package:inthepark/models/park_event.dart';
import 'package:inthepark/screens/chatroom_screen.dart';
import 'package:inthepark/widgets/ad_banner.dart';

class EventsTab extends StatefulWidget {
  final String? parkIdFilter; // optional: only events for a specific park
  const EventsTab({Key? key, this.parkIdFilter}) : super(key: key);

  @override
  State<EventsTab> createState() => _EventsTabState();
}

class _EventsTabState extends State<EventsTab> {
  // --- Config ---
  static const double nearbyKm = 2.0;
  static const int pageSize = 40;

  // --- State ---
  bool _isLoading = true;
  bool _isPaging = false;
  bool _hasMore = true;
  DocumentSnapshot? _lastDoc;

  final List<ParkEvent> _allEvents = [];
  List<ParkEvent> _likedEvents = [];
  List<ParkEvent> _nearbyEvents = [];

  // Caches
  final Map<String, String> _parkNameById = {}; // parkId -> park name

  // Location
  loc.LocationData? _userLocation;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _init();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _fetchUserLocation(); // if this fails, screen shows a message
    await _fetchEvents(reset: true); // still fetch so we’re ready when enabled
  }

  // ------------------ Location ------------------
  Future<void> _fetchUserLocation() async {
    try {
      final l = loc.Location();
      bool serviceEnabled = await l.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await l.requestService();
        if (!serviceEnabled) return;
      }
      var permission = await l.hasPermission();
      if (permission == loc.PermissionStatus.denied) {
        permission = await l.requestPermission();
        if (permission != loc.PermissionStatus.granted) return;
      }
      final data = await l.getLocation();
      if (mounted) setState(() => _userLocation = data);
    } catch (_) {
      // Do nothing — UI will ask user to enable location.
    }
  }

  // ------------------ Paging ------------------
  void _onScroll() {
    if (!_hasMore || _isPaging || _isLoading) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
      _fetchEvents();
    }
  }

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
      Query baseQuery;
      if (widget.parkIdFilter != null && widget.parkIdFilter!.isNotEmpty) {
        baseQuery = FirebaseFirestore.instance
            .collection('parks')
            .doc(widget.parkIdFilter)
            .collection('events');
      } else {
        baseQuery = FirebaseFirestore.instance.collectionGroup('events');
      }

      // Page by createdAt; client filters upcoming/recurring.
      Query q =
          baseQuery.orderBy('createdAt', descending: true).limit(pageSize);
      if (_lastDoc != null) q = q.startAfterDocument(_lastDoc!);

      final snap = await q.get();
      if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;

      // Keep upcoming or recurring
      final now = DateTime.now();
      final fetched =
          snap.docs.map((d) => ParkEvent.fromFirestore(d)).where((e) {
        final recurring = (e.recurrence.toLowerCase() != 'one time' &&
            e.recurrence.toLowerCase() != 'one-time' &&
            e.recurrence.toLowerCase() != 'none');
        final upcoming = e.endDateTime.isAfter(now);
        return recurring || upcoming;
      }).toList();

      _allEvents.addAll(fetched);

      // Prefetch park names
      await _warmParkNames(_allEvents);

      // Build visible sections (will respect “no location” in build)
      _recomputeSections();

      if (mounted) {
        setState(() {
          _isLoading = false;
          _isPaging = false;
          _hasMore = snap.docs.length == pageSize;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isPaging = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading events: $e')),
      );
    }
  }

  // ------------------ Sections ------------------
  void _recomputeSections() {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    // Liked regardless of distance (we still compute, but won’t show if no location)
    _likedEvents = uid == null
        ? <ParkEvent>[]
        : _allEvents.where((e) => e.likes.contains(uid)).toList();

    // Nearby within 2 km, excluding liked
    if (_userLocation?.latitude != null && _userLocation?.longitude != null) {
      final ulat = _userLocation!.latitude!;
      final ulng = _userLocation!.longitude!;
      final nearby = _allEvents.where((e) {
        if (uid != null && e.likes.contains(uid)) return false;
        final km = _distanceKm(ulat, ulng, e.parkLatitude, e.parkLongitude);
        return km <= nearbyKm;
      }).toList();

      nearby.sort((a, b) => a.startDateTime.compareTo(b.startDateTime));
      _nearbyEvents = nearby;
    } else {
      _nearbyEvents = <ParkEvent>[];
    }
  }

  // ------------------ Helpers ------------------
  Future<void> _warmParkNames(List<ParkEvent> events) async {
    final missing = <String>{};
    for (final e in events) {
      if (!_parkNameById.containsKey(e.parkId)) missing.add(e.parkId);
    }
    if (missing.isEmpty) return;

    final ids = missing.toList();
    for (var i = 0; i < ids.length; i += 10) {
      final batch = ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10);
      final snap = await FirebaseFirestore.instance
          .collection('parks')
          .where(FieldPath.documentId, whereIn: batch)
          .get();
      for (final d in snap.docs) {
        final data = d.data();
        _parkNameById[d.id] = (data['name'] ?? '') as String;
      }
      for (final id in batch) {
        _parkNameById.putIfAbsent(id, () => 'Park');
      }
    }
  }

  double _distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const earth = 6371.0; // km
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

  // ------------------ UI ------------------
  @override
  Widget build(BuildContext context) {
    // If location is missing, show only the message — no fallbacks, no lists.
    final noLocation =
        _userLocation?.latitude == null || _userLocation?.longitude == null;

    return Scaffold(
        body: Stack(
          children: [
            SafeArea(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : noLocation
                      ? _EnableLocationMessage(onRetry: _fetchUserLocation)
                      : RefreshIndicator(
                          onRefresh: () => _fetchEvents(reset: true),
                          child: ListView(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(8, 8, 8, 120),
                            children: [
                              if (_likedEvents.isNotEmpty) ...[
                                const _SectionTitle('Your Liked Events'),
                                ..._likedEvents.map(
                                    (e) => _eventCard(e, isFavorite: true)),
                                const Divider(),
                              ],
                              const _SectionTitle('Nearby (within 2 km)'),
                              if (_nearbyEvents.isEmpty)
                                const _EmptyHint(
                                    text: 'No events within 2 km.'),
                              ..._nearbyEvents.map(_eventCard),
                              if (_isPaging) ...[
                                const SizedBox(height: 12),
                                const Center(
                                    child: CircularProgressIndicator()),
                                const SizedBox(height: 12),
                              ],
                              if (!_isPaging &&
                                  !_hasMore &&
                                  (_likedEvents.isNotEmpty ||
                                      _nearbyEvents.isNotEmpty))
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: Center(child: Text('No more events')),
                                ),
                            ],
                          ),
                        ),
            ),

            // Fixed banner ad
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(top: false, child: AdBanner()),
            ),
          ],
        ),
        floatingActionButton: null);
  }

  Widget _eventCard(ParkEvent e, {bool isFavorite = false}) {
    final start = DateFormat('EEE, MMM d • h:mm a').format(e.startDateTime);
    final end = DateFormat('h:mm a').format(e.endDateTime);

    final nameRow = Row(
      children: [
        Flexible(
          child: Text(
            e.name,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (isFavorite) const SizedBox(width: 6),
        if (isFavorite) const Icon(Icons.star, size: 16, color: Colors.amber),
      ],
    );

    final parkName = _parkNameById[e.parkId] ?? 'Park';
    String trailing = parkName;
    if (_userLocation?.latitude != null && _userLocation?.longitude != null) {
      final km = _distanceKm(
        _userLocation!.latitude!,
        _userLocation!.longitude!,
        e.parkLatitude,
        e.parkLongitude,
      );
      trailing = '$parkName • ${km.toStringAsFixed(1)} km';
    }

    final recurrenceBadge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Text(
        _recurrenceLabel(e),
        style: const TextStyle(fontSize: 11, color: Colors.green),
      ),
    );

    final desc = (e.description ?? '').trim();
    final descWidget = desc.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              desc,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Colors.black87),
            ),
          );

    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    final liked = currentUid != null && e.likes.contains(currentUid);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showEventDetails(e),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              nameRow,
              const SizedBox(height: 6),
              Text(trailing,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.access_time,
                      size: 16, color: Colors.grey.shade700),
                  const SizedBox(width: 6),
                  Text('$start – $end', style: const TextStyle(fontSize: 12)),
                  const Spacer(),
                  recurrenceBadge,
                ],
              ),
              descWidget,
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => ChatRoomScreen(parkId: e.parkId)),
                      );
                    },
                    icon: const Icon(Icons.chat, size: 16),
                    label:
                        const Text('Park Chat', style: TextStyle(fontSize: 12)),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: liked ? 'Unlike' : 'Like',
                    onPressed: () => _toggleLike(e),
                    icon: Icon(liked ? Icons.favorite : Icons.favorite_border,
                        color: liked ? Colors.green : Colors.grey),
                  ),
                  Text('${e.likes.length}',
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _recurrenceLabel(ParkEvent e) {
    final r = e.recurrence.toLowerCase();
    switch (r) {
      case 'daily':
        return 'Daily';
      case 'weekly':
        return e.weekday != null ? 'Weekly • ${e.weekday}' : 'Weekly';
      case 'monthly':
        return e.eventDay != null ? 'Monthly • ${e.eventDay}' : 'Monthly';
      case 'one time':
      case 'one-time':
        return 'One-time';
      default:
        return 'One-time';
    }
  }

  // ------------------ Actions ------------------
  Future<void> _toggleLike(ParkEvent event) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final ref = FirebaseFirestore.instance
        .collection('parks')
        .doc(event.parkId)
        .collection('events')
        .doc(event.id);

    final liked = event.likes.contains(uid);
    try {
      await ref.update({
        'likes': liked
            ? FieldValue.arrayRemove([uid])
            : FieldValue.arrayUnion([uid]),
      });
      setState(() {
        liked ? event.likes.remove(uid) : event.likes.add(uid);
        _recomputeSections();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to update like: $e')),
      );
    }
  }

  void _showEventDetails(ParkEvent e) {
    final parkName = _parkNameById[e.parkId] ?? 'Park';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        final start = DateFormat('EEE, MMM d • h:mm a').format(e.startDateTime);
        final end = DateFormat('h:mm a').format(e.endDateTime);
        final hasLoc =
            _userLocation?.latitude != null && _userLocation?.longitude != null;
        final dist = hasLoc
            ? _distanceKm(_userLocation!.latitude!, _userLocation!.longitude!,
                    e.parkLatitude, e.parkLongitude)
                .toStringAsFixed(1)
            : null;

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Colors.black12,
                        borderRadius: BorderRadius.circular(999))),
                const SizedBox(height: 12),
                Text(e.name,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  dist != null ? '$parkName • $dist km' : parkName,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.access_time, size: 18),
                    const SizedBox(width: 6),
                    Text('$start – $end'),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Text(_recurrenceLabel(e),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.green)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if ((e.description ?? '').trim().isNotEmpty)
                  Text(e.description.trim(),
                      style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 16),
                Row(
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF567D46)),
                      onPressed: () {
                        Navigator.pop(context);
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    ChatRoomScreen(parkId: e.parkId)));
                      },
                      icon:
                          const Icon(Icons.chat, size: 16, color: Colors.white),
                      label: const Text('Open Park Chat',
                          style: TextStyle(color: Colors.white)),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => _showLikesDialog(e),
                      child: Text('${e.likes.length} likes'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showLikesDialog(ParkEvent event) async {
    final userIds = event.likes;
    final petList = <Map<String, dynamic>>[];
    try {
      for (var i = 0; i < userIds.length; i += 10) {
        final chunk = userIds.sublist(i, (i + 10).clamp(0, userIds.length));
        final snapshots = await FirebaseFirestore.instance
            .collection('pets')
            .where('ownerId', whereIn: chunk)
            .get();
        petList.addAll(snapshots.docs.map((d) => d.data()));
      }
    } catch (_) {}

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
                          : const CircleAvatar(child: Icon(Icons.pets)),
                      title: Text((pet['name'] ?? 'Unknown') as String),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }
}

// ------------------ Small widgets ------------------
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text, {Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
      child: Text(text,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint({Key? key, required this.text}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(child: Text(text, style: const TextStyle(fontSize: 14))),
    );
  }
}

class _EnableLocationMessage extends StatelessWidget {
  final Future<void> Function() onRetry;
  const _EnableLocationMessage({Key? key, required this.onRetry})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 120),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.location_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text(
              'Turn on Location Services to use Events Nearby.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              'We use your location to find park events within 2 km.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.my_location),
              label: const Text('Enable / Retry'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF567D46),
                  foregroundColor: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
