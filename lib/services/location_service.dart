import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:inthepark/utils/utils.dart';
import 'package:location/location.dart' as loc;
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/park_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class LocationService {
  final loc.Location _location = loc.Location();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final String _googlePlacesApiKey; // Your Google Places API key

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
    _location.enableBackgroundMode(enable: true);
  }

  /// Finds parks within a 500m radius of the user's location.
  /// Returns a list of Park objects.
  Future<List<Park>> findNearbyParks(double userLat, double userLng) async {
    const String baseUrl =
        "https://maps.googleapis.com/maps/api/place/nearbysearch/json";
    const String type = "park";
    const int radius = 500; // Search radius in meters for finding nearby parks

    final String url =
        "$baseUrl?location=$userLat,$userLng&radius=$radius&type=$type&key=$_googlePlacesApiKey";
    List<Park> parks = [];

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'OK' && data['results'].isNotEmpty) {
          for (var place in data['results']) {
            // Create a Park instance from the API data.
            Park park = Park(
              id: generateParkID(
                place['geometry']['location']['lat'],
                place['geometry']['location']['lng'],
                place['name'],
              ),
              name: place['name'],
              latitude: place['geometry']['location']['lat'],
              longitude: place['geometry']['location']['lng'],
            );
            // Check if a park with the same name (ignoring case) is already added.
            if (parks
                .any((p) => p.name.toLowerCase() == park.name.toLowerCase())) {
              continue;
            }
            parks.add(park);
          }
        }
      }
    } catch (e) {
      print("Error finding nearby parks: $e");
    }
    return parks;
  }

  Future<Park?> isUserAtPark(double userLat, double userLng) async {
    const String baseUrl =
        "https://maps.googleapis.com/maps/api/place/nearbysearch/json";
    const String type = "park";
    const int radius = 150; // or your preferred radius

    final String url =
        "$baseUrl?location=$userLat,$userLng&radius=$radius&type=$type&key=$_googlePlacesApiKey";

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'OK' && data['results'].isNotEmpty) {
          double minDistance = double.infinity;
          Map<String, dynamic>? closestPlace;
          for (var place in data['results']) {
            final parkLat = place['geometry']['location']['lat'];
            final parkLng = place['geometry']['location']['lng'];
            final distance =
                _calculateDistance(userLat, userLng, parkLat, parkLng);
            if (distance < minDistance) {
              minDistance = distance;
              closestPlace = place;
            }
          }
          if (closestPlace != null) {
            return Park(
              id: generateParkID(
                closestPlace['geometry']['location']['lat'],
                closestPlace['geometry']['location']['lng'],
                closestPlace['name'],
              ),
              name: closestPlace['name'],
              latitude: closestPlace['geometry']['location']['lat'],
              longitude: closestPlace['geometry']['location']['lng'],
            );
          }
        }
      }
    } catch (e) {
      print("Error determining if user is at park: $e");
    }
    return null;
  }

// Helper function to calculate distance between two lat/lng points in meters
  double _calculateDistance(
      double lat1, double lng1, double lat2, double lng2) {
    const earthRadius = 6371000; // meters
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

  double _deg2rad(double deg) => deg * (pi / 180);

  /// Ensures that a park document exists in Firestore.
  Future<void> ensureParkExists(Park park) async {
    final parkRef = _firestore.collection('parks').doc(park.id);
    final parkDoc = await parkRef.get();

    if (!parkDoc.exists) {
      // Park doesn't exist, create it using park.toJson()
      await parkRef.set(park.toJson());
    }
  }

  /// Uploads the current user's check-in data to the active_users collection of the specified park.
  /// Ensures that the park document exists before updating the userCount.
  Future<void> uploadUserToActiveUsersTable(
    double lat,
    double lng,
    String parkName,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Always generate the park ID using name, lat, lng
    final parkId = generateParkID(lat, lng, parkName);

    // Check out from all other parks first
    final parksSnapshot = await _firestore.collection('parks').get();
    for (var parkDoc in parksSnapshot.docs) {
      final otherParkId = parkDoc.id;
      if (otherParkId != parkId) {
        final userRef = _firestore
            .collection('parks')
            .doc(otherParkId)
            .collection('active_users')
            .doc(user.uid);
        final userDoc = await userRef.get();
        if (userDoc.exists) {
          await userRef.delete();
          // Decrement userCount if needed
          await _firestore.collection('parks').doc(otherParkId).update({
            'userCount': FieldValue.increment(-1),
          });
        }
      }
    }

    final parkRef = _firestore.collection('parks').doc(parkId);
    final parkDoc = await parkRef.get();

    if (!parkDoc.exists) {
      // Create the park document with minimal data if it doesn't exist.
      await parkRef.set({
        'id': parkId,
        'name': parkName,
        'latitude': lat,
        'longitude': lng,
        'userCount': 0,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }

    // Add the user to the active_users subcollection.
    final userRef = parkRef.collection('active_users').doc(user.uid);
    await userRef.set({
      'uid': user.uid,
      'latitude': lat,
      'longitude': lng,
      'timestamp': FieldValue.serverTimestamp(),
      'checkedInAt': FieldValue.serverTimestamp(),
    });

    // Increment the park's userCount field.
    await parkRef.update({'userCount': FieldValue.increment(1)});
  }

  /// Removes the current user from the active_users collection of the specified park.
  Future<void> removeUserFromActiveUsersTable(String parkId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final parkRef = _firestore.collection('parks').doc(parkId);
    final userRef = parkRef.collection('active_users').doc(user.uid);

    await userRef.delete();

    // Only update the userCount if the park document exists.
    final parkDoc = await parkRef.get();
    if (parkDoc.exists) {
      await parkRef.update({'userCount': FieldValue.increment(-1)});
    }
  }

  Future<loc.LocationData> getCurrentLocation() async {
    return await _location.getLocation();
  }

  /// Save user location and timestamp to cache
  Future<void> saveUserLocation(double latitude, double longitude) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_latitude', latitude);
    await prefs.setDouble('last_longitude', longitude);
    await prefs.setInt(
        'last_location_timestamp', DateTime.now().millisecondsSinceEpoch);
  }

  /// Get cached user location if not too old
  Future<LatLng?> getSavedUserLocation({int maxAgeSeconds = 300}) async {
    final prefs = await SharedPreferences.getInstance();
    final latitude = prefs.getDouble('last_latitude');
    final longitude = prefs.getDouble('last_longitude');
    final timestamp = prefs.getInt('last_location_timestamp');
    if (latitude != null && longitude != null && timestamp != null) {
      final age = DateTime.now().millisecondsSinceEpoch - timestamp;
      if (age < maxAgeSeconds * 1000) {
        return LatLng(latitude, longitude);
      }
    }
    return null;
  }

  /// Get user location, using cache if recent, otherwise request new
  Future<LatLng?> getUserLocationOrCached({int maxAgeSeconds = 300}) async {
    LatLng? cached = await getSavedUserLocation(maxAgeSeconds: maxAgeSeconds);
    if (cached != null) return cached;

    final locData = await getCurrentLocation();
    await saveUserLocation(locData.latitude!, locData.longitude!);
    return LatLng(locData.latitude!, locData.longitude!);
      return null;
  }
}
