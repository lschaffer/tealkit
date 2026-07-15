import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../services/location_service.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server with always-on utility tools.
class ToolboxMcpServer extends InternalMcpServer {
  static const String _geocodeUrl = 'https://geocoding-api.open-meteo.com/v1';

  @override
  String get type => 'toolbox';

  @override
  String get displayName => 'Toolbox';

  @override
  String get description => 'Always-available utility tools for current time, timezone info, current location, and city geocoding.';

  @override
  String get iconName => 'build';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'timezone': {'type': 'string', 'description': 'Default timezone mode: "local" or "utc".', 'default': 'local'},
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'timezone': 'local'};

  @override
  String get defaultSystemPrompt =>
      'Utility tools: use get_current_time for timestamps, get_timezone_info for timezone details, '
      'get_current_location for device/manual coordinates, geocode_city to resolve city names to coordinates. '
      'For arithmetic on LITERAL NUMBERS (sums, averages, percentages, multiplications) use the calculate or sum_numbers tool — '
      'never compute numbers in your head. Only use calculate when the expression contains actual numeric values, '
      'not variable names or identifiers.';

  String _timezoneMode = 'local';
  final LocationService _locationService = LocationService();

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    final mode = (initParams['timezone'] as String? ?? 'local').trim().toLowerCase();
    _timezoneMode = mode == 'utc' ? 'utc' : 'local';
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'get_current_time',
      description: 'Get current date/time with ISO timestamp, unix epoch, timezone name, and UTC offset.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'timezone': {
            'type': 'string',
            'description': 'Optional timezone mode override: "local" or "utc".',
            'enum': ['local', 'utc'],
          },
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'get_timezone_info',
      description: 'Get timezone details for local time or UTC.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'timezone': {
            'type': 'string',
            'description': 'Timezone mode: "local" or "utc".',
            'enum': ['local', 'utc'],
          },
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'get_current_location',
      description: 'Get current/manual location from app location service when available.',
      inputSchema: {'type': 'object', 'properties': {}, 'required': []},
    ),
    const McpToolDescriptor(
      name: 'geocode_city',
      description: 'Resolve a city name to coordinates and timezone metadata.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'city': {'type': 'string', 'description': 'City name (e.g. "Berlin", "New York").'},
          'count': {'type': 'integer', 'description': 'Max results (1-10). Default: 5.', 'default': 5},
        },
        'required': ['city'],
      },
    ),
    const McpToolDescriptor(
      name: 'calculate',
      description:
          'Evaluate a mathematical expression containing LITERAL NUMBERS and return the exact result. '
          'Use this whenever you need to add, subtract, multiply, divide, compute averages, '
          'percentages, or any other arithmetic — do NOT compute in your head. '
          'IMPORTANT: Only pass expressions with actual numeric values (e.g. "1234 + 5678"). '
          'Do NOT use this tool if any part of the expression is a variable name, identifier, '
          'script name, or word (e.g. "cpu_usage", "total", "value") — those are NOT math expressions. '
          'Supported operators/functions: +  -  *  /  %  ^  sqrt()  abs()  round()  floor()  ceil()  log()  sin()  cos()  tan()  pi  e. '
          'Example: "(1234 + 5678) * 0.001" or "sqrt(144)" or "sum([10, 20, 30])".',
      inputSchema: {
        'type': 'object',
        'properties': {
          'expression': {
            'type': 'string',
            'description': 'Mathematical expression to evaluate, e.g. "1234 + 5678" or "(100 - 42) / 100 * 2000".',
          },
        },
        'required': ['expression'],
      },
    ),
    const McpToolDescriptor(
      name: 'sum_numbers',
      description:
          'Sum a list of numbers and optionally compute the average. '
          'Use this to total up token counts, costs, or any list of values extracted from emails or documents.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'numbers': {
            'type': 'array',
            'items': {'type': 'number'},
            'description': 'List of numeric values to sum.',
          },
          'labels': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Optional labels for each number (for the breakdown in the result).',
          },
          'round_decimals': {'type': 'integer', 'description': 'Number of decimal places in the result (default: 4).', 'default': 4},
        },
        'required': ['numbers'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    switch (toolName) {
      case 'get_current_time':
        return _getCurrentTime(arguments);
      case 'get_timezone_info':
        return _getTimezoneInfo(arguments);
      case 'get_current_location':
        return _getCurrentLocation();
      case 'geocode_city':
        return _geocodeCity(arguments);
      case 'calculate':
        return _calculate(arguments);
      case 'sum_numbers':
        return _sumNumbers(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  Map<String, dynamic> _getCurrentTime(Map<String, dynamic> args) {
    final mode = _resolveTimezoneMode(args['timezone'] as String?);
    final now = mode == 'utc' ? DateTime.now().toUtc() : DateTime.now();
    final offset = now.timeZoneOffset;

    return {
      'timezoneMode': mode,
      'iso8601': now.toIso8601String(),
      'epochMs': now.millisecondsSinceEpoch,
      'timezoneName': now.timeZoneName,
      'offsetMinutes': offset.inMinutes,
      'offsetText': _formatOffset(offset),
      'date': now.toIso8601String().split('T').first,
      'time': now.toIso8601String().split('T').last,
    };
  }

  Map<String, dynamic> _getTimezoneInfo(Map<String, dynamic> args) {
    final mode = _resolveTimezoneMode(args['timezone'] as String?);
    final now = mode == 'utc' ? DateTime.now().toUtc() : DateTime.now();
    final offset = now.timeZoneOffset;

    return {
      'timezoneMode': mode,
      'timezoneName': now.timeZoneName,
      'offsetMinutes': offset.inMinutes,
      'offsetText': _formatOffset(offset),
      'nowIso8601': now.toIso8601String(),
      'supportedModes': const ['local', 'utc'],
    };
  }

  Future<Map<String, dynamic>> _getCurrentLocation() async {
    final position = await _locationService.getCurrentLocation();
    final locationText = await _locationService.getLocationString();

    return {
      'available': position != null || (locationText?.isNotEmpty ?? false),
      'locationText': locationText,
      'latitude': position?.latitude,
      'longitude': position?.longitude,
    };
  }

  Future<Map<String, dynamic>> _geocodeCity(Map<String, dynamic> args) async {
    final city = (args['city'] as String?)?.trim();
    if (city == null || city.isEmpty) {
      return {'error': 'Parameter "city" is required.'};
    }

    final count = ((args['count'] as int?) ?? 5).clamp(1, 10);
    final url = '$_geocodeUrl/search?name=${Uri.encodeComponent(city)}&count=$count&language=en&format=json';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        return {'error': 'Geocoding API returned status ${response.statusCode}'};
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final results = (body['results'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

      return {
        'query': city,
        'count': results.length,
        'results': results
            .map(
              (item) => {
                'name': item['name'],
                'country': item['country'],
                'admin1': item['admin1'],
                'latitude': item['latitude'],
                'longitude': item['longitude'],
                'timezone': item['timezone'],
                'population': item['population'],
              },
            )
            .toList(),
      };
    } catch (e) {
      return {'error': 'Geocoding failed: $e'};
    }
  }

  String _resolveTimezoneMode(String? override) {
    final normalized = (override ?? _timezoneMode).trim().toLowerCase();
    return normalized == 'utc' ? 'utc' : 'local';
  }

  String _formatOffset(Duration offset) {
    final sign = offset.isNegative ? '-' : '+';
    final totalMinutes = offset.inMinutes.abs();
    final hours = (totalMinutes ~/ 60).toString().padLeft(2, '0');
    final minutes = (totalMinutes % 60).toString().padLeft(2, '0');
    return '$sign$hours:$minutes';
  }

  // ── calculate ─────────────────────────────────────────────────────────────

  Map<String, dynamic> _calculate(Map<String, dynamic> args) {
    final expr = (args['expression'] as String? ?? '').trim();
    if (expr.isEmpty) return {'error': 'expression is required'};

    try {
      final result = _evalExpr(expr);
      return {'expression': expr, 'result': result, 'resultText': result % 1 == 0 ? result.toStringAsFixed(0) : result.toString()};
    } catch (e) {
      return {'error': 'Cannot evaluate "$expr": $e'};
    }
  }

  Map<String, dynamic> _sumNumbers(Map<String, dynamic> args) {
    final rawList = args['numbers'];
    if (rawList == null) return {'error': '"numbers" is required'};
    final numbers = (rawList as List<dynamic>).map((v) => (v as num).toDouble()).toList();
    if (numbers.isEmpty) return {'sum': 0.0, 'count': 0, 'average': null, 'breakdown': []};

    final labels = (args['labels'] as List<dynamic>?)?.map((v) => v.toString()).toList();
    final decimals = ((args['round_decimals'] as int?) ?? 4).clamp(0, 10);

    final sum = numbers.fold(0.0, (acc, n) => acc + n);
    final avg = sum / numbers.length;

    double r(double v) => double.parse(v.toStringAsFixed(decimals));

    final breakdown = <Map<String, dynamic>>[
      for (var i = 0; i < numbers.length; i++) {if (labels != null && i < labels.length) 'label': labels[i], 'value': numbers[i]},
    ];

    return {
      'sum': r(sum),
      'count': numbers.length,
      'average': r(avg),
      'min': numbers.reduce(math.min),
      'max': numbers.reduce(math.max),
      'breakdown': breakdown,
    };
  }

  // ── Minimal safe expression evaluator ────────────────────────────────────
  //
  // Supports: +  -  *  /  %  ^  unary -  parentheses
  // Functions: sqrt abs round floor ceil log sin cos tan
  // Constants: pi  e
  // sum([...]) — shorthand for summing a literal list
  //
  // Security: only numeric literals, operators, whitespace, and the
  // whitelisted function/constant names are allowed.  Any other identifier
  // character causes an immediate error so arbitrary Dart code cannot run.

  static final RegExp _safeChars = RegExp(r'^[\d\s\+\-\*\/\%\^\(\)\.\,\[\]a-zA-Z_]+$');

  static final RegExp _badIdent = RegExp(r'\b(?!sqrt|abs|round|floor|ceil|log|sin|cos|tan|sum|pi|e\b)[a-zA-Z_][a-zA-Z_0-9]*');

  double _evalExpr(String expr) {
    // Security guard — reject any unexpected identifier
    if (!_safeChars.hasMatch(expr)) throw ArgumentError('Unsupported characters in expression');
    if (_badIdent.hasMatch(expr)) throw ArgumentError('Unsupported identifier in expression');

    // Replace named constants
    var e2 = expr.replaceAll('pi', math.pi.toString()).replaceAll(RegExp(r'\be\b'), math.e.toString());

    // Expand sum([...]) shorthand → (n1+n2+...)
    e2 = e2.replaceAllMapped(RegExp(r'sum\(\[([^\]]+)\]\)'), (m) {
      final nums = m.group(1)!.split(',').map((s) => s.trim()).join('+');
      return '($nums)';
    });

    return _parseExpr(e2.replaceAll(' ', ''), _Cursor());
  }

  double _parseExpr(String s, _Cursor c) => _parseAddSub(s, c);

  double _parseAddSub(String s, _Cursor c) {
    var left = _parseMulDiv(s, c);
    while (c.pos < s.length && (s[c.pos] == '+' || s[c.pos] == '-')) {
      final op = s[c.pos++];
      final right = _parseMulDiv(s, c);
      left = op == '+' ? left + right : left - right;
    }
    return left;
  }

  double _parseMulDiv(String s, _Cursor c) {
    var left = _parsePow(s, c);
    while (c.pos < s.length && (s[c.pos] == '*' || s[c.pos] == '/' || s[c.pos] == '%')) {
      final op = s[c.pos++];
      final right = _parsePow(s, c);
      if (op == '*') {
        left = left * right;
      } else if (op == '/') {
        left = left / right;
      } else {
        left = left % right;
      }
    }
    return left;
  }

  double _parsePow(String s, _Cursor c) {
    final base = _parseUnary(s, c);
    if (c.pos < s.length && s[c.pos] == '^') {
      c.pos++;
      return math.pow(base, _parseUnary(s, c)).toDouble();
    }
    return base;
  }

  double _parseUnary(String s, _Cursor c) {
    if (c.pos < s.length && s[c.pos] == '-') {
      c.pos++;
      return -_parsePrimary(s, c);
    }
    if (c.pos < s.length && s[c.pos] == '+') {
      c.pos++;
    }
    return _parsePrimary(s, c);
  }

  double _parsePrimary(String s, _Cursor c) {
    if (c.pos < s.length && s[c.pos] == '(') {
      c.pos++; // consume '('
      final val = _parseExpr(s, c);
      if (c.pos < s.length && s[c.pos] == ')') c.pos++;
      return val;
    }
    // function call: name(...)
    final fnMatch = RegExp(r'^(sqrt|abs|round|floor|ceil|log|sin|cos|tan)\(').firstMatch(s.substring(c.pos));
    if (fnMatch != null) {
      c.pos += fnMatch.group(0)!.length;
      final arg = _parseExpr(s, c);
      if (c.pos < s.length && s[c.pos] == ')') c.pos++;
      return switch (fnMatch.group(1)!) {
        'sqrt' => math.sqrt(arg),
        'abs' => arg.abs(),
        'round' => arg.roundToDouble(),
        'floor' => arg.floorToDouble(),
        'ceil' => arg.ceilToDouble(),
        'log' => math.log(arg),
        'sin' => math.sin(arg),
        'cos' => math.cos(arg),
        'tan' => math.tan(arg),
        _ => throw ArgumentError('Unknown function'),
      };
    }
    // number literal
    final numMatch = RegExp(r'^\d+(\.\d+)?').firstMatch(s.substring(c.pos));
    if (numMatch != null) {
      c.pos += numMatch.group(0)!.length;
      return double.parse(numMatch.group(0)!);
    }
    throw ArgumentError('Unexpected token at position ${c.pos}: "${s.substring(c.pos)}"');
  }
}

/// Mutable position cursor used by the recursive-descent expression parser.
class _Cursor {
  int pos = 0;
}
