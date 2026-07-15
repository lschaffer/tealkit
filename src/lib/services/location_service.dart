import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'data_sources_settings_service.dart';
import '../utils/logger.dart';

/// Simple position model.
class GeoPosition {
  final double latitude;
  final double longitude;

  const GeoPosition({required this.latitude, required this.longitude});

  @override
  String toString() => 'GeoPosition($latitude, $longitude)';
}

/// Location service backed by [DataSourcesSettingsService] for persistence
/// and [geolocator] for actual GPS fetches.
///
/// • [lastKnownPosition] — returns the position stored in settings (null if
///   none has been saved yet).
/// • [fetchGpsLocation()] — requests permission, gets a GPS fix, saves it to
///   DataSourcesSettingsService, and notifies listeners.
/// • [getCurrentLocation()] — returns stored position if available (fast path).
class LocationService extends ChangeNotifier {
  LocationService();

  /// Returns the position persisted in DataSourcesSettingsService.
  GeoPosition? get lastKnownPosition {
    final ds = DataSourcesSettingsService.instance;
    final lat = ds.locationLatitude;
    final lng = ds.locationLongitude;
    if (lat == null || lng == null) return null;
    return GeoPosition(latitude: lat, longitude: lng);
  }

  /// Attempt to get current GPS position and save to settings.
  /// Returns the new position, or the stored fallback on failure.
  Future<GeoPosition?> fetchGpsLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        talker.warning('LocationService: GPS service is disabled on device.');
        return lastKnownPosition;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          talker.warning('LocationService: Location permission denied.');
          return lastKnownPosition;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        talker.warning('LocationService: Location permission permanently denied.');
        return lastKnownPosition;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 15)),
      );

      final geoPos = GeoPosition(latitude: position.latitude, longitude: position.longitude);
      await DataSourcesSettingsService.instance.saveLocation(position.latitude, position.longitude);
      talker.info('LocationService: GPS fix – ${geoPos.latitude}, ${geoPos.longitude}');
      notifyListeners();
      return geoPos;
    } catch (e) {
      talker.error('LocationService: GPS error – $e');
      return lastKnownPosition;
    }
  }

  /// Returns stored location if available; otherwise attempts a GPS fetch.
  Future<GeoPosition?> getCurrentLocation() async {
    final stored = lastKnownPosition;
    if (stored != null) return stored;
    return fetchGpsLocation();
  }

  /// Get location as a string for system prompt context.
  Future<String?> getLocationString() async {
    final pos = lastKnownPosition;
    if (pos != null) return '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';
    return null;
  }

  /// Get location coordinates.
  Future<Map<String, double>?> getLocationCoordinates() async {
    final pos = lastKnownPosition;
    if (pos != null) return {'latitude': pos.latitude, 'longitude': pos.longitude};
    return null;
  }

  /// Save a manually entered lat/lng coordinate pair.
  Future<void> setManualLocationCoords(double lat, double lng) async {
    await DataSourcesSettingsService.instance.saveLocation(lat, lng);
    talker.info('LocationService: Manual location set – $lat, $lng');
    notifyListeners();
  }

  /// Legacy string-based setter (no-op — use setManualLocationCoords).
  void setManualLocation(String location) {
    talker.info('LocationService: setManualLocation("$location") is a no-op; use setManualLocationCoords().');
  }

  void clearCache() => talker.info('LocationService: use DataSourcesSettingsService.clearLocation() to clear stored position.');
}
