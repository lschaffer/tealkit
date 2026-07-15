import 'dart:convert';
import '../models/mcp_models.dart';
import '../utils/server_logger.dart';

/// Converts MCP tool schemas to GBNF (GGML BNF) grammar strings for
/// grammar-constrained decoding ("Safe Tool Call Mode").
///
/// GBNF is the grammar format used by llama.cpp / Ollama to constrain
/// token generation. When a grammar is active, the inference engine
/// only allows tokens that lead to a valid completion of the grammar.
///
/// The generated grammar constrains output to:
/// ```json
/// {"tool_call": {"name": "tool_name", "arguments": {"param1": "value1", ...}}}
/// ```
class GrammarGenerator {
  /// Build a GBNF grammar string that constrains the LLM output to a valid
  /// tool-call JSON object.
  ///
  /// [tools] must be non-empty.
  static String buildToolCallGrammar(List<MCPTool> tools) {
    if (tools.isEmpty) {
      throw ArgumentError('At least one tool is required to build a grammar');
    }

    log.info(
      '[GrammarGenerator] Building GBNF grammar for ${tools.length} tools: ${tools.map((t) => t.name).join(", ")}',
    );

    final buf = StringBuffer();

    // ── Root rule ──────────────────────────────────────────────
    buf.writeln(
      'root ::= "{" ws "\\"tool_call\\"" ws ":" ws "{" ws'
      ' "\\"name\\"" ws ":" ws tool-name ws "," ws'
      ' "\\"arguments\\"" ws ":" ws arguments ws "}" ws "}"',
    );

    // ── Optional whitespace ────────────────────────────────────
    buf.writeln('ws ::= " "?');

    // ── Tool name alternation ──────────────────────────────────
    final toolNames = tools.map((t) => '"\\"${_escapeGbnfString(t.name)}\\""');
    buf.writeln('tool-name ::= ${toolNames.join(" | ")}');

    // ── Argument schemas ───────────────────────────────────────
    final allSchemas = tools
        .map((t) => t.inputSchema)
        .where((s) => s != null)
        .cast<Map<String, dynamic>>()
        .toList();

    if (allSchemas.isEmpty) {
      buf.writeln('arguments ::= "{" ws object-pairs? ws "}"');
      _addJsonObjectGrammar(buf);
    } else if (allSchemas.length == 1) {
      buf.writeln(
        'arguments ::= ${_schemaToGbnf(allSchemas.first, "arguments", 0)}',
      );
    } else {
      buf.writeln('arguments ::= "{" ws object-pairs? ws "}"');
      _addJsonObjectGrammar(buf);
    }

    final grammar = buf.toString();
    log.info('[GrammarGenerator] Generated grammar (${grammar.length} chars)');
    log.debug('[GrammarGenerator] Grammar:\n$grammar');

    return grammar;
  }

  /// Build a simpler grammar for any valid JSON.
  static String buildJsonGrammar() {
    final buf = StringBuffer();
    _addJsonObjectGrammar(buf);
    return buf.toString();
  }

  // ── Private helpers ──────────────────────────────────────────

  static String _schemaToGbnf(
    Map<String, dynamic> schema,
    String ruleName,
    int depth,
  ) {
    if (depth > 8) return _anyValueGbnf();

    final rawType = schema['type'];
    final types = <String>[];
    if (rawType is String) {
      types.add(rawType);
    } else if (rawType is List) {
      types.addAll(rawType.map((e) => e.toString()));
    }

    if (schema.containsKey('enum') && schema['enum'] is List) {
      final enumValues = (schema['enum'] as List)
          .map((v) => _jsonValueToGbnf(v))
          .join(' | ');
      return enumValues;
    }

    if (schema.containsKey('oneOf') && schema['oneOf'] is List) {
      final alternatives = (schema['oneOf'] as List)
          .map(
            (alt) => alt is Map<String, dynamic>
                ? _schemaToGbnf(alt, '${ruleName}_alt', depth + 1)
                : _anyValueGbnf(),
          )
          .toList();
      return '(${alternatives.join(" | ")})';
    }
    if (schema.containsKey('anyOf') && schema['anyOf'] is List) {
      final alternatives = (schema['anyOf'] as List)
          .map(
            (alt) => alt is Map<String, dynamic>
                ? _schemaToGbnf(alt, '${ruleName}_alt', depth + 1)
                : _anyValueGbnf(),
          )
          .toList();
      return '(${alternatives.join(" | ")})';
    }

    if (types.contains('object') ||
        types.isEmpty && schema.containsKey('properties')) {
      return _objectToGbnf(schema, ruleName, depth);
    }
    if (types.contains('array')) return _arrayToGbnf(schema, ruleName, depth);
    if (types.contains('string')) return _stringToGbnf();
    if (types.contains('number') || types.contains('integer')) {
      return types.contains('integer') ? _integerToGbnf() : _numberToGbnf();
    }
    if (types.contains('boolean')) return _booleanToGbnf();
    if (types.contains('null')) return '"null"';

    return _anyValueGbnf();
  }

  static String _objectToGbnf(
    Map<String, dynamic> schema,
    String ruleName,
    int depth,
  ) {
    final properties = schema['properties'];
    if (properties is! Map || properties.isEmpty) {
      return '"{" ws object-pairs? ws "}"';
    }

    final required =
        (schema['required'] as List?)?.map((e) => e.toString()).toSet() ??
        <String>{};
    final propEntries = properties.entries.toList();

    final propGrammars = <String>[];
    for (final entry in propEntries) {
      final key = entry.key.toString();
      final isRequired = required.contains(key);
      final propSchema = entry.value is Map
          ? Map<String, dynamic>.from(entry.value as Map)
          : <String, dynamic>{};
      final propGbnf = _schemaToGbnf(propSchema, '${ruleName}_$key', depth + 1);
      final quotedKey = '"\\"${_escapeGbnfString(key)}\\""';
      final pair = '$quotedKey ws ":" ws $propGbnf';
      propGrammars.add(isRequired ? pair : '($pair)?');
    }

    if (propGrammars.isEmpty) return '"{" ws "}"';
    return '"{" ws ${propGrammars.join(" ws \",\" ws ")} ws "}"';
  }

  static String _arrayToGbnf(
    Map<String, dynamic> schema,
    String ruleName,
    int depth,
  ) {
    final items = schema['items'];
    if (items is Map<String, dynamic>) {
      final itemGbnf = _schemaToGbnf(items, '${ruleName}_item', depth + 1);
      return '"[" ws ($itemGbnf (ws "," ws $itemGbnf)*)? ws "]"';
    }
    return '"[" ws json-values? ws "]"';
  }

  static String _stringToGbnf() => '"\\"" char* "\\""';
  static String _numberToGbnf() =>
      '("-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?)';
  static String _integerToGbnf() => '("-"? ("0" | [1-9] [0-9]*))';
  static String _booleanToGbnf() => '"true" | "false"';
  static String _anyValueGbnf() =>
      '(string-value | number-value | boolean-value | "{" ws object-pairs? ws "}" | "[" ws json-values? ws "]" | "null")';

  static String _jsonValueToGbnf(dynamic value) {
    if (value is String) return '"\\"${_escapeGbnfString(value)}\\""';
    if (value is num) return '"$value"';
    if (value is bool) return value ? '"true"' : '"false"';
    if (value == null) return '"null"';
    return '"\\"${_escapeGbnfString(value.toString())}\\""';
  }

  static String _escapeGbnfString(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }

  static void _addJsonObjectGrammar(StringBuffer buf) {
    buf.writeln(
      'char ::= [^"\\\\] | "\\\\" ("\\\\" | "/" | "\\"" | "b" | "f" | "n" | "r" | "t" | [\\u0000-\\u007F])',
    );
    buf.writeln('string-value ::= "\\"" char* "\\""');
    buf.writeln(
      'number-value ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?',
    );
    buf.writeln('boolean-value ::= "true" | "false"');
    buf.writeln('null-value ::= "null"');
    buf.writeln(
      'value ::= string-value | number-value | boolean-value | "{" ws object-pairs? ws "}" | "[" ws json-values? ws "]" | null-value',
    );
    buf.writeln('object-pairs ::= pair (ws "," ws pair)*');
    buf.writeln('pair ::= string-value ws ":" ws value');
    buf.writeln('json-values ::= value (ws "," ws value)*');
  }

  /// Parse a grammar-constrained tool call response.
  static Map<String, dynamic>? parseSafeToolCallResponse(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
      final toolCall = decoded['tool_call'];
      if (toolCall is! Map) return null;
      final tc = Map<String, dynamic>.from(toolCall);
      final name = (tc['name'] ?? '').toString().trim();
      if (name.isEmpty) return null;
      final arguments = tc['arguments'];
      final args = arguments is Map<String, dynamic>
          ? Map<String, dynamic>.from(arguments)
          : <String, dynamic>{};
      return {'name': name, 'arguments': args};
    } catch (e) {
      log.warning(
        '[GrammarGenerator] Failed to parse safe tool call response: $e',
      );
      return null;
    }
  }
}
