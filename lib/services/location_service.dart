// lib/services/location_service.dart
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:inthepark/utils/utils.dart';
import 'package:inthepark/models/park_model.dart';
import 'package:location/location.dart' as loc;
import 'package:shared_preferences/shared_preferences.dart';

/// Uses Places API (New) with a strict field mask to avoid
/// Atmosphere & Contact data charges.
/// Requested: id, displayName, location, types, primaryType (still "basic")
class LocationService {
  static const String _lastLatitudeKey = 'last_latitude';
  static const String _lastLongitudeKey = 'last_longitude';
  static const String _lastLocationTimestampKey = 'last_location_timestamp';
  static const String _lastMapCenterLatitudeKey = 'last_map_center_latitude';
  static const String _lastMapCenterLongitudeKey = 'last_map_center_longitude';
  static const String _lastMapCenterTimestampKey = 'last_map_center_timestamp';

  final loc.Location _location = loc.Location();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final String _googlePlacesApiKey;

  LocationService(this._googlePlacesApiKey);

  // ---------- Background location ----------
  Future<void> enableBackgroundLocation() async {
    bool serviceEnabled = await _location.serviceEnabled();
    if (!serviceEnabled) {
      serviceEnabled = await _location.requestService();
      if (!serviceEnabled) return;
    }

    loc.PermissionStatus permissionGranted = await _location.hasPermission();
    if (permissionGranted == loc.PermissionStatus.denied) {
      permissionGranted = await _location.requestPermission();
      if (permissionGranted != loc.PermissionStatus.granted) return;
    }

    _location.changeSettings(
        interval: 5000, accuracy: loc.LocationAccuracy.high);
    try {
      await _location.enableBackgroundMode(enable: true);
    } catch (_) {
      // Not supported or not granted—ignore.
    }
  }

  // ---------- Places (New) helpers ----------
  static const _placesHost = 'places.googleapis.com';
  static const _nearbyPath = '/v1/places:searchNearby';
  static const _textSearchPath = '/v1/places:searchText';

  // Types to exclude even if the result says "park"
  static const Set<String> _bannedTypes = {
    'parking',
    'rv_park',
    'campground',
    'car_rental',
    'car_repair',
    'gas_station',
    'cemetery',
    'funeral_home',
    'church',
    'synagogue',
    'mosque',
    'hindu_temple',
    'taxi_stand',
    'subway_station',
    'train_station',
    'bus_station',
    'light_rail_station',
    'airport',
    'hospital',
    'doctor',
    'pharmacy',
    'police',
    'fire_station',
    'courthouse',
  };

  /// Core POST to Places API (New) Nearby Search with a tight field mask.
  Future<List<Map<String, dynamic>>> _placesSearchNearby({
    required double lat,
    required double lng,
    double radiusMeters = 650, // tighter default
    int maxResultCount = 16, // lower cap
    List<String> includedTypes = const ['park'],
  }) async {
    final uri = Uri.https(_placesHost, _nearbyPath);

    final body = jsonEncode({
      "includedTypes": includedTypes,
      "maxResultCount": maxResultCount,
      "locationRestriction": {
        "circle": {
          "center": {"latitude": lat, "longitude": lng},
          "radius": radiusMeters
        }
      }
    });

    final resp = await http.post(
      uri,
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": _googlePlacesApiKey,
        // BASIC fields only → avoids contact/atmosphere charges.
        "X-Goog-FieldMask":
            "places.id,places.displayName,places.location,places.types,places.primaryType",
      },
      body: body,
    );

    if (resp.statusCode != 200) {
      // Return empty list on errors (keep UI resilient)
      return const [];
    }

    final data = jsonDecode(resp.body);
    final List places = (data["places"] as List?) ?? const [];

    // Normalize to simple maps with id, name, lat, lng, types
    return places
        .map<Map<String, dynamic>>((p) {
          final loc = p["location"] as Map<String, dynamic>? ?? const {};
          final nameObj = p["displayName"] as Map<String, dynamic>? ?? const {};
          final types = ((p["types"] as List?) ?? const [])
              .map((e) => (e as String).toLowerCase())
              .toList(growable: false);
          final primaryType = (p["primaryType"] as String? ?? '').toLowerCase();
          return {
            "id": p["id"] ?? "",
            "name": (nameObj["text"] ?? "").toString(),
            "lat": (loc["latitude"] as num?)?.toDouble(),
            "lng": (loc["longitude"] as num?)?.toDouble(),
            "types": types,
            "primaryType": primaryType,
          };
        })
        .where((m) =>
            m["lat"] != null &&
            m["lng"] != null &&
            (m["name"] as String).isNotEmpty)
        .toList();
  }

  Future<List<Map<String, dynamic>>> _placesSearchText({
    required String query,
    required double lat,
    required double lng,
    int pageSize = 20,
    double biasRadiusMeters = 50000,
  }) async {
    final uri = Uri.https(_placesHost, _textSearchPath);
    final body = jsonEncode({
      "textQuery": query,
      "pageSize": pageSize,
      "locationBias": {
        "circle": {
          "center": {"latitude": lat, "longitude": lng},
          "radius": biasRadiusMeters,
        }
      }
    });

    final resp = await http.post(
      uri,
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": _googlePlacesApiKey,
        "X-Goog-FieldMask":
            "places.id,places.displayName,places.location,places.types,places.primaryType",
      },
      body: body,
    );

    if (resp.statusCode != 200) {
      return const [];
    }

    final data = jsonDecode(resp.body);
    final List places = (data["places"] as List?) ?? const [];

    return places
        .map<Map<String, dynamic>>((p) {
          final loc = p["location"] as Map<String, dynamic>? ?? const {};
          final nameObj = p["displayName"] as Map<String, dynamic>? ?? const {};
          final types = ((p["types"] as List?) ?? const [])
              .map((e) => (e as String).toLowerCase())
              .toList(growable: false);
          final primaryType = (p["primaryType"] as String? ?? '').toLowerCase();
          return {
            "id": p["id"] ?? "",
            "name": (nameObj["text"] ?? "").toString(),
            "lat": (loc["latitude"] as num?)?.toDouble(),
            "lng": (loc["longitude"] as num?)?.toDouble(),
            "types": types,
            "primaryType": primaryType,
          };
        })
        .where((m) =>
            m["lat"] != null &&
            m["lng"] != null &&
            (m["name"] as String).isNotEmpty)
        .toList();
  }

  // ---------- Filtering helpers ----------
  bool _looksLikeRealPark(Map<String, dynamic> p) {
    final name = (p['name'] as String).trim();
    final primary = (p['primaryType'] as String);
    final types = (p['types'] as List).cast<String>();

    // Must be a park by primary or secondary type
    final isPark = primary == 'park' ||
        primary == 'dog_park' ||
        types.contains('park') ||
        types.contains('dog_park');
    if (!isPark) return false;

    // Exclude noisy categories
    if (types.any(_bannedTypes.contains)) return false;

    // Name-based guards
    final lower = name.toLowerCase();
    const badNameSnippets = [
      'parking',
      'garage',
      'lot',
      'trailhead',
      'drop-off',
      'pickup',
      'car park',
      'parkade'
    ];
    if (badNameSnippets.any((s) => lower.contains(s))) return false;

    return true;
  }

  bool _isLikelyDogPark(Map<String, dynamic> p) {
    final name = (p['name'] as String).toLowerCase();
    final primary = (p['primaryType'] as String);
    final types = (p['types'] as List).cast<String>();

    return primary == 'dog_park' ||
        types.contains('dog_park') ||
        name.contains('dog park') ||
        name.contains('off leash') ||
        name.contains('off-leash');
  }

  double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const R = 6371000.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLng = _deg2rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) *
            cos(_deg2rad(lat2)) *
            sin(dLng / 2) *
            sin(dLng / 2);
    return 2 * R * atan2(sqrt(a), sqrt(1 - a));
  }

  double _deg2rad(double deg) => deg * (pi / 180.0);

  /// Merge places that are within [thresholdM] of each other.
  /// Prefer names containing 'Park'; else prefer longer name.
  List<Map<String, dynamic>> _dedupeByProximity(
    List<Map<String, dynamic>> items, {
    double thresholdM = 120,
  }) {
    final kept = <Map<String, dynamic>>[];

    for (final p in items) {
      final plat = p['lat'] as double;
      final plng = p['lng'] as double;
      int? sameIdx;

      for (var i = 0; i < kept.length; i++) {
        final k = kept[i];
        final d =
            _haversine(plat, plng, k['lat'] as double, k['lng'] as double);
        if (d <= thresholdM) {
          sameIdx = i;
          break;
        }
      }

      if (sameIdx == null) {
        kept.add(p);
      } else {
        final current = kept[sameIdx];
        final cName = (current['name'] as String);
        final pName = (p['name'] as String);
        final cHasPark = cName.toLowerCase().contains('park');
        final pHasPark = pName.toLowerCase().contains('park');

        final pickP = (!cHasPark && pHasPark) ||
            (cHasPark == pHasPark && pName.length > cName.length);

        if (pickP) kept[sameIdx] = p;
      }
    }
    return kept;
  }

  String _normalizeSearchText(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<String> _searchTokens(String value) {
    final normalized = _normalizeSearchText(value);
    if (normalized.isEmpty) return const [];
    return normalized.split(' ').where((part) => part.isNotEmpty).toList();
  }

  int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final current = <int>[i + 1];
      for (var j = 0; j < b.length; j++) {
        final cost = a[i] == b[j] ? 0 : 1;
        current.add([
          current[j] + 1,
          previous[j + 1] + 1,
          previous[j] + cost,
        ].reduce(min));
      }
      previous = current;
    }
    return previous.last;
  }

  int _parkQueryScore(String query, String parkName) {
    final normalizedQuery = _normalizeSearchText(query);
    final normalizedName = _normalizeSearchText(parkName);
    if (normalizedQuery.isEmpty || normalizedName.isEmpty) return 0;

    if (normalizedName.contains(normalizedQuery)) {
      return 500 - normalizedName.indexOf(normalizedQuery);
    }

    final queryTokens = _searchTokens(normalizedQuery);
    final nameTokens = _searchTokens(normalizedName);
    if (queryTokens.isEmpty || nameTokens.isEmpty) return 0;

    var score = 0;
    for (final queryToken in queryTokens) {
      var matched = false;
      for (final nameToken in nameTokens) {
        if (nameToken == queryToken) {
          score += 90;
          matched = true;
          break;
        }
        if (nameToken.startsWith(queryToken) ||
            queryToken.startsWith(nameToken)) {
          score += 70;
          matched = true;
          break;
        }

        final distance = _levenshtein(queryToken, nameToken);
        final allowDistance = queryToken.length >= 6
            ? 2
            : queryToken.length >= 4
                ? 1
                : 0;
        if (distance <= allowDistance) {
          score += 45 - (distance * 10);
          matched = true;
          break;
        }
      }
      if (!matched) return 0;
    }

    if (normalizedName.contains('park')) score += 15;
    return score;
  }

  List<String> _searchQueryVariants(String query) {
    final normalized = _normalizeSearchText(query);
    if (normalized.isEmpty) return const [];

    final variants = <String>[normalized];
    final tokens = _searchTokens(normalized);

    if (!normalized.contains('park')) {
      variants.add('$normalized park');
    }
    if (tokens.length > 1) {
      variants.add(tokens.first);
      if (!tokens.first.contains('park')) {
        variants.add('${tokens.first} park');
      }
    }

    return variants.toSet().toList();
  }

  // ---------- Public API ----------
  /// Find nearby parks around (userLat,userLng).
  /// Uses Places (New) Nearby with basic fields only, then filters locally.
  Future<List<Park>> findNearbyParks(double userLat, double userLng) async {
    final parks = <Park>[];

    try {
      final raw = await _placesSearchNearby(
        lat: userLat,
        lng: userLng,
        radiusMeters: 650, // ~0.65 km; adjust to taste/zoom
        maxResultCount: 16,
        includedTypes: const ['park'],
      );

      // Keep only valid parks
      final filtered = raw.where(_looksLikeRealPark).toList();

      // Spatial de-dupe of large areas that produce multiple sub-entries
      final deduped = _dedupeByProximity(filtered, thresholdM: 120);

      // Name de-dupe (safety)
      final seenNames = <String>{};
      for (final p in deduped) {
        final name = (p['name'] as String).trim();
        final lat = p['lat'] as double;
        final lng = p['lng'] as double;

        final key = name.toLowerCase();
        if (seenNames.contains(key)) continue;
        seenNames.add(key);

        parks.add(
          Park(
            id: generateParkID(lat, lng, name),
            name: name,
            latitude: lat,
            longitude: lng,
            distance: _haversine(userLat, userLng, lat, lng) / 1000,
            isDogPark: _isLikelyDogPark(p),
          ),
        );
      }
    } catch (_) {
      // Swallow network/parse errors; return what we have.
    }

    return parks;
  }

  Future<List<Park>> searchParksByName(
    String query,
    double userLat,
    double userLng,
  ) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const [];

    final parks = <Park>[];
    final seenIds = <String>{};

    try {
      final rawLists = await Future.wait(
        _searchQueryVariants(normalizedQuery).map(
          (variant) => _placesSearchText(
            query: variant,
            lat: userLat,
            lng: userLng,
          ),
        ),
      );
      final raw = rawLists.expand((items) => items).toList();

      final filtered = raw.where(_looksLikeRealPark).toList();
      final deduped = _dedupeByProximity(filtered, thresholdM: 120);

      for (final p in deduped) {
        final name = (p['name'] as String).trim();
        final matchScore = _parkQueryScore(normalizedQuery, name);
        if (matchScore <= 0) continue;

        final lat = p['lat'] as double;
        final lng = p['lng'] as double;
        final parkId = generateParkID(lat, lng, name);
        if (!seenIds.add(parkId)) continue;

        parks.add(
          Park(
            id: parkId,
            name: name,
            latitude: lat,
            longitude: lng,
            distance: _haversine(userLat, userLng, lat, lng) / 1000,
            isDogPark: _isLikelyDogPark(p),
          ),
        );
      }

      parks.sort((a, b) {
        final scoreA = _parkQueryScore(normalizedQuery, a.name);
        final scoreB = _parkQueryScore(normalizedQuery, b.name);
        final byScore = scoreB.compareTo(scoreA);
        if (byScore != 0) return byScore;

        final da = a.distance ?? double.infinity;
        final db = b.distance ?? double.infinity;
        final byDistance = da.compareTo(db);
        if (byDistance != 0) return byDistance;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    } catch (_) {
      return const [];
    }

    return parks;
  }

  /// Determine if user is within ~150m of a valid park.
  Future<Park?> isUserAtPark(double userLat, double userLng) async {
    try {
      final list = await _placesSearchNearby(
        lat: userLat,
        lng: userLng,
        radiusMeters: 150, // tight radius for "at a park?"
        maxResultCount: 10,
        includedTypes: const ['park'],
      );

      final candidates = list.where(_looksLikeRealPark).toList();
      if (candidates.isEmpty) return null;

      // Closest valid candidate
      candidates.sort((a, b) {
        final da = _haversine(userLat, userLng, a['lat'], a['lng']);
        final db = _haversine(userLat, userLng, b['lat'], b['lng']);
        return da.compareTo(db);
      });

      final c = candidates.first;
      final name = (c['name'] as String).trim();
      return Park(
        id: generateParkID(c['lat'], c['lng'], name),
        name: name,
        latitude: c['lat'],
        longitude: c['lng'],
      );
    } catch (_) {
      return null;
    }
  }

  // ---------- Firestore helpers (unchanged) ----------
  Future<void> ensureParkExists(Park park) async {
    final parkRef = _firestore.collection('parks').doc(park.id);
    final snap = await parkRef.get();
    if (!snap.exists) {
      await parkRef.set({
        'id': park.id,
        'name': park.name,
        'latitude': park.latitude,
        'longitude': park.longitude,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> uploadUserToActiveUsersTable(
    double lat,
    double lng,
    String parkName,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final uid = user.uid;

    final db = FirebaseFirestore.instance;
    final parkId = generateParkID(lat, lng, parkName);
    final parkRef = db.collection('parks').doc(parkId);

    // 1) Ensure park exists
    final parkSnap = await parkRef.get();
    if (!parkSnap.exists) {
      await parkRef.set({
        'id': parkId,
        'name': parkName,
        'latitude': lat,
        'longitude': lng,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }

    // 2) Single-check-in anywhere
    final existing = await db
        .collectionGroup('active_users')
        .where('uid', isEqualTo: uid)
        .get();

    if (existing.docs.isNotEmpty) {
      final batch = db.batch();
      for (final d in existing.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
    }

    // 3) Create current check-in (server maintains userCount)
    await parkRef.collection('active_users').doc(uid).set({
      'uid': uid,
      'checkedInAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> removeUserFromActiveUsersTable(String parkId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userRef = _firestore
        .collection('parks')
        .doc(parkId)
        .collection('active_users')
        .doc(user.uid);

    await userRef.delete();
  }

  // ---------- Location cache ----------
  Future<loc.LocationData> getCurrentLocation() async {
    return await _location.getLocation();
  }

  Future<void> saveUserLocation(double latitude, double longitude) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lastLatitudeKey, latitude);
    await prefs.setDouble(_lastLongitudeKey, longitude);
    await prefs.setInt(
      _lastLocationTimestampKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<LatLng?> getSavedUserLocation({int maxAgeSeconds = 300}) async {
    final prefs = await SharedPreferences.getInstance();
    final latitude = prefs.getDouble(_lastLatitudeKey);
    final longitude = prefs.getDouble(_lastLongitudeKey);
    final timestamp = prefs.getInt(_lastLocationTimestampKey);

    if (latitude != null && longitude != null && timestamp != null) {
      final ageMs = DateTime.now().millisecondsSinceEpoch - timestamp;
      if (ageMs < maxAgeSeconds * 1000) {
        return LatLng(latitude, longitude);
      }
    }
    return null;
  }

  Future<LatLng?> getUserLocationOrCached({int maxAgeSeconds = 300}) async {
    final cached = await getSavedUserLocation(maxAgeSeconds: maxAgeSeconds);
    if (cached != null) return cached;

    final locData = await getCurrentLocation();
    final lat = locData.latitude;
    final lng = locData.longitude;
    if (lat == null || lng == null) return null;

    await saveUserLocation(lat, lng);
    return LatLng(lat, lng);
  }

  Future<void> saveMapCenter(double latitude, double longitude) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lastMapCenterLatitudeKey, latitude);
    await prefs.setDouble(_lastMapCenterLongitudeKey, longitude);
    await prefs.setInt(
      _lastMapCenterTimestampKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<LatLng?> getSavedMapCenter({int maxAgeSeconds = 86400}) async {
    final prefs = await SharedPreferences.getInstance();
    final latitude = prefs.getDouble(_lastMapCenterLatitudeKey);
    final longitude = prefs.getDouble(_lastMapCenterLongitudeKey);
    final timestamp = prefs.getInt(_lastMapCenterTimestampKey);

    if (latitude != null && longitude != null && timestamp != null) {
      final ageMs = DateTime.now().millisecondsSinceEpoch - timestamp;
      if (ageMs < maxAgeSeconds * 1000) {
        return LatLng(latitude, longitude);
      }
    }
    return null;
  }
}
