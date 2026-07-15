import 'dart:async';
import 'dart:io';
import 'dart:ui';


import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'l10n/app_localizations.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';
import 'config/app_theme.dart';
import 'database/duckdb_service.dart';
import 'database/task_database_service_duckdb.dart';
import 'providers/data_sources_settings_provider.dart';
import 'providers/external_tools_settings_provider.dart';
import 'providers/active_task_provider.dart';
import 'providers/llm_settings_provider.dart';
import 'services/app_preferences_service.dart';
import 'services/data_sources_settings_service.dart';
import 'services/external_tools_settings_service.dart';
import 'services/llm_settings_service.dart';
import 'services/notification_service.dart';
import 'services/scheduler_service.dart';
import 'services/shell_script_service.dart';
import 'services/powershell_script_service.dart';
import 'services/local_shell_script_service.dart';
import 'services/task_output_file_service.dart';
import 'services/windows_tray_service.dart';

import 'services/scheduler_log_service.dart';
import 'screens/startup_wizard_screen.dart';
import 'screens/playground_screen.dart';
import 'screens/server_settings_screen.dart';
import 'screens/workflow_list_screen.dart';
import 'providers/server_mode_provider.dart';
import 'providers/database_providers.dart';
import 'services/app_logger.dart';
import 'package:tealkit_api/tealkit_api.dart';
import 'services/github_mcp_library_service.dart';
import 'mcp/internal_mcp_registry.dart';
import 'services/function_hint_database_service.dart';
import 'services/function_hint_generation_service.dart';
import 'screens/function_hints_screen.dart';
import 'utils/credential_cipher.dart';
import 'widgets/particle_background.dart';
import 'providers/sidebar_provider.dart';

String _appVersion = '';

// ── About dialog ─────────────────────────────────────────────────────────────

// Scheduler activity log dialog (pro feature)
class _SchedulerActivityDialog extends StatefulWidget {
  const _SchedulerActivityDialog();

  @override
  State<_SchedulerActivityDialog> createState() => _SchedulerActivityDialogState();
}

class _SchedulerActivityDialogState extends State<_SchedulerActivityDialog> {
  List<SchedulerLogEntry>? _entries;

  @override
  void initState() {
    super.initState();
    SchedulerLogService().readRecent48h().then((e) {
      if (mounted) setState(() => _entries = e);
    });
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    return '$day.$month. $h:$m:$s';
  }

  (IconData, Color) _iconFor(SchedulerEventType event) {
    return switch (event) {
      SchedulerEventType.fired => (Icons.play_circle_outline, Colors.blue),
      SchedulerEventType.started => (Icons.hourglass_top_outlined, Colors.orange),
      SchedulerEventType.completed => (Icons.check_circle_outline, Colors.green),
      SchedulerEventType.failed => (Icons.error_outline, Colors.red),
      SchedulerEventType.skipped => (Icons.skip_next_outlined, Colors.grey),
      _ => (Icons.circle_outlined, Colors.grey),
    };
  }

  Widget _buildEntry(SchedulerLogEntry entry, ThemeData theme) {
    if (entry.event == SchedulerEventType.alarm) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
        child: Row(
          children: [
            Icon(Icons.alarm_outlined, size: 14, color: AppTheme.primaryBlue),
            const SizedBox(width: 6),
            Text(
              _formatTime(entry.timestamp),
              style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700, color: AppTheme.primaryBlue),
            ),
            const SizedBox(width: 4),
            Text(entry.taskName, style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.primaryBlue)),
            if (entry.detail != null) ...[
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.detail!,
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      );
    }
    final (icon, color) = _iconFor(entry.event);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 1, 12, 1),
      child: Row(
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(entry.taskName, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
          ),
          Text(_formatTime(entry.timestamp), style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600], fontSize: 11)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final theme = Theme.of(context);
    final entries = _entries;
    // Activity dialog: show only terminal events (completed / failed / skipped)
    // plus alarm ticks. Hide fired/started — they're intermediate noise.
    const terminalEvents = {SchedulerEventType.completed, SchedulerEventType.failed, SchedulerEventType.skipped, SchedulerEventType.alarm};
    final visible = entries?.where((e) => terminalEvents.contains(e.event)).toList();
    final screenHeight = MediaQuery.sizeOf(context).height;
    final isSmallScreen = screenHeight < 700;
    final verticalInset = isSmallScreen ? 0.0 : 48.0;
    final radius = isSmallScreen ? 0.0 : 16.0;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      insetPadding: EdgeInsets.fromLTRB(isSmallScreen ? 0 : 16, verticalInset, isSmallScreen ? 0 : 16, verticalInset),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
            child: Row(
              children: [
                Icon(Icons.history, color: AppTheme.primaryBlue, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(l.schedulerActivityTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (entries == null)
            const Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator.adaptive())
          else if (visible!.isEmpty)
            Expanded(
              child: Center(
                child: Text(l.noSchedulerLog, style: const TextStyle(color: Colors.grey)),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: visible.length,
                itemBuilder: (ctx, i) => _buildEntry(visible[i], theme),
              ),
            ),
        ],
      ),
    );
  }
}

void _showAboutDialog(BuildContext context) {
  final l = L.of(context);
  final theme = Theme.of(context);
  final isDE = Localizations.localeOf(context).languageCode == 'de';
  final guideUrl = isDE ? 'https://lschaffer.github.io/tealkit/guide/de/' : 'https://lschaffer.github.io/tealkit/guide/';
  const privacyUrl = 'https://lschaffer.github.io/tealkit/';
  const releaseNotesUrl = 'https://lschaffer.github.io/tealkit/release_notes.md';
  const isDeveloperMode = !kReleaseMode;

  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset('assets/icons/app_icon_transparent.png', width: 72, height: 72),
          const SizedBox(height: 12),
          Text(
            'TealKit',
            style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(color: AppTheme.primaryBlue, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text('Version $_appVersion', style: TextStyle(color: Colors.grey[500], fontSize: 13)),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse('https://github.com/lschaffer/tealkit'), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.code_outlined, size: 18),
              label: const Text('Readme'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse(releaseNotesUrl), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.new_releases_outlined, size: 18),
              label: const Text('Release Notes'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse(guideUrl), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.menu_book_outlined, size: 18),
              label: Text(l.userGuide),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse(privacyUrl), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.privacy_tip_outlined, size: 18),
              label: Text(l.privacyPolicy),
            ),
          ),
          const SizedBox(height: 8),
          if (isDeveloperMode) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  final nav = Navigator.of(ctx);
                  nav.pop();
                  nav.push(
                    MaterialPageRoute(
                      builder: (_) => TalkerScreen(
                        talker: talkerInstance,
                        theme: TalkerScreenTheme(backgroundColor: theme.scaffoldBackgroundColor, cardColor: theme.cardColor),
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.bug_report_outlined, size: 18),
                label: Text(l.viewLogs),
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                showDialog<void>(context: context, builder: (_) => const _SchedulerActivityDialog());
              },
              icon: const Icon(Icons.history, size: 18),
              label: Text(l.schedulerActivity),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.close))],
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  log.info('App starting');

  // Initialize DuckDB
  try {
    await DuckDbService().init();
    log.info('DuckDB initialized successfully');
  } catch (e) {
    log.error('Failed to initialize DuckDB: $e');
  }

  // Initialize credential cipher (must run before any task is loaded from DB).
  try {
    await CredentialCipher.instance.init();
    InternalMcpEntry.encryptor = CredentialCipher.instance.encryptParams;
    InternalMcpEntry.decryptor = CredentialCipher.instance.decryptParams;
    ServerApiClient.logCallback = log.warning;
    log.info('CredentialCipher and API Client delegates initialized');
  } catch (e) {
    log.error('Failed to initialize CredentialCipher/delegates: $e');
  }

  // Pre-load settings from secure storage.
  try {
    await LlmSettingsService.instance.load();
    log.info('LLM settings loaded');
  } catch (e) {
    log.error('Failed to load LLM settings: $e');
  }

  try {
    await DataSourcesSettingsService.instance.load();
    log.info('Data source settings loaded');
  } catch (e) {
    log.error('Failed to load data source settings: $e');
  }

  // Clean up task output files older than the configured retention period.
  // Must run AFTER AppPreferencesService is loaded.
  try {
    await AppPreferencesService.instance.load();
    log.info('App preferences loaded');
  } catch (e) {
    log.error('Failed to load app preferences: $e');
  }

  try {
    await TaskOutputFileService.cleanupOldFiles();
    log.info('Task output file cleanup done');
  } catch (e) {
    log.warning('Task output file cleanup failed: $e');
  }

  // Repeat cleanup every hour while the app is running.
  Timer.periodic(const Duration(hours: 1), (_) {
    TaskOutputFileService.cleanupOldFiles();
  });

  try {
    await ExternalToolsSettingsService.instance.load();
    log.info('External tools settings loaded');
  } catch (e) {
    log.error('Failed to load external tools settings: $e');
  }

  try {
    await ScriptLibraryService.instance.load();
    log.info('Script library loaded');
  } catch (e) {
    log.error('Failed to load script library: $e');
  }

  try {
    await PowershellScriptService.instance.load();
    log.info('PowerShell script library loaded');
  } catch (e) {
    log.error('Failed to load PowerShell script library: $e');
  }

  try {
    await LocalShellScriptService.instance.load();
    log.info('Local shell script library loaded');
  } catch (e) {
    log.error('Failed to load local shell script library: $e');
  }

  // Initialise the free-trial window stored in DuckDB._sys_meta.
  // Must run after DuckDbService is ready.
  // Initialize local notifications (Android + iOS).
  try {
    await NotificationService.instance.init();
    if (!kIsWeb && Platform.isAndroid) {
      await NotificationService.instance.requestAndroidPermission();
    }
    log.info('Notification service initialized');
  } catch (e) {
    log.error('Failed to initialize notification service: $e');
  }

  // Initialize WorkManager for background scheduling (Android + iOS).
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    try {
      await Workmanager().initialize(workManagerCallbackDispatcher);
      log.info('WorkManager initialized');
    } catch (e) {
      log.error('Failed to initialize WorkManager: $e');
    }
  }

  // Initialize AndroidAlarmManager for exact/wakeup alarms (fires when app is closed).
  if (!kIsWeb && Platform.isAndroid) {
    try {
      await AndroidAlarmManager.initialize();
      log.info('AndroidAlarmManager initialized');
    } catch (e) {
      log.error('Failed to initialize AndroidAlarmManager: $e');
    }
  }

  // Initialize Windows tray + startup.
  if (!kIsWeb && Platform.isWindows) {
    try {
      await WindowsTrayService.instance.init(appName: 'TealKit');
      log.info('Windows tray service initialized');
    } catch (e) {
      log.error('Failed to initialize tray service: $e');
    }
  }

  // Sync all enabled tasks to the scheduler.
  try {
    final prefs = await SharedPreferences.getInstance();
    final isRemoteMode = (prefs.getString('server_mode') ?? 'local') == 'remote';
    if (isRemoteMode) {
      await appScheduler.cancelAll();
      log.info('Scheduler disabled locally because remote mode is active');
    } else {
      final tasks = await TaskDatabaseService().getAllTasks();
      await appScheduler.syncAllTasks(tasks);
      log.info('Scheduler synced ${tasks.where((t) => t.enabled).length} enabled tasks');
    }
  } catch (e) {
    log.error('Failed to sync scheduler: $e');
  }

  // Re-register the website auto-index alarm so it survives app updates / reinstalls.
  try {
    final websiteIndexCron = DataSourcesSettingsService.instance.websiteIndexCron;
    await scheduleWebsiteIndexAlarm(websiteIndexCron);
    if (websiteIndexCron.isNotEmpty) {
      log.info('Website auto-index alarm registered (cron: $websiteIndexCron)');
    }
  } catch (e) {
    log.error('Failed to register website auto-index alarm: $e');
  }

  try {
    final info = await PackageInfo.fromPlatform();
    _appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {
    _appVersion = '1.0.0';
  }

  // Load GitHub MCP server library from DuckDB and register active servers.
  // Must run after DuckDbService is initialized.
  try {
    await GithubMcpLibraryService.instance.load();
    InternalMcpRegistry().registerGithubMcpServers();
    log.info('GitHub MCP library loaded (${GithubMcpLibraryService.instance.activeServers.length} active)');
  } catch (e) {
    log.error('Failed to load GitHub MCP library: $e');
  }

  // Trigger background skill generation for built-in tools (fire-and-forget).
  unawaited(FunctionHintGenerationService.instance.ensureSkillsForBuiltInTools());

  runApp(const ProviderScope(child: MobileAIAgentApp()));
}

class MobileAIAgentApp extends StatefulWidget {
  const MobileAIAgentApp({super.key});

  @override
  State<MobileAIAgentApp> createState() => _MobileAIAgentAppState();
}

class _MobileAIAgentAppState extends State<MobileAIAgentApp> with WidgetsBindingObserver {
  Timer? _foregroundPingTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPing();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPing();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPing();
    } else {
      _stopPing();
      // On detached (app terminated) or hidden (desktop window closed), close
      // DuckDB so the WAL is checkpointed before the process exits.
      if (state == AppLifecycleState.detached || state == AppLifecycleState.hidden) {
        DuckDbService().close().catchError((_) {});
      }
    }
  }

  /// Writes a liveness timestamp every 30 s while the app is in the foreground.
  /// The background isolate treats the app as active only if the stamp is recent.
  void _startPing() {
    _writePing();
    _foregroundPingTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => _writePing());
  }

  void _stopPing() {
    _foregroundPingTimer?.cancel();
    _foregroundPingTimer = null;
    SharedPreferences.getInstance().then((p) => p.remove('app_is_foreground')).catchError((_) => false);
  }

  void _writePing() {
    SharedPreferences.getInstance()
        .then((p) => p.setInt('app_is_foreground', DateTime.now().millisecondsSinceEpoch))
        .catchError((_) => false);
  }

  @override
  Widget build(BuildContext context) {
    // Listen directly on the singleton so that theme / locale changes
    // immediately rebuild the MaterialApp without requiring ChangeNotifierProvider
    // (which was removed in Riverpod 3.x).
    return ListenableBuilder(
      listenable: AppPreferencesService.instance,
      builder: (_, _) {
        final prefs = AppPreferencesService.instance;
        return Consumer(
          builder: (_, ref, _) {
            final isServerMode = ref.watch(serverModeProvider).value?.isRemote ?? false;
            return MaterialApp(
              title: 'TealKit',
              debugShowCheckedModeBanner: false,
              theme: isServerMode ? AppTheme.serverLightTheme : AppTheme.lightTheme,
              darkTheme: isServerMode ? AppTheme.serverDarkTheme : AppTheme.darkTheme,
              themeMode: prefs.themeMode,
              locale: Locale(prefs.locale),
              localizationsDelegates: L.localizationsDelegates,
              supportedLocales: L.supportedLocales,
              home: const HomeScreen(),
            );
          },
        );
      },
    );
  }
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _selectedScreenIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final mode = await ref.read(serverModeProvider.future);
      // Startup reconnect gate:
      // If the app was last used in server mode, route to server settings first
      // so the user explicitly reconnects before continuing.
      if (mode.isRemote && mounted) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServerSettingsScreen()));
        return;
      }
      // Check if LLM is configured; if not, show warning popup and redirect to settings.
      if (mounted) {
        await _checkAndPromptConfiguration();
        await _checkAndPromptSkillGeneration();
      }
    });
  }

  Future<void> _checkAndPromptConfiguration() async {
    final settings = LlmSettingsService.instance;
    if (!settings.isLoaded) await settings.load();
    if (settings.isConfigured) return;

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange[600], size: 24),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Configuration Required'),
            ),
          ],
        ),
        content: const Text(
          'Welcome to TealKit! To begin using the playground and running autonomous agents, '
          'you need to configure an AI model provider (such as OpenAI, Anthropic, Gemini, or local models).\n\n'
          'You will now be redirected to Settings to set this up.',
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (mounted) {
      final screenWidth = MediaQuery.sizeOf(context).width;
      if (screenWidth > 1200) {
        setState(() {
          _selectedScreenIndex = 2; // Redirect to Settings screen in desktop view
        });
      } else {
        // On mobile/compact mode, push the StartupWizardScreen
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StartupWizardScreen()),
        );
      }
    }
  }

  /// If LLM is ready and no skills exist yet, offer the user a quick-start
  /// skill-generation dialog.  Safe to call every cold start — it no-ops once
  /// skills are present.
  Future<void> _checkAndPromptSkillGeneration() async {
    final settings = LlmSettingsService.instance;
    if (!settings.isLoaded) await settings.load();
    if (!settings.isConfigured) return; // LLM not set up — nothing to generate

    final existing = await FunctionHintDatabaseService().getAll();
    if (existing.isNotEmpty) return; // already have skills
    if (!mounted) return;

    final doGenerate = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.auto_awesome, color: AppTheme.primaryBlue, size: 22),
            const SizedBox(width: 8),
            const Text('Generate Tool Skills'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'No tool skills have been generated yet.\n\n'
              'Tool skills teach the AI when and how to use each tool correctly. '
              'Generate them now from your registered tools?',
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.toll_outlined, color: Colors.amber, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Skills are generated by your configured LLM — tokens will be used.', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: const Text('Generate Now'),
          ),
        ],
      ),
    );

    if (doGenerate == true && mounted) {
      await FunctionHintsScreen.show(context, autoRebuild: true);
    }
  }

  Future<void> _onServerModeToggled(bool toRemote) async {
    if (!toRemote) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Switch To Local Mode'),
          content: const Text(
            'You are switching to local mode. Agents, schedules, and settings will use the local device database. '
            'The remote server database stays separate and is not synchronized.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Switch')),
          ],
        ),
      );
      if (confirmed != true) return;
      await ref.read(serverModeProvider.notifier).disconnect();
      // Clear the active task so its stale server-proxied LLMService is discarded.
      // It will be re-initialized with local settings when the user next opens the playground.
      ref.read(activeTaskProvider.notifier).clearTask();
      ref.invalidate(taskRepositoryProvider);
      ref.invalidate(taskListProvider);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServerSettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final theme = Theme.of(context);
    final isDE = Localizations.localeOf(context).languageCode == 'de';
    final guideUrl = isDE ? 'https://lschaffer.github.io/tealkit/guide/de/' : 'https://lschaffer.github.io/tealkit/guide/';
    final llmSettings = ref.watch(llmSettingsProvider);
    final dsSettings = ref.watch(dataSourcesSettingsProvider);
    final externalToolsSettings = ref.watch(externalToolsSettingsProvider);
    final serverModeAsync = ref.watch(serverModeProvider);
    final merged = Listenable.merge([
      llmSettings,
      dsSettings,
      externalToolsSettings,
      AppPreferencesService.instance,
    ]);
    final isRemote = serverModeAsync.value?.isRemote ?? false;
    final uiStyle = AppPreferencesService.instance.uiStyle;

    return ListenableBuilder(
      listenable: merged,
      builder: (context, _) {
        final llmReady = llmSettings.isConfigured;
        final screenWidth = MediaQuery.sizeOf(context).width;

        if (screenWidth > 1200) {
          final sidebarOpen = ref.watch(sidebarOpenProvider);
          final sidebarSticky = ref.watch(sidebarStickyProvider);
          final activeIndex = llmReady ? _selectedScreenIndex : 2;
          final isDark = theme.brightness == Brightness.dark;

          void closeSidebarIfNeeded() {
            if (!ref.read(sidebarStickyProvider)) {
              ref.read(sidebarOpenProvider.notifier).state = false;
            }
          }

          Widget rightScreen;
          if (activeIndex == 0) {
            rightScreen = const PlaygroundScreen();
          } else if (activeIndex == 1) {
            rightScreen = const WorkflowListScreen();
          } else {
            rightScreen = const StartupWizardScreen();
          }

          return Scaffold(
            body: ParticleBackground(
              animate: true,
              child: SafeArea(
                child: Stack(
                  children: [
                    // Right content view (takes full width, or pushed right if sticky & open)
                    Positioned(
                      left: (sidebarSticky && sidebarOpen) ? 190 : 0,
                      right: 0,
                      top: 0,
                      bottom: 0,
                      child: rightScreen,
                    ),

                    // Scrim overlay behind the sidebar (only when NOT sticky)
                    if (!sidebarSticky)
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: !sidebarOpen,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 250),
                            opacity: sidebarOpen ? 1.0 : 0.0,
                            child: GestureDetector(
                              onTap: () => ref.read(sidebarOpenProvider.notifier).state = false,
                              child: Container(
                                color: Colors.black54,
                              ),
                            ),
                          ),
                        ),
                      ),

                    // Left Sidebar (overlapping standard layout or sticked to left)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                        width: sidebarOpen ? 190 : 0,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0F172A).withValues(alpha: 0.92) : Colors.white.withValues(alpha: 0.95),
                          border: Border(
                            right: BorderSide(
                              color: isDark ? Colors.white12 : Colors.black12,
                              width: 1,
                            ),
                          ),
                          boxShadow: sidebarOpen
                              ? [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.35),
                                    blurRadius: 16,
                                    offset: const Offset(4, 0),
                                  )
                                ]
                              : null,
                        ),
                        child: ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
                            child: OverflowBox(
                              alignment: Alignment.topLeft,
                              minWidth: 190,
                              maxWidth: 190,
                              child: SizedBox(
                                width: 190,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      // Logo, title, and sticky pin icon
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 12),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Image.asset(
                                                    'assets/icons/app_icon_transparent.png',
                                                    width: 48,
                                                    height: 48,
                                                  ),
                                                  const SizedBox(height: 16),
                                                  Text(
                                                    'TealKit',
                                                    style: theme.textTheme.titleLarge?.copyWith(
                                                      color: isDark ? Colors.white : const Color(0xFF1F2937),
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    'Local AI Task Orchestrator',
                                                    style: theme.textTheme.bodySmall?.copyWith(
                                                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            IconButton(
                                              icon: Icon(
                                                sidebarSticky ? Icons.push_pin : Icons.push_pin_outlined,
                                                size: 18,
                                                color: sidebarSticky
                                                    ? const Color(0xFF7C3AED)
                                                    : (isDark ? Colors.white54 : Colors.black54),
                                              ),
                                              tooltip: sidebarSticky ? 'Unpin menu' : 'Pin menu',
                                              onPressed: () {
                                                ref.read(sidebarStickyProvider.notifier).state = !sidebarSticky;
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 32),

                                      // Menu navigation items
                                      _SidebarButton(
                                        icon: Icons.science_outlined,
                                        label: l.playground,
                                        selected: activeIndex == 0,
                                        enabled: llmReady,
                                        onTap: () {
                                          setState(() => _selectedScreenIndex = 0);
                                          closeSidebarIfNeeded();
                                        },
                                      ),
                                      _SidebarButton(
                                        icon: Icons.access_time_outlined,
                                        label: l.tasks,
                                        selected: activeIndex == 1,
                                        enabled: llmReady,
                                        onTap: () {
                                          setState(() => _selectedScreenIndex = 1);
                                          closeSidebarIfNeeded();
                                        },
                                      ),
                                      _SidebarButton(
                                        icon: Icons.settings,
                                        label: l.settings,
                                        selected: activeIndex == 2,
                                        enabled: true,
                                        onTap: () {
                                          setState(() => _selectedScreenIndex = 2);
                                          closeSidebarIfNeeded();
                                        },
                                      ),

                                      const Spacer(),

                                      // Theme switcher, About, User Guide
                                      _SidebarButton(
                                        icon: AppPreferencesService.instance.themeModeIcon,
                                        label: 'Theme',
                                        subtitle: 'Current: ${AppPreferencesService.instance.themeModeLabel}',
                                        selected: false,
                                        enabled: true,
                                        onTap: () {
                                          AppPreferencesService.instance.cycleTheme();
                                          closeSidebarIfNeeded();
                                        },
                                      ),
                                      _SidebarButton(
                                        icon: Icons.info_outline,
                                        label: '${l.aboutTitle} ${l.appTitle}',
                                        selected: false,
                                        enabled: true,
                                        onTap: () {
                                          _showAboutDialog(context);
                                          closeSidebarIfNeeded();
                                        },
                                      ),

                                      const SizedBox(height: 8),

                                      // Compact Mode toggle at the bottom of the sidebar
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                        child: _ModeToggle(
                                          isRemote: isRemote,
                                          onChanged: _onServerModeToggled,
                                          width: 174,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        if (uiStyle == 'classic') {
          return Scaffold(
            body: ParticleBackground(
              animate: true,
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset('assets/icons/app_icon_transparent.png', width: 96, height: 96),
                        const SizedBox(height: 24),
                        Text(
                          l.appTitle,
                          style: theme.textTheme.headlineLarge?.copyWith(color: AppTheme.primaryBlue, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l.appSubtitle,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.brightness == Brightness.dark ? AppTheme.textSecondaryDark : AppTheme.textSecondaryLight,
                          ),
                        ),
                        const SizedBox(height: 32),

                        // ── Mode toggle ────────────────────────────────────
                        _ModeToggle(isRemote: isRemote, onChanged: _onServerModeToggled),

                        const SizedBox(height: 32),
                        SizedBox(
                          width: 260,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Playground button
                              FilledButton.icon(
                                onPressed: llmReady
                                    ? () {
                                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlaygroundScreen()));
                                      }
                                    : null,
                                icon: const Icon(Icons.science_outlined),
                                label: Text(l.playground),
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(52),
                                  backgroundColor: AppTheme.primaryBlue,
                                  disabledBackgroundColor: theme.disabledColor.withAlpha(40),
                                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                ),
                              ),
                              const SizedBox(height: 12),

                              // Tasks button
                              FilledButton.icon(
                                onPressed: llmReady
                                    ? () {
                                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WorkflowListScreen()));
                                      }
                                    : null,
                                icon: const Icon(Icons.task_alt),
                                label: Text(l.tasks),
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(52),
                                  backgroundColor: AppTheme.accent,
                                  disabledBackgroundColor: theme.disabledColor.withAlpha(40),
                                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // ── "First Step" / "Settings" button ──
                        const SizedBox(height: 24),
                        if (!llmReady) ...[
                          Text(
                            l.configureLlmFirst,
                            style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warning),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                        ],
                        SizedBox(
                          width: 260,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StartupWizardScreen()));
                            },
                            icon: Icon(llmReady ? Icons.settings : Icons.flag_outlined, size: 18, color: llmReady ? null : AppTheme.warning),
                            label: Text(
                              llmReady ? l.settings : l.firstStep,
                              style: TextStyle(
                                color: llmReady ? null : AppTheme.warning,
                                fontWeight: llmReady ? FontWeight.normal : FontWeight.bold,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(44),
                              side: llmReady ? null : BorderSide(color: AppTheme.warning, width: 2),
                            ),
                          ),
                        ),

                        // ── Footer links ──
                        const SizedBox(height: 24),
                        TextButton.icon(
                          onPressed: () => launchUrl(Uri.parse(guideUrl), mode: LaunchMode.externalApplication),
                          icon: const Icon(Icons.menu_book_outlined, size: 16),
                          label: Text(l.userGuide),
                          style: TextButton.styleFrom(foregroundColor: Colors.grey[500], textStyle: const TextStyle(fontSize: 13)),
                        ),
                        const SizedBox(height: 4),
                        TextButton.icon(
                          onPressed: () => _showAboutDialog(context),
                          icon: const Icon(Icons.info_outline, size: 16),
                          label: Text(l.aboutTitle),
                          style: TextButton.styleFrom(foregroundColor: Colors.grey[500], textStyle: const TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        // Modern Premium Layout (Glassmorphism & Gradients)
        final isDark = theme.brightness == Brightness.dark;
        final primaryAccent = const Color(0xFF7C3AED); // Violet
        final secondaryAccent = const Color(0xFF06B6D4); // Cyan
        final tertiaryAccent = const Color(0xFF34D399); // Mint
        final gradient1 = [primaryAccent, secondaryAccent];
        final gradient2 = [secondaryAccent, tertiaryAccent];

        return Scaffold(
          body: ParticleBackground(
            animate: true,
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 400),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.black.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.35),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 30,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset('assets/icons/app_icon_transparent.png', width: 90, height: 90),
                        const SizedBox(height: 20),
                        Text(
                          l.appTitle,
                          style: theme.textTheme.headlineLarge?.copyWith(
                            color: isDark ? Colors.white : const Color(0xFF1F2937),
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          l.appSubtitle,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: isDark ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 28),

                        // Mode toggle
                        _ModeToggle(isRemote: isRemote, onChanged: _onServerModeToggled),
                        const SizedBox(height: 28),

                        // Actions
                        SizedBox(
                          width: 260,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _ModernMenuButton(
                                onPressed: llmReady
                                    ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlaygroundScreen()))
                                    : null,
                                icon: Icons.science_outlined,
                                label: l.playground,
                                gradientColors: gradient1,
                              ),
                              const SizedBox(height: 12),
                              _ModernMenuButton(
                                onPressed: llmReady
                                    ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WorkflowListScreen()))
                                    : null,
                                icon: Icons.task_alt,
                                label: l.tasks,
                                gradientColors: gradient2,
                              ),
                            ],
                          ),
                        ),

                        // Setup / Settings
                        const SizedBox(height: 24),
                        if (!llmReady) ...[
                          Text(
                            l.configureLlmFirst,
                            style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warning),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                        ],
                        SizedBox(
                          width: 260,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StartupWizardScreen()));
                            },
                            icon: Icon(llmReady ? Icons.settings : Icons.flag_outlined, size: 18, color: llmReady ? null : AppTheme.warning),
                            label: Text(
                              llmReady ? l.settings : l.firstStep,
                              style: TextStyle(
                                color: llmReady ? null : AppTheme.warning,
                                fontWeight: llmReady ? FontWeight.normal : FontWeight.bold,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              side: BorderSide(
                                color: llmReady
                                    ? (isDark ? Colors.white24 : Colors.black26)
                                    : AppTheme.warning,
                                width: llmReady ? 1 : 2,
                              ),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                            ),
                          ),
                        ),

                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            TextButton.icon(
                              onPressed: () => launchUrl(Uri.parse(guideUrl), mode: LaunchMode.externalApplication),
                              icon: const Icon(Icons.menu_book_outlined, size: 15),
                              label: Text(l.userGuide),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.grey[500],
                                textStyle: const TextStyle(fontSize: 12),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () => _showAboutDialog(context),
                              icon: const Icon(Icons.info_outline, size: 15),
                              label: Text(l.aboutTitle),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.grey[500],
                                textStyle: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Mode toggle widget ────────────────────────────────────────────────────────

class _ModeToggle extends StatelessWidget {
  final bool isRemote;
  final Future<void> Function(bool toRemote) onChanged;
  final double width;

  const _ModeToggle({
    required this.isRemote,
    required this.onChanged,
    this.width = 260,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: width,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: [
          _ModeChip(selected: !isRemote, icon: Icons.storage_outlined, label: 'Local', onTap: () => onChanged(false)),
          _ModeChip(selected: isRemote, icon: Icons.dns_outlined, label: 'Server', onTap: () => onChanged(true)),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ModeChip({required this.selected, required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected 
                ? (isDark ? cs.primary : const Color(0xFF7C3AED)) 
                : Colors.transparent, 
            borderRadius: BorderRadius.circular(10),
            boxShadow: selected && !isDark
                ? [
                    BoxShadow(
                      color: const Color(0xFF7C3AED).withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: selected ? cs.onPrimary : cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: selected ? cs.onPrimary : cs.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Modern Menu Button ───────────────────────────────────────────────────────

class _ModernMenuButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final List<Color> gradientColors;

  const _ModernMenuButton({
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.gradientColors,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: enabled
            ? LinearGradient(
                colors: gradientColors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: enabled ? null : theme.disabledColor.withValues(alpha: 0.12),
        boxShadow: enabled
            ? [
                BoxShadow(
                  color: gradientColors.first.withValues(alpha: 0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                )
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(30),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  color: enabled ? Colors.white : theme.disabledColor,
                ),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: enabled ? Colors.white : theme.disabledColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Sidebar Button Widget ────────────────────────────────────────────────────

class _SidebarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _SidebarButton({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    Color textColor;
    Color iconColor;
    BoxDecoration decoration;

    if (!enabled) {
      textColor = Colors.grey;
      iconColor = Colors.grey;
      decoration = const BoxDecoration();
    } else if (selected) {
      textColor = Colors.white;
      iconColor = Colors.white;
      decoration = BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const LinearGradient(
          colors: [Color(0xFF7C3AED), Color(0xFF06B6D4)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF7C3AED).withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          )
        ],
      );
    } else {
      textColor = isDark ? Colors.white70 : Colors.black87;
      iconColor = isDark ? Colors.white70 : Colors.black87;
      decoration = const BoxDecoration();
    }

    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        decoration: decoration,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              child: Row(
                children: [
                  Icon(icon, color: iconColor, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: textColor,
                            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark ? Colors.white38 : Colors.black38,
                              fontSize: 10,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

