import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_ui_mcp_core/flutter_ui_mcp_core.dart';

import '../providers/server_mode_provider.dart';
import '../services/app_preferences_service.dart';
import '../services/coding_settings_service.dart';
import '../config/app_theme.dart';

/// Responsive settings card for Coding Mode execution limits, discovery,
/// agent capabilities, and Human-in-the-Loop tool auto-approval.
///
/// Shown on Desktop (Windows/macOS/Linux) and on Mobile when connected in
/// Server Mode. Uses a 2-column grid on wide screens and vertical stacking
/// on mobile to avoid horizontal overflow.
class CodingSettingsCard extends ConsumerStatefulWidget {
  /// Optional live [PlaygroundController] (when opened inside Assistant
  /// Settings) so changes apply immediately to the active session.
  final PlaygroundController? controller;

  /// Whether to render the card collapsed in a compact expander by default
  /// (useful inside Global Settings so the page stays tidy).
  final bool initiallyExpanded;

  const CodingSettingsCard({
    super.key,
    this.controller,
    this.initiallyExpanded = true,
  });

  /// Returns true when Human-in-the-Loop Coding Tool Auto-Approval toggles
  /// should be shown: always on Desktop, or on Mobile when Server Mode is active.
  static bool showCodingToolPermissions({required bool isRemoteServerMode}) {
    final isDesktop =
        !kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    return isDesktop || isRemoteServerMode;
  }

  @override
  ConsumerState<CodingSettingsCard> createState() => _CodingSettingsCardState();
}

class _CodingSettingsCardState extends ConsumerState<CodingSettingsCard> {
  final _settings = CodingSettingsService.instance;

  late final TextEditingController _maxToolIterCtrl;
  late final TextEditingController _maxSessionTurnsCtrl;
  late final TextEditingController _turnLimitCtrl;
  late final TextEditingController _maxSessionSizeCtrl;
  late final TextEditingController _compressionThresholdCtrl;

  bool _expanded = true;
  bool _saving = false;
  bool _justSaved = false;
  bool _requestedServerSync = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
    _maxToolIterCtrl = TextEditingController(
      text: _settings.maxToolIterations.toString(),
    );
    _maxSessionTurnsCtrl = TextEditingController(
      text: _settings.maxSessionTurns.toString(),
    );
    _turnLimitCtrl = TextEditingController(
      text: _settings.turnLimit.toString(),
    );
    _maxSessionSizeCtrl = TextEditingController(
      text: _settings.maxSessionSizeMb.toString(),
    );
    _compressionThresholdCtrl = TextEditingController(
      text: _settings.compressionThreshold.toString(),
    );
    _settings.addListener(_syncControllersFromService);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeSyncFromServer();
    });
  }

  @override
  void dispose() {
    _settings.removeListener(_syncControllersFromService);
    _maxToolIterCtrl.dispose();
    _maxSessionTurnsCtrl.dispose();
    _turnLimitCtrl.dispose();
    _maxSessionSizeCtrl.dispose();
    _compressionThresholdCtrl.dispose();
    super.dispose();
  }

  void _syncControllersFromService() {
    if (!mounted) return;
    _setTextIfDifferent(
      _maxToolIterCtrl,
      _settings.maxToolIterations.toString(),
    );
    _setTextIfDifferent(
      _maxSessionTurnsCtrl,
      _settings.maxSessionTurns.toString(),
    );
    _setTextIfDifferent(_turnLimitCtrl, _settings.turnLimit.toString());
    _setTextIfDifferent(
      _maxSessionSizeCtrl,
      _settings.maxSessionSizeMb.toString(),
    );
    _setTextIfDifferent(
      _compressionThresholdCtrl,
      _settings.compressionThreshold.toString(),
    );
    setState(() {});
  }

  void _setTextIfDifferent(TextEditingController ctrl, String value) {
    if (ctrl.text != value) {
      ctrl.text = value;
    }
  }

  Future<void> _maybeSyncFromServer() async {
    if (_requestedServerSync || !mounted) return;
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    final client = ref.read(serverApiClientProvider);
    if (!isRemote || client == null) return;
    _requestedServerSync = true;
    await _settings.syncFromServer(client);
    if (widget.controller != null) {
      _settings.applyToController(widget.controller!);
    }
  }

  Future<void> _saveNumericFields() async {
    final maxToolIter =
        int.tryParse(_maxToolIterCtrl.text.trim()) ??
        _settings.maxToolIterations;
    final maxSessionTurns =
        int.tryParse(_maxSessionTurnsCtrl.text.trim()) ??
        _settings.maxSessionTurns;
    final turnLimit =
        int.tryParse(_turnLimitCtrl.text.trim()) ?? _settings.turnLimit;
    final maxSessionSize =
        int.tryParse(_maxSessionSizeCtrl.text.trim()) ??
        _settings.maxSessionSizeMb;
    final compressionThreshold =
        int.tryParse(_compressionThresholdCtrl.text.trim()) ??
        _settings.compressionThreshold;

    await _applyUpdate(
      maxToolIterations: maxToolIter,
      maxSessionTurns: maxSessionTurns,
      turnLimit: turnLimit,
      maxSessionSizeMb: maxSessionSize,
      compressionThreshold: compressionThreshold,
      showFeedback: true,
    );
  }

  Future<void> _resetDefaults() async {
    await _applyUpdate(
      maxToolIterations: 50,
      maxSessionTurns: 500,
      turnLimit: 0,
      maxSessionSizeMb: 10,
      compressionThreshold: 16000,
      progressiveMcpDiscovery: false,
      enableEpisodicMemory: true,
      enableSubAgents: true,
      autoApproveRead: true,
      autoApproveWrite: false,
      autoApproveExecute: false,
      autoApproveNetwork: true,
      showFeedback: true,
    );
  }

  Future<void> _applyUpdate({
    int? maxToolIterations,
    int? maxSessionTurns,
    int? turnLimit,
    int? maxSessionSizeMb,
    int? compressionThreshold,
    bool? progressiveMcpDiscovery,
    bool? enableEpisodicMemory,
    bool? enableSubAgents,
    bool? autoApproveRead,
    bool? autoApproveWrite,
    bool? autoApproveExecute,
    bool? autoApproveNetwork,
    bool showFeedback = false,
  }) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _justSaved = false;
    });

    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    final client = isRemote ? ref.read(serverApiClientProvider) : null;

    await _settings.update(
      maxToolIterations: maxToolIterations,
      maxSessionTurns: maxSessionTurns,
      turnLimit: turnLimit,
      maxSessionSizeMb: maxSessionSizeMb,
      compressionThreshold: compressionThreshold,
      progressiveMcpDiscovery: progressiveMcpDiscovery,
      enableEpisodicMemory: enableEpisodicMemory,
      enableSubAgents: enableSubAgents,
      autoApproveRead: autoApproveRead,
      autoApproveWrite: autoApproveWrite,
      autoApproveExecute: autoApproveExecute,
      autoApproveNetwork: autoApproveNetwork,
      serverClient: client,
    );

    if (widget.controller != null) {
      _settings.applyToController(widget.controller!);
    }

    if (!mounted) return;
    setState(() {
      _saving = false;
      _justSaved = showFeedback;
    });
    if (showFeedback) {
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _justSaved = false);
      });
    }
  }

  Widget _buildNumberField({
    required TextEditingController controller,
    required String label,
    required String helper,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onSubmitted: (_) => _saveNumericFields(),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDe = AppPreferencesService.instance.locale == 'de';
    final serverState = ref.watch(serverModeProvider).value;
    final isRemote = serverState?.isRemote ?? false;
    final showToolApprovals = CodingSettingsCard.showCodingToolPermissions(
      isRemoteServerMode: isRemote,
    );

    const accentOrange = Color(0xFFF95721);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withAlpha(35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withAlpha(55)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 520;

          final maxToolIterField = _buildNumberField(
            controller: _maxToolIterCtrl,
            label: isDe ? 'Max. Tool-Iterationen' : 'Max Tool Iterations',
            helper: isDe
                ? 'Pro Zug (0 = unbegrenzt)'
                : 'Per turn (0 = unlimited)',
          );
          final maxTurnsField = _buildNumberField(
            controller: _maxSessionTurnsCtrl,
            label: isDe ? 'Max. Sitzungs-Züge' : 'Max Session Turns',
            helper: isDe
                ? 'Vor automatischer Rotation'
                : 'Before auto-rotation',
          );
          final turnLimitField = _buildNumberField(
            controller: _turnLimitCtrl,
            label: isDe ? 'Zug-Limit pro Sitzung' : 'Session Turn Limit',
            helper: isDe ? '0 = unbegrenzt' : '0 = unlimited',
          );
          final maxSizeField = _buildNumberField(
            controller: _maxSessionSizeCtrl,
            label: isDe ? 'Max. Sitzungsgröße (MB)' : 'Max Session Size (MB)',
            helper: isDe
                ? 'Auto-Save Rotationsgröße'
                : 'Auto-save rotation limit',
          );
          final compressionField = _buildNumberField(
            controller: _compressionThresholdCtrl,
            label: isDe
                ? 'Komprimierungsschwelle (Tokens)'
                : 'Compression Threshold (tokens)',
            helper: isDe
                ? 'Ab wie vielen Tokens Kontext komprimiert wird (4.000–200.000)'
                : 'Token count before compressing context (4,000–200,000)',
          );

          return Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Card Header ──────────────────────────────────────
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.tune_rounded,
                        color: accentOrange,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isDe
                              ? 'Ausführungs- & Sitzungslimits'
                              : 'Execution & Session Limits',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isRemote && !isNarrow) ...[
                        const SizedBox(width: 6),
                        _buildServerSyncBadge(isDe),
                      ],
                      const SizedBox(width: 4),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),

                if (isRemote && isNarrow) ...[
                  const SizedBox(height: 6),
                  _buildServerSyncBadge(isDe),
                ],

                const SizedBox(height: 6),
                Text(
                  isDe
                      ? 'Steuert maximale Tool-Aufrufe, Sitzungslimits, Tool-Erkennung und Agenten-Funktionen für Assistent- & Coding-Modus (Lokal & Server).'
                      : 'Controls max tool calls, session turn limits, tool discovery, and agent capabilities across Assistant & Coding modes (Local & Server).',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),

                if (_expanded) ...[
                  const SizedBox(height: 14),

                  // ── 1. Execution & Session Limits ──────────────────
                  Text(
                    isDe
                        ? 'Ausführungs- & Sitzungslimits'
                        : 'Execution & Session Limits',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: AppTheme.primaryBlue,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),

                  if (isNarrow) ...[
                    maxToolIterField,
                    const SizedBox(height: 12),
                    maxTurnsField,
                    const SizedBox(height: 12),
                    turnLimitField,
                    const SizedBox(height: 12),
                    maxSizeField,
                    const SizedBox(height: 12),
                    compressionField,
                  ] else ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: maxToolIterField),
                        const SizedBox(width: 12),
                        Expanded(child: maxTurnsField),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: turnLimitField),
                        const SizedBox(width: 12),
                        Expanded(child: maxSizeField),
                      ],
                    ),
                    const SizedBox(height: 12),
                    compressionField,
                  ],

                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _saving ? null : _saveNumericFields,
                        icon: _saving
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save_outlined, size: 16),
                        label: Text(
                          isDe ? 'Limits speichern' : 'Save Limits',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _saving ? null : _resetDefaults,
                        icon: const Icon(Icons.restart_alt, size: 16),
                        label: Text(isDe ? 'Standard' : 'Reset Defaults'),
                      ),
                      if (_justSaved)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.check_circle,
                              size: 16,
                              color: AppTheme.success,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isDe ? 'Gespeichert' : 'Saved',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.success,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),

                  const Divider(height: 24),

                  // ── 2. Discovery & Agent Capabilities ──────────────
                  Text(
                    isDe
                        ? 'Erkennung & Agenten-Funktionen'
                        : 'Discovery & Agent Capabilities',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: AppTheme.primaryBlue,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      isDe
                          ? 'Progressive Tool-Erkennung'
                          : 'Progressive Tool Discovery',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      isDe
                          ? 'MCP-Tool-Schemas erst bei Bedarf laden (spart Kontext-Tokens)'
                          : 'Load MCP tool schemas on demand instead of sending all upfront',
                      style: const TextStyle(fontSize: 11),
                    ),
                    value: _settings.progressiveMcpDiscovery,
                    onChanged: (v) =>
                        _applyUpdate(progressiveMcpDiscovery: v),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      isDe ? 'Episodisches Gedächtnis' : 'Episodic Memory',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      isDe
                          ? 'Archiviert lange Kontexte und ruft sie bei Bedarf ab'
                          : 'Archive and retrieve long-term session context automatically',
                      style: const TextStyle(fontSize: 11),
                    ),
                    value: _settings.enableEpisodicMemory,
                    onChanged: (v) => _applyUpdate(enableEpisodicMemory: v),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      isDe
                          ? 'Spezialisierte Sub-Agenten'
                          : 'Specialized Sub-Agents',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      isDe
                          ? 'Erlaubt dem Coding-Agenten Teilaufgaben zu delegieren'
                          : 'Allow the coding agent to delegate subtasks via delegate_task',
                      style: const TextStyle(fontSize: 11),
                    ),
                    value: _settings.enableSubAgents,
                    onChanged: (v) => _applyUpdate(enableSubAgents: v),
                  ),

                  if (showToolApprovals) ...[
                    const Divider(height: 24),

                    // ── 3. Tool Auto-Approval Checks ─────────────────
                    Text(
                      isDe
                          ? 'Tool-Berechtigungen (Human-in-the-Loop)'
                          : 'Tool Auto-Approval Checks (Human-in-the-Loop)',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: accentOrange,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        isDe
                            ? 'Lese-Tools automatisch genehmigen'
                            : 'Auto-Approve Read Tools',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: const Text(
                        'fs_read_file, fs_list_dir, fs_grep, fs_find',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: _settings.autoApproveRead,
                      onChanged: (v) => _applyUpdate(autoApproveRead: v),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        isDe
                            ? 'Schreib-Tools automatisch genehmigen'
                            : 'Auto-Approve Write / File Edit Tools',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: const Text(
                        'fs_write_file, fs_patch_file, fs_delete',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: _settings.autoApproveWrite,
                      onChanged: (v) => _applyUpdate(autoApproveWrite: v),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        isDe
                            ? 'Ausführungs-Tools automatisch genehmigen'
                            : 'Auto-Approve Terminal Execution',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: const Text(
                        'terminal_exec',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: _settings.autoApproveExecute,
                      onChanged: (v) => _applyUpdate(autoApproveExecute: v),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        isDe
                            ? 'Netzwerk-Tools automatisch genehmigen'
                            : 'Auto-Approve Network / Web Tools',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: const Text(
                        'fetch_web, web_search',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: _settings.autoApproveNetwork,
                      onChanged: (v) => _applyUpdate(autoApproveNetwork: v),
                    ),
                  ],
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildServerSyncBadge(bool isDe) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.success.withAlpha(28),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.success.withAlpha(90)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_done_outlined, size: 13, color: AppTheme.success),
          const SizedBox(width: 4),
          Text(
            isDe ? 'Mit Server synchronisiert' : 'Synced with Server',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppTheme.success,
            ),
          ),
        ],
      ),
    );
  }
}
