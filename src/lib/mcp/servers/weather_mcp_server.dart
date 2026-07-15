import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/weather_forecast_report_service.dart';
import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server for weather data using Open-Meteo API.
///
/// Free, no API key required. Provides:
///   • Current weather conditions
///   • Hourly forecast (up to 7 days)
///   • Daily forecast (up to 16 days)
///   • Weather alerts (where available)
///
/// Init parameters:
///   • location: City name or "lat,lng" coordinates (e.g. "Vienna" or "48.2082,16.3738")
///               Use "current" for device location (if available)
class WeatherMcpServer extends InternalMcpServer {
  static const String _baseUrl = 'https://api.open-meteo.com/v1';
  static const String _geocodeUrl = 'https://geocoding-api.open-meteo.com/v1';

  double? _latitude;
  double? _longitude;
  String? _locationName;
  String _timezone = 'auto';
  final WeatherForecastReportService _reportService = WeatherForecastReportService();

  @override
  String get type => 'weather';

  @override
  String get displayName => 'Weather';

  @override
  String get description =>
      'Fetch weather forecasts using Open-Meteo (free, no API key). '
      'Provides current conditions, hourly and daily forecasts.';

  @override
  String get iconName => 'cloud';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'location': {
        'type': 'string',
        'description':
            'City name (e.g. "Vienna") or coordinates "lat,lng" (e.g. "48.2082,16.3738"). '
            'Use "current" for device GPS location.',
        'default': 'current',
      },
      'timezone': {
        'type': 'string',
        'description': 'IANA timezone (e.g. "Europe/Berlin"). Use "auto" for automatic detection.',
        'default': 'auto',
      },
    },
    'required': ['location'],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'location': 'current', 'timezone': 'auto'};

  @override
  String get defaultSystemPrompt =>
      'Weather tools: answer with current conditions, hourly forecast, or daily '
      'forecast as needed. Include temperature, wind speed, and precipitation '
      'probability. When a city is provided, geocode it first. Use concise output '
      'with units (°C, km/h, %).';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    final location = initParams['location'] as String? ?? 'current';
    _timezone = initParams['timezone'] as String? ?? 'auto';

    log.info('[Weather MCP] Initializing with location="$location", timezone="$_timezone"');

    if (location == 'current') {
      final ds = DataSourcesSettingsService.instance;
      if (ds.hasLocation) {
        _latitude = ds.locationLatitude;
        _longitude = ds.locationLongitude;
        _locationName = 'your location';
        log.info('[Weather MCP] Using stored device location: $_latitude, $_longitude');
      } else {
        log.warning('[Weather MCP] No stored location found. Save your location in Data Sources settings.');
      }
      return;
    }

    // Check if it's coordinates (lat,lng)
    final coordMatch = RegExp(r'^(-?\d+\.?\d*)\s*,\s*(-?\d+\.?\d*)$').firstMatch(location);
    if (coordMatch != null) {
      _latitude = double.parse(coordMatch.group(1)!);
      _longitude = double.parse(coordMatch.group(2)!);
      _locationName = 'Lat $_latitude, Lng $_longitude';
      log.info('[Weather MCP] Using coordinates: $_latitude, $_longitude');
      return;
    }

    // It's a city name — geocode it
    await _geocodeCity(location);
  }

  @override
  String? validateInitParams(Map<String, dynamic> params) {
    final location = params['location'] as String?;
    if (location == null || location.trim().isEmpty) {
      return 'Location is required';
    }
    return null;
  }

  /// Geocode a city name to lat/lng using Open-Meteo Geocoding API.
  Future<void> _geocodeCity(String cityName) async {
    final url = '$_geocodeUrl/search?name=${Uri.encodeComponent(cityName)}&count=1&language=en&format=json';
    log.info('[Weather MCP] Geocoding city: "$cityName"');

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final results = body['results'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          final first = results[0] as Map<String, dynamic>;
          _latitude = (first['latitude'] as num).toDouble();
          _longitude = (first['longitude'] as num).toDouble();
          _locationName = '${first['name']}, ${first['country'] ?? ''}';
          log.info('[Weather MCP] Geocoded "$cityName" → $_locationName ($_latitude, $_longitude)');
        } else {
          log.warning('[Weather MCP] No results for city: "$cityName"');
        }
      } else {
        log.error('[Weather MCP] Geocoding failed: ${response.statusCode}');
      }
    } catch (e) {
      log.error('[Weather MCP] Geocoding error: $e');
    }
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'get_current_weather',
      description: 'Get current weather conditions including temperature, wind, humidity, and weather description.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'latitude': {'type': 'number', 'description': 'Latitude (optional, uses configured location if omitted)'},
          'longitude': {'type': 'number', 'description': 'Longitude (optional, uses configured location if omitted)'},
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'get_hourly_forecast',
      description:
          'Get hourly weather forecast for the next 24-168 hours. '
          'Includes temperature, precipitation, wind speed, and weather code.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'hours': {'type': 'integer', 'description': 'Number of hours to forecast (default: 24, max: 168)', 'default': 24},
          'outputType': {
            'type': 'string',
            'description': 'Output format: text (default) or pdf (returns downloadable PDF report as base64 file).',
            'enum': ['text', 'pdf'],
            'default': 'text',
          },
          'latitude': {'type': 'number', 'description': 'Latitude (optional)'},
          'longitude': {'type': 'number', 'description': 'Longitude (optional)'},
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'get_daily_forecast',
      description:
          'Get daily weather forecast for the next 1-16 days. '
          'Includes high/low temperatures, precipitation sum, sunrise/sunset.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'days': {'type': 'integer', 'description': 'Number of days to forecast (default: 7, max: 16)', 'default': 7},
          'latitude': {'type': 'number', 'description': 'Latitude (optional)'},
          'longitude': {'type': 'number', 'description': 'Longitude (optional)'},
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'geocode_weather_city',
      description:
          'Look up the coordinates (latitude, longitude) for a city name. '
          'Useful for finding coordinates to pass to other weather tools.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'city': {'type': 'string', 'description': 'City name to look up (e.g. "Vienna", "New York")'},
        },
        'required': ['city'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    log.info('[Weather MCP] executeTool: $toolName');

    switch (toolName) {
      case 'get_current_weather':
        return _getCurrentWeather(arguments);
      case 'get_hourly_forecast':
        return _getHourlyForecast(arguments);
      case 'get_daily_forecast':
        return _getDailyForecast(arguments);
      case 'geocode_weather_city':
      case 'geocode_city':
        return _geocodeCityTool(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  // ──────────────────────────────────────────────
  // Tool implementations
  // ──────────────────────────────────────────────

  double _getLat(Map<String, dynamic> args) {
    if (args['latitude'] != null) return (args['latitude'] as num).toDouble();
    if (_latitude != null) return _latitude!;
    // Last resort: read stored location
    return DataSourcesSettingsService.instance.locationLatitude ?? 0;
  }

  double _getLng(Map<String, dynamic> args) {
    if (args['longitude'] != null) return (args['longitude'] as num).toDouble();
    if (_longitude != null) return _longitude!;
    // Last resort: read stored location
    return DataSourcesSettingsService.instance.locationLongitude ?? 0;
  }

  Future<Map<String, dynamic>> _getCurrentWeather(Map<String, dynamic> args) async {
    final lat = _getLat(args);
    final lng = _getLng(args);

    if (lat == 0 && lng == 0) {
      return {'error': 'No location configured. Provide latitude/longitude or initialize with a city name.'};
    }

    final url =
        '$_baseUrl/forecast?latitude=$lat&longitude=$lng'
        '&current=temperature_2m,relative_humidity_2m,apparent_temperature,'
        'is_day,precipitation,rain,showers,snowfall,weather_code,'
        'cloud_cover,pressure_msl,surface_pressure,wind_speed_10m,'
        'wind_direction_10m,wind_gusts_10m'
        '&timezone=$_timezone';

    return _fetchWeatherData(url, 'current_weather');
  }

  Future<Map<String, dynamic>> _getHourlyForecast(Map<String, dynamic> args) async {
    final lat = _getLat(args);
    final lng = _getLng(args);
    final hours = (args['hours'] as int?) ?? 24;
    final outputType = (args['outputType'] as String? ?? 'text').trim().toLowerCase();

    if (lat == 0 && lng == 0) {
      return {'error': 'No location configured.'};
    }

    final url =
        '$_baseUrl/forecast?latitude=$lat&longitude=$lng'
        '&hourly=temperature_2m,relative_humidity_2m,apparent_temperature,'
        'precipitation_probability,precipitation,rain,showers,snowfall,'
        'weather_code,cloud_cover,wind_speed_10m,wind_direction_10m,'
        'wind_gusts_10m'
        '&forecast_hours=$hours'
        '&timezone=$_timezone';

    final result = await _fetchWeatherData(url, 'hourly_forecast');
    if (result.containsKey('error')) {
      return result;
    }

    if (outputType == 'pdf') {
      return _reportService.buildHourlyForecastPdf(
        weatherData: result,
        locationName: _locationName ?? 'Unknown location',
        requestedHours: hours,
      );
    }

    return result;
  }

  Future<Map<String, dynamic>> _getDailyForecast(Map<String, dynamic> args) async {
    final lat = _getLat(args);
    final lng = _getLng(args);
    final days = (args['days'] as int?) ?? 7;

    if (lat == 0 && lng == 0) {
      return {'error': 'No location configured.'};
    }

    final url =
        '$_baseUrl/forecast?latitude=$lat&longitude=$lng'
        '&daily=weather_code,temperature_2m_max,temperature_2m_min,'
        'apparent_temperature_max,apparent_temperature_min,sunrise,sunset,'
        'uv_index_max,precipitation_sum,rain_sum,showers_sum,snowfall_sum,'
        'precipitation_hours,precipitation_probability_max,'
        'wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant'
        '&forecast_days=$days'
        '&timezone=$_timezone';

    return _fetchWeatherData(url, 'daily_forecast');
  }

  Future<Map<String, dynamic>> _geocodeCityTool(Map<String, dynamic> args) async {
    final city = args['city'] as String?;
    if (city == null || city.isEmpty) {
      return {'error': 'City name is required'};
    }

    final url = '$_geocodeUrl/search?name=${Uri.encodeComponent(city)}&count=5&language=en&format=json';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final results = body['results'] as List<dynamic>? ?? [];
        return {
          'query': city,
          'results': results.map((r) {
            final m = r as Map<String, dynamic>;
            return {
              'name': m['name'],
              'country': m['country'],
              'admin1': m['admin1'],
              'latitude': m['latitude'],
              'longitude': m['longitude'],
              'timezone': m['timezone'],
              'population': m['population'],
            };
          }).toList(),
        };
      }
      return {'error': 'Geocoding API returned status ${response.statusCode}'};
    } catch (e) {
      return {'error': 'Geocoding failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _fetchWeatherData(String url, String label) async {
    log.verbose('[Weather MCP] Fetching $label: $url');
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        // Add human-readable weather description from WMO code
        _addWeatherDescriptions(data);

        // Add location context
        data['_location'] = _locationName ?? 'Lat ${data['latitude']}, Lng ${data['longitude']}';

        log.info('[Weather MCP] $label: OK');
        return data;
      }
      log.error('[Weather MCP] $label failed: ${response.statusCode} ${response.body}');
      return {'error': 'API returned status ${response.statusCode}: ${response.body}'};
    } catch (e) {
      log.error('[Weather MCP] $label error: $e');
      return {'error': '$label failed: $e'};
    }
  }

  /// Add human-readable weather descriptions from WMO weather codes.
  void _addWeatherDescriptions(Map<String, dynamic> data) {
    // Current weather
    if (data['current'] is Map) {
      final current = data['current'] as Map<String, dynamic>;
      if (current['weather_code'] != null) {
        current['weather_description'] = _wmoCodeToDescription(current['weather_code'] as int);
      }
    }

    // Hourly weather codes
    if (data['hourly'] is Map) {
      final hourly = data['hourly'] as Map<String, dynamic>;
      if (hourly['weather_code'] is List) {
        hourly['weather_description'] = (hourly['weather_code'] as List).map((code) => _wmoCodeToDescription(code as int)).toList();
      }
    }

    // Daily weather codes
    if (data['daily'] is Map) {
      final daily = data['daily'] as Map<String, dynamic>;
      if (daily['weather_code'] is List) {
        daily['weather_description'] = (daily['weather_code'] as List).map((code) => _wmoCodeToDescription(code as int)).toList();
      }
    }
  }

  /// Convert WMO weather interpretation code to human-readable text.
  /// https://open-meteo.com/en/docs#weather_variables
  static String _wmoCodeToDescription(int code) {
    return switch (code) {
      0 => 'Clear sky',
      1 => 'Mainly clear',
      2 => 'Partly cloudy',
      3 => 'Overcast',
      45 => 'Fog',
      48 => 'Depositing rime fog',
      51 => 'Light drizzle',
      53 => 'Moderate drizzle',
      55 => 'Dense drizzle',
      56 => 'Light freezing drizzle',
      57 => 'Dense freezing drizzle',
      61 => 'Slight rain',
      63 => 'Moderate rain',
      65 => 'Heavy rain',
      66 => 'Light freezing rain',
      67 => 'Heavy freezing rain',
      71 => 'Slight snowfall',
      73 => 'Moderate snowfall',
      75 => 'Heavy snowfall',
      77 => 'Snow grains',
      80 => 'Slight rain showers',
      81 => 'Moderate rain showers',
      82 => 'Violent rain showers',
      85 => 'Slight snow showers',
      86 => 'Heavy snow showers',
      95 => 'Thunderstorm',
      96 => 'Thunderstorm with slight hail',
      99 => 'Thunderstorm with heavy hail',
      _ => 'Unknown ($code)',
    };
  }
}
