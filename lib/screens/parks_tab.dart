import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:inthepark/models/feed_article.dart';
import 'package:inthepark/widgets/level_system.dart';
import 'package:location/location.dart' as loc;
import 'package:inthepark/models/park_model.dart';
import 'package:inthepark/screens/chatroom_screen.dart';
import 'package:inthepark/services/location_service.dart';
import 'package:inthepark/services/news_feed_service.dart';
import 'package:inthepark/services/firestore_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:inthepark/widgets/ad_banner.dart';
import 'package:inthepark/widgets/active_pets_dialog.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class ParksTab extends StatefulWidget {
  final VoidCallback? onXpGained;
  final bool isWalkActive;
  final VoidCallback? onStartWalk;
  const ParksTab({
    Key? key,
    this.onXpGained,
    this.isWalkActive = false,
    this.onStartWalk,
  }) : super(key: key);

  @override
  State<ParksTab> createState() => _ParksTabState();
}

class _ParksTabState extends State<ParksTab>
    with AutomaticKeepAliveClientMixin<ParksTab>, WidgetsBindingObserver {
  static const Duration _activeUserStaleAfter = Duration(hours: 3);
  final _locationService =
      LocationService(dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '');
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _parkSearchController = TextEditingController();
  final FocusNode _parkSearchFocusNode = FocusNode();
  final String? _currentUserId = FirebaseAuth.instance.currentUser?.uid;
  final FirestoreService _fs = FirestoreService();
  final NewsFeedService _newsFeedService = NewsFeedService();

  // UI/state
  bool _isSearching = false;
  String? _mutatingParkId; // for check-in/out spinner
  String? _openingParkId; // NEW: tap-to-open loader

  // Data
  List<Park> _favoriteParks = [];
  Set<String> _favoriteParkIds = {};
  List<Park> _searchedParks = [];
  List<FeedArticle> _newsArticles = [];
  String _parkSearchQuery = '';
  String? _newsError;
  bool _isLoadingNews = false;
  bool _isRefreshingNews = false;
  bool _isAutoExpandingNews = false;
  int _visibleNewsCount = 10;
  int _parkSearchToken = 0;

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

  // Cache keys & TTL
  static const _kCacheFavs = 'parksTab.favs.v1';
  static const _kCacheMeta = 'parksTab.meta.v1';
  static const _kCacheTs = 'parksTab.ts.v1';
  static const Duration _cacheTtl = Duration(hours: 2);

  // Debounces
  Timer? _checkinDebounce;
  Timer? _cacheDebounce;

  // SharedPreferences reuse
  SharedPreferences? _prefs;
  Future<SharedPreferences> _sp() async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _parkSearchFocusNode.addListener(_handleParkSearchFocusChanged);
    _restoreCache(); // paint instantly if we have cache
    _bootstrap(); // then fetch fresh data
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _checkinDebounce?.cancel();
    _cacheDebounce?.cancel();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _parkSearchController.dispose();
    _parkSearchFocusNode
      ..removeListener(_handleParkSearchFocusChanged)
      ..dispose();
    _metaInFlight.clear();
    super.dispose();
  }

  DateTime? _activeUserCheckedInAt(Map<String, dynamic> data) {
    final checkedInAt = data['checkedInAt'];
    if (checkedInAt is Timestamp) return checkedInAt.toDate();

    final legacyCheckInAt = data['checkInAt'];
    if (legacyCheckInAt is Timestamp) return legacyCheckInAt.toDate();

    final createdAt = data['createdAt'];
    if (createdAt is Timestamp) return createdAt.toDate();

    return null;
  }

  bool _isStaleActiveUserData(
    Map<String, dynamic> data, {
    DateTime? now,
  }) {
    final checkedInAt = _activeUserCheckedInAt(data);
    if (checkedInAt == null) return true;
    return (now ?? DateTime.now()).difference(checkedInAt) >
        _activeUserStaleAfter;
  }

  void _handleParkSearchFocusChanged() {
    if (mounted) setState(() {});
  }

  void _handleScroll() {
    if (!_scrollController.hasClients ||
        _isAutoExpandingNews ||
        _isLoadingNews ||
        _isRefreshingNews ||
        _visibleNewsCount >= _newsArticles.length) {
      return;
    }

    final position = _scrollController.position;
    final threshold = math.max(240.0, position.viewportDimension * 0.35);
    if (position.extentAfter > threshold) return;

    _isAutoExpandingNews = true;
    if (mounted) {
      setState(() {
        _visibleNewsCount =
            math.min(_visibleNewsCount + 10, _newsArticles.length);
      });
    }
    Future<void>.delayed(const Duration(milliseconds: 150), () {
      _isAutoExpandingNews = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onFastResume();
  }

  Future<void> _bootstrap() async {
    await Future.wait([
      _fetchFavoriteParks(),
      _refreshCheckedInSet(),
      _loadNewsArticles(),
    ]);
  }

  // ---------- Resume: fast, spinner-less refresh ----------
  Future<void> _onFastResume() async {
    if (!mounted || _resumeRefreshing) return;
    _resumeRefreshing = true;
    try {
      await Future.wait([
        _refreshCheckedInSet(),
        _loadNewsArticles(),
      ]);
    } finally {
      _resumeRefreshing = false;
    }
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

      final favsRaw = p.getString(_kCacheFavs);
      final metaRaw = p.getString(_kCacheMeta);

      if (favsRaw != null) {
        _favoriteParks = await compute(_parseParksFromJson, favsRaw);
        _favoriteParkIds = _favoriteParks.map((p) => p.id).toSet();
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

  Future<LatLng?> _searchOrigin() async {
    final cached = await _locationService.getSavedUserLocation(
      maxAgeSeconds: 3600,
    );
    if (cached != null) return cached;

    try {
      final permission = loc.Location();
      final hasService = await permission.serviceEnabled() ||
          await permission.requestService();
      if (!hasService) return null;

      var status = await permission.hasPermission();
      if (status == loc.PermissionStatus.denied) {
        status = await permission.requestPermission();
      }
      if (status != loc.PermissionStatus.granted &&
          status != loc.PermissionStatus.grantedLimited) {
        return null;
      }

      final l = await permission.getLocation().timeout(
            const Duration(seconds: 2),
            onTimeout: () => loc.LocationData.fromMap({}),
          );
      if (l.latitude == null || l.longitude == null) return null;

      await _locationService.saveUserLocation(l.latitude!, l.longitude!);
      return LatLng(l.latitude!, l.longitude!);
    } catch (_) {
      return null;
    }
  }

  Future<void> _searchParksByName() async {
    final query = _parkSearchController.text.trim();
    final token = ++_parkSearchToken;
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _parkSearchQuery = '';
        _searchedParks = [];
        _isSearching = false;
      });
      return;
    }

    if (mounted) setState(() => _isSearching = true);
    try {
      final origin = await _searchOrigin();
      if (!mounted || token != _parkSearchToken) return;
      if (origin == null) {
        if (!mounted || token != _parkSearchToken) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Location is needed to sort park results by distance.'),
          ),
        );
        return;
      }

      final parks = await _locationService.searchParksByName(
        query,
        origin.latitude,
        origin.longitude,
      );
      if (!mounted || token != _parkSearchToken) return;

      final ids = parks.map((p) => p.id).toList();
      final toHydrate = ids.where((id) => !_hydratedMeta.contains(id)).toList();
      if (toHydrate.isNotEmpty) {
        await _hydrateMetaForIds(toHydrate);
        _hydratedMeta.addAll(toHydrate);
      }

      if (!mounted || token != _parkSearchToken) return;
      setState(() {
        _parkSearchQuery = query;
        _searchedParks = parks;
      });
    } catch (_) {
      if (!mounted || token != _parkSearchToken) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not search parks right now.')),
      );
    } finally {
      if (mounted && token == _parkSearchToken) {
        setState(() => _isSearching = false);
      }
    }
  }

  void _clearParkSearch() {
    _parkSearchToken++;
    _parkSearchController.clear();
    _parkSearchFocusNode.unfocus();
    if (!mounted) return;
    setState(() {
      _parkSearchQuery = '';
      _searchedParks = [];
      _isSearching = false;
    });
  }

  Future<void> _loadNewsArticles({bool forceRefresh = false}) async {
    if (!mounted) return;

    setState(() {
      if (_newsArticles.isEmpty) {
        _isLoadingNews = true;
      } else {
        _isRefreshingNews = true;
      }
      _newsError = null;
    });

    try {
      if (!forceRefresh && _newsArticles.isEmpty) {
        final previewArticles = await _newsFeedService.getPreviewArticles(
          limit: 3,
        );

        if (mounted && previewArticles.isNotEmpty) {
          setState(() {
            _newsArticles = previewArticles;
            _visibleNewsCount = math.min(3, previewArticles.length);
            _isLoadingNews = false;
            _isRefreshingNews = true;
            _isAutoExpandingNews = false;
          });
        }
      }

      final articles = await _newsFeedService.getArticles(
        forceRefresh: forceRefresh,
        limit: 30,
      );

      if (!mounted) return;
      setState(() {
        _newsArticles = articles;
        _visibleNewsCount =
            articles.isEmpty ? 10 : math.min(10, articles.length);
        _isAutoExpandingNews = false;
        if (articles.isEmpty) {
          _newsError = 'No dog news is available right now.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (_newsArticles.isEmpty) {
          _newsError = 'Could not load dog news right now.';
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingNews = false;
          _isRefreshingNews = false;
        });
      }
    }
  }

  Future<void> _openNewsArticle(FeedArticle article) async {
    final uri = Uri.tryParse(article.url);
    if (uri == null) return;

    final opened = await launchUrl(
      uri,
      mode: LaunchMode.inAppBrowserView,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open article right now.')),
      );
    }
  }

  Future<void> _scrollToTop() async {
    if (!_scrollController.hasClients) return;
    await _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
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
      final staleRefs = <DocumentReference>[];
      for (final doc in snaps.docs) {
        final data = doc.data();
        if (_isStaleActiveUserData(data)) {
          staleRefs.add(doc.reference);
          continue;
        }
        final parkRef = doc.reference.parent.parent; // parks/{parkId}
        if (parkRef != null) newSet.add(parkRef.id);
      }

      if (staleRefs.isNotEmpty) {
        await Future.wait(
          staleRefs.map((ref) => ref.delete().catchError((_) {})),
        );
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
  Future<void> _showActiveUsersDialog(Park park) async {
    final parkId = park.id;
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
    final activeUserDocs = activeUsersSnapshot.docs.where((doc) {
      final data = doc.data();
      return !_isStaleActiveUserData(data);
    }).toList(growable: false);
    final userIds = activeUserDocs.map((d) => d.id).toList();

    final checkedInForByOwner = <String, String>{};
    for (final u in activeUserDocs) {
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

    if (mounted) {
      setState(() {
        _activeUserCounts[parkId] = activeUserDocs.length;
      });
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) {
        return ActivePetsDialog(
          pets: activePets,
          parkName: park.name,
          isCheckedIn: _checkedInParkIds.contains(parkId),
          onCheckInToggle: () => _toggleCheckIn(park),
          onOpenParkChat: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatRoomScreen(parkId: parkId),
              ),
            );
          },
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
    final parkId = park.id;
    await _ensureParkDoc(parkId, park); // ensure doc only on mutation

    try {
      if (_favoriteParkIds.contains(parkId)) {
        await _fs.unlikePark(parkId);
        _favoriteParkIds.remove(parkId);
        _favoriteParks.removeWhere((p) => p.id == parkId);
      } else {
        await _fs.likePark(parkId);
        _favoriteParkIds.add(parkId);
        if (!_favoriteParks.any((p) => p.id == parkId)) {
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

    final parkId = park.id;
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
          await LevelSystem.addXp(
            uid,
            20,
            reason: 'Daily park check-in',
          );
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

  String _formatDistance(double distanceKm) {
    if (distanceKm < 1) {
      return '${(distanceKm * 1000).round()} m away';
    }
    return '${distanceKm.toStringAsFixed(distanceKm < 10 ? 1 : 0)} km away';
  }

  String _parkMetaLine(Park park, int userCount) {
    final parts = <String>[];
    if (park.distance != null) {
      parts.add(_formatDistance(park.distance!));
    }
    parts.add(userCount == 1 ? '1 active user' : '$userCount active users');
    return parts.join('  •  ');
  }

  String _formatArticleTime(DateTime? publishedAt) {
    if (publishedAt == null) return 'Recently';
    final diff = DateTime.now().difference(publishedAt);
    if (diff.inMinutes < 60) {
      final mins = math.max(1, diff.inMinutes);
      return '$mins min ago';
    }
    if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    }
    if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    }
    return DateFormat('MMM d').format(publishedAt);
  }

  Widget _buildParkCard(Park park, {required bool isFavorite}) {
    final parkId = park.id;
    final liked = _favoriteParkIds.contains(parkId);
    final userCount = _activeUserCounts[parkId] ?? 0;
    final services = _parkServices[parkId] ?? park.services;
    final isCheckedIn = _checkedInParkIds.contains(parkId);
    final isBusy = _mutatingParkId == parkId;
    final isOpening = _openingParkId == parkId; // NEW

    return KeyedSubtree(
      key: ValueKey('park:$parkId'),
      child: Stack(
        children: [
          Card(
            color: isFavorite ? Colors.green.shade50 : null,
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: InkWell(
              onTap: () async {
                await _runWithCardLoader(parkId, () async {
                  await _ensureParkDoc(parkId, park);
                  await _showActiveUsersDialog(park);
                });
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                              liked ? Icons.favorite : Icons.favorite_border),
                          color: liked ? Colors.green : Colors.grey,
                          onPressed: isOpening ? null : () => _toggleLike(park),
                          tooltip: liked ? 'Unlike' : 'Like',
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),

                    // Services chips
                    if (services.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: -8,
                        children: services.map((s) {
                          return Chip(
                            avatar: Icon(_serviceIcon(s),
                                size: 14, color: Colors.green),
                            label:
                                Text(s, style: const TextStyle(fontSize: 11.5)),
                            backgroundColor: Colors.green[50],
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            visualDensity: const VisualDensity(
                                horizontal: -4, vertical: -4),
                            labelPadding:
                                const EdgeInsets.symmetric(horizontal: 2),
                            padding: EdgeInsets.zero,
                          );
                        }).toList(),
                      ),
                    ],

                    const SizedBox(height: 4),
                    Text(
                      _parkMetaLine(park, userCount),
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Colors.black54,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Actions
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: isOpening
                                ? null
                                : () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            ChatRoomScreen(parkId: parkId),
                                      ),
                                    ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF567D46),
                              side: const BorderSide(color: Color(0xFF567D46)),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              minimumSize: const Size(0, 38),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: const VisualDensity(
                                horizontal: -2,
                                vertical: -2,
                              ),
                            ),
                            child: const Text(
                              "Park Chat",
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor:
                                  isCheckedIn ? Colors.red : Colors.green,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              minimumSize: const Size(0, 38),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: const VisualDensity(
                                horizontal: -2,
                                vertical: -2,
                              ),
                            ),
                            onPressed: (isBusy || isOpening)
                                ? null
                                : () => _toggleCheckIn(park),
                            child: isBusy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
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
                  color: Colors.black.withValues(alpha: 0.08),
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

  Widget _buildSectionTitle(String title, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildNewsCard(FeedArticle article) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openNewsArticle(article),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF3E2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      article.source,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF365A38),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _formatArticleTime(article.publishedAt),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.open_in_new_rounded,
                    size: 18,
                    color: Colors.black38,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                article.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.28,
                ),
              ),
              if (article.summary.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  article.summary,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.black87,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNewsSection() {
    final visibleArticles = _newsArticles.take(_visibleNewsCount).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(
          'Dog News & Tips',
          trailing: IconButton(
            onPressed: _isRefreshingNews
                ? null
                : () => _loadNewsArticles(forceRefresh: true),
            tooltip: 'Refresh news',
            icon: _isRefreshingNews
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ),
        if (_isLoadingNews)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFDCE7D6)),
              ),
              child: const Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Fetching the latest dog news and park-side tips...',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        else if (_newsError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text(
              _newsError!,
              style: const TextStyle(color: Colors.black54),
            ),
          )
        else ...[
          ...visibleArticles.map(_buildNewsCard),
          if (_visibleNewsCount < _newsArticles.length)
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 6, 10, 10),
              child: Text(
                'Scroll for more articles',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.black54,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ],
    );
  }

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    super.build(context); // KeepAlive mixin
    final searchActive = _parkSearchQuery.isNotEmpty;
    final searchUiActive = searchActive || _parkSearchFocusNode.hasFocus;
    final displayedParks = _searchedParks;

    return Scaffold(
      body: Stack(
        children: [
          RepaintBoundary(
            child: ListView(
              controller: _scrollController,
              cacheExtent: 1200, // Increased from 800 to reduce scroll jank
              padding: const EdgeInsets.only(bottom: 70),
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.14),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _parkSearchController,
                            focusNode: _parkSearchFocusNode,
                            textInputAction: TextInputAction.search,
                            onTapOutside: (_) =>
                                FocusScope.of(context).unfocus(),
                            onChanged: (_) {
                              if (mounted) setState(() {});
                            },
                            onSubmitted: (_) => _searchParksByName(),
                            style: const TextStyle(
                              color: Colors.black87,
                              fontWeight: FontWeight.w600,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Search parks by name',
                              hintStyle: const TextStyle(color: Colors.black45),
                              prefixIcon: const Icon(
                                Icons.search_rounded,
                                color: Color(0xFF365A38),
                              ),
                              suffixIcon: _parkSearchController.text.isEmpty &&
                                      !searchActive
                                  ? null
                                  : IconButton(
                                      tooltip: 'Clear search',
                                      icon: const Icon(Icons.close),
                                      onPressed: _clearParkSearch,
                                    ),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 14,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: const BorderSide(
                                  color: Color(0x22000000),
                                  width: 1.2,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: const BorderSide(
                                  color: Color(0x22000000),
                                  width: 1.2,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: const BorderSide(
                                  color: Color(0xFF567D46),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF567D46), Color(0xFF365A38)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ElevatedButton(
                            onPressed: _isSearching ? null : _searchParksByName,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 16,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: const Text(
                              'Search',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (searchActive || _isSearching) ...[
                  _buildSectionTitle('Search Results'),
                  if (_isSearching)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (displayedParks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Text(
                        'No parks found for "$_parkSearchQuery". Try a broader name.',
                        style: const TextStyle(color: Colors.black54),
                      ),
                    )
                  else
                    ...displayedParks.map((p) => _buildParkCard(
                          p,
                          isFavorite: _favoriteParkIds.contains(p.id),
                        )),
                ],
                if (_favoriteParks.isNotEmpty) ...[
                  _buildSectionTitle("Liked Parks"),
                  ..._favoriteParks
                      .map((p) => _buildParkCard(p, isFavorite: true))
                      .toList(),
                ],
                _buildNewsSection(),
              ],
            ),
          ),
          // Start Walk button - floating above ad banner
          if (!widget.isWalkActive && !searchUiActive)
            Positioned(
              left: 16,
              right: 16,
              bottom: 78,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color:
                                const Color(0xFF567D46).withValues(alpha: 0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Material(
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          onTap: widget.onStartWalk,
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              gradient: const LinearGradient(
                                colors: [
                                  Color(0xFF567D46),
                                  Color(0xFF4a6c3a),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 20,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.directions_walk,
                                  color: Colors.white,
                                  size: 22,
                                ),
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.pets,
                                  color: Colors.white,
                                  size: 18,
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  "Start a Walk",
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 17,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 64,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color:
                                const Color(0xFF365A38).withValues(alpha: 0.18),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          onTap: _scrollToTop,
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 0,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.vertical_align_top_rounded,
                                  color: Color(0xFF365A38),
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
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
