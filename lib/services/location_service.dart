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

  // ---------- Filtering helpers ----------
  bool _looksLikeRealPark(Map<String, dynamic> p) {
    final name = (p['name'] as String).trim();
    final primary = (p['primaryType'] as String);
    final types = (p['types'] as List).cast<String>();

    // Must be a park by primary or secondary type
    final isPark = primary == 'park' || types.contains('park');
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
          ),
        );
      }
    } catch (_) {
      // Swallow network/parse errors; return what we have.
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
    await prefs.setDouble('last_latitude', latitude);
    await prefs.setDouble('last_longitude', longitude);
    await prefs.setInt(
        'last_location_timestamp', DateTime.now().millisecondsSinceEpoch);
  }

  Future<LatLng?> getSavedUserLocation({int maxAgeSeconds = 300}) async {
    final prefs = await SharedPreferences.getInstance();
    final latitude = prefs.getDouble('last_latitude');
    final longitude = prefs.getDouble('last_longitude');
    final timestamp = prefs.getInt('last_location_timestamp');

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
}
