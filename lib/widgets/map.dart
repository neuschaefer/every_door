import 'dart:async';
import 'dart:math' show min, max, Point;

import 'package:every_door/constants.dart';
import 'package:every_door/helpers/closest_points.dart';
import 'package:every_door/models/amenity.dart';
import 'package:every_door/providers/geolocation.dart';
import 'package:every_door/providers/imagery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:every_door/helpers/tile_layers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AmenityMapController {
  Function(LatLng, bool)? moveListener;
  Function(Iterable<LatLng>)? zoomListener;

  setLocation(LatLng location, {bool emitDrag = true}) {
    if (moveListener != null) moveListener!(location, emitDrag);
  }

  zoomToFit(Iterable<LatLng> locations) {
    if (locations.isNotEmpty) {
      if (zoomListener != null) zoomListener!(locations);
    }
  }
}

class AmenityMap extends ConsumerStatefulWidget {
  final LatLng initialLocation;
  final List<OsmChange> amenities;
  final void Function(LatLng)? onDrag;
  final void Function(LatLng)? onDragEnd;
  final void Function(LatLng)? onTrack;
  final void Function(LatLngBounds)? onTap;
  final AmenityMapController? controller;

  const AmenityMap({
    required this.initialLocation,
    this.onDrag,
    this.onDragEnd,
    this.onTrack,
    this.onTap,
    this.amenities = const [],
    this.controller,
  });

  @override
  _AmenityMapState createState() => _AmenityMapState();
}

class _AmenityMapState extends ConsumerState<AmenityMap> {
  static const kMapZoom = 17.0;

  late final MapController mapController;
  late final StreamSubscription<MapEvent> mapSub;
  late LatLng mapCenter;
  bool showAttribution = true;
  String lastAmenityIds = '';

  @override
  void initState() {
    super.initState();
    mapController = MapController();
    mapCenter = widget.initialLocation;
    if (widget.controller != null) {
      widget.controller!.moveListener = onControllerLocation;
      widget.controller!.zoomListener = onControllerZoom;
    }
    mapSub = mapController.mapEventStream.listen(onMapEvent);
    // hideAttribution();
  }

  hideAttribution() {
    Future.delayed(Duration(seconds: 9), () {
      if (showAttribution) {
        setState(() {
          showAttribution = false;
        });
      }
    });
  }

  void onMapEvent(MapEvent event) {
    if (event is MapEventMove) {
      mapCenter = event.targetCenter;
      if (event.source != MapEventSource.mapController) {
        ref.read(trackingProvider.state).state = false;
        setState(() {
          // redraw center marker
        });
        if (widget.onDrag != null) widget.onDrag!(event.targetCenter);
      }
    } else if (event is MapEventMoveEnd) {
      if (widget.onDragEnd != null &&
          event.source != MapEventSource.mapController)
        widget.onDragEnd!(event.center);
    } else if (event is MapEventTap) {
      if (widget.onTap != null) {
        widget.onTap!(_getBoundsForRadius(event.tapPosition, event.zoom, kTapRadius));
      }
    }
  }

  void onControllerLocation(LatLng location, bool emitDrag) {
    mapController.move(location, mapController.zoom);
    if (emitDrag && widget.onDrag != null) {
      widget.onDrag!(location);
    }
  }

  LatLngBounds _getBoundsForRadius(LatLng center, double zoom, double radiusPixels) {
    const crs = Epsg3857();
    final point = crs.latLngToPoint(center, zoom);
    final swPoint = crs.pointToLatLng(point - Point(radiusPixels, radiusPixels), zoom);
    final nePoint = crs.pointToLatLng(point + Point(radiusPixels, radiusPixels), zoom);
    return LatLngBounds(swPoint, nePoint);
  }

  double _calculateZoom(Iterable<LatLng> locations, EdgeInsets padding) {
    // Add a virtual location to keep center.
    // Here we don't reproject, since on low zooms Mercator could be considered equirectandular.
    // Taking first 9, for we display only 9.
    final bounds = LatLngBounds.fromPoints(locations.take(9).toList());
    final center = mapController.center;
    final dlat = max(
      (bounds.north - center.latitude).abs(),
      (bounds.south - center.latitude).abs(),
    );
    final dlon = max(
      (bounds.east - center.longitude).abs(),
      (bounds.west - center.longitude).abs(),
    );
    final newBounds = LatLngBounds(
      LatLng(center.latitude - dlat, center.longitude - dlon),
      LatLng(center.latitude + dlat, center.longitude + dlon),
    );
    return mapController
        .centerZoomFitBounds(newBounds,
            options: FitBoundsOptions(
              padding: padding,
              maxZoom: kMapZoom + 1,
              inside: false,
            ))
        .zoom;
  }

  onControllerZoom(Iterable<LatLng> locations) {
    const kPadding = EdgeInsets.all(12.0);
    const kZoomThreshold = 0.2;
    const kTooCloseThreshold = 10.0; // meters. I know, bad.

    double zoom = _calculateZoom(locations, kPadding);
    if (zoom < kMapZoom - 1 && locations.length >= 6) {
      // When outliers are too far, we can skip them I guess.
      zoom = _calculateZoom(locations.take(locations.length - 2), kPadding);
    }

    final curZoom = mapController.zoom;
    double maxZoomHere = kMapZoom;
    if (zoom > kMapZoom && zoom > curZoom) {
      // Overzoom only if points are too close.
      if (closestPairDistance(locations) <= kTooCloseThreshold) maxZoomHere++;
    }
    if (zoom < kMapZoom - 1)
      zoom = min(curZoom, kMapZoom - 1);
    else if (zoom > maxZoomHere) zoom = max(curZoom, maxZoomHere);
    if ((zoom - curZoom).abs() >= kZoomThreshold)
      mapController.move(mapController.center, zoom);
  }

  @override
  void dispose() {
    mapSub.cancel();
    super.dispose();
  }

  trackAmenities() {
    List<String> newAmenityIds = widget.amenities
        .map((e) => e.isNew ? e.typeAndName : e.id.toString())
        .toList();
    newAmenityIds.sort();
    String amenityString = newAmenityIds.join();
    if (amenityString != lastAmenityIds) {
      // TODO: zoom?
      lastAmenityIds = amenityString;
    }
  }

  @override
  Widget build(BuildContext context) {
    final LatLng? trackLocation = ref.watch(geolocationProvider);

    // When tracking location, move map and notify the poi list.
    ref.listen<LatLng?>(geolocationProvider, (_, LatLng? location) {
      if (location != null && ref.watch(trackingProvider)) {
        mapController.move(location, mapController.zoom);
        if (widget.onDragEnd != null) widget.onDragEnd!(location);
        if (widget.onTrack != null) widget.onTrack!(location);
      }
    });

    // When turning the tracking on, move the map immediately.
    ref.listen(trackingProvider, (_, bool newState) {
      if (trackLocation != null && newState) {
        mapController.move(trackLocation, mapController.zoom);
        if (widget.onDragEnd != null) widget.onDragEnd!(trackLocation);
        if (widget.onTrack != null) widget.onTrack!(trackLocation);
      }
    });

    trackAmenities();

    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        center: widget.initialLocation, // This does not work :(
        zoom: kMapZoom,
        minZoom: 15.0,
        maxZoom: 20.0,
        interactiveFlags: InteractiveFlag.drag | InteractiveFlag.pinchZoom,
      ),
      children: [
        TileLayerWidget(
          options: buildTileLayerOptions(
              ref.watch(selectedImageryProvider), showAttribution),
        ),
        if (trackLocation != null)
          CircleLayerWidget(
            options: CircleLayerOptions(
              circles: [
                CircleMarker(
                  point: trackLocation,
                  color: Colors.blue.withOpacity(0.4),
                  radius: 10.0,
                ),
                if (ref.watch(trackingProvider))
                  CircleMarker(
                    point: trackLocation,
                    borderColor: Colors.black.withOpacity(0.8),
                    borderStrokeWidth: 1.0,
                    color: Colors.transparent,
                    radius: 10.0,
                  ),
              ],
            ),
          ),
        MarkerLayerWidget(
          options: MarkerLayerOptions(
            markers: [
              if (!ref.watch(trackingProvider))
                Marker(
                  point:
                      mapCenter, // mapController.center throws late init exception
                  anchorPos: AnchorPos.exactly(Anchor(15.0, 5.0)),
                  builder: (ctx) => Icon(Icons.location_pin),
                ),
              for (var i = 0; i < widget.amenities.length && i < 9; i++)
                Marker(
                  point: widget.amenities[i].location,
                  anchorPos: AnchorPos.exactly(Anchor(20.0, 20.0)),
                  builder: (ctx) => Stack(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 20.0,
                        color: Colors.white.withOpacity(0.7),
                      ),
                      Container(
                        padding: EdgeInsets.only(left: 6.0, top: 1.0),
                        child: Text(
                          (i + 1).toString(),
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 15.0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
