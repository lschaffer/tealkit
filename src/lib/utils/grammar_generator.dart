import 'dart:convert';
import '../models/mcp_models.dart';
import '../services/llm_service.dart' show LLMToolCall;
import 'logger.dart';

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
  /// The grammar structure is:
  /// ```
  /// root ::= "{" ws "\"tool_call\"" ws ":" ws "{" ws "\"name\"" ws ":" ws tool-name ws "," ws "\"arguments\"" ws ":" ws arguments ws "}" ws "}"
  /// tool-name ::= "\"tool_a\"" | "\"tool_b\"" | ...
  /// arguments ::= <per-tool JSON schema in GBNF>
  /// ```
  ///
  /// [tools] must be non-empty. When it contains multiple tools, the grammar
  /// uses alternation for the tool name.
  static String buildToolCallGrammar(List<MCPTool> tools) {
    if (tools.isEmpty) {
      throw ArgumentError('At least one tool is required to build a grammar');
    }

    talker.info(
      '[GrammarGenerator] Building GBNF grammar for ${tools.length} tools: ${tools.map((t) => t.name).join(", ")}',
    );

    final buf = StringBuffer();

    // ── Root rule ──────────────────────────────────────────────
    // Constrains the outermost structure to:
    //   {"tool_call": {"name": "...", "arguments": {...}}}
    buf.writeln(
      'root ::= "{" ws "\\"tool_call\\"" ws ":" ws "{" ws'
      ' "\\"name\\"" ws ":" ws tool-name ws "," ws'
      ' "\\"arguments\\"" ws ":" ws arguments ws "}" ws "}"',
    );

    // ── Optional whitespace ────────────────────────────────────
    buf.writeln('ws ::= " "?');

    // ── Tool name alternation ──────────────────────────────────
    // tool-name ::= "\"tool_a\"" | "\"tool_b\"" | ...
    final toolNames = tools.map((t) => '"\\"${_escapeGbnfString(t.name)}\\""');
    buf.writeln('tool-name ::= ${toolNames.join(" | ")}');

    // ── Combine all argument schemas with alternation ──────────
    // We need to match the correct schema to each tool name.
    // Strategy: use named rules for each tool and alternate at the arguments level.
    // arguments ::= tool-a-args | tool-b-args | ...
    // But GBNF can't backtrack based on the tool name. Instead, we create a
    // single comprehensive grammar that accepts ANY tool's arguments.
    //
    // A simpler and more reliable approach: constrain arguments to any valid
    // JSON object, since the tool name (which is grammar-constrained) tells us
    // which tool was called. We validate argument correctness at execution time.
    final allSchemas = tools
        .map((t) => t.inputSchema)
        .where((s) => s != null)
        .cast<Map<String, dynamic>>()
        .toList();

    if (allSchemas.isEmpty) {
      // No schemas — accept any JSON object as arguments.
      buf.writeln('arguments ::= "{" ws object-pairs? ws "}"');
      _addJsonObjectGrammar(buf);
    } else if (allSchemas.length == 1) {
      // Single tool — embed its exact schema.
      buf.writeln(
        'arguments ::= ${_schemaToGbnf(allSchemas.first, "arguments", 0)}',
      );
    } else {
      // Multiple tools with different schemas — accept any object.
      // A stricter approach would alternate schemas but GBNF lacks
      // name-correlation during generation, so any-object is the
      // pragmatic choice. Tool name validation happens at execution.
      buf.writeln('arguments ::= "{" ws object-pairs? ws "}"');
      _addJsonObjectGrammar(buf);
    }

    final grammar = buf.toString();
    talker.info(
      '[GrammarGenerator] Generated grammar (${grammar.length} chars)',
    );
    talker.debug('[GrammarGenerator] Grammar:\n$grammar');

    return grammar;
  }

  /// Build a simpler grammar for cases where we just need any valid JSON.
  /// Useful as a more lenient fallback when tool schemas are very complex.
  static String buildJsonGrammar() {
    final buf = StringBuffer();
    _addJsonObjectGrammar(buf);
    return buf.toString();
  }

  // ── Private helpers ──────────────────────────────────────────

  /// Convert a JSON Schema map to a GBNF rule string.
  ///
  /// [schema] is a JSON Schema property definition.
  /// [ruleName] is used for naming generated sub-rules.
  /// [depth] prevents infinite recursion on circular schemas.
  static String _schemaToGbnf(
    Map<String, dynamic> schema,
    String ruleName,
    int depth,
  ) {
    if (depth > 8) {
      // Safety limit — fall back to any-value
      return _anyValueGbnf();
    }

    // Get the type(s) — may be a string or a list
    final rawType = schema['type'];
    final types = <String>[];
    if (rawType is String) {
      types.add(rawType);
    } else if (rawType is List) {
      types.addAll(rawType.map((e) => e.toString()));
    }

    // Handle enum first — it takes priority over type
    if (schema.containsKey('enum') && schema['enum'] is List) {
      final enumValues = (schema['enum'] as List)
          .map((v) => _jsonValueToGbnf(v))
          .join(' | ');
      return enumValues;
    }

    // Handle oneOf / anyOf
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

    // Types
    if (types.contains('object') ||
        types.isEmpty && schema.containsKey('properties')) {
      return _objectToGbnf(schema, ruleName, depth);
    }
    if (types.contains('array')) {
      return _arrayToGbnf(schema, ruleName, depth);
    }
    if (types.contains('string')) {
      return _stringToGbnf();
    }
    if (types.contains('number') || types.contains('integer')) {
      return types.contains('integer') ? _integerToGbnf() : _numberToGbnf();
    }
    if (types.contains('boolean')) {
      return _booleanToGbnf();
    }
    if (types.contains('null')) {
      return '"null"';
    }

    // If type is missing or unsupported, accept any value
    return _anyValueGbnf();
  }

  /// Convert an object schema to GBNF.
  static String _objectToGbnf(
    Map<String, dynamic> schema,
    String ruleName,
    int depth,
  ) {
    final properties = schema['properties'];
    if (properties is! Map || properties.isEmpty) {
      // Empty object — allow any JSON object
      return '"{" ws object-pairs? ws "}"';
    }

    final required =
        (schema['required'] as List?)?.map((e) => e.toString()).toSet() ??
        <String>{};
    final propEntries = properties.entries.toList();

    // Generate a GBNF rule for each property
    final propGrammars = <String>[];
    for (final entry in propEntries) {
      final key = entry.key.toString();
      final isRequired = required.contains(key);
      final propSchema = entry.value is Map
          ? Map<String, dynamic>.from(entry.value as Map)
          : <String, dynamic>{};
      final propGbnf = _schemaToGbnf(propSchema, '${ruleName}_$key', depth + 1);

      // Property format: "key": value
      final quotedKey = '"\\"${_escapeGbnfString(key)}\\""';
      final pair = '$quotedKey ws ":" ws $propGbnf';

      if (isRequired) {
        propGrammars.add(pair);
      } else {
        propGrammars.add('($pair)?');
      }
    }

    if (propGrammars.isEmpty) {
      return '"{" ws "}"';
    }

    return '"{" ws ${propGrammars.join(" ws \",\" ws ")} ws "}"';
  }

  /// Convert an array schema to GBNF.
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
    // No items schema or unknown format — accept any JSON array
    return '"[" ws json-values? ws "]"';
  }

  /// GBNF for a JSON string value.
  static String _stringToGbnf() {
    return '"\\"" char* "\\""';
  }

  /// GBNF for a JSON number value.
  static String _numberToGbnf() {
    return '("-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?)';
  }

  /// GBNF for a JSON integer value.
  static String _integerToGbnf() {
    return '("-"? ("0" | [1-9] [0-9]*))';
  }

  /// GBNF for a JSON boolean value.
  static String _booleanToGbnf() {
    return '"true" | "false"';
  }

  /// GBNF that accepts any valid JSON value.
  static String _anyValueGbnf() {
    return '(string-value | number-value | boolean-value | "{" ws object-pairs? ws "}" | "[" ws json-values? ws "]" | "null")';
  }

  /// Convert a Dart value to its GBNF literal representation.
  static String _jsonValueToGbnf(dynamic value) {
    if (value is String) {
      return '"\\"${_escapeGbnfString(value)}\\""';
    }
    if (value is num) {
      return '"$value"';
    }
    if (value is bool) {
      return value ? '"true"' : '"false"';
    }
    if (value == null) {
      return '"null"';
    }
    return '"\\"${_escapeGbnfString(value.toString())}\\""';
  }

  /// Escape special characters for GBNF string literals.
  static String _escapeGbnfString(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }

  /// Add GBNF rules for basic JSON types (string, number, boolean, etc.).
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
  ///
  /// The grammar produces:
  /// ```json
  /// {"tool_call": {"name": "tool_name", "arguments": {...}}}
  /// ```
  ///
  /// Returns the parsed [LLMToolCall] or null if parsing fails.
  static LLMToolCall? parseSafeToolCallResponse(String jsonText) {
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
      return LLMToolCall(name: name, arguments: args);
    } catch (e) {
      talker.warning(
        '[GrammarGenerator] Failed to parse safe tool call response: $e',
      );
      return null;
    }
  }
}
