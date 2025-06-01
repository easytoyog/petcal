import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:location/location.dart' as loc;
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/park_model.dart';

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
              id: place['place_id'],
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

  /// Determines if the user is currently at a park (within 100m).
  /// Returns the Park object if user is at a park, null otherwise.
  Future<Park?> isUserAtPark(double userLat, double userLng) async {
    const String baseUrl =
        "https://maps.googleapis.com/maps/api/place/nearbysearch/json";
    const String type = "park";
    const int radius =
        100; // Smaller radius in meters to determine if user is at a park

    final String url =
        "$baseUrl?location=$userLat,$userLng&radius=$radius&type=$type&key=$_googlePlacesApiKey";

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'OK' && data['results'].isNotEmpty) {
          final place = data['results'][0]; // Get the nearest park
          return Park(
            id: place['place_id'],
            name: place['name'],
            latitude: place['geometry']['location']['lat'],
            longitude: place['geometry']['location']['lng'],
          );
        }
      }
    } catch (e) {
      print("Error determining if user is at park: $e");
    }
    return null;
  }

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
      String parkId, double lat, double lng) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

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
        'name': 'Unknown Park',
        'latitude': lat,
        'longitude': lng,
        'userCount': 0,
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
}
