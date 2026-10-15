import 'dart:io';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' hide Step;

import '../config/app_theme.dart';
import '../models/mcp_models.dart';
import '../models/step_types.dart';
import '../services/app_preferences_service.dart';
import '../services/desktop_clipboard_service.dart';

export '../models/step_types.dart' show Step, parseWorkflowSteps, serializeWorkflowSteps, stepSepRegex;

// --- ToolGroup ---

class ToolGroup {
  final String name;
  final List<String> toolNames;
  const ToolGroup({required this.name, required this.toolNames});

  @override
  bool operator ==(Object other) => other is ToolGroup && other.name == name && listEquals(other.toolNames, toolNames);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(toolNames));
}

// ------ Mutable entry (widget-layer only) ----------------------------------------------------------------------------

/// Mutable view-model for one step in a [StepListEditor].
///
/// [enabledToolNames]:
///   * `null`      -> all tools (default)
///   * `[]`        -> no tools
///   * `[...]`     -> only the listed tools
class SubPromptEntry {
  final TextEditingController controller;

  /// `null` = all tools; `[]` = no tools; non-empty = specific tools.
  List<String>? enabledToolNames;

  /// When `true`, halt the LLM loop after the first tool call for this step;
  /// the tool result is NOT sent back to the LLM and the next step starts.
  bool stopAfterToolCall;

  SubPromptEntry({String text = '', this.enabledToolNames, this.stopAfterToolCall = false})
    : controller = TextEditingController(text: text);

  factory SubPromptEntry.fromStep(Step s) => SubPromptEntry(
    text: s.text,
    enabledToolNames: s.enabledToolNames != null ? List<String>.from(s.enabledToolNames!) : null,
    stopAfterToolCall: s.stopAfterToolCall,
  );

  Step toStep() => Step(
    text: controller.text,
    enabledToolNames: enabledToolNames != null ? List<String>.unmodifiable(enabledToolNames!) : null,
    stopAfterToolCall: stopAfterToolCall,
  );

  void dispose() => controller.dispose();
}

// ------ Widget ------------------------------------------------------------------------------------------------------------------------------------

/// A multi-step prompt editor where each step has its own text area and an
/// optional per-step tool selector.
///
/// Pass [availableToolNames] to enable per-step tool selection. Each step
/// shows a checklist icon; tapping it opens a checklist of the available
/// tools so the user can enable/disable individual tools for that step.
///
/// Works as a drop-in replacement for a plain `TextField` backed by a
/// [TextEditingController].
class StepListEditor extends StatefulWidget {
  const StepListEditor({
    super.key,
    required this.controller,
    this.chatMode = false,
    this.availableToolGroups = const [],
    this.minLines = 2,
    this.maxLines = 8,
    this.hintText,
    this.validator,
    this.onToolSelectionChanged,
    this.leading,
    this.trailing,
    this.onAttachmentsPasted,
    this.isCodingMode = false,
  });

  final TextEditingController controller;
  final bool chatMode;
  final bool isCodingMode;

  /// Tool groups (one per MCP server) currently selected in the global tool
  /// settings. When non-empty, each step shows a per-group checklist button.
  final List<ToolGroup> availableToolGroups;

  final int minLines;
  final int maxLines;
  final String? hintText;

  /// Optional validator called with the full serialised text (for use inside
  /// a [Form]).
  final String? Function(String?)? validator;

  /// Called whenever the user changes per-step tool selections.
  final VoidCallback? onToolSelectionChanged;

  final Widget? leading;
  final Widget? trailing;

  /// Called when an image or file is pasted from clipboard into a step's textfield
  final ValueChanged<List<MessageAttachment>>? onAttachmentsPasted;

  @override
  State<StepListEditor> createState() => _SubPromptListEditorState();
}

class _SubPromptListEditorState extends State<StepListEditor> {
  late List<SubPromptEntry> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _parse(widget.controller.text);
    widget.controller.addListener(_onExternalWrite);
    for (final e in _entries) {
      e.controller.addListener(_onEntryChanged);
    }
  }

  @override
  void didUpdateWidget(StepListEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onExternalWrite);
      widget.controller.addListener(_onExternalWrite);
      _rebuildFromController();
    }
    // Sync when the global tool groups change.
    if (!listEquals(old.availableToolGroups, widget.availableToolGroups)) {
      // If the controller text is also out of sync, a full session load is
      // in progress: re-parse entries from the new text instead of syncing.
      // Syncing on stale entries would corrupt per-step tool selections.
      if (widget.controller.text != _serialize()) {
        _rebuildFromController();
      } else {
        _syncToolGroupsToNewList(widget.availableToolGroups);
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onExternalWrite);
    for (final e in _entries) {
      e.controller.removeListener(_onEntryChanged);
      e.dispose();
    }
    super.dispose();
  }

  // ---- Parse / serialise ----

  List<SubPromptEntry> _parse(String text) => parseWorkflowSteps(text).map(SubPromptEntry.fromStep).toList();

  String _serialize() => serializeWorkflowSteps(_entries.map((e) => e.toStep()).toList());

  // ---- Sync outer tool list ----

  void _syncToolGroupsToNewList(List<ToolGroup> newGroups) {
    // If any of the available groups is currently empty (connecting/loading/discovering),
    // do NOT remove any tools from the enabled list yet. Otherwise, we would
    // wipe out the saved selection before the server's tools are discovered!
    if (newGroups.any((g) => g.toolNames.isEmpty)) {
      return;
    }
    final newAllNames = {for (final g in newGroups) ...g.toolNames};
    bool changed = false;
    for (final entry in _entries) {
      if (entry.enabledToolNames == null) continue;
      final before = entry.enabledToolNames!.length;
      // Only remove tools that no longer exist in available groups.
      // Never auto-add: if a new server appears, each step's explicit
      // selection should stay as-is — the user opts in per step.
      entry.enabledToolNames!.removeWhere((t) => !newAllNames.contains(t));
      if (entry.enabledToolNames!.length != before) changed = true;
    }
    if (changed) {
      setState(() {});
      _onEntryChanged();
    }
  }

  // ---- Sync with outer controller ----

  bool _suppressExternalWrite = false;

  void _onEntryChanged() {
    _suppressExternalWrite = true;
    widget.controller.text = _serialize();
    _suppressExternalWrite = false;
  }

  void _onExternalWrite() {
    if (_suppressExternalWrite) return;
    _rebuildFromController();
  }

  void _rebuildFromController() {
    final newText = widget.controller.text;
    if (newText == _serialize()) return;
    setState(() {
      for (final e in _entries) {
        e.controller.removeListener(_onEntryChanged);
        e.dispose();
      }
      _entries = _parse(newText);
      for (final e in _entries) {
        e.controller.addListener(_onEntryChanged);
      }
    });
  }

  // ---- Entry management ----

  void _addEntryAfter(int index) {
    setState(() {
      final e = SubPromptEntry(
        // New step: default to all tools (null) and no per-step SATC.
        enabledToolNames: null,
        stopAfterToolCall: false,
      );
      e.controller.addListener(_onEntryChanged);
      _entries.insert(index + 1, e);
      _onEntryChanged();
    });
  }

  void _removeEntry(int index) {
    if (_entries.length <= 1) return;
    setState(() {
      _entries[index].controller.removeListener(_onEntryChanged);
      _entries[index].dispose();
      _entries.removeAt(index);
      _onEntryChanged();
    });
  }

  void _setEnabledTools(int index, List<String>? names) {
    setState(() {
      _entries[index].enabledToolNames = names;
      _onEntryChanged();
    });
    widget.onToolSelectionChanged?.call();
  }

  void _setStopAfterToolCall(int index, bool value) {
    setState(() {
      _entries[index].stopAfterToolCall = value;
      _onEntryChanged();
    });
  }

  Widget _buildStepTextField(
    BuildContext context,
    SubPromptEntry entry,
    int index,
    InputDecoration decoration,
  ) {
    final theme = Theme.of(context);
    final textField = TextField(
      controller: entry.controller,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      style: TextStyle(
        color: theme.brightness == Brightness.dark ? Colors.white : Colors.black87,
        fontSize: 14,
      ),
      decoration: decoration,
      contentInsertionConfiguration: ContentInsertionConfiguration(
        onContentInserted: (KeyboardInsertedContent data) async {
          if (data.data != null && widget.onAttachmentsPasted != null) {
            final mime = data.mimeType;
            final isImg = mime.startsWith('image/');
            final ext = mime.split('/').last;
            final att = MessageAttachment(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              type: isImg ? AttachmentType.image : AttachmentType.file,
              path: 'clipboard_insert',
              name: 'pasted_media.$ext',
              size: data.data!.length,
              mimeType: mime,
              bytes: data.data,
            );
            widget.onAttachmentsPasted!([att]);
          }
        },
        allowedMimeTypes: const ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
            _handlePaste(entry.controller),
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
            _handlePaste(entry.controller),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          PasteTextIntent: CallbackAction<PasteTextIntent>(
            onInvoke: (intent) {
              _handlePaste(entry.controller);
              return null;
            },
          ),
        },
        child: textField,
      ),
    );
  }

  Future<void> _handlePaste(TextEditingController controller) async {
    // 1. First check desktop clipboard for images/files if on desktop platform
    if (widget.onAttachmentsPasted != null && DesktopClipboardService.isDesktop) {
      final attachments = await DesktopClipboardService.getClipboardAttachments();
      if (attachments.isNotEmpty) {
        widget.onAttachmentsPasted!(attachments);
        return;
      }
    }

    // 2. Otherwise get plain text
    final clipData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipData?.text;

    if (text != null && text.isNotEmpty) {
      // Check if text is a single-line path to an existing local file
      final trimmed = text.trim().replaceAll('"', '');
      if (trimmed.length < 500 &&
          (trimmed.startsWith('/') ||
              (trimmed.length > 2 && trimmed[1] == ':'))) {
        final f = File(trimmed);
        if (f.existsSync() && widget.onAttachmentsPasted != null) {
          final att = await DesktopClipboardService.createAttachmentFromFile(trimmed);
          if (att != null) {
            widget.onAttachmentsPasted!([att]);
            return;
          }
        }
      }

      // Normal text paste (handling inverted selection safely)
      final sel = controller.selection;
      if (!sel.isValid || sel.start < 0) {
        controller.text = controller.text + text;
        controller.selection = TextSelection.collapsed(offset: controller.text.length);
      } else {
        final start = sel.start < sel.end ? sel.start : sel.end;
        final end = sel.start < sel.end ? sel.end : sel.start;
        final old = controller.text;
        final newText = old.replaceRange(start, end, text);
        controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: start + text.length),
        );
      }
    }
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (int i = 0; i < _entries.length; i++) _buildRow(context, i)],
    );
  }

  Widget _buildRow(BuildContext context, int index) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final entry = _entries[index];
    final theme = Theme.of(context);
    final hasTools = widget.availableToolGroups.isNotEmpty;
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';

    if (isModern) {
      return Padding(
        padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (index > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(child: Divider(color: theme.dividerColor, height: 1)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text('Step ${index + 1}', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
                    ),
                    Expanded(child: Divider(color: theme.dividerColor, height: 1)),
                  ],
                ),
              ),
            Container(
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? Colors.white.withValues(alpha: 0.04)
                    : Colors.black.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(isMobile ? 16 : 28),
                border: Border.all(
                  color: theme.brightness == Brightness.dark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.08),
                  width: 1,
                ),
              ),
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: isMobile ? 8 : 4),
              child: isMobile
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            if (index == 0 && widget.leading != null) ...[
                              widget.leading!,
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: _buildStepTextField(
                                context,
                                entry,
                                index,
                                InputDecoration(
                                  hintText: index == 0
                                      ? (widget.hintText ?? 'Message AI Playground...')
                                      : 'Continue...  use \${tool_result} to inject prior step output',
                                  hintStyle: TextStyle(
                                    color: theme.brightness == Brightness.dark ? Colors.white38 : Colors.black38,
                                    fontSize: 14,
                                  ),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  disabledBorder: InputBorder.none,
                                  focusedErrorBorder: InputBorder.none,
                                  errorBorder: InputBorder.none,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 12, thickness: 0.5),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (!widget.chatMode && hasTools)
                              _ToolsChecklistButton(
                                entry: entry,
                                stepIndex: index,
                                availableToolGroups: widget.availableToolGroups,
                                isMobile: isMobile,
                                onChanged: (names) => _setEnabledTools(index, names),
                              ),
                            if (!widget.chatMode && !widget.isCodingMode)
                              _StopAfterToolCallBtn(
                                active: entry.stopAfterToolCall,
                                onToggle: () => _setStopAfterToolCall(index, !entry.stopAfterToolCall),
                              ),
                            if (!widget.isCodingMode) ...[
                              const SizedBox(width: 8),
                              _IconBtn(
                                icon: Icons.add_circle_outline,
                                color: AppTheme.primaryBlue,
                                tooltip: 'Add step after this one',
                                onPressed: () => _addEntryAfter(index),
                              ),
                            ],
                            if (_entries.length > 1)
                              _IconBtn(
                                icon: Icons.remove_circle_outline,
                                color: theme.colorScheme.error,
                                tooltip: 'Remove this step',
                                onPressed: () => _removeEntry(index),
                              ),
                            if (index == 0 && widget.trailing != null) ...[
                              const SizedBox(width: 8),
                              widget.trailing!,
                            ],
                          ],
                        ),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (index == 0 && widget.leading != null) ...[
                          widget.leading!,
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: _buildStepTextField(
                            context,
                            entry,
                            index,
                            InputDecoration(
                              hintText: index == 0
                                  ? (widget.hintText ?? 'Message AI Playground...')
                                  : 'Continue...  use \${tool_result} to inject prior step output',
                              hintStyle: TextStyle(
                                color: theme.brightness == Brightness.dark ? Colors.white38 : Colors.black38,
                                fontSize: 14,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              focusedErrorBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!widget.chatMode && hasTools)
                              _ToolsChecklistButton(
                                entry: entry,
                                stepIndex: index,
                                availableToolGroups: widget.availableToolGroups,
                                isMobile: isMobile,
                                onChanged: (names) => _setEnabledTools(index, names),
                              ),
                            if (!widget.chatMode && !widget.isCodingMode)
                              _StopAfterToolCallBtn(
                                active: entry.stopAfterToolCall,
                                onToggle: () => _setStopAfterToolCall(index, !entry.stopAfterToolCall),
                              ),
                            if (!widget.isCodingMode)
                              _IconBtn(
                                icon: Icons.add_circle_outline,
                                color: AppTheme.primaryBlue,
                                tooltip: 'Add step after this one',
                                onPressed: () => _addEntryAfter(index),
                              ),
                            if (_entries.length > 1)
                              _IconBtn(
                                icon: Icons.remove_circle_outline,
                                color: theme.colorScheme.error,
                                tooltip: 'Remove this step',
                                onPressed: () => _removeEntry(index),
                              ),
                            if (index == 0 && widget.trailing != null) ...[
                              const SizedBox(width: 8),
                              widget.trailing!,
                            ],
                          ],
                        ),
                      ],
                    ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (index > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(child: Divider(color: theme.dividerColor, height: 1)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('Step ${index + 1}', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
                  ),
                  Expanded(child: Divider(color: theme.dividerColor, height: 1)),
                ],
              ),
            ),
          if (isMobile) ...[
            _buildStepTextField(
              context,
              entry,
              index,
              InputDecoration(
                hintText: index == 0
                    ? (widget.hintText ?? 'Enter your prompt...')
                    : 'Continue...  use \${tool_result} to inject prior step output',
                hintStyle: TextStyle(
                  color: isModern
                      ? (theme.brightness == Brightness.dark ? Colors.white38 : Colors.black38)
                      : null,
                ),
                filled: isModern,
                fillColor: isModern
                    ? (theme.brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 0.04)
                        : Colors.black.withValues(alpha: 0.03))
                    : null,
                border: isModern
                    ? OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: theme.brightness == Brightness.dark ? Colors.white12 : Colors.black12,
                        ),
                      )
                    : const OutlineInputBorder(),
                enabledBorder: isModern
                    ? OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: theme.brightness == Brightness.dark ? Colors.white10 : Colors.black12,
                        ),
                      )
                    : null,
                focusedBorder: isModern
                    ? OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: theme.brightness == Brightness.dark
                              ? const Color(0xFF06B6D4) // Cyan
                              : const Color(0xFF7C3AED), // Violet
                          width: 1.5,
                        ),
                      )
                    : null,
                isDense: true,
                contentPadding: isModern
                    ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
                    : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!widget.chatMode && hasTools)
                  _ToolsChecklistButton(
                    entry: entry,
                    stepIndex: index,
                    availableToolGroups: widget.availableToolGroups,
                    isMobile: isMobile,
                    onChanged: (names) => _setEnabledTools(index, names),
                  ),
                if (!widget.chatMode && !widget.isCodingMode)
                  _StopAfterToolCallBtn(
                    active: entry.stopAfterToolCall,
                    onToggle: () => _setStopAfterToolCall(index, !entry.stopAfterToolCall),
                  ),
                if (!widget.isCodingMode) ...[
                  const SizedBox(width: 8),
                  _IconBtn(
                    icon: Icons.add_circle_outline,
                    color: AppTheme.primaryBlue,
                    tooltip: 'Add step after this one',
                    onPressed: () => _addEntryAfter(index),
                  ),
                ],
                if (_entries.length > 1)
                  _IconBtn(
                    icon: Icons.remove_circle_outline,
                    color: theme.colorScheme.error,
                    tooltip: 'Remove this step',
                    onPressed: () => _removeEntry(index),
                  ),
              ],
            ),
          ] else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildStepTextField(
                    context,
                    entry,
                    index,
                    InputDecoration(
                      hintText: index == 0
                          ? (widget.hintText ?? 'Enter your prompt...')
                          : 'Continue...  use \${tool_result} to inject prior step output',
                      hintStyle: TextStyle(
                        color: isModern
                            ? (theme.brightness == Brightness.dark ? Colors.white38 : Colors.black38)
                            : null,
                      ),
                      filled: isModern,
                      fillColor: isModern
                          ? (theme.brightness == Brightness.dark
                              ? Colors.white.withValues(alpha: 0.04)
                              : Colors.black.withValues(alpha: 0.03))
                          : null,
                      border: isModern
                          ? OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(
                                color: theme.brightness == Brightness.dark ? Colors.white12 : Colors.black12,
                              ),
                            )
                          : const OutlineInputBorder(),
                      enabledBorder: isModern
                          ? OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(
                                color: theme.brightness == Brightness.dark ? Colors.white10 : Colors.black12,
                              ),
                            )
                          : null,
                      focusedBorder: isModern
                          ? OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(
                                color: theme.brightness == Brightness.dark
                                    ? const Color(0xFF06B6D4) // Cyan
                                    : const Color(0xFF7C3AED), // Violet
                                width: 1.5,
                              ),
                            )
                          : null,
                      isDense: true,
                      contentPadding: isModern
                          ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
                          : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!widget.chatMode && hasTools)
                        _ToolsChecklistButton(
                          entry: entry,
                          stepIndex: index,
                          availableToolGroups: widget.availableToolGroups,
                          isMobile: isMobile,
                          onChanged: (names) => _setEnabledTools(index, names),
                        ),
                      if (!widget.chatMode && !widget.isCodingMode)
                        _StopAfterToolCallBtn(
                          active: entry.stopAfterToolCall,
                          onToggle: () => _setStopAfterToolCall(index, !entry.stopAfterToolCall),
                        ),
                      if (!widget.isCodingMode) ...[
                        const SizedBox(height: 4),
                        _IconBtn(
                          icon: Icons.add_circle_outline,
                          color: AppTheme.primaryBlue,
                          tooltip: 'Add step after this one',
                          onPressed: () => _addEntryAfter(index),
                        ),
                      ],
                      if (_entries.length > 1)
                        _IconBtn(
                          icon: Icons.remove_circle_outline,
                          color: theme.colorScheme.error,
                          tooltip: 'Remove this step',
                          onPressed: () => _removeEntry(index),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ------ Private sub-widgets ----------------------------------------------------------------------------------------------------------

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.color, required this.tooltip, required this.onPressed});

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 20, color: color),
      ),
    ),
  );
}

// --- Per-step stop-after-tool-call toggle button -----------------------------

class _StopAfterToolCallBtn extends StatelessWidget {
  const _StopAfterToolCallBtn({required this.active, required this.onToggle});

  final bool active;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: active
          ? 'Stop after tool call: ON\nResult not sent to LLM — next step starts immediately'
          : 'Stop after tool call: OFF for this step\nTap to stop LLM loop after first tool call',
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(active ? Icons.flag : Icons.flag_outlined, size: 18, color: active ? Colors.orange : Colors.grey),
        ),
      ),
    );
  }
}

// --- Per-step tool checklist button -------------------------------------------

class _ToolsChecklistButton extends StatelessWidget {
  const _ToolsChecklistButton({
    required this.entry,
    required this.stepIndex,
    required this.availableToolGroups,
    required this.isMobile,
    required this.onChanged,
  });

  final SubPromptEntry entry;
  final int stepIndex;
  final List<ToolGroup> availableToolGroups;
  final bool isMobile;
  final ValueChanged<List<String>?> onChanged;

  /// Returns the set of currently-enabled individual tool names.
  Set<String> _enabledToolNamesSet() {
    if (entry.enabledToolNames == null) {
      return {for (final g in availableToolGroups) ...g.toolNames};
    }
    return entry.enabledToolNames!.toSet();
  }

  int get _totalToolCount => availableToolGroups.fold(0, (s, g) => s + g.toolNames.length);

  (IconData, Color) _iconState() {
    if (entry.enabledToolNames == null) return (Icons.build_rounded, AppTheme.primaryBlue);
    if (entry.enabledToolNames!.isEmpty) return (Icons.block_outlined, Colors.grey);
    if (entry.enabledToolNames!.length == _totalToolCount) return (Icons.build_rounded, AppTheme.primaryBlue);
    return (Icons.rule, Colors.orange);
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _iconState();
    final enabledCount = entry.enabledToolNames?.length ?? _totalToolCount;
    final tooltip = 'Tools: $enabledCount/$_totalToolCount';
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => isMobile ? _showMobileSheet(context) : _showDesktopDialog(context),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }

  Future<void> _showMobileSheet(BuildContext context) async {
    final theme = Theme.of(context);
    var current = _enabledToolNamesSet();
    final allToolNames = {for (final g in availableToolGroups) ...g.toolNames};

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        minChildSize: 0.3,
        builder: (ctx2, scrollCtrl) => StatefulBuilder(
          builder: (ctx3, setSheetState) {
            final allSelected = current.length == allToolNames.length;
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.build_rounded, size: 16, color: AppTheme.primaryBlue),
                        const SizedBox(width: 8),
                        Expanded(child: Text('Tools -- Step ${stepIndex + 1}', style: theme.textTheme.titleSmall)),
                      ],
                    ),
                  ),
                  const Divider(height: 16),
                  Flexible(
                    child: ListView(
                      controller: scrollCtrl,
                      shrinkWrap: true,
                      children: [
                        for (final group in availableToolGroups) ...[
                          // Group header row with select-all toggle for this group
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    group.name.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.grey[600],
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => setSheetState(() {
                                    final groupSet = group.toolNames.toSet();
                                    if (groupSet.every(current.contains)) {
                                      current = current.difference(groupSet);
                                    } else {
                                      current = current.union(groupSet);
                                    }
                                  }),
                                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(40, 28)),
                                  child: Text(
                                    group.toolNames.every(current.contains) ? 'None' : 'All',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (group.toolNames.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
                              child: Text(
                                '(connecting…)',
                                style: TextStyle(fontSize: 12, color: Colors.grey[500], fontStyle: FontStyle.italic),
                              ),
                            )
                          else
                            for (final toolName in group.toolNames)
                              CheckboxListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                                title: Text(toolName, style: const TextStyle(fontSize: 13)),
                                value: current.contains(toolName),
                                activeColor: AppTheme.primaryBlue,
                                onChanged: (v) => setSheetState(() {
                                  if (v == true) {
                                    current = {...current, toolName};
                                  } else {
                                    current = current.difference({toolName});
                                  }
                                }),
                              ),
                        ],
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: () => setSheetState(() => current = Set.from(allToolNames)),
                          child: Text(allSelected ? 'All selected' : 'Select all'),
                        ),
                        TextButton(onPressed: () => setSheetState(() => current = {}), child: const Text('None')),
                        const Spacer(),
                        FilledButton(
                          onPressed: () {
                            Navigator.of(ctx3).pop();
                            _commit(current);
                          },
                          child: const Text('Apply'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showDesktopDialog(BuildContext context) async {
    var current = _enabledToolNamesSet();
    final allToolNames = {for (final g in availableToolGroups) ...g.toolNames};

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setDialogState) {
          final allSelected = current.length == allToolNames.length;
          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.build_rounded, size: 18, color: AppTheme.primaryBlue),
                const SizedBox(width: 8),
                Text('Tools -- Step ${stepIndex + 1}', style: const TextStyle(fontSize: 15)),
              ],
            ),
            contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
            content: SizedBox(
              width: 340,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 460),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final group in availableToolGroups) ...[
                      // Group header with select-all toggle
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                group.name.toUpperCase(),
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey[600], letterSpacing: 0.5),
                              ),
                            ),
                            TextButton(
                              onPressed: () => setDialogState(() {
                                final groupSet = group.toolNames.toSet();
                                if (groupSet.every(current.contains)) {
                                  current = current.difference(groupSet);
                                } else {
                                  current = current.union(groupSet);
                                }
                              }),
                              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(40, 28)),
                              child: Text(group.toolNames.every(current.contains) ? 'None' : 'All', style: const TextStyle(fontSize: 11)),
                            ),
                          ],
                        ),
                      ),
                      if (group.toolNames.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                          child: Text(
                            '(connecting…)',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500], fontStyle: FontStyle.italic),
                          ),
                        )
                      else
                        for (final toolName in group.toolNames)
                          CheckboxListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                            title: Text(toolName, style: const TextStyle(fontSize: 13)),
                            value: current.contains(toolName),
                            activeColor: AppTheme.primaryBlue,
                            onChanged: (v) => setDialogState(() {
                              if (v == true) {
                                current = {...current, toolName};
                              } else {
                                current = current.difference({toolName});
                              }
                            }),
                          ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => setDialogState(() => current = Set.from(allToolNames)),
                child: Text(allSelected ? 'All selected' : 'Select all'),
              ),
              TextButton(onPressed: () => setDialogState(() => current = {}), child: const Text('None')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx2).pop();
                  _commit(current);
                },
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _commit(Set<String> selectedToolNames) {
    final allCount = _totalToolCount;
    if (selectedToolNames.length == allCount) {
      onChanged(null); // all tools = null (default)
    } else if (selectedToolNames.isEmpty) {
      onChanged([]);
    } else {
      onChanged(selectedToolNames.toList());
    }
  }
}
