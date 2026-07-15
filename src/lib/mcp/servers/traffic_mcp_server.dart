import 'dart:convert';

import 'package:http/http.dart' as http;

import '../internal_mcp_server.dart';

class TrafficMcpServer extends InternalMcpServer {
  String _provider = 'tomtom';
  String _apiKey = '';

  @override
  String get type => 'traffic';

  @override
  String get displayName => 'Traffic live';

  @override
  String get description => 'Fetch live traffic flow snapshots around coordinates using TomTom or HERE APIs (API key required).';

  @override
  String get iconName => 'traffic';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'provider': {
        'type': 'string',
        'enum': ['tomtom', 'here'],
        'default': 'tomtom',
        'description': 'Traffic provider. Both require API keys.',
      },
      'apiKey': {'type': 'string', 'description': 'Provider API key. Can be overridden per tool call.'},
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'provider': 'tomtom', 'apiKey': ''};

  @override
  String get defaultSystemPrompt =>
      'Use get_traffic_snapshot for real-time traffic speed/flow near coordinates. '
      'If provider API key is missing, ask the user to add one in MCP config.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    final provider = (initParams['provider'] as String? ?? 'tomtom').trim().toLowerCase();
    _provider = provider == 'here' ? 'here' : 'tomtom';
    _apiKey = (initParams['apiKey'] as String? ?? '').trim();
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'get_traffic_snapshot',
      description: 'Get a live traffic snapshot around a location (lat/lon).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'lat': {'type': 'number', 'description': 'Latitude.'},
          'lon': {'type': 'number', 'description': 'Longitude.'},
          'provider': {
            'type': 'string',
            'enum': ['tomtom', 'here'],
            'description': 'Optional provider override.',
          },
          'apiKey': {'type': 'string', 'description': 'Optional API key override.'},
          'zoom': {'type': 'integer', 'default': 12, 'description': 'TomTom zoom level (0-22).'},
          'radiusMeters': {'type': 'integer', 'default': 1000, 'description': 'HERE search radius in meters (100-5000).'},
        },
        'required': ['lat', 'lon'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    switch (toolName) {
      case 'get_traffic_snapshot':
        return _getTrafficSnapshot(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  Future<Map<String, dynamic>> _getTrafficSnapshot(Map<String, dynamic> args) async {
    final lat = (args['lat'] as num?)?.toDouble();
    final lon = (args['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) {
      return {'error': 'Parameters "lat" and "lon" are required.'};
    }

    final providerOverride = (args['provider'] as String?)?.trim().toLowerCase();
    final provider = providerOverride == 'here' ? 'here' : (providerOverride == 'tomtom' ? 'tomtom' : _provider);

    final keyOverride = (args['apiKey'] as String? ?? '').trim();
    final apiKey = keyOverride.isNotEmpty ? keyOverride : _apiKey;
    if (apiKey.isEmpty) {
      return {'error': 'Traffic API key missing. Configure apiKey in this MCP or pass apiKey per call. TomTom and HERE both require keys.'};
    }

    if (provider == 'here') {
      return _fetchHereTraffic(lat: lat, lon: lon, apiKey: apiKey, radiusMeters: ((args['radiusMeters'] as num?)?.toInt() ?? 1000));
    }

    return _fetchTomTomTraffic(lat: lat, lon: lon, apiKey: apiKey, zoom: ((args['zoom'] as num?)?.toInt() ?? 12));
  }

  Future<Map<String, dynamic>> _fetchTomTomTraffic({
    required double lat,
    required double lon,
    required String apiKey,
    required int zoom,
  }) async {
    final clampedZoom = zoom.clamp(0, 22);
    final uri = Uri.parse(
      'https://api.tomtom.com/traffic/services/4/flowSegmentData/absolute/$clampedZoom/json',
    ).replace(queryParameters: {'key': apiKey, 'point': '$lat,$lon'});

    try {
      final res = await http.get(uri, headers: const {'Accept': 'application/json'});
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return {'error': 'TomTom traffic error ${res.statusCode}: ${_errorText(decoded, res.reasonPhrase)}'};
      }

      final flow = (decoded is Map<String, dynamic>) ? decoded['flowSegmentData'] as Map<String, dynamic>? : null;
      if (flow == null) {
        return {'error': 'TomTom response missing flowSegmentData.'};
      }

      return {
        'provider': 'tomtom',
        'location': {'lat': lat, 'lon': lon},
        'freeFlowSpeedKph': flow['freeFlowSpeed'],
        'currentSpeedKph': flow['currentSpeed'],
        'currentTravelTimeSec': flow['currentTravelTime'],
        'freeFlowTravelTimeSec': flow['freeFlowTravelTime'],
        'roadClosure': flow['roadClosure'],
        'frc': flow['frc'],
        'confidence': flow['confidence'],
        'coordinates': flow['coordinates'],
        'raw': flow,
      };
    } catch (e) {
      return {'error': 'TomTom traffic request failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _fetchHereTraffic({
    required double lat,
    required double lon,
    required String apiKey,
    required int radiusMeters,
  }) async {
    final clampedRadius = radiusMeters.clamp(100, 5000);
    final uri = Uri.parse(
      'https://data.traffic.hereapi.com/v7/flow',
    ).replace(queryParameters: {'in': 'circle:$lat,$lon;r=$clampedRadius', 'locationReferencing': 'none', 'apiKey': apiKey});

    try {
      final res = await http.get(uri, headers: const {'Accept': 'application/json'});
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return {'error': 'HERE traffic error ${res.statusCode}: ${_errorText(decoded, res.reasonPhrase)}'};
      }

      final results = (decoded is Map<String, dynamic>) ? (decoded['results'] as List<dynamic>? ?? const []) : const [];

      return {
        'provider': 'here',
        'location': {'lat': lat, 'lon': lon},
        'radiusMeters': clampedRadius,
        'segmentCount': results.length,
        'segments': results,
      };
    } catch (e) {
      return {'error': 'HERE traffic request failed: $e'};
    }
  }

  String _errorText(Object? decoded, String? fallback) {
    if (decoded is Map<String, dynamic>) {
      final msg = decoded['error'] ?? decoded['message'] ?? decoded['title'] ?? decoded['detail'];
      if (msg != null && msg.toString().trim().isNotEmpty) return msg.toString();
    }
    return fallback ?? 'unknown';
  }
}
