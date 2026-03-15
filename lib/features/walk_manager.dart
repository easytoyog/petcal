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
  final loc.Location location;

  final Duration minDuration;
  final int minSteps;

  WalkManager({
    required this.location,
    this.minDuration = const Duration(seconds: 1),
    this.minSteps = 1,
  });

  static const _persistKey = 'active_walk';
  static const inactivityLimit = Duration(minutes: 15);
  static const maxWalkLimit = Duration(hours: 48);

  // ---- Public state ----
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

  DateTime? _endedAt;
  DateTime? get endedAt => _endedAt;

  Duration _elapsed = Duration.zero;
  Duration get elapsed => _elapsed;

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

  // ---- internals ----
  StreamSubscription<loc.LocationData>? _locSub;
  StreamSubscription<StepCount>? _stepSub;
  Timer? _uiTicker;
  Timer? _autoStopTimer;
  Timer? _persistTimer;
  int? _stepBaseline;
  DateTime? _lastMoveAt;

  bool _stopping = false;

  // Prevent stale async persist calls from resurrecting an old walk.
  int _persistGeneration = 0;

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

    final generation = ++_persistGeneration;
    _stopping = false;

    await _enableNavMode();

    _active = true;
    _points.clear();
    _meters = 0;
    _steps = 0;
    _stepBaseline = null;
    _startedAt = DateTime.now();
    _endedAt = null;
    _lastMoveAt = _startedAt;
    _elapsed = Duration.zero;
    notifyListeners();

    if (seed != null) {
      _points.add(seed);
      unawaited(_persist(generation));
    }

    await _locSub?.cancel();
    _locSub = location.onLocationChanged.listen(_onLocTick);

    await _stepSub?.cancel();
    try {
      _stepSub = Pedometer.stepCountStream.listen((sc) {
        if (!_active || _stopping) return;

        _stepBaseline ??= sc.steps;
        final raw = sc.steps - (_stepBaseline ?? sc.steps);
        if (raw >= 0) {
          final prev = _steps;
          _steps = raw;
          if (_steps > prev) _lastMoveAt = DateTime.now();
          notifyListeners();
        }
      });
    } catch (_) {}

    unawaited(() async {
      try {
        final l = await location
            .getLocation()
            .timeout(const Duration(milliseconds: 800));

        if (!_active || _stopping || generation != _persistGeneration) return;

        if (l.latitude != null && l.longitude != null) {
          final p = LatLng(l.latitude!, l.longitude!);
          if (_points.isEmpty || _haversine(_points.last, p) >= 1.0) {
            _points.add(p);
            _lastMoveAt = DateTime.now();
            notifyListeners();
            await _persist(generation);
          }
        }
      } catch (_) {}
    }());

    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_startedAt != null && _active) {
        _elapsed = DateTime.now().difference(_startedAt!);
        notifyListeners();
      }
    });

    _autoStopTimer?.cancel();
    _autoStopTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkAutoStop();
    });

    _persistTimer?.cancel();
    _persistTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_persist(generation)),
    );

    unawaited(_persist(generation));
  }

  /// Stops tracking. Does NOT save to Firestore.
  /// After calling this, read `meetsMinimum` and `tooShortReason`.
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;

    // Invalidate any in-flight persist calls from the active walk.
    _persistGeneration++;

    try {
      try {
        await _locSub?.cancel();
      } catch (_) {}
      _locSub = null;

      try {
        await _stepSub?.cancel();
      } catch (_) {}
      _stepSub = null;

      _uiTicker?.cancel();
      _uiTicker = null;

      _autoStopTimer?.cancel();
      _autoStopTimer = null;

      _persistTimer?.cancel();
      _persistTimer = null;

      try {
        await _disableNavMode();
      } catch (_) {}

      final ended = DateTime.now();
      _endedAt = ended;
      final started = _startedAt ?? ended;
      _elapsed = ended.difference(started);

      if (_steps == 0) {
        _steps = (_meters / 0.78).round();
      }

      _active = false;
      notifyListeners();

      await _clearPersisted();
    } finally {
      _stopping = false;
    }
  }

  Future<void> forceEndAndReset() async {
    await stop();
    await reset();
  }

  /// Completely resets the walk to a clean slate (for rejected walks)
  Future<void> reset() async {
    // Invalidate any stale persist calls.
    _persistGeneration++;
    _stopping = false;

    try {
      await _locSub?.cancel();
    } catch (_) {}
    _locSub = null;

    try {
      await _stepSub?.cancel();
    } catch (_) {}
    _stepSub = null;

    _uiTicker?.cancel();
    _uiTicker = null;

    _autoStopTimer?.cancel();
    _autoStopTimer = null;

    _persistTimer?.cancel();
    _persistTimer = null;

    try {
      await _disableNavMode();
    } catch (_) {}

    _active = false;
    _points.clear();
    _meters = 0;
    _steps = 0;
    _stepBaseline = null;
    _startedAt = null;
    _endedAt = null;
    _elapsed = Duration.zero;
    _lastMoveAt = null;

    await _clearPersisted();
    notifyListeners();
  }

  Future<void> resume() async {
    if (_active != true) return;

    final generation = ++_persistGeneration;
    _stopping = false;

    await _enableNavMode();

    await _locSub?.cancel();
    _locSub = location.onLocationChanged.listen(_onLocTick);

    await _stepSub?.cancel();
    try {
      _stepSub = Pedometer.stepCountStream.listen((sc) {
        if (!_active || _stopping) return;

        _stepBaseline ??=
            sc.steps - _steps; // baseline so current - baseline == saved _steps
        final raw = sc.steps - (_stepBaseline ?? sc.steps);
        if (raw >= 0) {
          final prev = _steps;
          _steps = raw;
          if (_steps > prev) _lastMoveAt = DateTime.now();
          notifyListeners();
        }
      });
    } catch (_) {}

    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_startedAt != null && _active) {
        _elapsed = DateTime.now().difference(_startedAt!);
        notifyListeners();
      }
    });

    _autoStopTimer?.cancel();
    _autoStopTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkAutoStop();
    });

    _persistTimer?.cancel();
    _persistTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_persist(generation)),
    );

    unawaited(_persist(generation));
  }

  Future<void> restoreIfAny() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_persistKey);
      if (raw == null) return;

      final m = jsonDecode(raw) as Map<String, dynamic>;

      // Clean up any non-active leftovers.
      if (m['isWalking'] != true) {
        await _clearPersisted();
        return;
      }

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
      _lastMoveAt = (m['lastMoveAt'] != null)
          ? DateTime.tryParse(m['lastMoveAt'] as String)
          : _startedAt;

      if (_active && _startedAt != null) {
        _elapsed = DateTime.now().difference(_startedAt!);
        notifyListeners();

        final now = DateTime.now();
        if (_lastMoveAt != null &&
            now.difference(_lastMoveAt!) >= inactivityLimit) {
          await stop();
        } else {
          await resume();
        }
      } else {
        await _clearPersisted();
        notifyListeners();
      }
    } catch (_) {}
  }

  // ——— internals ———

  void _onLocTick(loc.LocationData d) {
    if (!_active || _stopping || d.latitude == null || d.longitude == null) {
      return;
    }

    final acc = d.accuracy ?? double.infinity;
    if (acc > 50) return;

    final next = LatLng(d.latitude!, d.longitude!);

    if (_points.isNotEmpty) {
      final inc = _haversine(_points.last, next);
      if (inc > 250) return;
      if (inc < 1.0) return;
      _meters += inc;
      _lastMoveAt = DateTime.now();
    } else {
      _lastMoveAt = DateTime.now();
    }

    _points.add(next);
    unawaited(_persist(_persistGeneration));
    notifyListeners();
  }

  void _checkAutoStop() async {
    if (!_active || _stopping) return;

    final now = DateTime.now();

    if (_startedAt != null && now.difference(_startedAt!) >= maxWalkLimit) {
      await stop();
      return;
    }

    if (_lastMoveAt != null &&
        now.difference(_lastMoveAt!) >= inactivityLimit) {
      await stop();
    }
  }

  Future<void> _persist([int? generation]) async {
    final g = generation ?? _persistGeneration;

    if (_stopping || !_active) return;

    try {
      final payload = {
        'startedAt': _startedAt?.toIso8601String(),
        'endedAt': _endedAt?.toIso8601String(),
        'lastMoveAt': _lastMoveAt?.toIso8601String(),
        'meters': _meters,
        'steps': _steps,
        'isWalking': _active,
        'points': _points
            .map((p) => {'lat': p.latitude, 'lng': p.longitude})
            .toList(),
      };

      final prefs = await SharedPreferences.getInstance();

      // Abort stale writes that started before stop/reset/new walk.
      if (g != _persistGeneration || _stopping || !_active) return;

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
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final la1 = a.latitude * pi / 180;
    final la2 = b.latitude * pi / 180;

    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2);

    return 2 * r * atan2(sqrt(h), sqrt(1 - h));
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
