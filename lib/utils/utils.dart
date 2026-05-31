String generateParkID(double latitude, double longitude, String placeID) {
  // Firestore document IDs cannot contain path separators like "/".
  final trimmedPlaceID =
      placeID.replaceAll('/', '').replaceAll('\\', '').replaceAll(' ', '');
  final trimmedLat = latitude.toStringAsFixed(1).replaceAll(' ', '');
  final trimmedLng = longitude.toStringAsFixed(1).replaceAll(' ', '');
  return '${trimmedPlaceID}_${trimmedLat}_$trimmedLng';
}
