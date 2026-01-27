// lib/screens/map_tab.dart
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle, PlatformException;
import 'package:cloud_firestore/cloud_firestore.dart'; // FirebaseException

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:inthepark/widgets/level_system.dart';
import 'package:location/location.dart' as loc;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inthepark/features/add_event_sheet.dart';
import 'package:inthepark/features/celebration_dialog.dart';
import 'package:inthepark/features/walk_manager.dart';
import 'package:inthepark/models/park_model.dart';
import 'package:inthepark/services/firestore_service.dart';
import 'package:inthepark/services/location_service.dart';
import 'package:inthepark/widgets/interstitial_ad_manager.dart';
import 'package:inthepark/widgets/rewarded_streak_ads.dart';
import 'package:inthepark/widgets/map_surface.dart';
import 'package:inthepark/features/park_users_dialog.dart';

// ---------- Filter Option ----------
class _FilterOption {
  final String value; // exact service string in Firestore
  final String label; // short label to show
  final IconData icon;
  const _FilterOption(this.value, this.label, this.icon);
}

class MapTab extends StatefulWidget {
  final void Function(String parkId) onShowEvents;
  // 👇 new optional callback
  final VoidCallback? onXpGained;
  const MapTab({Key? key, required this.onShowEvents, this.onXpGained})
      : super(key: key);

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab>
    with AutomaticKeepAliveClientMixin<MapTab>, WidgetsBindingObserver {
  // --- Map Controller + Completer (for reliable camera ops) ---
  GoogleMapController? _mapController;
  final Completer<GoogleMapController> _mapCtlCompleter = Completer();
  bool _manualFinishing = false;
  final loc.Location _location = loc.Location();
  late final LocationService _locationService;

  bool _adLoaderShowing = false;

  // Walk manager
  late final WalkManager _walk;
  late final VoidCallback _walkListener;

  // Ads
  late final InterstitialAdManager _adManager;

  bool _resumeRefreshing = false;
  LatLng? _finalPosition;
  LatLng _currentMapCenter = const LatLng(43.7615, -79.4111);
  bool _isMapReady = false;

  // ---- Smooth polyline state (avoid rebuilding whole route each frame) ----
  final List<LatLng> _drawnRoute = [];
  int _lastSyncedIdx = 0;
  DateTime _lastPolylineUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  Set<Polyline> _livePolylineSet = {}; // what we feed to GoogleMap

  // Tuning knobs
  static const int _polylineUpdateMs = 400; // throttle redraws (~2–3 fps)
  static const double _minRoutePointMeters = 5; // drop near points
  static const int _simplifyEveryNPoints = 300; // run DP every N new points
  static const double _simplifyToleranceMeters = 4.0;

  // Park state
  final Set<String> _existingParkIds = {};
  final Map<String, Marker> _markersMap = {}; // keyed by parkId
  final Map<String, List<String>> _parkServicesById = {}; // cache per parkId
  List<Park> _allParks = []; // current parks list

  bool _celebratePending = false;
  int? _pcSteps;
  double? _pcMeters;
  int? _pcStreakCur;
  int? _pcStreakLongest;
  bool _pcIsNewRecord = false;

  // Precomputed visible sets (don’t rebuild in build())
  Set<Marker> _visibleMarkers = {};
  Set<Polyline> _visiblePolylines = {};

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
  bool _startingWalk = false;
  bool _isCentering = false; // prevent spam taps on center FAB

  // Debounces & listeners
  Timer? _locationSaveDebounce;
  Timer? _filterDebounce;
  Timer? _parksUiDebounce; // debounce UI after Firestore snapshot bursts
  final List<StreamSubscription<QuerySnapshot>> _parksSubs = [];
  String _parksListenerKey = '';

  // --- Timer text without rebuilding map ---
  final ValueNotifier<String> _elapsedText = ValueNotifier('00:00');
  Timer? _uiTicker;
  void _startUiTicker() {
    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_walk.isActive) {
        _stopUiTicker();
        return;
      }
      _elapsedText.value = _formatElapsed();
    });
  }

  void _stopUiTicker() {
    _uiTicker?.cancel();
    _uiTicker = null;
  }

  double _metersBetween(LatLng a, LatLng b) {
    const earth = 6371000.0;
    final dLat = _deg2rad(b.latitude - a.latitude);
    final dLng = _deg2rad(b.longitude - a.longitude);
    final la1 = _deg2rad(a.latitude);
    final la2 = _deg2rad(b.latitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la1) * math.cos(la2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * earth * math.asin(math.min(1.0, math.sqrt(h)));
  }

  double _deg2rad(double d) => d * math.pi / 180.0;

  void _resetLiveRoute() {
    _drawnRoute.clear();
    _lastSyncedIdx = 0;
    _livePolylineSet = {};
    _lastPolylineUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    _recomputeVisiblePolylines();
  }

  // --- Douglas-Peucker simplification (meters tolerance) ---
  List<LatLng> _simplifyRoute(List<LatLng> pts, double tolMeters) {
    if (pts.length <= 2) return pts;
    final keep = List<bool>.filled(pts.length, false);
    keep[0] = true;
    keep[pts.length - 1] = true;

    final stack = <List<int>>[
      [0, pts.length - 1]
    ];

    while (stack.isNotEmpty) {
      final seg = stack.removeLast();
      int start = seg[0], end = seg[1];
      double maxDist = -1;
      int index = -1;

      for (int i = start + 1; i < end; i++) {
        final d = _perpDistanceMeters(pts[i], pts[start], pts[end]);
        if (d > maxDist) {
          maxDist = d;
          index = i;
        }
      }

      if (maxDist > tolMeters && index != -1) {
        keep[index] = true;
        stack.add([start, index]);
        stack.add([index, end]);
      }
    }

    final out = <LatLng>[];
    for (int i = 0; i < pts.length; i++) {
      if (keep[i]) out.add(pts[i]);
    }
    return out;
  }

  double _perpDistanceMeters(LatLng p, LatLng a, LatLng b) {
    final latRad = _deg2rad(a.latitude);
    final mPerDegLat = 111132.92 -
        559.82 * math.cos(2 * latRad) +
        1.175 * math.cos(4 * latRad);
    final mPerDegLng =
        111412.84 * math.cos(latRad) - 93.5 * math.cos(3 * latRad);

    const ax = 0.0;
    const ay = 0.0;
    final bx = (b.longitude - a.longitude) * mPerDegLng;
    final by = (b.latitude - a.latitude) * mPerDegLat;
    final px = (p.longitude - a.longitude) * mPerDegLng;
    final py = (p.latitude - a.latitude) * mPerDegLat;

    final dx = bx - ax;
    final dy = by - ay;
    if (dx == 0 && dy == 0) {
      return math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
    }
    final t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
    final projx = ax + t * dx;
    final projy = ay + t * dy;
    return math.sqrt((px - projx) * (px - projx) + (py - projy) * (py - projy));
  }

  /// Syncs _walk.points -> _drawnRoute (distance filter + throttle).
  /// Returns true when the visible polyline actually changed.
  bool _syncPolylineIfNeeded() {
    final pts = _walk.points;
    if (pts.isEmpty) {
      if (_drawnRoute.isEmpty && _livePolylineSet.isEmpty) return false;
      _resetLiveRoute();
      return true;
    }

    final now = DateTime.now();
    if (now.difference(_lastPolylineUpdate).inMilliseconds <
        _polylineUpdateMs) {
      return false;
    }

    bool appended = false;
    for (var i = _lastSyncedIdx; i < pts.length; i++) {
      final p = pts[i];
      if (_drawnRoute.isEmpty ||
          _metersBetween(_drawnRoute.last, p) >= _minRoutePointMeters) {
        _drawnRoute.add(p);
        appended = true;
      }
    }
    _lastSyncedIdx = pts.length;

    if (!appended) {
      _lastPolylineUpdate = now;
      return false;
    }

    if (_drawnRoute.length > 2 &&
        (_drawnRoute.length % _simplifyEveryNPoints == 0)) {
      final copy = List<LatLng>.from(_drawnRoute);
      Future(() {
        final simplified = _simplifyRoute(copy, _simplifyToleranceMeters);
        _drawnRoute
          ..clear()
          ..addAll(simplified);

        if (_livePolylineSet.isEmpty) {
          _livePolylineSet = {
            Polyline(
              polylineId: const PolylineId('current_walk'),
              points: List<LatLng>.from(_drawnRoute),
              width: 6,
              color: Colors.blueAccent,
              geodesic: !Platform.isAndroid,
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
              jointType: JointType.round,
            ),
          };
        } else {
          _livePolylineSet = {
            _livePolylineSet.first
                .copyWith(pointsParam: List<LatLng>.from(_drawnRoute)),
          };
        }

        _recomputeVisiblePolylines();
        if (mounted) setState(() {});
      });
    }

    final useGeodesic = !Platform.isAndroid;
    _livePolylineSet = {
      Polyline(
        polylineId: const PolylineId('current_walk'),
        points: List<LatLng>.from(_drawnRoute),
        width: 6,
        color: Colors.blueAccent,
        geodesic: useGeodesic,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
      ),
    };
    _lastPolylineUpdate = now;
    _recomputeVisiblePolylines();
    return true;
  }

  Future<void> _showAdLoaderOverlay({
    String title = "Getting it ready…",
    String message = "One sec! A quick ad is loading 🐾",
  }) async {
    if (!mounted || _adLoaderShowing) return;
    _adLoaderShowing = true;

    // Use root navigator but don’t await it (so caller can continue)
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) {
        const themeGreen = Color(0xFF567D46);
        return WillPopScope(
          onWillPop: () async => false,
          child: Dialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: Row(
                children: [
                  SizedBox(
                    width: 46,
                    height: 46,
                    child: Stack(
                      alignment: Alignment.center,
                      children: const [
                        CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor: AlwaysStoppedAnimation<Color>(themeGreen),
                        ),
                        Icon(Icons.pets, size: 18, color: themeGreen),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(
                          message,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.25,
                            color: Colors.grey.shade700,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
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

  void _hideAdLoaderOverlay() {
    if (!mounted || !_adLoaderShowing) return;

    // Only pop if the top route is a dialog (best effort)
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) {
      nav.pop();
    }
    _adLoaderShowing = false;
  }

  /// Call this only AFTER a rewarded ad completes successfully.
  /// Revives the streak by restoring the pre-loss streak and
  /// crediting both the missed day and today's walk.
  Future<void> applyStreakReviveAfterReward() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw 'Not signed in';

    String dayKey(DateTime d) {
      final dd = DateTime(d.year, d.month, d.day);
      final mm = dd.month.toString().padLeft(2, '0');
      final dd2 = dd.day.toString().padLeft(2, '0');
      return '${dd.year}-$mm-$dd2';
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todayKey = dayKey(today);
    final y = today.subtract(const Duration(days: 1));
    final yKey = dayKey(y);

    final docRef = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('stats')
        .doc('walkStreak');

    await FirebaseFirestore.instance.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      if (!snap.exists) throw 'No streak to revive.';

      final data = snap.data() as Map<String, dynamic>;

      final canRevive = (data['canRevive'] as bool?) ?? false;
      if (!canRevive) throw 'Revive not eligible.';

      final prevBeforeLoss = (data['prevBeforeLoss'] as int?) ?? 0;
      if (prevBeforeLoss <= 0) throw 'No previous streak to revive.';

      final alreadyRevivedFor = (data['revivedForDay'] as String?)?.trim();
      if (alreadyRevivedFor == yKey) {
        throw 'Yesterday already revived.';
      }

      final lostAt = data['lostAt'];
      if (lostAt is Timestamp) {
        if (now.difference(lostAt.toDate()) > const Duration(hours: 48)) {
          throw 'Revive window expired.';
        }
      }

      int longest = (data['longest'] ?? 0) as int;

      // ✅ Restore as if you never missed:
      // prevBeforeLoss (up to the day before the missed day)
      // + 1 for the missed day (yesterday)
      // + 1 for today's walk that triggered this flow
      final int newCurrent = prevBeforeLoss + 2;

      if (newCurrent > longest) {
        longest = newCurrent;
      }

      txn.set(
        docRef,
        {
          'current': newCurrent,
          'longest': longest,
          'lastDate': todayKey, // streak now extends through today
          'revivedForDay': yKey, // the day we "filled in"
          'canRevive': false, // consume eligibility
          'prevBeforeLoss': FieldValue.delete(),
          'lostAt': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    });
  }

  String _dayKeyLocal(DateTime dt) {
    final d = DateTime(dt.year, dt.month, dt.day);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  /// Updates (or creates) the user's daily walk streak document atomically.
  /// - Increments if yesterday was walked.
  /// - Does NOT reset to 1 on a gap; it only sets revive flags.
  /// - Fallback reset to 1 is applied explicitly when user declines revive.
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

      // Keep the value before we change it, to publish eligibility metadata if we broke the streak.
      final previousStreak = current;

      bool reviveEligible = false;
      int? revivePrevBeforeLoss;

      if (!alreadyToday) {
        if (lastDate == null) {
          // First time we ever record a streak
          current = 1;
          incremented = true;
          lastDate = todayKey;
        } else if (lastDate == yesterdayKey) {
          // Chain continues
          current += 1;
          incremented = true;
          lastDate = todayKey;

          txn.set(
            docRef,
            {
              'prevBeforeLoss': FieldValue.delete(),
              'lostAt': FieldValue.delete(),
              'canRevive': false,
            },
            SetOptions(merge: true),
          );
        } else {
          // Gap detected → publish revive metadata
          txn.set(
            docRef,
            {
              'prevBeforeLoss': previousStreak,
              'lostAt': FieldValue.serverTimestamp(),
              'revivedForDay': FieldValue.delete(),
              'canRevive': previousStreak > 0,
            },
            SetOptions(merge: true),
          );

          reviveEligible = previousStreak > 0;
          revivePrevBeforeLoss = previousStreak;
        }
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
        reviveEligible: reviveEligible,
        prevBeforeLoss: revivePrevBeforeLoss,
      );
    });
  }

  /// When user chooses NOT to revive their streak,
  /// we commit the "new streak = 1 day (today)" fallback.
  Future<void> _applyStreakFallbackForToday() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final docRef = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('stats')
        .doc('walkStreak');

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todayKey = _dayKeyLocal(today);

    await FirebaseFirestore.instance.runTransaction((txn) async {
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

      // If we've already marked today somewhere else, don't touch it.
      if (lastDate == todayKey) return;

      current = 1;
      if (longest < current) longest = current;

      txn.set(
        docRef,
        {
          'current': current,
          'longest': longest,
          'lastDate': todayKey,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
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
  String? _currentWalkId;
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

  // ★ NEW: we remember previous active state to detect auto-finish
  bool _wasActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isSearching = true;
    _locationService = LocationService(dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '');
    _fetchFavorites();

    _walk = WalkManager(location: _location);

    _walkListener = () async {
      final changed = _syncPolylineIfNeeded();
      if (changed && mounted) setState(() {});
      _elapsedText.value = _formatElapsed();

      // Only auto-finish if we didn't just manually stop
      if (_wasActive &&
          !_walk.isActive &&
          !_manualFinishing &&
          !_finishingWalk) {
        await _handleWalkFinished(auto: true);
      }
      _wasActive = _walk.isActive;
    };
    _walk.addListener(_walkListener);
    _walk.restoreIfAny();

    _adManager = InterstitialAdManager(cooldownSeconds: 60);
    _adManager.preload();

    _loadSavedLocationAndSetMap();

    _restoreCachedParks();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initLocationFlow();
      if (_finalPosition != null) {
        _moveCameraTo(_finalPosition!, zoom: 17, instant: true);
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

    await _ensureNoteIcons();

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
                onPressed: () => Navigator.of(ctx).pop(null),
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
      _noteMarkers[id] = m;
      _recomputeVisibleMarkers();
    });

    final recIndex = _noteRecords.length;
    _noteIndexById[id] = recIndex;
    _noteRecords.add({
      'id': id,
      'type': type,
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
      _recomputeVisibleMarkers();
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
    // Optional: keep background mode relaxed when leaving the map UI
    () async {
      try {
        if (!_walk.isActive) {
          await _location.enableBackgroundMode(enable: false);
        }
        await _location.changeSettings(accuracy: loc.LocationAccuracy.balanced);
      } catch (_) {}
    }();

    WidgetsBinding.instance.removeObserver(this);
    for (final s in _parksSubs) {
      s.cancel();
    }
    _parksSubs.clear();

    _locationSaveDebounce?.cancel();
    _filterDebounce?.cancel();
    _parksUiDebounce?.cancel();
    _uiTicker?.cancel();
    _adManager.dispose();
    _mapController?.dispose();

    _walk.removeListener(_walkListener);

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onFastResume();
      // ★ Show any queued celebration
      if (_celebratePending && mounted) {
        _celebratePending = false;
        final s = _pcSteps ?? 0;
        final m = _pcMeters ?? 0.0;
        final sc = _pcStreakCur;
        final sl = _pcStreakLongest;
        final nr = _pcIsNewRecord;
        // clear payload
        _pcSteps = null;
        _pcMeters = null;
        _pcStreakCur = null;
        _pcStreakLongest = null;
        _pcIsNewRecord = false;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showCelebrationDialog(
            steps: s,
            meters: m,
            streakCurrent: sc,
            streakLongest: sl,
            streakIsNewRecord: nr,
          );
        });
      }
    }
  }

  Future<void> _onFastResume() async {
    if (!mounted || _resumeRefreshing) return;
    _resumeRefreshing = true;

    // 1) Immediately restore camera to last known (no awaits blocking UI)
    final pos = _finalPosition ?? _currentMapCenter;
    // fire-and-forget; the map is already on screen
    // ignore: discarded_futures
    _moveCameraTo(pos, zoom: 17, instant: true);

    // 2) Light background refresh: only reload parks if we actually moved or cache is stale
    try {
      final saved = await _locationService.getSavedUserLocation();
      final movedFar =
          (saved != null) && _metersBetween(saved, _currentMapCenter) > 150;
      final stale =
          await _isParksCacheStale(); // implement using your _kParksCacheTsKey + _cacheTtl

      if (movedFar || stale) {
        // ignore: discarded_futures
        _loadNearbyParks(saved ?? pos);
      }
    } finally {
      _resumeRefreshing = false;
    }
  }

  Future<bool> _isParksCacheStale() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_kParksCacheTsKey);
    if (ts == null) return true;
    final age =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
    return age > _cacheTtl;
  }

  Future<void> _loadNearbyParks(LatLng position) async {
    setState(() => _isSearching = true);
    try {
      final nearbyParks = await _locationService.findNearbyParks(
        position.latitude,
        position.longitude,
      );
      _allParks = nearbyParks;

      await _applyMarkerDiff(nearbyParks); // markers now visible quickly

      // Defer services unless needed
      if (_selectedFilters.isNotEmpty) {
        await _hydrateServicesForParks(nearbyParks);
      }

      _rebuildParksListeners();
      await _cacheParksAndServices(nearbyParks);
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  // ★ NEW: single place to finalize any walk (manual or auto)
  // ★ Change signature to support silent mode
  Future<void> _handleWalkFinished(
      {bool auto = false, bool silent = false}) async {
    if (_finishingWalk) return;
    _finishingWalk = true;
    if (mounted) setState(() {});
    _stopUiTicker();

    try {
      await _location.enableBackgroundMode(enable: false);
      await _location.changeSettings(accuracy: loc.LocationAccuracy.balanced);
    } catch (_) {}

    if (!_walk.meetsMinimum) {
      _resetLiveRoute();
      if (!silent && mounted) {
        setState(() => _finishingWalk = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Walk not saved. ${_walk.tooShortReason}")),
        );
      } else {
        _finishingWalk = false;
        if (mounted) setState(() {});
      }
      return;
    }

    _StreakResult? streak;
    try {
      final saved = await _persistWalkSession();
      if (!saved) return; // bail before queuing/showing
      streak = await _updateDailyStreak();
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      _finishingWalk = false;
      if (mounted) setState(() {});
    }

    if (silent) return;

    final steps_ = _walk.steps;
    final meters_ = _walk.meters;
    final streakCurrent_ = streak?.current;
    final streakLongest_ = streak?.longest;
    final streakIsNewRecord_ = streak?.isNewRecord ?? false;
    final reviveEligible_ = streak?.reviveEligible == true;
    final prevBeforeLoss_ = streak?.prevBeforeLoss;

    // If the app is not in foreground, queue celebration for later.
    final life = WidgetsBinding.instance.lifecycleState;
    final isForeground = (life == AppLifecycleState.resumed);

    if (!isForeground || !mounted) {
      _celebratePending = true;
      _pcSteps = steps_;
      _pcMeters = meters_;
      _pcStreakCur = streakCurrent_;
      _pcStreakLongest = streakLongest_;
      _pcIsNewRecord = streakIsNewRecord_;
      return;
    }

    // Foreground → show now
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (reviveEligible_ && (prevBeforeLoss_ ?? 0) > 0) {
        _showReviveDialog(
          previousStreak: prevBeforeLoss_!,
          steps: steps_,
          meters: meters_,
          streakCurrent: streakCurrent_,
          streakLongest: streakLongest_,
          streakIsNewRecord: streakIsNewRecord_,
        );
      } else {
        // --- XP AWARDING LOGIC ---
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          int xp = 0;

          // 1) Daily check-in bonus (if streak incremented today)
          if (streak?.wasIncremented == true) {
            xp += 20;
          }

          // 2) Distance XP (1 xp per 100m)
          xp += (meters_ / 100).floor();

          // 3) Steps XP (1 xp per 500 steps)
          xp += (steps_ / 500).floor();

          // 4) Streak multiplier bonus
          if (streakCurrent_ != null) {
            xp += streakCurrent_ * 5;
          }

          // Apply XP to Level System
          await LevelSystem.addXp(uid, xp, reason: 'Walk completed');
          debugPrint("Awarded $xp XP");
          // Show XP fly-up animation
          if (widget.onXpGained != null && xp > 0) {
            widget.onXpGained!();
          }
        }
        _showCelebrationDialog(
          steps: steps_,
          meters: meters_,
          streakCurrent: streakCurrent_,
          streakLongest: streakLongest_,
          streakIsNewRecord: streakIsNewRecord_,
        );
      }
    });
  }

  Future<void> _toggleWalk() async {
    if (_walk.isActive) {
      _manualFinishing = true;
      try {
        await _walk.stop();
        await _handleWalkFinished(auto: false);
      } finally {
        _manualFinishing = false;
      }
      return;
    }

    if (_startingWalk) return;
    setState(() => _startingWalk = true);

    try {
      // 1) Only require "when-in-use" to START (fast)
      if (!await _ensureLocationPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Location permission is required to start.")),
          );
        }
        return;
      }

      // 3) Begin tracking immediately (don’t await slow background setup)
      await _location.changeSettings(
        accuracy: loc.LocationAccuracy.high,
        interval: 2000,
        distanceFilter: 3,
      );

      await _walk.start();

      _startUiTicker();
      if (mounted) {
        setState(() {}); // show "End Walk"
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Walk started. Have fun!")),
        );
      }

      // 4) Kick off background requirements without blocking start
      unawaited(_postStartBackgroundHardening());
    } catch (e, st) {
      debugPrint('start walk error: $e\n$st');
      // best-effort rollback
      unawaited(() async {
        try {
          await _location.enableBackgroundMode(enable: false);
          await _location.changeSettings(
              accuracy: loc.LocationAccuracy.balanced);
        } catch (_) {}
      }());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't start walk: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _startingWalk = false);
    }
  }

  /// Ask for notification permission where required (iOS 10+, Android 13+).
  Future<void> _ensureNotifPermission() async {
    // ---- iOS notifications ----
    // (Android automatically handles notification permission except 13+)
    try {
      // Flutter Local Notifications or Firebase Messaging permission check
      // If you're using FirebaseMessaging:
      /*
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    */
    } catch (e) {
      debugPrint("Notification permission error: $e");
    }

    // ---- Android 13+ explicit notification permission ----
    if (Platform.isAndroid) {
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        await Permission.notification.request();
      }
    }
  }

  /// Explains why background location is needed and then requests it on Android.
  /// Returns true if we end up with background location allowed.
  Future<bool> _explainAndRequestBackgroundLocation(
      BuildContext context) async {
    // Only relevant for Android; iOS handles this differently.
    if (!Platform.isAndroid) return true;

    // Check current permissions
    final whenInUse = await Permission.location.status;
    final bg = await Permission.locationAlways.status;

    // Already have both → nothing to do
    if (whenInUse.isGranted && bg.isGranted) return true;

    // Show an explanation dialog before requesting
    final proceed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('Enable background location'),
            content: Text.rich(
              const TextSpan(
                children: [
                  TextSpan(
                    text:
                        'To keep tracking your walk when the screen is off, Android requires you to choose ',
                  ),
                  TextSpan(
                    text: 'Allow all the time',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(
                    text:
                        ' for Location. We only use your location while a walk is active, and you can stop anytime.',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Not now'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Continue'),
              ),
            ],
          ),
        ) ??
        false;

    if (!proceed) return false;

    // First make sure "when in use" is granted
    if (!whenInUse.isGranted) {
      final r = await Permission.location.request();
      if (!r.isGranted) return false;
    }

    // Then request "always"
    var bgStatus = await Permission.locationAlways.status;
    if (!bgStatus.isGranted) {
      bgStatus = await Permission.locationAlways.request();
    }

    if (bgStatus.isGranted) return true;

    // If still not granted, offer to open system Settings
    final openSettings = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('Turn on “Allow all the time”'),
            content: const Text(
              'Background location is currently off. To enable it:\n\n'
              'Settings → Apps → InThePark → Permissions → Location → Allow all the time.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Open Settings'),
              ),
            ],
          ),
        ) ??
        false;

    if (openSettings) {
      await openAppSettings();
      final bgAfter = await Permission.locationAlways.status;
      if (bgAfter.isGranted) return true;
    }

    return false;
  }

  Future<void> _postStartBackgroundHardening() async {
    try {
      await _ensureNotifPermission();

      // Ask for background *after* starting, and only on Android
      final ok = await _explainAndRequestBackgroundLocation(context);
      if (!ok) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                "Walk is tracking now. Enable background to keep tracking with screen off."),
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }

      bool bgOk = false;
      try {
        bgOk = await _location.enableBackgroundMode(enable: true);
      } catch (e) {
        debugPrint('enable BG mode failed: $e');
      }

      if (!bgOk && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                "Couldn’t enable background mode. Walk continues while the app is open."),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint('postStart hardening error: $e');
    }
  }

  Future<bool> _persistWalkSession() async {
    if (_persistingWalk) return false;
    if (!_walk.meetsMinimum) return false;

    _persistingWalk = true;
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) return false;

      final walksCol = FirebaseFirestore.instance
          .collection('owners')
          .doc(currentUid)
          .collection('walks');

      // ★ Create new doc only now (no doc at start)
      final walkRef = walksCol.doc();
      _currentWalkId = walkRef.id;

      final route = _walk.points
          .map((p) => GeoPoint(p.latitude, p.longitude))
          .toList(growable: false);

      final startedAt = _walk.startedAt != null
          ? Timestamp.fromDate(_walk.startedAt!)
          : FieldValue.serverTimestamp();
      final endedAt = _walk.endedAt != null
          ? Timestamp.fromDate(_walk.endedAt!)
          : FieldValue.serverTimestamp();

      await walkRef.set({
        'status': 'completed',
        'startedAt': startedAt,
        'endedAt': endedAt,
        'durationSec': _walk.elapsed.inSeconds,
        'distanceMeters': _walk.meters,
        'steps': _walk.steps == 0 ? (_walk.meters / 0.78).round() : _walk.steps,
        'route': route,
        'createdAt': FieldValue.serverTimestamp(),
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
      _resetLiveRoute();
      _recomputeVisibleMarkers();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error saving walk: $e")),
        );
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
      _recomputeVisiblePolylines();

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
      _recomputeVisibleMarkers();

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
          _moveCameraTo(userLocation, zoom: 17);
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
        _recomputeVisibleMarkers();
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
    final snaps = await Future.wait(ids.map((chunk) => FirebaseFirestore
        .instance
        .collection('parks')
        .where(FieldPath.documentId, whereIn: chunk)
        .get()));
    for (final qs in snaps) {
      for (final d in qs.docs) {
        final svcs =
            (d.data()['services'] as List?)?.cast<String>() ?? const [];
        _parkServicesById[d.id] = svcs;
      }
    }
  }

  // ---- Marker diff keyed by park.id ----
  Future<void> _applyMarkerDiff(List<Park> parks) async {
    bool changed = false;
    final nextIds = parks.map((p) => p.id).toSet();
    final prevIds = _markersMap.keys.toSet();

    for (final removed in prevIds.difference(nextIds)) {
      _markersMap.remove(removed);
      changed = true;
    }

    final toAdd = parks.where((p) => !_markersMap.containsKey(p.id)).toList();
    if (toAdd.isNotEmpty) {
      final futures =
          toAdd.map((p) async => MapEntry(p.id, await _createParkMarker(p)));
      for (final e in await Future.wait(futures)) {
        _markersMap[e.key] = e.value;
      }
      changed = true;
    }

    for (final p in parks) {
      final old = _markersMap[p.id];
      if (old == null) continue;
      final newSnippet = (p.userCount > 0) ? 'Users: ${p.userCount}' : null;
      if (old.infoWindow.snippet != newSnippet ||
          old.infoWindow.title != p.name) {
        _markersMap[p.id] = old.copyWith(
          infoWindowParam: InfoWindow(title: p.name, snippet: newSnippet),
        );
        changed = true;
      }
    }

    if (changed) {
      _recomputeVisibleMarkers();
      if (mounted) setState(() {});
    }
  }

  void _rebuildParksListeners() {
    final ids = _markersMap.keys.toList()..sort();
    final newKey = ids.join(',');
    if (newKey == _parksListenerKey) return;
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

        if ((changedInfo || servicesChanged)) {
          _parksUiDebounce?.cancel();
          _parksUiDebounce = Timer(const Duration(milliseconds: 220), () {
            if (!mounted) return;
            setState(() {
              _recomputeVisibleMarkers();
            });
            if (servicesChanged && _selectedFilters.isNotEmpty) {
              _filterDebounce?.cancel();
              _filterDebounce =
                  Timer(const Duration(milliseconds: 120), _applyFilters);
            }
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

  // --------------- Map callbacks ---------------
  void _onMapCreated(GoogleMapController controller) async {
    _mapController = controller;
    if (!_mapCtlCompleter.isCompleted) {
      _mapCtlCompleter.complete(controller);
    }
    _currentMapCenter = _finalPosition ?? const LatLng(43.7615, -79.4111);

    if (_finalPosition != null) {
      _moveCameraTo(_finalPosition!, zoom: 17, instant: true);
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

  Future<void> _moveCameraTo(LatLng pos,
      {double zoom = 17, bool instant = false}) async {
    final ctl = await _mapCtlCompleter.future;
    final update = CameraUpdate.newLatLngZoom(pos, zoom);
    if (instant) {
      await ctl.moveCamera(update);
    } else {
      await ctl.animateCamera(update);
    }
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
      // super short fresh attempt
      final user = await _getFreshUserLatLng(
            freshTimeout: const Duration(milliseconds: 1200),
            minAccuracyMeters: 100,
          ) ??
          _currentMapCenter;

      _finalPosition = user;
      _currentMapCenter = user;
      await _moveCameraTo(user, zoom: 17);

      // background refresh of parks
      // ignore: discarded_futures
      _loadNearbyParks(user);
    } finally {
      if (mounted) setState(() => _isCentering = false);
    }
  }

  Future<LatLng?> _getFreshUserLatLng({
    Duration freshTimeout = const Duration(milliseconds: 2500),
    double minAccuracyMeters = 50,
  }) async {
    if (_walk.points.isNotEmpty) return _walk.points.last;

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
    } finally {
      try {
        await _location.changeSettings(accuracy: loc.LocationAccuracy.balanced);
      } catch (_) {}
    }

    try {
      final l = await _location
          .getLocation()
          .timeout(const Duration(milliseconds: 800));
      if (l.latitude != null && l.longitude != null) {
        return LatLng(l.latitude!, l.longitude!);
      }
    } catch (_) {}

    final saved = await _locationService.getUserLocationOrCached();
    if (saved != null) return saved;

    return _currentMapCenter;
  }

  // --- Assets -> Bitmap ---
  Future<BitmapDescriptor> _bitmapFromAsset(
    String assetPath, {
    int width = 64,
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

  Future<void> _awardDailyCheckInXp() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      final result = await LevelSystem.awardDailyParkCheckInXp(uid);

      // If skipped == true, user already got today's daily check-in XP.
      if (result['skipped'] == true) {
        debugPrint('Daily park check-in XP already awarded today.');
        return;
      }

      debugPrint('Awarded daily park check-in XP from MapTab.');

      // Let the parent show XP UI (fly-up / level badge refresh)
      if (widget.onXpGained != null) {
        widget.onXpGained!();
      }
    } catch (e, st) {
      debugPrint('Failed to award daily park check-in XP: $e\n$st');
    }
  }

  // --------------- Users in park ---------------
  Future<void> _showUsersInPark(
    String parkId,
    String parkName,
    double parkLatitude,
    double parkLongitude,
  ) async {
    await showUsersInParkDialog(
      context: context,
      parkId: parkId,
      parkName: parkName,
      parkLatitude: parkLatitude,
      parkLongitude: parkLongitude,
      firestoreService: FirestoreService(),
      locationService: _locationService,
      favoritePetIds: _favoritePetIds,
      onShowEvents: widget.onShowEvents,
      onAddEvent: _addEvent,
      onAddFriend: _addFriend,
      onUnfriend: _unfriend,
      checkedInForSince: _checkedInForSince,
      onLikeChanged: (id, liked) {
        // Optional hook: if you want to react to likes at map level
      },
      onServicesUpdated: (id, newServices) {
        // Keep your cache + filters up to date
        _parkServicesById[id] = List<String>.from(newServices);
        if (_selectedFilters.isNotEmpty) {
          _applyFilters();
        }
      },
      onCheckInXp: _awardDailyCheckInXp,
    );
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

  // ---------- Precomputed visible sets ----------
  void _recomputeVisibleMarkers() {
    _visibleMarkers = {
      ..._markersMap.values,
      ..._noteMarkers.values,
      ..._historicNoteMarkers.values,
    };
  }

  void _recomputeVisiblePolylines() {
    _visiblePolylines = {
      ..._livePolylineSet,
      ..._historicPolylines,
    };
  }

  // ---------- Build ----------
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
                // Map is isolated to avoid rebuilds from overlays/ticker
                MapSurface(
                  onMapCreated: _onMapCreated,
                  onCameraMove: _onCameraMove,
                  initialTarget: _currentMapCenter,
                  markers: _visibleMarkers,
                  polylines: _visiblePolylines,
                  myLocationEnabled: true,
                ),

                _buildFilterBar(),

                if (_isSearching)
                  const IgnorePointer(
                    ignoring: true,
                    child: Center(child: CircularProgressIndicator()),
                  ),

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
                    onPressed: (_finishingWalk || _startingWalk)
                        ? null
                        : _toggleWalk, // disable while starting/finishing
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
                        : _startingWalk
                            ? Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: const [
                                  SizedBox(
                                    height: 22,
                                    width: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          Colors.white),
                                    ),
                                  ),
                                  SizedBox(width: 10),
                                  Text("Starting…",
                                      style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800)),
                                ],
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (_walk.isActive)
                                    const Icon(Icons.flag,
                                        size: 24, color: Colors.white)
                                  else ...[
                                    const Icon(Icons.directions_walk,
                                        size: 24, color: Colors.white),
                                    const SizedBox(width: 6),
                                    const Icon(Icons.pets,
                                        size: 22, color: Colors.white),
                                  ],
                                  const SizedBox(width: 10),
                                  Text(
                                    _walk.isActive
                                        ? "End Walk"
                                        : "Start New Walk",
                                    style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800),
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
                                      child: ValueListenableBuilder<String>(
                                        valueListenable: _elapsedText,
                                        builder: (_, t, __) => Text(
                                          t,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w800),
                                        ),
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
  Widget _filterShell({required Widget child}) {
    if (Platform.isAndroid) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.92),
          borderRadius: BorderRadius.circular(22),
          boxShadow: const [
            BoxShadow(
                color: Colors.black12, blurRadius: 12, offset: Offset(0, 4)),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: child,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.85),
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black12, blurRadius: 12, offset: Offset(0, 4)),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: child,
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    final hasSelection = _selectedFilters.isNotEmpty;

    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: _filterShell(
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

  // ---------- Celebration + Revive ----------
  Future<void> _showCelebrationDialog({
    required int steps,
    required double meters,
    int? streakCurrent,
    int? streakLongest,
    bool streakIsNewRecord = false,
    bool showAdAfter = true,
  }) async {
    if (!mounted) return;
    final km = (meters / 1000).toStringAsFixed(meters >= 100 ? 1 : 2);

    await showDialog(
      context: context,
      useRootNavigator: true,
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

    if (!mounted || !showAdAfter) return;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // show loader immediately
      unawaited(_showAdLoaderOverlay(
        title: "Quick pause…",
        message: "Loading a short ad so we can keep the app running 🐶",
      ));

      try {
        await _adManager.show(onUnavailable: _adManager.preload);
      } finally {
        _hideAdLoaderOverlay();
        _adManager.preload();
      }
    });
  }

  Future<void> _showReviveDialog({
    required int previousStreak,
    required int steps,
    required double meters,
    int? streakCurrent,
    int? streakLongest,
    bool streakIsNewRecord = false,
  }) async {
    if (!mounted) return;
    final km = (meters / 1000).toStringAsFixed(meters >= 100 ? 1 : 2);

    final watchAd = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.local_fire_department,
                      color: Colors.orange, size: 26),
                  SizedBox(width: 8),
                  Text(
                    "Don't lose your streak!",
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                "$previousStreak-day streak at risk",
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF567D46).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.pets, size: 18, color: Color(0xFF567D46)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Today's walk: $km km • $steps steps",
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                "Watch a short ad to:",
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text("•  ", style: TextStyle(fontSize: 13)),
                  Expanded(
                    child: Text(
                      "Restore your full streak as if you never missed 💫",
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text("•  ", style: TextStyle(fontSize: 13)),
                  Expanded(
                    child: Text(
                      "Keep your progress and momentum going",
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text("•  ", style: TextStyle(fontSize: 13)),
                  Expanded(
                    child: Text(
                      "Only takes a few seconds",
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                "You can still finish your walk normally if you skip.",
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF567D46),
                        foregroundColor: Colors.white,
                        elevation: 2,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      onPressed: () => Navigator.of(dialogCtx).pop(true),
                      child: const Text("Revive my streak 🔥"),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(false),
                    child: Text(
                      "It's ok, I'll lose my streak",
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );

    // Helper to pull the latest streak from Firestore
    Future<(int?, int?)> _loadLatestStreak() async {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return (streakCurrent, streakLongest);

      try {
        final doc = await FirebaseFirestore.instance
            .collection('owners')
            .doc(uid)
            .collection('stats')
            .doc('walkStreak')
            .get();

        if (!doc.exists) return (streakCurrent, streakLongest);
        final data = doc.data() as Map<String, dynamic>;
        final cur = (data['current'] ?? streakCurrent) as int?;
        final lng = (data['longest'] ?? streakLongest) as int?;
        return (cur, lng);
      } catch (e) {
        debugPrint('loadLatestStreak failed: $e');
        return (streakCurrent, streakLongest);
      }
    }

    // User declined → apply fallback (streak = 1 for today), then show updated numbers
    if (watchAd != true) {
      int? latestCur = streakCurrent;
      int? latestLng = streakLongest;
      try {
        await _applyStreakFallbackForToday();
        final pair = await _loadLatestStreak();
        latestCur = pair.$1;
        latestLng = pair.$2;
      } catch (e) {
        debugPrint('fallback streak update failed: $e');
      }

      final isNew =
          (latestCur != null && latestLng != null && latestCur! >= latestLng!)
              ? true
              : streakIsNewRecord;

      await _showCelebrationDialog(
        steps: steps,
        meters: meters,
        streakCurrent: latestCur,
        streakLongest: latestLng,
        streakIsNewRecord: isNew,
        showAdAfter: true,
      );
      return;
    }

    bool rewardEarned = false;
    String? adError;

    final completer = Completer<void>();

    _showAdLoaderOverlay(
      title: "Saving your streak…",
      message: "Loading a quick revive ad 🦴",
    );

    RewardedStreakAds.show(
      onRewardEarned: (_) async {
        rewardEarned = true;
        if (!completer.isCompleted) completer.complete();
      },
      onDismissed: () {
        if (!completer.isCompleted) completer.complete();
      },
      onFailedToShow: (msg) {
        adError = msg;
        if (!completer.isCompleted) completer.complete();
      },
    );

// ✅ wait exactly once
    await completer.future;
    if (!mounted) return;

// if failed, show blocking dialog (readable)
    if (adError != null) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text("Ad failed to load"),
          content: Text(adError!),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("OK"),
            ),
          ],
        ),
      );

      await _showCelebrationDialog(
        steps: steps,
        meters: meters,
        streakCurrent: streakCurrent,
        streakLongest: streakLongest,
        streakIsNewRecord: streakIsNewRecord,
        showAdAfter: true,
      );
      return;
    }

    int? finalCur = streakCurrent;
    int? finalLng = streakLongest;
    bool finalIsNewRecord = streakIsNewRecord;

    if (rewardEarned) {
      try {
        await applyStreakReviveAfterReward();

        // pull the *updated* streak
        final pair = await _loadLatestStreak();
        finalCur = pair.$1;
        finalLng = pair.$2;

        if (finalCur != null && finalLng != null && finalCur! >= finalLng!) {
          finalIsNewRecord = true;
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "Your $previousStreak-day streak has been restored! 🎉",
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Couldn't revive streak: $e")),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Streak not revived (ad not completed)."),
          ),
        );
      }
    }

    await _showCelebrationDialog(
      steps: steps,
      meters: meters,
      streakCurrent: finalCur,
      streakLongest: finalLng,
      streakIsNewRecord: finalIsNewRecord,
      showAdAfter: true,
    );
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

  // NEW: revive info
  final bool reviveEligible;
  final int? prevBeforeLoss;

  const _StreakResult({
    required this.alreadyUpdatedToday,
    required this.wasIncremented,
    required this.isNewRecord,
    required this.current,
    required this.longest,
    this.reviveEligible = false,
    this.prevBeforeLoss,
  });
}
