import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:inthepark/utils/utils.dart';
import 'package:inthepark/widgets/level_system.dart';
import 'package:location/location.dart' as loc;
import 'package:inthepark/models/park_model.dart';
import 'package:inthepark/screens/chatroom_screen.dart';
import 'package:inthepark/services/location_service.dart';
import 'package:inthepark/services/firestore_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:inthepark/widgets/ad_banner.dart';
import 'package:inthepark/widgets/active_pets_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ParksTab extends StatefulWidget {
  final void Function(String parkId) onShowEvents;
  final VoidCallback? onXpGained;
  const ParksTab({Key? key, required this.onShowEvents, this.onXpGained})
      : super(key: key);

  @override
  State<ParksTab> createState() => _ParksTabState();
}

class _ParksTabState extends State<ParksTab>
    with AutomaticKeepAliveClientMixin<ParksTab>, WidgetsBindingObserver {
  final _locationService =
      LocationService(dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '');
  final String? _currentUserId = FirebaseAuth.instance.currentUser?.uid;
  final FirestoreService _fs = FirestoreService();

  // UI/state
  bool _isSearching = false;
  bool _hasFetchedNearby = false;
  String? _mutatingParkId; // for check-in/out spinner
  String? _openingParkId; // NEW: tap-to-open loader

  // Data
  List<Park> _favoriteParks = [];
  Set<String> _favoriteParkIds = {};
  List<Park> _nearbyParks = [];

  // Cached park meta
  final Map<String, int> _activeUserCounts = {}; // parkId -> count
  final Map<String, List<String>> _parkServices = {}; // parkId -> services[]
  final Set<String> _checkedInParkIds = {}; // where current user is checked-in

  // Meta hydration memo / in-flight
  final Set<String> _hydratedMeta = {}; // parkIds already fetched
  final Set<String> _metaInFlight = {}; // currently hydrating

  // Ensure-park-doc memo
  final Set<String> _ensuredParkDocs = {};

  // Resume throttle
  bool _resumeRefreshing = false;
  DateTime _lastNearbyRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _lastRefreshLoc;

  // Cache keys & TTL
  static const _kCacheNearby = 'parksTab.nearby.v1';
  static const _kCacheFavs = 'parksTab.favs.v1';
  static const _kCacheMeta = 'parksTab.meta.v1';
  static const _kCacheTs = 'parksTab.ts.v1';
  static const Duration _cacheTtl = Duration(hours: 2);

  bool get _shouldAutoFetchNearby =>
      _favoriteParks.isEmpty && _favoriteParkIds.isEmpty;

  // Debounces
  Timer? _checkinDebounce;
  Timer? _cacheDebounce;

  // SharedPreferences reuse
  SharedPreferences? _prefs;
  Future<SharedPreferences> _sp() async =>
      _prefs ??= await SharedPreferences.getInstance();

  // ---------- Helpers ----------
  String _parkIdOf(Park p) => generateParkID(p.latitude, p.longitude, p.name);

  // Filtered nearby list (favorites excluded)
  List<Park> get _nearbyParksVisible => _nearbyParks
      .where((p) => !_favoriteParkIds.contains(_parkIdOf(p)))
      .toList();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreCache(); // paint instantly if we have cache
    _bootstrap(); // then fetch fresh data
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _checkinDebounce?.cancel();
    _cacheDebounce?.cancel();
    _metaInFlight.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onFastResume();
  }

  Future<void> _bootstrap() async {
    // Fetch favourites first so we can decide about auto nearby
    await _fetchFavoriteParks();
    await _refreshCheckedInSet();

    if (_shouldAutoFetchNearby) {
      await _fetchNearbyParksFast(); // spinner-less fast pass
    }
  }

  // ---------- Resume: fast, spinner-less refresh ----------
  Future<void> _onFastResume() async {
    if (!mounted || _resumeRefreshing) return;
    _resumeRefreshing = true;
    try {
      // 🚫 Do not auto-refresh nearby if the user has favourites
      if (!_shouldAutoFetchNearby) return;

      final saved = await _locationService.getSavedUserLocation();
      final movedFar = (saved != null && _lastRefreshLoc != null)
          ? _approxMeters(saved, _lastRefreshLoc!) > 150
          : (_lastRefreshLoc == null);
      final stale = DateTime.now().difference(_lastNearbyRefresh) >
          const Duration(minutes: 5);

      if (movedFar || stale || !_hasFetchedNearby) {
        await _fetchNearbyParksFast(); // no spinner
        _lastNearbyRefresh = DateTime.now();
        _lastRefreshLoc = saved ?? _lastRefreshLoc;

        final ids = _nearbyParks.map(_parkIdOf).toList();
        final toHydrate =
            ids.where((id) => !_hydratedMeta.contains(id)).toList();
        if (toHydrate.isNotEmpty) {
          // ignore: discarded_futures
          _hydrateMetaForIds(toHydrate);
        }
      }
    } finally {
      _resumeRefreshing = false;
    }
  }

  double _approxMeters(LatLng a, LatLng b) {
    const k = 111000.0; // ~ meters / degree latitude
    final dx = (a.latitude - b.latitude) * k;
    final dy = (a.longitude - b.longitude) *
        k *
        math.cos(a.latitude * math.pi / 180.0);
    return math.sqrt(dx * dx + dy * dy);
  }

  // ---------- Cache (restore + save, debounced) ----------
  void _cacheStateDebounced() {
    _cacheDebounce?.cancel();
    _cacheDebounce = Timer(const Duration(milliseconds: 250), _cacheState);
  }

  Future<void> _restoreCache() async {
    try {
      final p = await _sp();
      final ts = p.getInt(_kCacheTs);
      if (ts == null) return;
      final age =
          DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
      if (age > _cacheTtl) return;

      final nearbyRaw = p.getString(_kCacheNearby);
      final favsRaw = p.getString(_kCacheFavs);
      final metaRaw = p.getString(_kCacheMeta);

      if (nearbyRaw != null) {
        // parse off-thread
        _nearbyParks = await compute(_parseParksFromJson, nearbyRaw);
        _hasFetchedNearby = _nearbyParks.isNotEmpty;
      }
      if (favsRaw != null) {
        _favoriteParks = await compute(_parseParksFromJson, favsRaw);
        _favoriteParkIds = _favoriteParks.map(_parkIdOf).toSet();
      }
      if (metaRaw != null) {
        final meta = jsonDecode(metaRaw) as Map<String, dynamic>;
        _activeUserCounts
          ..clear()
          ..addAll((meta['counts'] as Map?)?.map(
                (k, v) => MapEntry(k as String, (v as num).toInt()),
              ) ??
              {});
        _parkServices
          ..clear()
          ..addAll((meta['services'] as Map?)?.map(
                (k, v) => MapEntry(
                    k as String, ((v as List?) ?? const []).cast<String>()),
              ) ??
              {});
        _hydratedMeta
          ..clear()
          ..addAll(_parkServices.keys);
      }

      if (mounted) setState(() {});
    } catch (_) {
      // ignore cache errors
    }
  }

  Future<void> _cacheState() async {
    try {
      final p = await _sp();
      await p.setString(_kCacheNearby,
          jsonEncode(_nearbyParks.map((x) => x.toJson()).toList()));
      await p.setString(_kCacheFavs,
          jsonEncode(_favoriteParks.map((x) => x.toJson()).toList()));
      await p.setString(
        _kCacheMeta,
        jsonEncode({
          'counts': _activeUserCounts,
          'services': _parkServices,
        }),
      );
      await p.setInt(_kCacheTs, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // ignore
    }
  }

  // ---------- Card loader helper ----------
  Future<void> _runWithCardLoader(
      String parkId, Future<void> Function() action) async {
    if (!mounted) return;
    if (_openingParkId != null) return; // prevent parallel opens
    setState(() => _openingParkId = parkId);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _openingParkId = null);
    }
  }

  // ---------- Firestore helpers ----------
  Future<void> _ensureParkDoc(String parkId, Park p) async {
    if (_ensuredParkDocs.contains(parkId)) return;
    final ref = FirebaseFirestore.instance.collection('parks').doc(parkId);
    try {
      final snap = await ref.get().timeout(const Duration(seconds: 6));
      if (!snap.exists) {
        await ref.set({
          'id': parkId,
          'name': p.name,
          'latitude': p.latitude,
          'longitude': p.longitude,
          'createdAt': FieldValue.serverTimestamp(),
        }).timeout(const Duration(seconds: 6));
      }
      _ensuredParkDocs.add(parkId);
    } catch (_) {
      // ignore ensure failures silently
    }
  }

  // ---------- Favorites ----------
  Future<void> _fetchFavoriteParks() async {
    final uid = _currentUserId;
    if (uid == null) return;
    try {
      final likedSnapshot = await FirebaseFirestore.instance
          .collection('owners')
          .doc(uid)
          .collection('likedParks')
          .get()
          .timeout(const Duration(seconds: 8));

      final parkIds = likedSnapshot.docs.map((d) => d.id).toList();

      // Fetch park docs in chunks of 10 (whereIn limit)
      final List<Park> parks = [];
      for (var i = 0; i < parkIds.length; i += 10) {
        final end = (i + 10).clamp(0, parkIds.length);
        final chunk = parkIds.sublist(i, end);
        if (chunk.isEmpty) continue;

        final qs = await FirebaseFirestore.instance
            .collection('parks')
            .where(FieldPath.documentId, whereIn: chunk)
            .get()
            .timeout(const Duration(seconds: 8));

        parks.addAll(qs.docs.map((d) => Park.fromFirestore(d)));
        _hydrateMetaFromDocs(qs.docs);
        _hydratedMeta.addAll(qs.docs.map((d) => d.id));
      }

      if (!mounted) return;
      setState(() {
        _favoriteParkIds = parkIds.toSet();
        _favoriteParks = parks;
      });
      _cacheStateDebounced();
    } catch (_) {
      // silently ignore
    }
  }

  String _checkedInForSince(DateTime since) {
    final diff = DateTime.now().difference(since);
    final mins = diff.inMinutes;
    if (mins < 1) return "< 1 min";
    if (mins < 60) return "$mins min";
    final hrs = diff.inHours;
    final rem = mins - hrs * 60;
    return rem == 0 ? "$hrs hr" : "$hrs hr $rem min";
  }

  // ---------- Nearby (FAST first, then precise) ----------
  Future<void> _fetchNearbyParksFast() async {
    // 🚫 Skip auto nearby fetch if favourites are present
    if (!_shouldAutoFetchNearby) return;

    try {
      final cached = await _locationService.getUserLocationOrCached();
      if (cached == null) return;

      final parks = await _locationService.findNearbyParks(
        cached.latitude,
        cached.longitude,
      );

      bool changed = parks.length != _nearbyParks.length;
      if (!changed) {
        for (int i = 0; i < parks.length; i++) {
          if (_parkIdOf(parks[i]) != _parkIdOf(_nearbyParks[i])) {
            changed = true;
            break;
          }
        }
      }
      if (!changed) return;

      final ids = parks.map(_parkIdOf).toList();
      final toHydrate = ids.where((id) => !_hydratedMeta.contains(id)).toList();
      if (toHydrate.isNotEmpty) {
        // ignore: discarded_futures
        _hydrateMetaForIds(toHydrate);
      }

      _nearbyParks = parks;
      _hasFetchedNearby = true;
      _lastRefreshLoc = cached;
      if (mounted) setState(() {});
      _cacheStateDebounced();
    } catch (_) {
      // ignore
    }
  }

  Future<void> _fetchNearbyParks() async {
    if (mounted) setState(() => _isSearching = true);
    try {
      final permission = loc.Location();
      final hasService = await permission.serviceEnabled() ||
          await permission.requestService();
      if (!hasService) return;

      var status = await permission.hasPermission();
      if (status == loc.PermissionStatus.denied) {
        status = await permission.requestPermission();
      }
      if (status != loc.PermissionStatus.granted) {
        return;
      }

      final l = await permission.getLocation().timeout(
          const Duration(seconds: 2),
          onTimeout: () => loc.LocationData.fromMap({}));
      if (l.latitude == null || l.longitude == null) return;
      await _fetchNearbyParksAt(l.latitude!, l.longitude!);
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _fetchNearbyParksAt(double lat, double lng) async {
    if (mounted) setState(() => _isSearching = true);
    try {
      final parks = await _locationService.findNearbyParks(lat, lng);

      // Hydrate meta for any parks we haven't hydrated yet (batched by 10)
      final ids = parks.map(_parkIdOf).toList();
      final toHydrate = ids.where((id) => !_hydratedMeta.contains(id)).toList();
      if (toHydrate.isNotEmpty) {
        await _hydrateMetaForIds(toHydrate);
        _hydratedMeta.addAll(toHydrate);
      }

      // Only update UI if changed
      bool changed = parks.length != _nearbyParks.length;
      if (!changed) {
        for (int i = 0; i < parks.length; i++) {
          if (_parkIdOf(parks[i]) != _parkIdOf(_nearbyParks[i])) {
            changed = true;
            break;
          }
        }
      }
      if (!changed) return;

      if (!mounted) return;
      setState(() {
        _nearbyParks = parks; // keep raw list; UI filters out favorites
        _hasFetchedNearby = true;
      });
      _cacheStateDebounced();
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  // ---------- Meta (userCount + services) ----------
  void _hydrateMetaFromDocs(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    bool anyChange = false;
    for (final d in docs) {
      final data = d.data();
      final newCount = (data['userCount'] ?? 0) as int;
      final newSvcs = (data['services'] as List?)?.cast<String>() ?? const [];
      if (_activeUserCounts[d.id] != newCount) {
        _activeUserCounts[d.id] = newCount;
        anyChange = true;
      }
      // compare lists shallowly
      final oldSvcs = _parkServices[d.id] ?? const <String>[];
      if (oldSvcs.length != newSvcs.length ||
          !oldSvcs.toSet().containsAll(newSvcs)) {
        _parkServices[d.id] = newSvcs;
        anyChange = true;
      }
    }
    if (anyChange) {
      if (mounted) setState(() {});
      _cacheStateDebounced();
    }
  }

  Future<void> _hydrateMetaForIds(List<String> parkIds) async {
    // avoid duplicate in-flight fetches
    final ids = parkIds
        .where(
            (id) => !_hydratedMeta.contains(id) && !_metaInFlight.contains(id))
        .toList();
    if (ids.isEmpty) return;

    _metaInFlight.addAll(ids);
    try {
      final futures = <Future<void>>[];
      for (var i = 0; i < ids.length; i += 10) {
        final end = (i + 10).clamp(0, ids.length);
        final chunk = ids.sublist(i, end);
        if (chunk.isEmpty) continue;

        futures.add(FirebaseFirestore.instance
            .collection('parks')
            .where(FieldPath.documentId, whereIn: chunk)
            .get()
            .timeout(const Duration(seconds: 8))
            .then((qs) => _hydrateMetaFromDocs(qs.docs)));
      }
      await Future.wait(futures);
      _hydratedMeta.addAll(ids);
    } catch (_) {
      // ignore
    } finally {
      _metaInFlight.removeAll(ids);
    }
  }

  Future<void> _refreshCheckedInSet() async {
    final uid = _currentUserId;
    if (uid == null) return;

    try {
      final snaps = await FirebaseFirestore.instance
          .collectionGroup('active_users')
          .where('uid', isEqualTo: uid)
          .get()
          .timeout(const Duration(seconds: 8));

      final newSet = <String>{};
      for (final doc in snaps.docs) {
        final parkRef = doc.reference.parent.parent; // parks/{parkId}
        if (parkRef != null) newSet.add(parkRef.id);
      }

      if (!mounted) return;
      setState(() {
        _checkedInParkIds
          ..clear()
          ..addAll(newSet);
      });
    } catch (e) {
      // Leave _checkedInParkIds as-is on error
      // debugPrint('refreshCheckedInSet error: $e');
    }
  }

  // ---------- Transactions ----------
  Future<void> _txCheckOut(String parkId) async {
    final uid = _currentUserId;
    if (uid == null) return;

    final db = FirebaseFirestore.instance;
    final userRef =
        db.collection('parks').doc(parkId).collection('active_users').doc(uid);

    try {
      await db.runTransaction((tx) async {
        final snap = await tx.get(userRef);
        if (!snap.exists) return;
        tx.delete(userRef);
      }).timeout(const Duration(seconds: 8));
    } catch (_) {
      // ignore
    }
  }

  Future<void> _txCheckIn(String parkId) async {
    final uid = _currentUserId;
    if (uid == null) return;

    final db = FirebaseFirestore.instance;
    final userRef =
        db.collection('parks').doc(parkId).collection('active_users').doc(uid);

    try {
      await db.runTransaction((tx) async {
        final snap = await tx.get(userRef);
        if (snap.exists) return; // already checked in
        tx.set(userRef, {
          'uid': uid,
          'checkedInAt': FieldValue.serverTimestamp(),
        });
      }).timeout(const Duration(seconds: 8));
    } catch (_) {
      // ignore
    }
  }

  Future<void> _checkOutFromAllParks() async {
    final uid = _currentUserId;
    if (uid == null) return;

    try {
      final snaps = await FirebaseFirestore.instance
          .collectionGroup('active_users')
          .where('uid', isEqualTo: uid)
          .get()
          .timeout(const Duration(seconds: 8));

      if (snaps.docs.isEmpty) return;

      final wb = FirebaseFirestore.instance.batch();
      for (final d in snaps.docs) {
        wb.delete(d.reference);
        final parkRef = d.reference.parent.parent;
        if (parkRef != null) {
          _checkedInParkIds.remove(parkRef.id);
          _activeUserCounts.update(
            parkRef.id,
            (v) => (v - 1).clamp(0, 1 << 30),
            ifAbsent: () => 0,
          );
        }
      }
      await wb.commit().timeout(const Duration(seconds: 8));
    } catch (_) {
      // ignore
    }
  }

  // ---------- Pets query (string vs reference resilient) ----------
  Future<QuerySnapshot<Map<String, dynamic>>> _queryPetsByOwnerIds(
    List<String> ownerIds,
  ) async {
    final petsCol = FirebaseFirestore.instance.collection('pets');
    if (ownerIds.isEmpty) {
      return petsCol
          .where(FieldPath.documentId, isEqualTo: '__none__')
          .limit(0)
          .get();
    }

    try {
      return await petsCol
          .where('ownerId', whereIn: ownerIds)
          .get()
          .timeout(const Duration(seconds: 8));
    } on FirebaseException catch (_) {
      final ownerRefs = ownerIds
          .map((id) => FirebaseFirestore.instance.collection('owners').doc(id))
          .toList();
      return await petsCol
          .where('ownerId', whereIn: ownerRefs)
          .get()
          .timeout(const Duration(seconds: 8));
    }
  }

  // ---------- Active pets dialog ----------
  Future<void> _showActiveUsersDialog(String parkId) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final favPetsSnap = await FirebaseFirestore.instance
        .collection('favorites')
        .doc(currentUser.uid)
        .collection('pets')
        .get()
        .timeout(const Duration(seconds: 8));
    final favoritePetIds = favPetsSnap.docs.map((d) => d.id).toSet();

    final activeUsersSnapshot = await FirebaseFirestore.instance
        .collection('parks')
        .doc(parkId)
        .collection('active_users')
        .get()
        .timeout(const Duration(seconds: 8));
    final userIds = activeUsersSnapshot.docs.map((d) => d.id).toList();

    final checkedInForByOwner = <String, String>{};
    for (final u in activeUsersSnapshot.docs) {
      final ts = (u.data()['checkedInAt']);
      if (ts != null) {
        final dt = (ts as Timestamp).toDate();
        checkedInForByOwner[u.id] = _checkedInForSince(dt);
      } else {
        checkedInForByOwner[u.id] = '';
      }
    }

    final List<Map<String, dynamic>> activePets = [];
    for (var i = 0; i < userIds.length; i += 10) {
      final end = (i + 10).clamp(0, userIds.length);
      final chunk = userIds.sublist(i, end);
      if (chunk.isEmpty) continue;

      final petsSnapshot = await _queryPetsByOwnerIds(chunk);

      for (final petDoc in petsSnapshot.docs) {
        final pet = petDoc.data();
        final ownerId = (pet['ownerId'] is DocumentReference)
            ? (pet['ownerId'] as DocumentReference).id
            : (pet['ownerId'] as String? ?? '');
        activePets.add({
          'petName': pet['name'] ?? 'Unknown Pet',
          'petPhotoUrl': pet['photoUrl'] ?? '',
          'ownerId': ownerId,
          'petId': petDoc.id,
          'checkInTime': checkedInForByOwner[ownerId] ?? '',
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
              await FirebaseFirestore.instance
                  .collection('friends')
                  .doc(currentUser.uid)
                  .collection('userFriends')
                  .doc(ownerId)
                  .delete()
                  .timeout(const Duration(seconds: 8));
              await FirebaseFirestore.instance
                  .collection('favorites')
                  .doc(currentUser.uid)
                  .collection('pets')
                  .doc(petId)
                  .delete()
                  .timeout(const Duration(seconds: 8));
              favoritePetIds.remove(petId);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Friend removed.")),
                );
              }
            } else {
              final ownerDoc = await FirebaseFirestore.instance
                  .collection('owners')
                  .doc(ownerId)
                  .get()
                  .timeout(const Duration(seconds: 8));
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
              }).timeout(const Duration(seconds: 8));
              await FirebaseFirestore.instance
                  .collection('favorites')
                  .doc(currentUser.uid)
                  .collection('pets')
                  .doc(petId)
                  .set({
                'petId': petId,
                'addedAt': FieldValue.serverTimestamp(),
              }).timeout(const Duration(seconds: 8));
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
    await _ensureParkDoc(parkId, park); // ensure doc only on mutation

    try {
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
      _cacheStateDebounced();
    } catch (_) {
      // ignore
    }
  }

  // ---------- Check-in / out ----------
  Future<void> _toggleCheckIn(Park park) async {
    final uid = _currentUserId;
    if (uid == null) return;

    final parkId = _parkIdOf(park);
    if (mounted) setState(() => _mutatingParkId = parkId);

    try {
      await _ensureParkDoc(parkId, park);

      final isCheckedIn = _checkedInParkIds.contains(parkId);

      if (isCheckedIn) {
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
        await _checkOutFromAllParks();
        await _txCheckIn(parkId);

        _checkedInParkIds
          ..clear()
          ..add(parkId);
        _activeUserCounts.update(
          parkId,
          (v) => v + 1,
          ifAbsent: () => 1,
        );

        // ✅ Add XP here
        try {
          if (uid != null) {
            await LevelSystem.addXp(
              uid,
              20,
              reason: 'Daily park check-in',
            );
          }
        } catch (e) {
          // debugPrint('Failed to add XP: $e');
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Checked in to park")),
          );
        }
        if (mounted && widget.onXpGained != null) {
          widget.onXpGained!();
        }
      }
      _cacheStateDebounced();
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _mutatingParkId = null);
    }
  }

  // ---------- UI ----------
  static const _svcIcons = <String, IconData>{
    "Off-leash Dog Park": Icons.pets,
    "Off-leash Trail": Icons.terrain,
    "Off-leash Beach": Icons.beach_access,
  };
  IconData _serviceIcon(String s) => _svcIcons[s] ?? Icons.park;

  Widget _buildParkCard(Park park, {required bool isFavorite}) {
    final parkId = _parkIdOf(park);
    final liked = _favoriteParkIds.contains(parkId);
    final userCount = _activeUserCounts[parkId] ?? 0;
    final services = _parkServices[parkId] ?? park.services ?? const <String>[];
    final isCheckedIn = _checkedInParkIds.contains(parkId);
    final isBusy = _mutatingParkId == parkId;
    final isOpening = _openingParkId == parkId; // NEW

    return KeyedSubtree(
      key: ValueKey('park:$parkId'),
      child: Stack(
        children: [
          Card(
            color: isFavorite ? Colors.green.shade50 : null,
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: InkWell(
              onTap: () async {
                await _runWithCardLoader(parkId, () async {
                  await _ensureParkDoc(parkId, park);
                  await _showActiveUsersDialog(parkId);
                });
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
                          icon: Icon(
                              liked ? Icons.favorite : Icons.favorite_border),
                          color: liked ? Colors.green : Colors.grey,
                          onPressed: isOpening ? null : () => _toggleLike(park),
                          tooltip: liked ? 'Unlike' : 'Like',
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
                          return Chip(
                            avatar: Icon(_serviceIcon(s),
                                size: 16, color: Colors.green),
                            label:
                                Text(s, style: const TextStyle(fontSize: 12)),
                            backgroundColor: Colors.green[50],
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            visualDensity: const VisualDensity(
                                horizontal: -4, vertical: -4),
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
                          onPressed: isOpening
                              ? null
                              : () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          ChatRoomScreen(parkId: parkId),
                                    ),
                                  ),
                          child: const Text("Park Chat",
                              style: TextStyle(fontSize: 12)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: isOpening
                              ? null
                              : () => widget.onShowEvents(parkId),
                          child: const Text("Park Events",
                              style: TextStyle(fontSize: 12)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                isCheckedIn ? Colors.red : Colors.green,
                          ),
                          onPressed: (isBusy || isOpening)
                              ? null
                              : () => _toggleCheckIn(park),
                          child: isBusy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white),
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
          ),

          // --- Opening overlay ---
          if (isOpening)
            Positioned.fill(
              child: AbsorbPointer(
                child: Container(
                  color: Colors.black.withOpacity(0.08),
                  alignment: Alignment.center,
                  child: const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    super.build(context); // KeepAlive mixin
    final nearbyVisible = _nearbyParksVisible;

    return Scaffold(
      body: Stack(
        children: [
          RepaintBoundary(
            child: ListView(
              cacheExtent: 800, // prefetch a bit to reduce scroll jank
              padding: const EdgeInsets.only(bottom: 70),
              children: [
                // Favorites
                if (_favoriteParks.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Text("Favourite Parks",
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  ..._favoriteParks
                      .map((p) => _buildParkCard(p, isFavorite: true)),
                ],

                // Nearby header
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      const Text(
                        "Nearby Parks",
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _isSearching ? null : _fetchNearbyParks,
                        icon: const Icon(Icons.near_me, size: 16),
                        label: const Text("Find Nearby"),
                        style: TextButton.styleFrom(
                          visualDensity:
                              const VisualDensity(horizontal: -2, vertical: -2),
                        ),
                      ),
                    ],
                  ),
                ),

                // CTA to fetch nearby (only shows if we didn’t have a cached fix)
                if (!_isSearching && nearbyVisible.isEmpty)
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

                // Nearby list (favorites excluded)
                ...nearbyVisible
                    .map((p) => _buildParkCard(p, isFavorite: false)),
              ],
            ),
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

// ---------- Top-level helpers for compute() ----------

List<Park> _parseParksFromJson(String raw) {
  final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  return list.map((e) => Park.fromJson(e)).toList();
}
