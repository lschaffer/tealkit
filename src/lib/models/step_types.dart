// Shared types and helpers for sub-prompt chaining.
//
// Kept in `lib/models/` (pure Dart — no Flutter imports) so it can be used
// by services (chat_service.dart) and widgets alike.

// ─── Regex ───────────────────────────────────────────────────────────────────

/// Matches a separator line `++#++` with an optional tool tag and/or stop flag.
///
/// Supported tag formats:
///   (none)             → all tools (backward-compat default)
///   `[N0]`             → no tools (legacy)
///   `[N1]`             → basic tools (legacy, treated as all tools on read)
///   `[N2]`             → all tools (legacy explicit)
///   `[NT:]`            → no tools (empty named list)
///   `[NT:t1|t2|t3]`   → specific named tools (pipe-separated)
///   `[SATC]`           → stop after tool call for this step
///
/// Group 1 = digit (legacy [Ndigit] format)
/// Group 2 = NT content string (new named format, may be empty)
/// Group 3 = `[SATC]` flag string (non-null when present)
/// `multiLine: true` so `^`/`$` match line boundaries.
final RegExp stepSepRegex = RegExp(r'^\+\+#\+\+(?:\[N(\d)\]|\[NT:([^\]]*)\])?(\[SATC\])?\r?$', multiLine: true);

// ─── Entry ───────────────────────────────────────────────────────────────────

/// One step in a sub-prompt chain: plain text + per-step enabled tool names
/// + optional per-step stop-after-tool-call flag.
///
/// * `enabledToolNames == null`  → all tools (default, backward-compat)
/// * `enabledToolNames.isEmpty`  → no tools
/// * `enabledToolNames.isNotEmpty` → only the listed tools are available
/// * `stopAfterToolCall == true`  → halt the LLM loop after the first tool call
///   for this step; execution resumes with the next step immediately.
class Step {
  final String text;

  /// `null` = all tools; `[]` = no tools; non-empty = specific named tools.
  final List<String>? enabledToolNames;

  /// When `true`, the LLM loop stops after the first tool call for this step.
  /// The tool result is NOT sent back to the LLM; the next step starts instead.
  final bool stopAfterToolCall;

  const Step({required this.text, this.enabledToolNames, this.stopAfterToolCall = false});

  bool get isAllTools => enabledToolNames == null;
  bool get isNoTools => enabledToolNames != null && enabledToolNames!.isEmpty;

  // ── Legacy compat ──────────────────────────────────────────────────────────

  /// Derive [enabledToolNames] from a legacy [N{digit}] separator tag.
  ///
  /// * `'0'` → `[]`  (no tools)
  /// * `'1'` → `null` (treat as all tools — cannot reconstruct basic-tool names)
  /// * anything else → `null` (all tools)
  static List<String>? _fromLegacyDigit(String? d) {
    if (d == '0') return const [];
    return null; // '1', '2', or null → all tools
  }

  factory Step.fromLegacyDigit(String text, String? digit, {bool stopAfterToolCall = false}) =>
      Step(text: text, enabledToolNames: _fromLegacyDigit(digit), stopAfterToolCall: stopAfterToolCall);

  factory Step.fromNamedTools(String text, String ntContent, {bool stopAfterToolCall = false}) {
    if (ntContent.isEmpty) return Step(text: text, enabledToolNames: const [], stopAfterToolCall: stopAfterToolCall);
    return Step(
      text: text,
      enabledToolNames: ntContent.split('|').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      stopAfterToolCall: stopAfterToolCall,
    );
  }
}

// ─── Parse ───────────────────────────────────────────────────────────────────

/// Parse a raw prompt string into an ordered list of [Step] objects.
///
/// Rules:
/// * Text before the first separator → step 0, all tools.
/// * Each separator introduces the following step; its optional tag sets the
///   tool list for that step.
/// * Leading/trailing whitespace is trimmed from each step text.
/// * Always returns at least one entry.
List<Step> parseWorkflowSteps(String text) {
  final matches = stepSepRegex.allMatches(text).toList();

  if (matches.isEmpty) {
    return [Step(text: text.trim())];
  }

  final steps = <Step>[];

  // Text before first separator → first step, all tools.
  final beforeFirst = text.substring(0, matches[0].start).trim();
  if (beforeFirst.isNotEmpty) {
    steps.add(Step(text: beforeFirst));
  }

  for (int i = 0; i < matches.length; i++) {
    final m = matches[i];
    final segEnd = i + 1 < matches.length ? matches[i + 1].start : text.length;
    final segText = text.substring(m.end, segEnd).trim();

    final legacyDigit = m.group(1); // group 1 = digit from [Ndigit]
    final ntContent = m.group(2); // group 2 = content from [NT:...]
    final satcFlag = m.group(3); // group 3 = [SATC] flag (non-null when present)
    final satc = satcFlag != null;

    Step step;
    if (ntContent != null) {
      step = Step.fromNamedTools(segText, ntContent, stopAfterToolCall: satc);
    } else {
      step = Step.fromLegacyDigit(segText, legacyDigit, stopAfterToolCall: satc);
    }
    steps.add(step);
  }

  if (steps.isEmpty) steps.add(const Step(text: ''));
  return steps;
}

// ─── Serialize ───────────────────────────────────────────────────────────────

/// Serialise a list of [Step] objects back into a raw prompt string.
///
/// * Single all-tools step with no SATC → plain text (backward-compat).
/// * `enabledToolNames == null` → `++#++` (no tag, all tools)
/// * `enabledToolNames.isEmpty` → `++#++[NT:]`
/// * `enabledToolNames.isNotEmpty` → `++#++[NT:t1|t2|t3]`
/// * `stopAfterToolCall == true` → appends `[SATC]` to the separator tag
String serializeWorkflowSteps(List<Step> steps) {
  if (steps.isEmpty) return '';

  // Single all-tools step with no SATC → plain text (backward-compat).
  if (steps.length == 1 && steps[0].isAllTools && !steps[0].stopAfterToolCall) {
    return steps[0].text;
  }

  String tag(Step s) {
    final nt = s.enabledToolNames == null ? '' : (s.enabledToolNames!.isEmpty ? '[NT:]' : '[NT:${s.enabledToolNames!.join('|')}]');
    final satc = s.stopAfterToolCall ? '[SATC]' : '';
    return '$nt$satc';
  }

  final sb = StringBuffer();
  for (int i = 0; i < steps.length; i++) {
    final s = steps[i];
    final t = tag(s);
    if (i == 0 && t.isEmpty) {
      // Step 0 with no metadata: write plain text (backward-compat).
      sb.write(s.text);
    } else {
      // Step with metadata (NT/SATC) or step 1+: write separator + text.
      if (sb.isNotEmpty) sb.write('\n');
      sb.write('++#++$t');
      sb.write('\n');
      sb.write(s.text);
    }
  }
  return sb.toString();
}

// ─── Legacy shim ─────────────────────────────────────────────────────────────
// Kept so that existing code referencing SubPromptToolMode still compiles.

@Deprecated('Use Step.enabledToolNames instead')
enum SubPromptToolMode {
  allTools,
  basicTools,
  noTools;

  String get separatorTag {
    switch (this) {
      case SubPromptToolMode.noTools:
        return '[NT:]';
      case SubPromptToolMode.basicTools:
        return '';
      case SubPromptToolMode.allTools:
        return '';
    }
  }
}
