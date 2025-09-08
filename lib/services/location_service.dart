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

class LocationService {
  final loc.Location _location = loc.Location();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final String _googlePlacesApiKey;

  LocationService(this._googlePlacesApiKey);

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
      // Background mode not supported / not granted – ignore gracefully.
    }
  }

  /// Google Places Nearby Search for parks within ~500m.
  Future<List<Park>> findNearbyParks(double userLat, double userLng) async {
    const String baseUrl =
        "https://maps.googleapis.com/maps/api/place/nearbysearch/json";
    const String type = "park";
    const int radius = 500;

    final String url =
        "$baseUrl?location=$userLat,$userLng&radius=$radius&type=$type&key=$_googlePlacesApiKey";

    final parks = <Park>[];
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'OK' && (data['results'] as List).isNotEmpty) {
          for (final place in data['results']) {
            final name = (place['name'] ?? '').toString();
            final lat =
                (place['geometry']['location']['lat'] as num).toDouble();
            final lng =
                (place['geometry']['location']['lng'] as num).toDouble();

            final park = Park(
              id: generateParkID(lat, lng, name),
              name: name,
              latitude: lat,
              longitude: lng,
            );

            // Dedup by name (case-insensitive)
            if (parks
                .any((p) => p.name.toLowerCase() == park.name.toLowerCase())) {
              continue;
            }
            parks.add(park);
          }
        }
      }
    } catch (e) {
      // Network/parse errors are non-fatal for UI – just return what we have.
      // print("Error finding nearby parks: $e");
    }
    return parks;
  }

  /// Is the user currently within ~150m of a park? Returns the closest match.
  Future<Park?> isUserAtPark(double userLat, double userLng) async {
    const String baseUrl =
        "https://maps.googleapis.com/maps/api/place/nearbysearch/json";
    const String type = "park";
    const int radius = 150;

    final String url =
        "$baseUrl?location=$userLat,$userLng&radius=$radius&type=$type&key=$_googlePlacesApiKey";

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'OK' && (data['results'] as List).isNotEmpty) {
          double minDistance = double.infinity;
          Map<String, dynamic>? closestPlace;

          for (final place in data['results']) {
            final parkLat =
                (place['geometry']['location']['lat'] as num).toDouble();
            final parkLng =
                (place['geometry']['location']['lng'] as num).toDouble();
            final distance =
                _calculateDistance(userLat, userLng, parkLat, parkLng);
            if (distance < minDistance) {
              minDistance = distance;
              closestPlace = place as Map<String, dynamic>;
            }
          }

          if (closestPlace != null) {
            final name = (closestPlace['name'] ?? '').toString();
            final lat =
                (closestPlace['geometry']['location']['lat'] as num).toDouble();
            final lng =
                (closestPlace['geometry']['location']['lng'] as num).toDouble();

            return Park(
              id: generateParkID(lat, lng, name),
              name: name,
              latitude: lat,
              longitude: lng,
            );
          }
        }
      }
    } catch (e) {
      // print("Error determining if user is at park: $e");
    }
    return null;
  }

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

  /// Ensure a park doc exists with only safe, allow-listed fields.
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

  /// Check the current user into a park (single-check-in).
  /// Cloud Functions increment/decrement `userCount`.
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

    // 1) Ensure park exists (safe fields only). Do NOT write 'uid'.
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

    // 2) Single-check-in: delete any existing active_users/{uid} anywhere
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
      // CF onDocumentDeleted will decrement userCount
    }

    // 3) Create/overwrite check-in here – write 'uid' + 'checkedInAt' only
    await parkRef.collection('active_users').doc(uid).set({
      'uid': uid,
      'checkedInAt': FieldValue.serverTimestamp(),
    });

    // Do NOT touch userCount here (server maintains it).
  }



  /// Uncheck the current user from a specific park.
  /// Cloud Functions will decrement `userCount`.
  Future<void> removeUserFromActiveUsersTable(String parkId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userRef = _firestore
        .collection('parks')
        .doc(parkId)
        .collection('active_users')
        .doc(user.uid);

    await userRef.delete();
    // No client-side userCount updates.
  }

  Future<loc.LocationData> getCurrentLocation() async {
    return await _location.getLocation();
  }

  /// Cache user location
  Future<void> saveUserLocation(double latitude, double longitude) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_latitude', latitude);
    await prefs.setDouble('last_longitude', longitude);
    await prefs.setInt(
        'last_location_timestamp', DateTime.now().millisecondsSinceEpoch);
  }

  /// Read cached user location if recent
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

  /// Get user location, prefer cache, else read & cache fresh
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
