// lib/screens/map_tab.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:location/location.dart' as loc;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inthepark/widgets/interstitial_ad_manager.dart';
import 'package:inthepark/features/add_event_sheet.dart';
import 'package:inthepark/features/celebration_dialog.dart';
import 'package:inthepark/features/walk_manager.dart';
import 'package:inthepark/models/park_model.dart';
import 'package:inthepark/services/firestore_service.dart';
import 'package:inthepark/services/location_service.dart';
import 'package:inthepark/utils/utils.dart';

// ---------- Filter Option ----------
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
    with AutomaticKeepAliveClientMixin<MapTab>, WidgetsBindingObserver {
  // --- Map Controller + Completer (for reliable camera ops) ---
  GoogleMapController? _mapController;
  final Completer<GoogleMapController> _mapCtlCompleter = Completer();

  final loc.Location _location = loc.Location();
  late final LocationService _locationService;

  // Walk manager
  late final WalkManager _walk;
  late final VoidCallback _walkListener;

  // Ads
  late final InterstitialAdManager _adManager;

  LatLng? _finalPosition;
  LatLng _currentMapCenter = const LatLng(43.7615, -79.4111);
  bool _isMapReady = false;

  // Park state
  final Set<String> _existingParkIds = {};
  final Map<String, Marker> _markersMap = {}; // keyed by parkId
  final Map<String, List<String>> _parkServicesById = {}; // cache per parkId
  List<Park> _allParks = []; // current parks list

  // Filters
  final List<_FilterOption> _filterOptions = const [
    _FilterOption('Off-leash Dog Park', 'Dog Park', Icons.pets),
    _FilterOption('Off-leash Trail', 'Off-leash Trail', Icons.terrain),
    _FilterOption('On-leash Trail', 'On-leash Trail', Icons.directions_walk),
    _FilterOption('Off-leash Beach', 'Beach', Icons.beach_access),
  ];
  final Set<String> _selectedFilters = {};

  // Favorites/pets
  List<String> _favoritePetIds = [];
  final String? currentUserId = FirebaseAuth.instance.currentUser?.uid;

  // Flags & UI state
  bool _isSearching = false;
  bool _finishingWalk = false; // disables End Walk + shows loader
  bool _isCentering = false; // prevent spam taps on center FAB

  // Debounces & listeners
  Timer? _locationSaveDebounce;
  Timer? _filterDebounce;
  final List<StreamSubscription<QuerySnapshot>> _parksSubs = [];
  String _parksListenerKey = ''; // to avoid rebuilding identical listeners

  // --- UI ticker so the timer text updates every second immediately ---
  Timer? _uiTicker;
  void _startUiTicker() {
    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!_walk.isActive) {
        _stopUiTicker();
        return;
      }
      setState(() {}); // refresh elapsed text
    });
  }

  void _stopUiTicker() {
    _uiTicker?.cancel();
    _uiTicker = null;
  }

  Future<LatLng?> _getFreshUserLatLng({
    Duration freshTimeout = const Duration(milliseconds: 2500),
    double minAccuracyMeters = 50, // accept up to 50m accuracy
  }) async {
    // 1) If walking and the last point is fresh, reuse it.
    if (_walk.points.isNotEmpty) {
      final last = _walk.points.last;
      return last;
    }

    // 2) Try to get a *fresh* GPS fix with high accuracy, then restore default.
    try {
      await _location.changeSettings(
        accuracy: loc.LocationAccuracy.high,
        interval: 0,
        distanceFilter: 0,
      );

      final fresh = await _location.onLocationChanged.firstWhere((l) {
        final acc = l.accuracy ?? double.infinity;
        return l.latitude != null &&
            l.longitude != null &&
            acc <= minAccuracyMeters;
      }).timeout(freshTimeout);

      if (fresh.latitude != null && fresh.longitude != null) {
        return LatLng(fresh.latitude!, fresh.longitude!);
      }
    } catch (_) {
      // Ignore and fall through to cached sources.
    } finally {
      // Restore to a saner default to save battery.
      try {
        await _location.changeSettings(
          accuracy: loc.LocationAccuracy.balanced,
        );
      } catch (_) {}
    }

    // 3) Fall back to the instant reading (may be cached by the OS).
    try {
      final l = await _location
          .getLocation()
          .timeout(const Duration(milliseconds: 800));
      if (l.latitude != null && l.longitude != null) {
        return LatLng(l.latitude!, l.longitude!);
      }
    } catch (_) {}

    // 4) Fall back to your saved/cached app location.
    final saved = await _locationService.getUserLocationOrCached();
    if (saved != null) return saved;

    // 5) Last resort: current camera center (never null here).
    return _currentMapCenter;
  }

  // --- Assets -> Bitmap ---
  Future<BitmapDescriptor> _bitmapFromAsset(
    String assetPath, {
    int width = 64, // target logical px
  }) async {
    final data = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: width,
      targetHeight: width,
    );
    final frame = await codec.getNextFrame();
    final byteData =
        await frame.image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
  }

  // --- Custom bitmaps for walk notes (pee/poop/caution) ---
  BitmapDescriptor? _peeIcon;
  BitmapDescriptor? _poopIcon;
  BitmapDescriptor? _cautionIcon;

  Future<void> _ensureNoteIcons() async {
    _peeIcon ??= await _bitmapFromAsset('assets/icon/pee.png', width: 64);
    _poopIcon ??= await _bitmapFromAsset('assets/icon/poop.png', width: 64);
    _cautionIcon ??= await _bitmapFromIcon(
      Icons.warning_amber_rounded,
      fg: Colors.black87,
      bg: Colors.amber.shade600,
    );
  }

  String _dayKeyLocal(DateTime dt) {
    final d = DateTime(dt.year, dt.month, dt.day); // local midnight
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd'; // e.g. 2025-01-31
  }

  /// Atomically update the user's daily walk streak.
  /// Path: owners/{uid}/stats/walkStreak
  Future<_StreakResult> _updateDailyStreak() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const _StreakResult(
        alreadyUpdatedToday: false,
        wasIncremented: false,
        isNewRecord: false,
        current: 0,
        longest: 0,
      );
    }

    final docRef = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('stats')
        .doc('walkStreak');

    // DST-safe "today" and "yesterday"
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todayKey = _dayKeyLocal(today);
    final yesterdayKey = _dayKeyLocal(today.subtract(const Duration(days: 1)));

    return FirebaseFirestore.instance.runTransaction((txn) async {
      final snap = await txn.get(docRef);

      int current = 0;
      int longest = 0;
      String? lastDate;

      if (snap.exists) {
        final data = snap.data() as Map<String, dynamic>;
        current = (data['current'] ?? 0) as int;
        longest = (data['longest'] ?? 0) as int;
        lastDate = (data['lastDate'] as String?)?.trim();
      }

      final alreadyToday = (lastDate == todayKey);
      bool incremented = false;

      if (!alreadyToday) {
        if (lastDate == yesterdayKey) {
          current += 1;
        } else {
          current = 1;
        }
        incremented = true;
        lastDate = todayKey;
      }

      bool newRecord = false;
      if (current > longest) {
        longest = current;
        newRecord = true;
      }

      if (incremented || newRecord || !snap.exists) {
        txn.set(
          docRef,
          {
            'current': current,
            'longest': longest,
            'lastDate': lastDate,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      }

      return _StreakResult(
        alreadyUpdatedToday: alreadyToday,
        wasIncremented: incremented,
        isNewRecord: newRecord,
        current: current,
        longest: longest,
      );
    });
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

  /// Draw a round badge with a Material icon and return as a BitmapDescriptor
  Future<BitmapDescriptor> _bitmapFromIcon(
    IconData icon, {
    required Color fg,
    required Color bg,
    double size = 64,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()..color = bg;

    final double radius = size / 2;
    final ui.Offset center = ui.Offset(radius, radius);

    canvas.drawCircle(center, radius, paint);

    final textPainter = TextPainter(
      textDirection: ui.TextDirection.ltr,
      textAlign: TextAlign.center,
    );

    final double iconSize = size * 0.58;
    textPainter.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: iconSize,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: fg,
      ),
    );
    textPainter.layout();

    final ui.Offset iconOffset = ui.Offset(
      center.dx - textPainter.width / 2,
      center.dy - textPainter.height / 2,
    );
    textPainter.paint(canvas, iconOffset);

    final picture = recorder.endRecording();
    final ui.Image img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
  }

  // --- Encouragements (used by celebration dialog) ---
  static const _encouragements = <String>[
    "Way to go!",
    "Good job!",
    "Pawsome!",
    "Nice work!",
    "You crushed it!",
    "Amazing stride!",
    "Keep wagging!",
    "Walkstar!",
  ];

  // --- Parks cache keys ---
  static const _kParksCacheKey = 'map.parks_cache.v2';
  static const _kParksCacheTsKey = 'map.parks_cache_ts.v2';
  static const Duration _cacheTtl = Duration(hours: 3);

  // Helper to format the timer text (reads from _walk.elapsed)
  String _formatElapsed() {
    final s = _walk.elapsed.inSeconds;
    final hh = (s ~/ 3600).toString().padLeft(2, '0');
    final mm = ((s % 3600) ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return (s >= 3600) ? '$hh:$mm:$ss' : '$mm:$ss';
  }

  @override
  bool get wantKeepAlive => true;

  // ======== Walk persistence state ========
  String? _currentWalkId; // Firestore owners/{uid}/walks/{walkId}
  bool _persistingWalk = false;

  // in-memory notes to be saved at end
  final Map<String, Marker> _noteMarkers = {}; // keyed by noteId
  final Map<String, Map<String, String?>> _noteMeta = {}; // id -> {type,msg}
  final Map<String, int> _noteIndexById = {}; // id -> index in _noteRecords
  final List<Map<String, dynamic>> _noteRecords = [];
  int _noteSeq = 0;

  // When viewing a past walk
  Set<Polyline> _historicPolylines = {};
  final Map<String, Marker> _historicNoteMarkers = {};

  // track last explicit camera move to help refocus on appear
  DateTime _lastCameraMove = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isSearching = true;
    _locationService = LocationService(dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '');
    _fetchFavorites();

    _walk = WalkManager(location: _location);
    _walkListener = () {
      if (mounted) setState(() {}); // WalkManager internal changes
    };
    _walk.addListener(_walkListener);
    _walk.restoreIfAny();

    // Ads: create manager & preload one ad up front
    _adManager = InterstitialAdManager(cooldownSeconds: 60);
    _adManager.preload();

    _loadSavedLocationAndSetMap();

    // Try to restore cached parks immediately for instant UI
    _restoreCachedParks();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initLocationFlow();
      if (_finalPosition != null) {
        _moveCameraTo(_finalPosition!, zoom: 17);
      }
    });
    // Prewarm icons (best-effort)
    // ignore: discarded_futures
    _ensureNoteIcons();
  }

  // --------------- Walk notes (pee/poop/caution) ---------------
  Future<LatLng?> _currentUserLatLng() async {
    if (_walk.points.isNotEmpty) return _walk.points.last;
    if (_finalPosition != null) return _finalPosition!;
    final cached = _currentMapCenter;
    try {
      final l = await _location
          .getLocation()
          .timeout(const Duration(milliseconds: 400));
      if (l.latitude != null && l.longitude != null) {
        return LatLng(l.latitude!, l.longitude!);
      }
    } catch (_) {}
    return cached;
  }

  Future<void> _addWalkNote(String type) async {
    if (!_walk.isActive) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Start a walk to add notes.")),
      );
      return;
    }

    // Ensure icons exist BEFORE creating markers so they show instantly
    await _ensureNoteIcons();

    // For caution, collect a message
    String? noteMsg;
    if (type == 'caution') {
      final input = await showDialog<String>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          final ctrl = TextEditingController();
          return AlertDialog(
            title: const Text('Add Caution'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 2,
              decoration: const InputDecoration(
                hintText: 'What should others watch out for?',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null), // cancel
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(ctrl.text),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );

      if (input == null) return;
      noteMsg = input.trim();
      if (noteMsg.isEmpty) return;
    }

    final here = await _currentUserLatLng();
    if (here == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't get your location.")),
      );
      return;
    }

    // pick icon + title
    late final BitmapDescriptor iconBitmap;
    late final String title;
    switch (type) {
      case 'pee':
        iconBitmap = _peeIcon!;
        title = 'Pee';
      case 'poop':
        iconBitmap = _poopIcon!;
        title = 'Poop';
      default:
        iconBitmap = _cautionIcon!;
        title = 'Caution';
    }

    final id = 'note_${_noteSeq++}';
    final m = Marker(
      markerId: MarkerId(id),
      position: here,
      draggable: true,
      icon: iconBitmap,
      infoWindow: InfoWindow(title: title, snippet: noteMsg),
      onDragEnd: (pos) => _updateNotePosition(id, pos),
    );

    setState(() {
      _noteMeta[id] = {'type': type, 'message': noteMsg};
      _noteMarkers[id] = m; // shows immediately
    });

    // Record for persistence
    final recIndex = _noteRecords.length;
    _noteIndexById[id] = recIndex;
    _noteRecords.add({
      'id': id,
      'type': type, // pee | poop | caution
      'message': noteMsg,
      'lat': here.latitude,
      'lng': here.longitude,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  void _updateNotePosition(String id, LatLng newPos) {
    final existing = _noteMarkers[id];
    if (existing == null) return;
    final updated = existing.copyWith(positionParam: newPos);
    setState(() {
      _noteMarkers[id] = updated;
    });

    final i = _noteIndexById[id];
    if (i != null && i >= 0 && i < _noteRecords.length) {
      _noteRecords[i]['lat'] = newPos.latitude;
      _noteRecords[i]['lng'] = newPos.longitude;
    }
  }

  // --------------- Lifecycle & map setup ---------------
  Future<void> _loadSavedLocationAndSetMap() async {
    final savedLocation = await _locationService.getSavedUserLocation();
    setState(() {
      _finalPosition = savedLocation ?? const LatLng(43.7615, -79.4111);
      _isMapReady = true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _parksSubs) {
      s.cancel();
    }
    _parksSubs.clear();
    _locationSaveDebounce?.cancel();
    _filterDebounce?.cancel();
    _uiTicker?.cancel();
    _adManager.dispose();
    _mapController?.dispose();
    _walk.removeListener(_walkListener);
    _walk.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // no-op: WalkManager manages its own timers
  }

  // --------------- Walk: start/stop + persistence ---------------
  Future<void> _toggleWalk() async {
    if (_walk.isActive) {
      // Disable button immediately and show loader
      if (!_finishingWalk) setState(() => _finishingWalk = true);

      // END walk
      await _walk.stop();
      _stopUiTicker();

      // WalkManager decides if it's long enough
      if (!_walk.meetsMinimum) {
        await _discardCurrentWalk();
        if (mounted) {
          setState(() => _finishingWalk = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Walk not saved. ${_walk.tooShortReason}")),
          );
        }
        return;
      }

      // Long enough — persist + celebrate
      final saved = await _persistWalkSession(); // save route + notes

      // Get streak BEFORE showing the dialog so we can render it inside
      _StreakResult? streak;
      if (saved) {
        streak = await _updateDailyStreak();
      }

// Capture values NOW; don't read from _walk later.
      final steps_ = _walk.steps;
      final meters_ = _walk.meters;
      final streakCurrent_ = streak?.current;
      final streakLongest_ = streak?.longest;
      final streakIsNewRecord_ = streak?.isNewRecord ?? false;

// Re-enable button BEFORE showing the dialog.
      if (mounted) setState(() => _finishingWalk = false);

// Show dialog on the next frame to avoid platform-view jank.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showCelebrationDialog(
          steps: steps_,
          meters: meters_,
          streakCurrent: streakCurrent_,
          streakLongest: streakLongest_,
          streakIsNewRecord: streakIsNewRecord_,
        );
      });

      // Re-enable after dialog/ads
      if (mounted) setState(() => _finishingWalk = false);
    } else {
      // START walk
      if (!await _ensureLocationPermission()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Location permission is required to start a walk."),
          ),
        );
        return;
      }
      final startFuture =
          _walk.start(); // fire-and-forget; start sets isActive synchronously
      if (mounted) setState(() {}); // flip UI to "End Walk" immediately
      _startUiTicker(); // start ticking right away
      _startWalkSession(); // create Firestore doc, clear local notes

// Optional: surface errors without crashing UX
      startFuture.catchError((e, _) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't start walk: $e")),
        );
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Walk started. Have fun!")),
      );
    }
  }

  Future<void> _startWalkSession() async {
    _noteMarkers.clear();
    _noteMeta.clear();
    _noteRecords.clear();
    _noteIndexById.clear();

    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) {
      _currentWalkId = null;
      return;
    }

    final walksCol = FirebaseFirestore.instance
        .collection('owners')
        .doc(currentUid)
        .collection('walks');

    final docRef = walksCol.doc(); // id generated locally
    _currentWalkId = docRef.id;

    // Fire-and-forget; no await here
    docRef.set({
      'status': 'active',
      'startedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true)).catchError((e) {
      debugPrint('walk session set() failed: $e');
    });
  }

  Future<void> _discardCurrentWalk() async {
    if (_currentWalkId == null) return;
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid != null) {
        final walkRef = FirebaseFirestore.instance
            .collection('owners')
            .doc(currentUid)
            .collection('walks')
            .doc(_currentWalkId);
        await walkRef.delete();
      }
    } catch (e) {
      debugPrint('discard walk error: $e');
    } finally {
      _currentWalkId = null;
    }
  }

  Future<bool> _persistWalkSession() async {
    if (_persistingWalk) return false;
    if (!_walk.meetsMinimum) return false;

    _persistingWalk = true;
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null || _currentWalkId == null) return false;

      final walkRef = FirebaseFirestore.instance
          .collection('owners')
          .doc(currentUid)
          .collection('walks')
          .doc(_currentWalkId);

      final route = _walk.points
          .map((p) => GeoPoint(p.latitude, p.longitude))
          .toList(growable: false);

      await walkRef.set({
        'status': 'completed',
        'endedAt': FieldValue.serverTimestamp(),
        'durationSec': _walk.elapsed.inSeconds,
        'distanceMeters': _walk.meters,
        'steps': _walk.steps,
        'route': route,
      }, SetOptions(merge: true));

      if (_noteRecords.isNotEmpty) {
        final batch = FirebaseFirestore.instance.batch();
        for (final rec in _noteRecords) {
          final nref = walkRef.collection('notes').doc(rec['id'] as String);
          batch.set(
            nref,
            {
              'type': rec['type'],
              'message': rec['message'],
              'position': GeoPoint(rec['lat'] as double, rec['lng'] as double),
              'createdAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
        }
        await batch.commit();
      }

      _currentWalkId = null;
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Error saving walk: $e")));
      }
      return false;
    } finally {
      _persistingWalk = false;
    }
  }

  // --------------- View a past walk (route + notes) ---------------
  Future<void> loadWalkAndShow(String walkId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final walkRef = FirebaseFirestore.instance
          .collection('owners')
          .doc(uid)
          .collection('walks')
          .doc(walkId);

      final walkSnap = await walkRef.get();
      if (!walkSnap.exists) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Walk not found.")),
        );
        return;
      }

      final data = walkSnap.data()!;
      final List<dynamic> route = (data['route'] ?? []) as List<dynamic>;
      final pts = <LatLng>[];
      for (final gp in route) {
        if (gp is GeoPoint) {
          pts.add(LatLng(gp.latitude, gp.longitude));
        } else if (gp is Map && gp['lat'] != null && gp['lng'] != null) {
          pts.add(LatLng(
              (gp['lat'] as num).toDouble(), (gp['lng'] as num).toDouble()));
        }
      }

      _historicPolylines = pts.isEmpty
          ? {}
          : {
              Polyline(
                polylineId: PolylineId('walk_$walkId'),
                points: pts,
                width: 6,
                color: Colors.blueAccent,
                geodesic: true,
                startCap: Cap.roundCap,
                endCap: Cap.roundCap,
                jointType: JointType.round,
              ),
            };

      _historicNoteMarkers.clear();
      final notesSnap = await walkRef.collection('notes').get();
      await _ensureNoteIcons();

      for (final d in notesSnap.docs) {
        final n = d.data();
        final type = (n['type'] ?? '') as String;
        final msg = (n['message'] as String?)?.trim();
        final pos = n['position'];
        if (pos is! GeoPoint) continue;

        BitmapDescriptor icon;
        String title;
        switch (type) {
          case 'pee':
            icon = _peeIcon!;
            title = 'Pee';
          case 'poop':
            icon = _poopIcon!;
            title = 'Poop';
          default:
            icon = _cautionIcon!;
            title = 'Caution';
        }

        final id = 'hist_${d.id}';
        _historicNoteMarkers[id] = Marker(
          markerId: MarkerId(id),
          position: LatLng(pos.latitude, pos.longitude),
          icon: icon,
          infoWindow: InfoWindow(title: title, snippet: msg),
        );
      }

      if (pts.isNotEmpty) {
        await _moveCameraTo(pts.first, zoom: 16);
      }

      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Error loading walk: $e")));
    }
  }

  // --------------- Location & parks flow ---------------
  String _checkedInForSince(DateTime since) {
    final diff = DateTime.now().difference(since);
    final mins = diff.inMinutes;
    if (mins < 1) return "< 1 min";
    if (mins < 60) return "$mins min";
    final hrs = diff.inHours;
    final rem = mins - hrs * 60;
    return rem == 0 ? "$hrs hr" : "$hrs hr $rem min";
  }

  Future<void> _initLocationFlow() async {
    try {
      final userLocation = await _locationService.getUserLocationOrCached();
      if (userLocation != null) {
        setState(() {
          _finalPosition = userLocation;
          _isMapReady = true;
        });

        if (_mapController != null) {
          await _moveCameraTo(userLocation, zoom: 17);
        }

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

      await _applyMarkerDiff(nearbyParks);
      await _hydrateServicesForParks(nearbyParks);
      _rebuildParksListeners();

      // Cache the full parks list (fast resume)
      await _cacheParksAndServices(nearbyParks);

      if (!mounted) return;
      setState(() => _isSearching = false);

      // Check-in prompt if at a park
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

  // ---- Cache restore/save ----
  Future<void> _restoreCachedParks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts = prefs.getInt(_kParksCacheTsKey);
      if (ts == null) return;

      final stale =
          DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts)) >
              _cacheTtl;
      if (stale) return;

      final raw = prefs.getString(_kParksCacheKey);
      if (raw == null) return;

      final rawList = jsonDecode(raw) as List<dynamic>;
      final parks =
          rawList.map((e) => Park.fromJson(e as Map<String, dynamic>)).toList();

      final nextMarkers = <String, Marker>{};
      for (final p in parks) {
        final snippet = (p.userCount > 0) ? 'Users: ${p.userCount}' : null;
        nextMarkers[p.id] = Marker(
          markerId: MarkerId(p.id),
          position: LatLng(p.latitude, p.longitude),
          infoWindow: InfoWindow(title: p.name, snippet: snippet),
          onTap: () => _showUsersInPark(p.id, p.name, p.latitude, p.longitude),
        );
        if (p.services.isNotEmpty) {
          _parkServicesById[p.id] = List<String>.from(p.services);
        }
      }

      if (!mounted) return;
      setState(() {
        _allParks = parks;
        _markersMap
          ..clear()
          ..addAll(nextMarkers);
      });
    } catch (e) {
      debugPrint('restore cache failed: $e');
    }
  }

  Future<void> _cacheParksAndServices(List<Park> parks) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = parks.map((p) => p.toJson()).toList();
      await prefs.setString(_kParksCacheKey, jsonEncode(payload));
      await prefs.setInt(
        _kParksCacheTsKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('cache parks failed: $e');
    }
  }

  // ---- Services hydrator ----
  Future<void> _hydrateServicesForParks(List<Park> parks) async {
    final ids = parks.map((p) => p.id).toList().chunked(10);
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

  // ---- Marker diff keyed by park.id ----
  Future<void> _applyMarkerDiff(List<Park> parks) async {
    final next = <String, Marker>{};
    final futures = parks.map((p) async {
      final m = await _createParkMarker(p);
      return MapEntry(p.id, m);
    }).toList();

    for (final entry in await Future.wait(futures)) {
      next[entry.key] = entry.value;
    }

    if (!mounted) return;
    setState(() {
      _markersMap
        ..clear()
        ..addAll(next);
    });
  }

  void _rebuildParksListeners() {
    final ids = _markersMap.keys.toList()..sort();
    final newKey = ids.join(',');
    if (newKey == _parksListenerKey) {
      return; // no change to listener set
    }
    _parksListenerKey = newKey;

    for (final s in _parksSubs) {
      s.cancel();
    }
    _parksSubs.clear();

    if (ids.isEmpty) return;

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

            final oldMarker = _markersMap[parkId]!;
            final newSnippet = count > 0 ? 'Users: $count' : null;

            // Compare actual visible change instead of object equality
            final oldSnippet = oldMarker.infoWindow.snippet;
            if (oldSnippet != newSnippet) {
              _markersMap[parkId] = oldMarker.copyWith(
                infoWindowParam: InfoWindow(
                  title: oldMarker.infoWindow.title,
                  snippet: newSnippet,
                ),
              );
              changedInfo = true;
            }

            final prevSvcs = _parkServicesById[parkId] ?? const [];
            if (!_listEquals(prevSvcs, services)) {
              _parkServicesById[parkId] = services;
              servicesChanged = true;
            }
          }
        }

        if ((changedInfo || servicesChanged) && mounted) {
          setState(() {});
          if (servicesChanged && _selectedFilters.isNotEmpty) {
            _filterDebounce?.cancel();
            _filterDebounce =
                Timer(const Duration(milliseconds: 120), _applyFilters);
          }
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

  // --------------- Map callbacks ---------------
  void _onMapCreated(GoogleMapController controller) async {
    _mapController = controller;
    if (!_mapCtlCompleter.isCompleted) {
      _mapCtlCompleter.complete(controller);
    }
    _currentMapCenter = _finalPosition ?? const LatLng(43.7615, -79.4111);

    // Ensure immediate, reliable focusing when map is first created.
    if (_finalPosition != null) {
      await _moveCameraTo(_finalPosition!, zoom: 17);
    }
  }

  void _onCameraMove(CameraPosition position) {
    _currentMapCenter = position.target;
    _lastCameraMove = DateTime.now();
    _locationSaveDebounce?.cancel();
    _locationSaveDebounce = Timer(const Duration(seconds: 2), () {
      final c = _currentMapCenter;
      // ignore: discarded_futures
      _locationService.saveUserLocation(c.latitude, c.longitude);
    });
  }

  Future<void> _moveCameraTo(LatLng pos, {double zoom = 17}) async {
    // Always use the completer to ensure readiness
    final ctl = await _mapCtlCompleter.future;

    // Perform a reliable two-step move then animate, with small frame delay
    await ctl.moveCamera(CameraUpdate.newCameraPosition(
      CameraPosition(target: pos, zoom: zoom),
    ));
    await Future.delayed(const Duration(milliseconds: 50));
    await ctl.animateCamera(CameraUpdate.newLatLngZoom(pos, zoom));

    _lastCameraMove = DateTime.now();
  }

  // --------------- Center-on-me (more robust) ---------------
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
    if (_isCentering) return;
    setState(() => _isCentering = true);

    try {
      if (!await _ensureLocationPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Location permission is required.")),
          );
        }
        return;
      }

      final user = await _getFreshUserLatLng();
      if (user == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Unable to get current location.")),
          );
        }
        return;
      }

      _finalPosition = user;
      _currentMapCenter = user;

      // Two-step move for reliability (instant place, then smooth settle).
      await _moveCameraTo(user, zoom: 17);

      // Update cache + nearby parks asynchronously (don’t interfere with camera)
      // ignore: discarded_futures
      _locationService.saveUserLocation(user.latitude, user.longitude);
      // ignore: discarded_futures
      _loadNearbyParks(user);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error centering: $e")),
      );
    } finally {
      if (mounted) setState(() => _isCentering = false);
    }
  }

  // --------------- Park dialogs & actions ---------------
  Future<void> _ensureParkDocExists(
    String parkId,
    String name,
    double lat,
    double lng, {
    List<String> services = const [],
  }) async {
    if (_existingParkIds.contains(parkId)) return;
    try {
      final parkRef =
          FirebaseFirestore.instance.collection('parks').doc(parkId);
      final parkSnap = await parkRef.get();
      if (!parkSnap.exists) {
        await parkRef.set({
          'id': parkId,
          'name': name,
          'latitude': lat,
          'longitude': lng,
          'services': services,
          'createdAt': Timestamp.now(),
        }, SetOptions(merge: true));
      }
      _existingParkIds.add(parkId);
    } catch (e) {
      // best-effort
      debugPrint('ensureParkDocExists error: $e');
    }
  }

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
        const SnackBar(
            content: Text("You are already checked in to this park.")),
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

  Future<void> _showUsersInPark(String parkId, String parkName,
      double parkLatitude, double parkLongitude) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    if (!mounted) return;
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
      // Best-effort ensure the park doc exists when opening details
      await _ensureParkDocExists(parkId, parkName, parkLatitude, parkLongitude);

      final fs = FirestoreService();
      bool isLiked = await fs.isParkLiked(parkId);

      final likesCol = FirebaseFirestore.instance
          .collection('parks')
          .doc(parkId)
          .collection('likes');

      final parkDoc = await FirebaseFirestore.instance
          .collection('parks')
          .doc(parkId)
          .get();

      List<String> services = [];
      if (parkDoc.exists &&
          parkDoc.data() != null &&
          parkDoc.data()!.containsKey('services')) {
        services = List<String>.from(parkDoc['services'] ?? []);
      }

      final activeDocRef = FirebaseFirestore.instance
          .collection('parks')
          .doc(parkId)
          .collection('active_users')
          .doc(currentUser.uid);
      final activeDoc = await activeDocRef.get();
      bool isCheckedIn = activeDoc.exists;

      if (isCheckedIn) {
        final data = activeDoc.data() as Map<String, dynamic>;
        if (data.containsKey('checkedInAt')) {
          final checkedInAt = (data['checkedInAt'] as Timestamp).toDate();
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
      final profiles = await _loadPublicProfiles(userIds.toSet());

      final List<Map<String, dynamic>> userList = [];
      if (userIds.isNotEmpty) {
        for (var i = 0; i < userIds.length; i += 10) {
          final batchIds = userIds.sublist(
              i, i + 10 > userIds.length ? userIds.length : i + 10);
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
            final checkInTime = (userDoc.data())['checkedInAt'] as Timestamp?;
            final ownerPets = petsByOwner[ownerId] ?? [];

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
                    ? _checkedInForSince(checkInTime.toDate())
                    : '',
              });
            }
          }
        }
      }

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close spinner

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
                  StreamBuilder<QuerySnapshot>(
                    stream: likesCol.snapshots(),
                    builder: (context, snap) {
                      final likeCount =
                          snap.hasData ? snap.data!.docs.length : 0;

                      return Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 2.0),
                            child: Text(
                              '$likeCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: isLiked ? 'Unlike' : 'Like Park',
                            onPressed: () async {
                              try {
                                if (isLiked) {
                                  await fs.unlikePark(parkId);
                                  await likesCol.doc(currentUser.uid).delete();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text("Removed park like")),
                                    );
                                  }
                                } else {
                                  await fs.likePark(parkId);
                                  await likesCol.doc(currentUser.uid).set({
                                    'uid': currentUser.uid,
                                    'createdAt': FieldValue.serverTimestamp(),
                                  });
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text("Park liked!")),
                                    );
                                  }
                                }
                                setStateDialog(() => isLiked = !isLiked);
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content:
                                            Text("Error updating like: $e")),
                                  );
                                }
                              }
                            },
                            icon: Icon(
                              isLiked
                                  ? Icons.thumb_up
                                  : Icons.thumb_up_outlined,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
              body: Column(
                children: [
                  // Services chips
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
                            const SizedBox(width: 6),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // ... rest of the dialog body
                ],
              ),
            );
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
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
      await _checkOutFromAllParks();

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
    } catch (e) {
      debugPrint("Error checking out: $e");
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Error checking out: $e")));
      }
    } finally {
      if (_finalPosition != null) {
        await _loadNearbyParks(_finalPosition!);
      }
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Checked out successfully")),
        );
      }
    }
  }

  Future<void> _checkOutFromAllParks() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      final snaps = await FirebaseFirestore.instance
          .collectionGroup('active_users')
          .where('uid',
              isEqualTo: currentUser.uid) // <-- type must match schema
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => AddEventSheet(
        parkId: parkId,
        parkLatitude: parkLatitude,
        parkLongitude: parkLongitude,
      ),
    );
  }

  Future<Marker> _createParkMarker(Park park) async {
    // No Firestore writes here — keep marker creation lightweight.
    return Marker(
      markerId: MarkerId(park.id),
      position: LatLng(park.latitude, park.longitude),
      onTap: () {
        _showUsersInPark(park.id, park.name, park.latitude, park.longitude);
      },
      infoWindow: InfoWindow(
        title: park.name,
        onTap: () {
          _showUsersInPark(park.id, park.name, park.latitude, park.longitude);
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

      // refresh cache too
      await _cacheParksAndServices(nearbyParks);

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

  Future<void> _addFriend(String friendUserId, String petId) async {
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final stale = DateTime.now().difference(_lastCameraMove) >
          const Duration(seconds: 5);
      if (stale && _finalPosition != null && _mapController != null) {
        _moveCameraTo(_finalPosition!, zoom: 17);
      }
    });
  }

  // --------------- Build ---------------
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
    final double noteButtonsTop = MediaQuery.of(context).padding.top +
        12 /*filter padding*/ +
        64 /*approx filter height*/ +
        8 /*gap*/;

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
                  markers: {
                    ..._markersMap.values, // park markers
                    ..._noteMarkers.values, // live walk notes
                    ..._historicNoteMarkers.values, // loaded past-walk notes
                  }.toSet(),
                  polylines: {
                    ..._walkPolylines, // live walk
                    ..._historicPolylines, // loaded past walk
                  },
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  compassEnabled: true,
                ),
                _buildFilterBar(),

                if (_isSearching)
                  const Center(child: CircularProgressIndicator()),

                // Top-right walk-note buttons (only when walking)
                if (_walk.isActive)
                  Positioned(
                    top: noteButtonsTop,
                    right: 12,
                    child: SafeArea(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          FloatingActionButton(
                            heroTag: 'Mark Pee',
                            mini: true,
                            backgroundColor: Colors.amber.shade700,
                            onPressed: () => _addWalkNote('pee'),
                            tooltip: 'Mark Pee',
                            child: const ImageIcon(
                              AssetImage('assets/icon/pee.png'),
                              size: 22,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 8),
                          FloatingActionButton(
                            heroTag: 'Mark Poop',
                            mini: true,
                            backgroundColor: const Color(0xFF8D6E63),
                            onPressed: () => _addWalkNote('poop'),
                            tooltip: 'Mark Poop',
                            child: const ImageIcon(
                                AssetImage('assets/icon/poop.png'),
                                size: 22,
                                color: Colors.white),
                          ),
                          const SizedBox(height: 8),
                          _NoteFab(
                            tooltip: 'Add Caution',
                            icon: Icons.warning_amber_rounded,
                            background: Colors.amber.shade700,
                            foreground: Colors.black87,
                            onPressed: () => _addWalkNote('caution'),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Center-on-me
                Positioned(
                  bottom: 150,
                  right: 16,
                  child: FloatingActionButton(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.green,
                    heroTag: 'center_me',
                    onPressed: _isCentering ? null : _centerOnUser,
                    child: _isCentering
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location),
                  ),
                ),

                // Search around center
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

                // Walk button
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _walk.isActive
                          ? Colors.redAccent
                          : const Color(0xFF567D46),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18)),
                      elevation: 6,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _finishingWalk ? null : _toggleWalk,
                    child: _finishingWalk
                        ? const SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_walk.isActive)
                                const Icon(Icons.flag, size: 24)
                              else ...[
                                const Icon(Icons.directions_walk, size: 24),
                                const SizedBox(width: 6),
                                const Icon(Icons.pets, size: 22),
                              ],
                              const SizedBox(width: 10),
                              Text(
                                _walk.isActive ? "End Walk" : "Start New Walk",
                                style: const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w800),
                              ),
                              if (_walk.isActive) ...[
                                const SizedBox(width: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    _formatElapsed(),
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800),
                                  ),
                                ),
                              ],
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Filter bar ----------
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
              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
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
    final filtered = _selectedFilters.isEmpty
        ? _allParks
        : _allParks.where((p) {
            final svcs = _parkServicesById[p.id] ?? p.services;
            return svcs.any((s) => _selectedFilters.contains(s));
          }).toList();

    await _applyMarkerDiff(filtered);
    _rebuildParksListeners();
  }

  // ---------- Celebration ----------
  Future<void> _showCelebrationDialog({
    required int steps,
    required double meters,
    int? streakCurrent,
    int? streakLongest,
    bool streakIsNewRecord = false,
  }) async {
    if (!mounted) return;
    final km = (meters / 1000).toStringAsFixed(meters >= 100 ? 1 : 2);

    await showDialog(
      context: context,
      useRootNavigator: true, // 👈 IMPORTANT
      barrierDismissible: true,
      builder: (_) => CelebrationDialog(
        steps: steps,
        kmText: km,
        encouragements: _encouragements,
        streakCurrent: streakCurrent,
        streakLongest: streakLongest,
        streakIsNewRecord: streakIsNewRecord,
      ),
    );

    if (!mounted) return;
    // Schedule ad AFTER the dialog has popped and on a fresh frame
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _adManager.show(onUnavailable: _adManager.preload);
      } finally {
        _adManager.preload();
      }
    });
  }

  // ---------- Utils ----------
  Set<Polyline> get _walkPolylines {
    if (_walk.points.isEmpty) return {};
    return {
      Polyline(
        polylineId: const PolylineId('current_walk'),
        points: _walk.points,
        width: 6,
        color: Colors.blueAccent,
        geodesic: true,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
      ),
    };
  }
}

// ---------- Helpers ----------
extension _ChunkExt<T> on List<T> {
  List<List<T>> chunked(int size) {
    final out = <List<T>>[];
    for (var i = 0; i < length; i += size) {
      out.add(sublist(i, i + size > length ? length : i + size));
    }
    return out;
  }
}

class _NoteFab extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color background;
  final Color foreground;
  final VoidCallback onPressed;

  const _NoteFab({
    Key? key,
    required this.tooltip,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.onPressed,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      heroTag: tooltip,
      mini: true,
      backgroundColor: background,
      foregroundColor: foreground,
      onPressed: onPressed,
      tooltip: tooltip,
      child: Icon(icon),
    );
  }
}

class _StreakResult {
  final bool alreadyUpdatedToday;
  final bool wasIncremented;
  final bool isNewRecord;
  final int current;
  final int longest;

  const _StreakResult({
    required this.alreadyUpdatedToday,
    required this.wasIncremented,
    required this.isNewRecord,
    required this.current,
    required this.longest,
  });
}
