import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class MapSurface extends StatefulWidget {
  final void Function(GoogleMapController) onMapCreated;
  final void Function(CameraPosition) onCameraMove;
  final LatLng initialTarget;
  final Set<Marker> markers;
  final Set<Polyline> polylines;
  final bool myLocationEnabled;

  const MapSurface({
    Key? key,
    required this.onMapCreated,
    required this.onCameraMove,
    required this.initialTarget,
    required this.markers,
    required this.polylines,
    required this.myLocationEnabled,
  }) : super(key: key);

  @override
  State<MapSurface> createState() => _MapSurfaceState();
}

class _MapSurfaceState extends State<MapSurface> {
  @override
  Widget build(BuildContext context) {
    return GoogleMap(
      onMapCreated: widget.onMapCreated,
      onCameraMove: widget.onCameraMove,
      initialCameraPosition: CameraPosition(
        target: widget.initialTarget,
        zoom: 14,
      ),
      markers: widget.markers,
      polylines: widget.polylines,
      myLocationEnabled: widget.myLocationEnabled,
      myLocationButtonEnabled: false,
      compassEnabled: true,
    );
  }
}
