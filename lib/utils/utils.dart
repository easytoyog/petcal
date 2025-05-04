// lib/utils/utils.dart
String generateParkID(double latitude, double longitude, String placeID) {
  // Generate a unique park ID
  return '${placeID}_${latitude.toStringAsFixed(6)}_${longitude.toStringAsFixed(6)}';
}
