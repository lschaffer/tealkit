import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import '../models/function_hint.dart';
import '../services/function_hint_database_service.dart';
import '../mcp/internal_mcp_registry.dart';
import '../l10n/app_localizations.dart';
import '../providers/sidebar_provider.dart';

import '../config/app_theme.dart';
import '../providers/app_preferences_provider.dart';
import '../providers/data_sources_settings_provider.dart';
import '../providers/external_tools_settings_provider.dart';
import '../providers/llm_settings_provider.dart';
import '../providers/server_mode_provider.dart';
import '../services/app_preferences_service.dart';
import '../services/import_export_service.dart';
import '../services/llm_settings_service.dart';
import 'external_tools_settings_screen.dart';
import 'github_mcp_registry_screen.dart';
import 'py_tool_library_screen.dart';
import 'script_library_screen.dart';
import 'js_tool_library_screen.dart';
import 'powershell_tool_library_screen.dart';
import 'local_shell_tool_library_screen.dart';
import '../widgets/data_sources_settings_screen.dart';
import '../widgets/llm_settings_dialog.dart';
import 'settings_vault_screen.dart';
import 'server_settings_screen.dart';
import 'function_hints_screen.dart';
import '../widgets/particle_background.dart';
import '../widgets/tool_list_export_sheet.dart';

/// Settings page — shows all 3 configuration cards on a single scrollable page.
///
/// The title adapts: "First Step" when LLM is not yet configured,
/// "Settings" once the minimum configuration is done.
class StartupWizardScreen extends ConsumerStatefulWidget {
  final int initialStep;
  final bool autoOpenInitialStep;

  const StartupWizardScreen({
    super.key,
    this.initialStep = 0,
    this.autoOpenInitialStep = false,
  });

  @override
  ConsumerState<StartupWizardScreen> createState() =>
      _StartupWizardScreenState();
}

class _StartupWizardScreenState extends ConsumerState<StartupWizardScreen> {
  bool _initialStepHandled = false;

  Future<void> _quickConfigureMistral() async {
    final apiKeyCtrl = TextEditingController();
    final modelCtrl = TextEditingController(text: 'mistral-large-latest');
    final baseUrlCtrl = TextEditingController(
      text: 'https://api.mistral.ai/v1',
    );

    final config = await showDialog<(String, String, String)?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Quick Mistral Setup'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: apiKeyCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  hintText: 'mistral-... or sk-...',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: modelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Model',
                  hintText:
                      'mistral-large-latest / mistral-medium-latest / mistral-small-latest',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: baseUrlCtrl,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final apiKey = apiKeyCtrl.text.trim();
              final model = modelCtrl.text.trim();
              final baseUrl = baseUrlCtrl.text.trim();
              final uri = Uri.tryParse(baseUrl);

              if (apiKey.isEmpty ||
                  model.isEmpty ||
                  baseUrl.isEmpty ||
                  uri == null ||
                  !(uri.isScheme('http') || uri.isScheme('https'))) {
                return;
              }

              Navigator.of(context).pop((apiKey, model, baseUrl));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (config == null || !mounted) return;
    final apiKey = config.$1;
    final model = config.$2;
    final baseUrl = config.$3;

    if (!(apiKey.startsWith('mistral-') || apiKey.startsWith('sk-'))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Mistral API key should usually start with mistral- or sk-',
          ),
          backgroundColor: Colors.orange,
        ),
      );
    }

    final llmSettings = ref.read(llmSettingsProvider);
    await llmSettings.save(
      provider: LlmProvider.mistral,
      model: model,
      apiKey: apiKey,
      baseUrl: baseUrl,
      temperature: llmSettings.temperature,
      maxTokens: llmSettings.maxTokens,
      maxToolOutputSize: llmSettings.maxToolOutputSize,
      tokenWarningThreshold: llmSettings.tokenWarningThreshold,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Mistral saved as default LLM'),
        backgroundColor: AppTheme.success,
      ),
    );
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleInitialStep());
  }

  Future<void> _handleInitialStep() async {
    if (_initialStepHandled || !mounted || !widget.autoOpenInitialStep) return;
    _initialStepHandled = true;
    await _openStep(widget.initialStep.clamp(0, 2));
  }

  // ignore: unused_element
  Future<void> _exportSettings() async {
    final messenger = ScaffoldMessenger.of(context);
    final l = L.of(context);
    final result = await ImportExportService.exportSettings();
    if (!mounted) return;
    if (result.error != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.exportFailed(result.error!)),
          backgroundColor: AppTheme.error,
        ),
      );
    } else if (result.savedPath != null) {
      // Mobile: file saved silently to Downloads — show path in snackbar
      final fileName = result.savedPath!.split(RegExp(r'[/\\]')).last;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.exportSavedToDownloads(fileName)),
          backgroundColor: AppTheme.success,
          duration: const Duration(seconds: 5),
        ),
      );
    } else {
      // Desktop: OS dialog handled it
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.exportSuccess),
          backgroundColor: AppTheme.success,
        ),
      );
    }
  }

  Future<void> _pickDefaultOutputDir() async {
    final prefs = ref.read(appPreferencesProvider);
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: L.of(context).defaultOutputDir,
      initialDirectory: prefs.defaultOutputPath.isNotEmpty
          ? prefs.defaultOutputPath
          : null,
    );
    if (path != null) await prefs.setDefaultOutputPath(path);
  }

  Future<void> _openVault() => SettingsVaultScreen.show(context);

  Future<void> _openStep(int index) async {
    if (!mounted) return;
    if (index == 0) {
      final llmSettings = ref.read(llmSettingsProvider);
      final serverClient = ref.read(serverApiClientProvider);
      final isLightMode = ref.read(isLightModeProvider);
      await LlmSettingsDialog.show(
        context,
        llmSettings,
        serverClient: serverClient,
        isLightMode: isLightMode,
      );
    } else if (index == 1) {
      final dataSources = ref.read(dataSourcesSettingsProvider);
      final serverClient = ref.read(serverApiClientProvider);
      await DataSourcesSettingsScreen.show(
        context,
        dataSources,
        serverClient: serverClient,
      );
    } else {
      final externalTools = ref.read(externalToolsSettingsProvider);
      await ExternalToolsSettingsScreen.show(context, externalTools);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final llmSettings = ref.watch(llmSettingsProvider);
    final dataSources = ref.watch(dataSourcesSettingsProvider);
    final externalTools = ref.watch(externalToolsSettingsProvider);
    // Use ref.read – prefs rebuilds are handled by ListenableBuilder below.
    final prefs = ref.read(appPreferencesProvider);
    final llmReady = llmSettings.isConfigured;
    final dataSourcesReady = dataSources.configuredCount > 0;
    final externalReady = externalTools.isConfigured;

    // Title adapts based on LLM configuration state
    final title = llmReady ? l.settings : l.firstStep;

    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';

    final mainContent = Scaffold(
      backgroundColor: isModern ? Colors.transparent : null,
      appBar: AppBar(
        backgroundColor: isModern ? Colors.transparent : null,
        elevation: 0,
        title: Text(title),
        leading:
            (isModern &&
                MediaQuery.sizeOf(context).width > 1200 &&
                !(ModalRoute.of(context)?.canPop ?? false))
            ? Consumer(
                builder: (context, ref, _) {
                  final isOpen = ref.watch(sidebarOpenProvider);
                  return IconButton(
                    icon: const Icon(Icons.menu),
                    onPressed: () {
                      ref.read(sidebarOpenProvider.notifier).state = !isOpen;
                    },
                  );
                },
              )
            : null,
        actions: [
          Consumer(
            builder: (context, ref, _) {
              final modeAsync = ref.watch(serverModeProvider);
              final serverState = modeAsync.value;
              if (serverState == null || !serverState.isRemote) {
                return const SizedBox.shrink();
              }
              return IconButton(
                icon: Icon(
                  serverState.isConnected ? Icons.cloud : Icons.cloud_outlined,
                ),
                tooltip: serverState.isConnected
                    ? 'Server connected: ${serverState.serverUrl}'
                    : 'Server mode — not connected',
                color: serverState.isConnected ? AppTheme.success : null,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ServerSettingsScreen(),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Server connection (shown at top when in remote mode) ──
          Consumer(
            builder: (context, ref, _) {
              final modeAsync = ref.watch(serverModeProvider);
              final serverState = modeAsync.value;
              if (serverState == null || !serverState.isRemote) {
                return const SizedBox.shrink();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ServerConnectionCard(serverState: serverState),
                  const SizedBox(height: 16),
                ],
              );
            },
          ),

          // ── 1. LLM (required) ──
          _StepCard(
            icon: Icons.psychology,
            title: 'LLM',
            description: l.wizardLlmDescription,
            ready: llmReady,
            required_: true,
            actionLabel: l.wizardOpenLlmSettings,
            onPressed: () => _openStep(0),
          ),
          if (!llmReady) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _quickConfigureMistral,
                icon: const Icon(Icons.rocket_launch, size: 16),
                label: const Text('Quick Mistral'),
              ),
            ),
          ],
          const SizedBox(height: 16),

          // ── 2. Datasources ──
          _StepCard(
            icon: Icons.source,
            title: l.dataSources,
            description: l.wizardDataSourcesDescription,
            ready: dataSourcesReady,
            actionLabel: l.wizardOpenDataSources,
            onPressed: () => _openStep(1),
          ),
          const SizedBox(height: 16),

          // ── Inbuilt tools ──
          const _InbuiltToolsCard(),
          const SizedBox(height: 16),

          // ── 3. External tools ──
          _StepCard(
            icon: Icons.extension,
            title: l.wizardExternalToolsTitle,
            description: l.wizardExternalToolsDescription,
            ready: externalReady,
            actionLabel: l.wizardOpenExternalTools,
            onPressed: () => _openStep(2),
          ),
          const SizedBox(height: 16),

          // ── Scripts ──
          _ScriptsCard(
            onOpenSshScripts: () => ScriptLibraryScreen.show(context),
            onOpenJsTools: () => JsToolLibraryScreen.show(context),
            // Python MCP Tools is desktop-only and shown in _DesktopFeaturesCard below.
            onOpenPyTools: null,
            onOpenLocalShell:
                (!kIsWeb && (Platform.isMacOS || Platform.isLinux))
                ? () => LocalShellToolLibraryScreen.show(context)
                : null,
          ),
          const SizedBox(height: 16),

          // ── Desktop Features (desktop always; mobile when server mode is active) ──
          Consumer(
            builder: (context, ref, _) {
              final isServerMode =
                  ref.watch(serverModeProvider).value?.isRemote ?? false;
              final isDesktopPlatform =
                  !kIsWeb &&
                  (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
              final showDesktopFeatures = isDesktopPlatform || isServerMode;
              if (!showDesktopFeatures) return const SizedBox.shrink();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _DesktopFeaturesCard(
                    onOpenPyTools: () => PyToolLibraryScreen.show(context),
                    onOpenMcpRegistry: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const GithubMcpRegistryScreen(),
                      ),
                    ),
                    onOpenPwsh: (!kIsWeb && Platform.isWindows && !isServerMode)
                        ? () => PowershellToolLibraryScreen.show(context)
                        : null,
                  ),
                  const SizedBox(height: 16),
                ],
              );
            },
          ),

          // ── Tool Hints ──
          _SkillsCard(onOpen: () => FunctionHintsScreen.show(context)),
          const SizedBox(height: 16),

          // ── 4. Generic ── rebuild whenever prefs change
          ListenableBuilder(
            listenable: prefs,
            builder: (_, _) => _GenericCard(
              prefs: prefs,
              onPickOutputDir: _pickDefaultOutputDir,
              onVault: _openVault,
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );

    if (isModern) {
      return ParticleBackground(child: mainContent);
    }
    return mainContent;
  }
}

class _StepCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool ready;
  final bool required_;
  final String actionLabel;
  final VoidCallback onPressed;

  const _StepCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.ready,
    this.required_ = false,
    required this.actionLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';
    final cardBg = isModern
        ? (isDark
              ? Colors.black.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.65))
        : (isDark ? AppTheme.cardDark : AppTheme.cardLight);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: ready
              ? AppTheme.success.withAlpha(128)
              : (required_
                    ? AppTheme.warning.withAlpha(128)
                    : theme.dividerColor),
          width: ready || required_ ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: ready ? AppTheme.success : AppTheme.primaryBlue,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                ready ? Icons.check_circle : Icons.radio_button_unchecked,
                color: ready
                    ? AppTheme.success
                    : (required_ ? AppTheme.warning : Colors.grey),
                size: 20,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(description, style: theme.textTheme.bodySmall),
          if (required_ && !ready) ...[
            const SizedBox(height: 4),
            Text(
              L.of(context).requiredLabel,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppTheme.warning,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onPressed,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────// Scripts card
// ───────────────────────────────────────────────────────────────────────────────

class _ScriptsCard extends StatelessWidget {
  final VoidCallback onOpenSshScripts;
  final VoidCallback onOpenJsTools;
  final VoidCallback? onOpenPyTools;
  final VoidCallback? onOpenLocalShell;

  const _ScriptsCard({
    required this.onOpenSshScripts,
    required this.onOpenJsTools,
    this.onOpenPyTools,
    this.onOpenLocalShell,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';
    final cardBg = isModern
        ? (isDark
              ? Colors.black.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.65))
        : (isDark ? AppTheme.cardDark : AppTheme.cardLight);

    final buttons = <Widget>[
      _DesktopFeatureButton(
        icon: Icons.terminal,
        label: 'SSH Shell Scripts',
        description:
            'Manage and test shell scripts that run on the configured SSH server.',
        onTap: onOpenSshScripts,
      ),
      _DesktopFeatureButton(
        icon: Icons.javascript,
        label: 'JavaScript Tools',
        description:
            'Create and manage custom JavaScript tools exposed as MCP tools.',
        onTap: onOpenJsTools,
      ),
      if (onOpenPyTools != null)
        _DesktopFeatureButton(
          icon: Icons.code,
          label: 'Python MCP Tools',
          description: 'Create and manage Python tools exposed as MCP servers.',
          onTap: onOpenPyTools!,
        ),
      if (onOpenLocalShell != null)
        _DesktopFeatureButton(
          icon: Icons.terminal,
          label: 'Local Shell Scripts',
          description: 'Manage shell scripts that run locally on this machine.',
          onTap: onOpenLocalShell!,
        ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.primary.withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.code, color: AppTheme.primaryBlue, size: 22),
              const SizedBox(width: 10),
              Text(
                'Scripts',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Script and tool libraries. Access depends on your active plan or trial status.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final useRow = constraints.maxWidth >= 480;
              final rows = <Widget>[];
              for (var i = 0; i < buttons.length; i += 2) {
                if (i > 0) rows.add(const SizedBox(height: 12));
                if (useRow && i + 1 < buttons.length) {
                  rows.add(
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: buttons[i]),
                        const SizedBox(width: 12),
                        Expanded(child: buttons[i + 1]),
                      ],
                    ),
                  );
                } else if (useRow) {
                  rows.add(
                    Row(
                      children: [
                        Expanded(child: buttons[i]),
                        const Expanded(child: SizedBox()),
                      ],
                    ),
                  );
                } else {
                  rows.add(buttons[i]);
                  if (i + 1 < buttons.length) {
                    rows.add(const SizedBox(height: 12));
                    rows.add(buttons[i + 1]);
                  }
                }
              }
              return Column(children: rows);
            },
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────────// Desktop Features card (Windows / macOS / Linux only)
// ─────────────────────────────────────────────────────────────────────────────

class _DesktopFeaturesCard extends StatelessWidget {
  final VoidCallback onOpenPyTools;
  final VoidCallback onOpenMcpRegistry;
  final VoidCallback? onOpenPwsh;

  const _DesktopFeaturesCard({
    required this.onOpenPyTools,
    required this.onOpenMcpRegistry,
    this.onOpenPwsh,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';
    final cardBg = isModern
        ? (isDark
              ? Colors.black.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.65))
        : (isDark ? AppTheme.cardDark : AppTheme.cardLight);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.primary.withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Icon(
                Icons.desktop_windows,
                color: AppTheme.primaryBlue,
                size: 22,
              ),
              const SizedBox(width: 10),
              Text(
                'Desktop Features',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Responsive buttons: row on wide screens, column on narrow
          LayoutBuilder(
            builder: (context, constraints) {
              final useRow = constraints.maxWidth >= 480;
              final buttons = <Widget>[
                _DesktopFeatureButton(
                  icon: Icons.code,
                  label: 'Python MCP Tool Generator',
                  description:
                      'Create and manage custom Python tools as MCP servers.',
                  onTap: onOpenPyTools,
                ),
                _DesktopFeatureButton(
                  icon: Icons.cloud_download_outlined,
                  label: 'MCP Server Registry',
                  description:
                      'Browse and install Python or Node.js MCP servers from the community registry.',
                  onTap: onOpenMcpRegistry,
                ),
                if (onOpenPwsh != null)
                  _DesktopFeatureButton(
                    icon: Icons.terminal,
                    label: 'PowerShell Scripts',
                    description:
                        'Manage and test PowerShell scripts that run locally on Windows.',
                    onTap: onOpenPwsh!,
                  ),
              ];
              final rows = <Widget>[];
              for (var i = 0; i < buttons.length; i += 2) {
                if (i > 0) rows.add(const SizedBox(height: 12));
                if (useRow && i + 1 < buttons.length) {
                  rows.add(
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: buttons[i]),
                        const SizedBox(width: 12),
                        Expanded(child: buttons[i + 1]),
                      ],
                    ),
                  );
                } else if (useRow) {
                  rows.add(
                    Row(
                      children: [
                        Expanded(child: buttons[i]),
                        const Expanded(child: SizedBox()),
                      ],
                    ),
                  );
                } else {
                  rows.add(buttons[i]);
                  if (i + 1 < buttons.length) {
                    rows.add(const SizedBox(height: 12));
                    rows.add(buttons[i + 1]);
                  }
                }
              }
              return Column(children: rows);
            },
          ),
        ],
      ),
    );
  }
}

// Tool Hints card
// ─────────────────────────────────────────────────────────────────────────────

class _SkillsCard extends StatelessWidget {
  final VoidCallback onOpen;
  const _SkillsCard({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lightbulb_outlined,
                  color: Colors.amber[600],
                  size: 24,
                ),
                const SizedBox(width: 12),
                Text(
                  'Function Hints',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'AI-generated usage guides for each MCP tool. '
              'Hints are automatically created when you first configure an LLM and injected into system prompts to improve tool-use accuracy.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.manage_search),
                label: const Text('Manage Function Hints'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Generic settings card
// ─────────────────────────────────────────────────────────────────────────────

class _GenericCard extends StatelessWidget {
  final AppPreferencesService prefs;
  final VoidCallback onPickOutputDir;
  final VoidCallback onVault;

  const _GenericCard({
    required this.prefs,
    required this.onPickOutputDir,
    required this.onVault,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';
    final cardBg = isModern
        ? (isDark
              ? Colors.black.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.65))
        : (isDark ? AppTheme.cardDark : AppTheme.cardLight);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ─────────────────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.tune, color: AppTheme.primaryBlue, size: 22),
              const SizedBox(width: 10),
              Text(
                L.of(context).generalSection,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            L.of(context).generalSectionDescription,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),

          // ── Theme toggle ───────────────────────────────────────────────
          _SettingsRow(
            icon: prefs.themeModeIcon,
            label: L.of(context).themeLabel,
            value: prefs.themeModeLabel,
            tooltip: L.of(context).themeToggleTooltip,
            onTap: prefs.cycleTheme,
          ),
          const SizedBox(height: 10),

          // ── UI Style toggle ───────────────────────────────────────────────
          _SettingsRow(
            icon: Icons.palette_outlined,
            label: prefs.locale == 'de' ? 'Design-Stil' : 'UI Design Style',
            value: prefs.uiStyle == 'modern'
                ? (prefs.locale == 'de' ? 'Modern' : 'Modern')
                : (prefs.locale == 'de'
                      ? 'Klassisch (Original)'
                      : 'Classic (Original)'),
            tooltip: prefs.locale == 'de'
                ? 'Zwischen modernem und klassischem Design wechseln'
                : 'Toggle between modern and classic design styles',
            onTap: () {
              final next = prefs.uiStyle == 'modern' ? 'classic' : 'modern';
              prefs.setUiStyle(next);
            },
          ),
          const SizedBox(height: 10),

          // ── Language toggle ─────────────────────────────────────────────
          _SettingsRow(
            icon: Icons.language,
            label: L.of(context).languageLabel,
            value: prefs.locale == 'de' ? 'Deutsch' : 'English',
            tooltip: L.of(context).languageToggleTooltip,
            onTap: prefs.toggleLocale,
          ),
          const Divider(height: 24),

          // ── Default output directory ────────────────────────────────────
          Text(
            L.of(context).defaultOutputDir,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            L.of(context).defaultOutputDirDescription,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          // ── Folder picker row ──────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    prefs.defaultOutputPath.isNotEmpty
                        ? prefs.defaultOutputPath
                        : L.of(context).defaultOutputDirNotSet,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: prefs.defaultOutputPath.isNotEmpty
                          ? null
                          : Colors.grey,
                      overflow: TextOverflow.ellipsis,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 40,
                child: OutlinedButton(
                  onPressed: onPickOutputDir,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: const Icon(Icons.folder_open, size: 18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ── Retention days stepper ─────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      L.of(context).outputRetentionDays,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      L.of(context).outputRetentionDaysDescription,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                onPressed: prefs.outputRetentionDays > 1
                    ? () => prefs.setOutputRetentionDays(
                        prefs.outputRetentionDays - 1,
                      )
                    : null,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
              Text(
                '${prefs.outputRetentionDays}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                onPressed: prefs.outputRetentionDays < 60
                    ? () => prefs.setOutputRetentionDays(
                        prefs.outputRetentionDays + 1,
                      )
                    : null,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ── Background check interval ────────────────────────────────────
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                L.of(context).backgroundCheckInterval,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                L.of(context).backgroundCheckIntervalDescription,
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: AppPreferencesService.backgroundCheckIntervalOptions
                    .map(
                      (m) => ButtonSegment<int>(value: m, label: Text('${m}m')),
                    )
                    .toList(),
                selected: {prefs.backgroundCheckIntervalMinutes},
                onSelectionChanged: (s) =>
                    prefs.setBackgroundCheckInterval(s.first),
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStateProperty.all(
                    const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 24),

          // ── Settings Vault ───────────────────────────────────────────────
          _ActionRow(
            icon: Icons.lock_outlined,
            label: L.of(context).vaultTitle,
            description: L.of(context).vaultSubtitle,
            onTap: onVault,
          ),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String tooltip;
  final VoidCallback onTap;

  const _SettingsRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppTheme.primaryBlue),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            Tooltip(
              message: tooltip,
              child: Chip(
                label: Text(value, style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                side: const BorderSide(color: AppTheme.primaryBlue),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Desktop feature button (large, emphasis style) ─────────────────────────

class _DesktopFeatureButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;

  const _DesktopFeatureButton({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: cs.primaryContainer.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 30, color: cs.primary),
              const SizedBox(height: 10),
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
          ),
        ],
      ),
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        minimumSize: const Size.fromHeight(48),
      ),
    );
  }
}

// ── Server Connection Card ────────────────────────────────────────────────────

class _ServerConnectionCard extends StatelessWidget {
  final ServerModeState serverState;

  const _ServerConnectionCard({required this.serverState});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    final isConnected = serverState.isConnected;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardDark : AppTheme.cardLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isConnected
              ? AppTheme.success.withAlpha(160)
              : Colors.orange.withAlpha(160),
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isConnected ? Icons.cloud_done : Icons.cloud_off,
                color: isConnected ? AppTheme.success : Colors.orange,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isConnected
                      ? 'Server Mode \u2022 Connected'
                      : 'Server Mode \u2022 Not Connected',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (serverState.serverUrl.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              serverState.serverUrl,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ServerSettingsScreen()),
              ),
              icon: const Icon(Icons.settings_ethernet, size: 16),
              label: const Text('Server Settings'),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Inbuilt Tools Settings Card ──────────────────────────────────────────────

class _InbuiltToolsCard extends ConsumerStatefulWidget {
  const _InbuiltToolsCard();

  @override
  ConsumerState<_InbuiltToolsCard> createState() => _InbuiltToolsCardState();
}

class _InbuiltToolsCardState extends ConsumerState<_InbuiltToolsCard> {
  final Set<String> _expandedTypes = {};
  List<FunctionHint> _skills = [];
  bool _loadingSkills = true;
  bool _isCardExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadSkills();
  }

  Future<void> _loadSkills() async {
    if (!mounted) return;
    setState(() => _loadingSkills = true);
    try {
      final client = ref.read(serverApiClientProvider);
      final List<FunctionHint> all;
      if (client != null) {
        final raw = await client.getAllSkills();
        all = raw.map((j) => FunctionHint.fromJson(j)).toList();
      } else {
        all = await FunctionHintDatabaseService().getAll();
      }
      if (mounted) {
        setState(() {
          _skills = all;
          _loadingSkills = false;
        });
      }
    } catch (e) {
      debugPrint('Failed to load skills for Inbuilt Tools: $e');
      if (mounted) {
        setState(() => _loadingSkills = false);
      }
    }
  }

  void _exportSingleTool(InternalMcpInfo info) {
    final registry = InternalMcpRegistry();
    final server = registry.create(info.type);
    final matchingSkills = _skills
        .where((s) => s.mcpType == info.type)
        .toList();

    final List<Map<String, dynamic>> toolsList = (server?.tools ?? []).map((
      tool,
    ) {
      final skill = matchingSkills
          .where((s) => s.toolName == tool.name)
          .firstOrNull;
      return {
        'name': tool.name,
        'description': tool.description,
        'inputSchema': tool.inputSchema,
        if (tool.returnType != null) 'returnType': tool.returnType,
        if (skill != null)
          'skill': {
            'id': skill.id,
            'skillText': skill.skillText,
            'skillTextSlm': skill.skillTextSlm,
            'isEnabled': skill.isEnabled,
            'isCustom': skill.isCustom,
            'generatedAt': skill.generatedAt.toIso8601String(),
            'updatedAt': skill.updatedAt.toIso8601String(),
          },
      };
    }).toList();

    ToolListExportSheet.show(
      context,
      serverName: info.displayName,
      tools: toolsList,
    );
  }

  void _exportAllTools(List<InternalMcpInfo> available) {
    final registry = InternalMcpRegistry();
    final List<Map<String, dynamic>> exportList = [];

    for (final info in available) {
      final server = registry.create(info.type);
      final matchingSkills = _skills
          .where((s) => s.mcpType == info.type)
          .toList();

      exportList.addAll(
        (server?.tools ?? []).map((tool) {
          final skill = matchingSkills
              .where((s) => s.toolName == tool.name)
              .firstOrNull;
          return {
            'name': tool.name,
            'description': '${info.displayName}: ${tool.description}',
            'inputSchema': tool.inputSchema,
            if (tool.returnType != null) 'returnType': tool.returnType,
            if (skill != null)
              'skill': {
                'id': skill.id,
                'skillText': skill.skillText,
                'skillTextSlm': skill.skillTextSlm,
                'isEnabled': skill.isEnabled,
                'isCustom': skill.isCustom,
                'generatedAt': skill.generatedAt.toIso8601String(),
                'updatedAt': skill.updatedAt.toIso8601String(),
              },
          };
        }),
      );
    }

    ToolListExportSheet.show(
      context,
      serverName: 'All Inbuilt Tools',
      tools: exportList,
    );
  }

  IconData _mcpIcon(String name) {
    return switch (name) {
      'cloud' => Icons.cloud,
      'description' => Icons.description,
      'email' => Icons.email,
      'search' => Icons.search,
      'language' => Icons.language,
      'build' => Icons.build,
      'add_to_drive' => Icons.add_to_drive,
      'home' => Icons.home,
      'javascript' => Icons.javascript,
      'terminal' => Icons.terminal,
      'schema' => Icons.schema,
      'picture_as_pdf' => Icons.picture_as_pdf,
      'traffic' => Icons.traffic,
      'calendar_today' => Icons.calendar_today,
      'table_chart' => Icons.table_chart,
      'insert_chart' => Icons.insert_chart,
      _ => Icons.extension,
    };
  }

  String _formatInputSchema(Map<String, dynamic> schema) {
    final properties = schema['properties'] as Map?;
    if (properties == null || properties.isEmpty) return 'None';
    final List<String> params = [];
    for (final entry in properties.entries) {
      final val = entry.value as Map?;
      final type = val?['type'] ?? 'any';
      final desc = val?['description'] ?? '';
      params.add('• ${entry.key} ($type): $desc');
    }
    return params.join('\n');
  }

  List<Widget> _buildSubToolsList(
    InternalMcpInfo info,
    List<FunctionHint> matchingSkills,
  ) {
    final registry = InternalMcpRegistry();
    final server = registry.create(info.type);
    if (server == null || server.tools.isEmpty) {
      return [
        const Text(
          'No tools available for this server.',
          style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
        ),
      ];
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return server.tools.map((tool) {
      final skill = matchingSkills
          .where((s) => s.toolName == tool.name)
          .firstOrNull;

      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withAlpha(5) : Colors.black.withAlpha(5),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: theme.dividerColor.withAlpha(30)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tool.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (skill != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: skill.isEnabled
                          ? AppTheme.success.withAlpha(30)
                          : theme.hintColor.withAlpha(30),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      skill.isEnabled ? 'Skill Active' : 'Skill Disabled',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: skill.isEnabled
                            ? AppTheme.success
                            : theme.hintColor,
                      ),
                    ),
                  ),
              ],
            ),
            if (tool.description.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                tool.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
            const SizedBox(height: 6),
            if (tool.inputSchema.isNotEmpty) ...[
              Text(
                'Parameters:',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _formatInputSchema(tool.inputSchema),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 6),
            ],
            Text(
              'Procedural Guide (Skill):',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            if (skill != null) ...[
              Text(
                skill.skillText.isNotEmpty
                    ? skill.skillText
                    : 'Empty skill text.',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (skill.skillTextSlm.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'SLM version: ${skill.skillTextSlm}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: theme.hintColor,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ] else
              Text(
                'No skill generated for this tool yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                  fontStyle: FontStyle.italic,
                ),
              ),
          ],
        ),
      );
    }).toList();
  }

  Widget _buildToolItem(InternalMcpInfo info) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isExpanded = _expandedTypes.contains(info.type);
    final matchingSkills = _skills
        .where((s) => s.mcpType == info.type)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 2,
          ),
          leading: Icon(_mcpIcon(info.iconName), color: AppTheme.primaryBlue),
          title: Text(
            info.displayName,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(info.description, style: theme.textTheme.bodySmall),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.download, size: 20),
                tooltip: 'Export ${info.displayName} for training',
                onPressed: () => _exportSingleTool(info),
              ),
              Icon(
                isExpanded ? Icons.expand_less : Icons.expand_more,
                color: theme.hintColor,
              ),
            ],
          ),
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expandedTypes.remove(info.type);
              } else {
                _expandedTypes.add(info.type);
              }
            });
          },
        ),
        if (isExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 48, right: 8, bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (info.initParamSchema.isNotEmpty) ...[
                  Text(
                    'Initialization Parameters',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.hintColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white10
                          : Colors.black.withAlpha(10),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      const JsonEncoder.withIndent(
                        '  ',
                      ).convert(info.initParamSchema),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  'Tools & Skills',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.hintColor,
                  ),
                ),
                const SizedBox(height: 4),
                ..._buildSubToolsList(info, matchingSkills),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      FunctionHintsScreen.show(context, filter: info.type);
                    },
                    icon: const Icon(Icons.open_in_new, size: 14),
                    label: const Text('Manage Skills directly'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';
    final cardBg = isModern
        ? (isDark
              ? Colors.black.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.65))
        : (isDark ? AppTheme.cardDark : AppTheme.cardLight);

    final available = InternalMcpRegistry().availableServers;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _isCardExpanded = !_isCardExpanded;
              });
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(
                    Icons.construction,
                    color: AppTheme.primaryBlue,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Inbuilt Tools',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Built-in capabilities for tasks.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.model_training),
                    tooltip: 'Export all for training',
                    onPressed: () => _exportAllTools(available),
                  ),
                  Icon(
                    _isCardExpanded ? Icons.expand_less : Icons.expand_more,
                    color: theme.hintColor,
                  ),
                ],
              ),
            ),
          ),
          if (_isCardExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _loadingSkills
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: available.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final info = available[index];
                        return _buildToolItem(info);
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }
}
