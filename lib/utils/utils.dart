String generateParkID(double latitude, double longitude, String placeID) {
  // Generate a unique park ID with all spaces trimmed
  final trimmedPlaceID = placeID.replaceAll(' ', '');
  final trimmedLat = latitude.toStringAsFixed(6).replaceAll(' ', '');
  final trimmedLng = longitude.toStringAsFixed(6).replaceAll(' ', '');
  return '${trimmedPlaceID}_${trimmedLat}_${trimmedLng}';
}
