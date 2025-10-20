// lib/features/walk_manager.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:location/location.dart' as loc;
import 'package:pedometer/pedometer.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WalkManager extends ChangeNotifier {
  // Inject for testability
  final loc.Location location;

  // Minimums (single source of truth)
  final Duration minDuration;
  final int minSteps;

  WalkManager({
    required this.location,
    this.minDuration = const Duration(seconds: 30),
    this.minSteps = 50,
  });

  static const _persistKey = 'active_walk';
  static const inactivityLimit = Duration(minutes: 15);
  static const maxWalkLimit = Duration(hours: 24);

  // ---- Public state (read-only via getters)
  bool _active = false;
  bool get isActive => _active;

  final List<LatLng> _points = [];
  List<LatLng> get points => List.unmodifiable(_points);

  double _meters = 0;
  double get meters => _meters;

  int _steps = 0;
  int get steps => _steps;

  DateTime? _startedAt;
  DateTime? get startedAt => _startedAt;

  // ✨ NEW: track when a walk actually ended
  DateTime? _endedAt;
  DateTime? get endedAt => _endedAt;

  Duration _elapsed = Duration.zero;
  Duration get elapsed => _elapsed;

  // Convenience: UI asks the manager about minimum rule + reason
  bool get meetsMinimum => _elapsed >= minDuration && _steps >= minSteps;

  String get tooShortReason {
    final meetsDur = _elapsed >= minDuration;
    final meetsStp = _steps >= minSteps;
    if (!meetsDur && !meetsStp) {
      return "under ${_prettyDuration(minDuration)} and fewer than $minSteps steps – Let's keep that walk a little longer!.";
    } else if (!meetsDur) {
      return "under ${_prettyDuration(minDuration)} – not saved.";
    } else {
      return "fewer than $minSteps steps – not saved.";
    }
  }

  // ---- internals
  StreamSubscription<loc.LocationData>? _locSub;
  StreamSubscription<StepCount>? _stepSub;
  Timer? _uiTicker;
  Timer? _autoStopTimer;
  Timer? _persistTimer;
  int? _stepBaseline;
  DateTime? _lastMoveAt;

  Future<bool> _ensureLocationReady() async {
    final svc =
        await location.serviceEnabled() || await location.requestService();
    if (!svc) return false;
    var perm = await location.hasPermission();
    if (perm == loc.PermissionStatus.denied) {
      perm = await location.requestPermission();
    }
    return perm == loc.PermissionStatus.granted;
  }

  // ————— API —————
  Future<void> start({LatLng? seed}) async {
    if (!await _ensureLocationReady()) return;
    await _enableNavMode();

    _active = true;
    _points.clear();
    _meters = 0;
    _steps = 0;
    _stepBaseline = null;
    _startedAt = DateTime.now();
    _endedAt = null; // ✨ reset on new walk
    _lastMoveAt = _startedAt;
    _elapsed = Duration.zero;
    notifyListeners();

    // seed first point
    try {
      final l = await location.getLocation();
      if (l.latitude != null && l.longitude != null) {
        _points.add(LatLng(l.latitude!, l.longitude!));
        await _persist();
      }
    } catch (_) {}

    // location stream
    _locSub?.cancel();
    _locSub = location.onLocationChanged.listen(_onLocTick);

    // pedometer stream (best effort)
    _stepSub?.cancel();
    try {
      _stepSub = Pedometer.stepCountStream.listen((sc) {
        _stepBaseline ??= sc.steps;
        final raw = sc.steps - (_stepBaseline ?? sc.steps);
        if (raw >= 0) {
          _steps = raw;
          notifyListeners();
        }
      });
    } catch (_) {}

    // UI timer
    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_startedAt != null) {
        _elapsed = DateTime.now().difference(_startedAt!);
        notifyListeners();
      }
    });

    // auto-stop guard
    _autoStopTimer?.cancel();
    _autoStopTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkAutoStop();
    });

    // local persistence
    _persistTimer?.cancel();
    _persistTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _persist());
    await _persist();
  }

  /// Stops tracking. Does NOT save to Firestore.
  /// After calling this, read `meetsMinimum` and `tooShortReason`.
  Future<void> stop() async {
    await _locSub?.cancel();
    await _stepSub?.cancel();
    _uiTicker?.cancel();
    _autoStopTimer?.cancel();
    _persistTimer?.cancel();

    await _disableNavMode();

    final ended = DateTime.now();
    _endedAt = ended; // ✨ set end time
    final started = _startedAt ?? ended;
    _elapsed = ended.difference(started);

    // If pedometer produced 0, backfill from distance with ~0.78m stride.
    if (_steps == 0) {
      _steps = (_meters / 0.78).round();
    }

    _active = false;
    notifyListeners();

    await _clearPersisted();
  }

  Future<void> resume() async {
    if (_active != true) return; // only if persisted said we're active
    await _enableNavMode();

    // reattach streams
    _locSub?.cancel();
    _locSub = location.onLocationChanged.listen(_onLocTick);

    _stepSub?.cancel();
    try {
      _stepSub = Pedometer.stepCountStream.listen((sc) {
        _stepBaseline ??=
            sc.steps - _steps; // baseline so (current-baseline) == _steps
        final raw = sc.steps - (_stepBaseline ?? sc.steps);
        if (raw >= 0) {
          _steps = raw;
          notifyListeners();
        }
      });
    } catch (_) {}

    // UI timer
    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_startedAt != null) {
        _elapsed = DateTime.now().difference(_startedAt!);
        notifyListeners();
      }
    });

    // auto-stop guard
    _autoStopTimer?.cancel();
    _autoStopTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkAutoStop();
    });

    // re-enable periodic persist
    _persistTimer?.cancel();
    _persistTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _persist());
  }

  Future<void> restoreIfAny() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_persistKey);
      if (raw == null) return;

      final m = jsonDecode(raw) as Map<String, dynamic>;
      final pts = (m['points'] as List?)
              ?.map((e) => LatLng(
                    (e['lat'] as num).toDouble(),
                    (e['lng'] as num).toDouble(),
                  ))
              .toList() ??
          <LatLng>[];

      _points
        ..clear()
        ..addAll(pts);
      _meters = (m['meters'] as num?)?.toDouble() ?? 0.0;
      _steps = (m['steps'] as num?)?.toInt() ?? 0;
      _startedAt = (m['startedAt'] != null)
          ? DateTime.tryParse(m['startedAt'] as String)
          : null;
      _endedAt = (m['endedAt'] != null)
          ? DateTime.tryParse(m['endedAt'] as String)
          : null;
      _active = (m['isWalking'] == true);

      if (_active && _startedAt != null) {
        _elapsed = DateTime.now().difference(_startedAt!);
        notifyListeners();
        // ★ IMPORTANT: fully resume sensors/timers
        // ignore: discarded_futures
        resume();
      } else {
        // if not active we still publish restored state
        notifyListeners();
      }
    } catch (_) {}
  }

  // ——— internals ———
  void _onLocTick(loc.LocationData d) {
    if (!_active || d.latitude == null || d.longitude == null) return;
    final next = LatLng(d.latitude!, d.longitude!);

    if (_points.isNotEmpty) {
      final inc = _haversine(_points.last, next);
      if (inc > 250) return; // teleport jump
      if (inc < 1.0) return; // jitter
      _meters += inc;
      _lastMoveAt = DateTime.now();
    } else {
      _lastMoveAt = DateTime.now();
    }
    _points.add(next);
    _persist();
    notifyListeners();
  }

  void _checkAutoStop() {
    if (!_active) return;
    final now = DateTime.now();
    if (_startedAt != null && now.difference(_startedAt!) >= maxWalkLimit) {
      stop();
      return;
    }
    if (_lastMoveAt != null &&
        now.difference(_lastMoveAt!) >= inactivityLimit) {
      stop();
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = {
        'startedAt': _startedAt?.toIso8601String(),
        'endedAt': _endedAt?.toIso8601String(), // ✨ save end time if any
        'meters': _meters,
        'steps': _steps,
        'isWalking': _active,
        'points': _points
            .map((p) => {'lat': p.latitude, 'lng': p.longitude})
            .toList(),
      };
      await prefs.setString(_persistKey, jsonEncode(payload));
    } catch (_) {}
  }

  Future<void> _clearPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_persistKey);
    } catch (_) {}
  }

  Future<void> _enableNavMode() async {
    try {
      await location.enableBackgroundMode(enable: true);
      await location.changeSettings(
        accuracy: loc.LocationAccuracy.navigation,
        interval: 2000,
        distanceFilter: 5,
      );
    } catch (_) {}
  }

  Future<void> _disableNavMode() async {
    try {
      await location.changeSettings(
        accuracy: loc.LocationAccuracy.balanced,
        interval: 5000,
        distanceFilter: 10,
      );
      await location.enableBackgroundMode(enable: false);
    } catch (_) {}
  }

  // ——— helpers ———
  double _haversine(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final la1 = a.latitude * pi / 180;
    final la2 = b.latitude * pi / 180;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2);
    return 2 * R * atan2(sqrt(h), sqrt(1 - h));
  }

  String _prettyDuration(Duration d) {
    if (d.inMinutes >= 1 && d.inSeconds % 60 == 0) {
      final m = d.inMinutes;
      return '$m minute${m == 1 ? '' : 's'}';
    }
    if (d.inMinutes >= 1) {
      final m = d.inMinutes;
      final s = d.inSeconds % 60;
      return '${m}m ${s}s';
    }
    return '${d.inSeconds}s';
  }

  @override
  void dispose() {
    _locSub?.cancel();
    _stepSub?.cancel();
    _uiTicker?.cancel();
    _autoStopTimer?.cancel();
    _persistTimer?.cancel();
    super.dispose();
  }
}
