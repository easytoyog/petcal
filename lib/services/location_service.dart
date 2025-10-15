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
/// Requested fields: places.id, places.displayName, places.location
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

  /// Core POST to Places API (New) Nearby Search with a tight field mask.
  Future<List<Map<String, dynamic>>> _placesSearchNearby({
    required double lat,
    required double lng,
    double radiusMeters = 800, // keep small; scale by zoom if desired
    int maxResultCount = 20, // hard cap to avoid extra costs
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
        // IMPORTANT: Field mask avoids Contact/Atmosphere charges.
        "X-Goog-FieldMask": "places.id,places.displayName,places.location",
      },
      body: body,
    );

    if (resp.statusCode != 200) {
      // Return empty list on errors (keep UI resilient)
      return const [];
    }

    final data = jsonDecode(resp.body);
    final List places = (data["places"] as List?) ?? const [];
    // Normalize to simple maps with id, name, lat, lng
    return places
        .map<Map<String, dynamic>>((p) {
          final loc = p["location"] as Map<String, dynamic>? ?? const {};
          final nameObj = p["displayName"] as Map<String, dynamic>? ?? const {};
          return {
            "id": p["id"] ?? "",
            "name": (nameObj["text"] ?? "").toString(),
            "lat": (loc["latitude"] as num?)?.toDouble(),
            "lng": (loc["longitude"] as num?)?.toDouble(),
          };
        })
        .where((m) =>
            m["lat"] != null &&
            m["lng"] != null &&
            (m["name"] as String).isNotEmpty)
        .toList();
  }

  // ---------- Public API ----------
  /// Find nearby parks around (userLat,userLng).
  /// Uses Places (New) Nearby with tight field mask → Basic data only.
  Future<List<Park>> findNearbyParks(double userLat, double userLng) async {
    final parks = <Park>[];

    try {
      final raw = await _placesSearchNearby(
        lat: userLat,
        lng: userLng,
        radiusMeters: 800, // ~0.8 km; adjust to taste/zoom
        maxResultCount: 20,
        includedTypes: const ['park'],
      );

      // Dedup by (lowercased) name to mimic your previous behavior.
      final seenNames = <String>{};

      for (final p in raw) {
        final name = (p['name'] as String).trim();
        final lat = p['lat'] as double;
        final lng = p['lng'] as double;

        final key = name.toLowerCase();
        if (seenNames.contains(key)) continue;
        seenNames.add(key);

        parks.add(
          Park(
            // Keep your existing stable ID scheme used elsewhere:
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

  /// Determine if user is within ~150m of a park.
  /// Rewritten to Places (New) Nearby with small radius, Basic fields only.
  Future<Park?> isUserAtPark(double userLat, double userLng) async {
    try {
      final list = await _placesSearchNearby(
        lat: userLat,
        lng: userLng,
        radiusMeters: 150, // tight radius for "at a park?"
        maxResultCount: 10,
        includedTypes: const ['park'],
      );

      if (list.isEmpty) return null;

      // Pick the closest by haversine distance.
      double minDistance = double.infinity;
      Map<String, dynamic>? closest;

      for (final p in list) {
        final lat = p['lat'] as double;
        final lng = p['lng'] as double;
        final d = _calculateDistance(userLat, userLng, lat, lng);
        if (d < minDistance) {
          minDistance = d;
          closest = p;
        }
      }

      if (closest == null) return null;

      final name = (closest['name'] as String).trim();
      final lat = closest['lat'] as double;
      final lng = closest['lng'] as double;

      return Park(
        id: generateParkID(lat, lng, name),
        name: name,
        latitude: lat,
        longitude: lng,
      );
    } catch (_) {
      return null;
    }
  }

  // ---------- Geometry ----------
  // Haversine distance in meters
  double _calculateDistance(
      double lat1, double lng1, double lat2, double lng2) {
    const earthRadius = 6371000.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLng = _deg2rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) *
            cos(_deg2rad(lat2)) *
            sin(dLng / 2) *
            sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  double _deg2rad(double deg) => deg * (pi / 180.0);

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
