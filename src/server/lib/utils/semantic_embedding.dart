import 'dart:convert';
import 'dart:math' as math;

/// Lightweight, local embedding helper for semantic ranking.
///
/// Pure-Dart copy of the Flutter app's SemanticEmbedding — no Flutter deps.
/// Builds a deterministic normalized vector by hashing tokens and character
/// trigrams into a fixed-dimensional space.
class SemanticEmbedding {
  static const int defaultDimensions = 256;

  static final Set<String> _stopWords = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'by',
    'for',
    'from',
    'has',
    'he',
    'in',
    'is',
    'it',
    'its',
    'of',
    'on',
    'or',
    'that',
    'the',
    'to',
    'was',
    'were',
    'will',
    'with',
    'this',
    'these',
    'those',
    'your',
    'you',
    'ich',
    'du',
    'der',
    'die',
    'das',
    'und',
    'ist',
    'mit',
    'ein',
    'eine',
  };

  static final Map<String, String> _normalizations = {
    'emails': 'email',
    'mails': 'email',
    'mailing': 'mail',
    'documents': 'document',
    'files': 'file',
    'searching': 'search',
    'searched': 'search',
    'forecasting': 'forecast',
    'summaries': 'summary',
  };

  static List<double> buildEmbedding(String text, {int dimensions = defaultDimensions}) {
    final tokens = _tokenize(text);
    if (tokens.isEmpty) return List<double>.filled(dimensions, 0);

    final vector = List<double>.filled(dimensions, 0);
    final tf = <String, int>{};
    for (final token in tokens) {
      tf[token] = (tf[token] ?? 0) + 1;
    }

    for (final entry in tf.entries) {
      final token = entry.key;
      final freq = entry.value;
      final weight = 1.0 + math.log(freq.toDouble());

      final idx = _fnv1a(token) % dimensions;
      vector[idx] += weight;

      for (final tri in _charTrigrams(token)) {
        final triIdx = _fnv1a('tri:$tri') % dimensions;
        vector[triIdx] += 0.35 * weight;
      }
    }

    _normalize(vector);
    return vector;
  }

  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;
    double dot = 0, normA = 0, normB = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  static double keywordOverlapScore(String query, String document) {
    final q = _tokenize(query).toSet();
    final d = _tokenize(document).toSet();
    if (q.isEmpty || d.isEmpty) return 0;
    return q.where(d.contains).length / q.length;
  }

  static String toJson(List<double> vector) => jsonEncode(vector);

  static List<double> fromJson(String? json, {int dimensions = defaultDimensions}) {
    if (json == null || json.isEmpty) return List<double>.filled(dimensions, 0);
    try {
      final parsed = jsonDecode(json) as List<dynamic>;
      final values = parsed.map((e) => (e as num).toDouble()).toList();
      if (values.length == dimensions) return values;
      if (values.length > dimensions) return values.sublist(0, dimensions);
      return [...values, ...List<double>.filled(dimensions - values.length, 0)];
    } catch (_) {
      return List<double>.filled(dimensions, 0);
    }
  }

  static List<String> _tokenize(String text) {
    final cleaned = text.toLowerCase().replaceAll(RegExp(r'[^\w\s]+'), ' ');
    final parts = cleaned.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    final tokens = <String>[];
    for (var token in parts) {
      token = _normalizations[token] ?? token;
      if (token.length < 2 || _stopWords.contains(token)) continue;
      tokens.add(token);
    }
    return tokens;
  }

  static List<String> _charTrigrams(String token) {
    if (token.length < 3) return [token];
    final grams = <String>[];
    for (var i = 0; i <= token.length - 3; i++) {
      grams.add(token.substring(i, i + 3));
    }
    return grams;
  }

  static int _fnv1a(String input) {
    const prime = 0x01000193;
    var hash = 0x811C9DC5;
    for (final code in input.codeUnits) {
      hash ^= code;
      hash = (hash * prime) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }

  static void _normalize(List<double> vector) {
    double norm = 0;
    for (final v in vector) {
      norm += v * v;
    }
    norm = math.sqrt(norm);
    if (norm == 0) return;
    for (var i = 0; i < vector.length; i++) {
      vector[i] = vector[i] / norm;
    }
  }
}
