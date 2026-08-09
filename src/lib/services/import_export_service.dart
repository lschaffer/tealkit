import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../database/task_database_service_duckdb.dart';
import '../models/workflow_task.dart';
import '../models/mcp_models.dart';
import '../models/skill_def.dart';
import 'skill_def_database_service.dart';
import 'app_logger.dart';
import 'external_tools_settings_service.dart';
import 'js_tool_library_service.dart';
import 'shell_script_service.dart';

/// Export / import service for tasks and external MCP server configurations.
///
/// – Export  : collects all tasks + selected MCP servers, strips sensitive
///             credential fields, writes a JSON file, and opens the OS save
///             dialog (desktop) or the Downloads folder (mobile).
///
/// – Import  : opens the OS file-picker, parses the JSON, upserts tasks and
///             MCP server definitions (credentials are NOT modified because
///             they are not present in the import file).
class ImportExportService {
  ImportExportService._();

  // ─────────────────────────────────────────────────────────────────────────
  // Sensitive field names that are stripped from the export JSON.
  // ─────────────────────────────────────────────────────────────────────────

  static const _sensitiveKeys = <String>{
    'api_key',
    'api_password',
    'password',
    'access_token',
    'refresh_token',
    'client_secret',
    'oauth_token',
    'id_token',
    'bearer_token',
    'smithery_api_key',
  };

  // ─────────────────────────────────────────────────────────────────────────
  // Export
  // ─────────────────────────────────────────────────────────────────────────

  /// Exports all tasks and selected external MCP servers to a JSON file.
  ///
  /// Sensitive fields (API keys, passwords, tokens) are automatically stripped.
  ///
  /// On desktop the OS "Save As" dialog is opened.
  /// On Android / iOS the file is written silently to the Downloads folder.
  ///
  /// Returns `({String? error, String? savedPath})`.
  /// On desktop success both fields are null (dialog handled the path).
  /// On mobile success `savedPath` holds the full file path.
  /// On error `error` contains the message.
  static Future<({String? error, String? savedPath})> exportSettings() async {
    try {
      // ── 1. Collect data ──────────────────────────────────────────────────
      final tasks = await TaskDatabaseService().getAllTasks();
      final externalService = ExternalToolsSettingsService.instance;

      final exportPayload = <String, dynamic>{
        'export_version': 2,
        'exported_at': DateTime.now().toIso8601String(),
        'tasks': tasks.map((t) => _sanitize(t.toJson())).toList(),
        'external_mcp_servers': externalService.selectedServers.map((s) => _sanitize(s.toJson())).toList(),
        'catalog_base_url': externalService.catalogBaseUrl,
        'scripts': ScriptLibraryService.instance.exportToJson(),
        'js_tools': JsToolLibraryService.instance.exportToJson(),
        'skills': (await SkillDefDatabaseService.instance.getAllSkills()).map((s) => _sanitize(s.toJson())).toList(),
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(exportPayload);
      final jsonBytes = utf8.encode(jsonString);
      final timestamp = _fileTimestamp();
      const fileName = 'tealkit_backup';
      final fullName = '${fileName}_$timestamp.json';

      // ── 2. Write / offer file ────────────────────────────────────────────
      if (!kIsWeb) {
        final isMobile = Platform.isAndroid || Platform.isIOS;
        // Show directory chooser on all platforms; fall back to Downloads/Docs on mobile if cancelled
        String? dirPath = await FilePicker.getDirectoryPath(dialogTitle: 'Choose Export Directory');
        if (dirPath == null) {
          if (isMobile) {
            // Mobile fallback: save silently to Downloads / Documents
            if (Platform.isAndroid) {
              final downloads = Directory('/storage/emulated/0/Download');
              dirPath = await downloads.exists() ? downloads.path : (await getApplicationDocumentsDirectory()).path;
            } else {
              dirPath = (await getApplicationDocumentsDirectory()).path;
            }
          } else {
            return (error: null, savedPath: null); // user cancelled on desktop
          }
        }
        final filePath = '$dirPath${Platform.pathSeparator}$fullName';
        await File(filePath).writeAsBytes(jsonBytes);
        log.info('[Export] Saved to $filePath');
        return (error: null, savedPath: isMobile ? filePath : null);
      }
      return (error: 'Export not supported on this platform.', savedPath: null);
    } catch (e, st) {
      log.error('[Export] failed: $e\n$st');
      return (error: e.toString(), savedPath: null);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Import
  // ─────────────────────────────────────────────────────────────────────────

  /// Opens the OS file-picker and imports tasks and MCP server definitions
  /// from the selected JSON file.
  ///
  /// Returns an [ImportResult] describing what was imported.
  /// Throws / returns an error message if something goes wrong.
  static Future<ImportResult> importSettings() async {
    // ── 1. Pick file ─────────────────────────────────────────────────────
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Select TealKit Backup',
      type: FileType.custom,
      allowedExtensions: ['json'],
      allowMultiple: false,
      withData: true,
    );

    if (picked == null || picked.files.isEmpty) {
      return ImportResult.cancelled();
    }

    try {
      // ── 2. Read JSON ────────────────────────────────────────────────────
      final file = picked.files.first;
      final String content;
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        return ImportResult.error('Could not read file content.');
      }

      final json = jsonDecode(content);
      if (json is! Map<String, dynamic>) {
        return ImportResult.error('Invalid backup file format.');
      }

      final rawVersion = json['export_version'];
      final backupVersion = rawVersion is int ? rawVersion : int.tryParse(rawVersion?.toString() ?? '') ?? 1;
      log.info('[Import] Backup version detected: v$backupVersion');

      // Backward compatibility:
      // - v1 backups may not include scripts/js_tools keys
      // - v2 backups include scripts + js_tools

      int importedTasks = 0;
      int importedServers = 0;
      final errors = <String>[];

      // ── 3. Import tasks ─────────────────────────────────────────────────
      final rawTasks = json['tasks'];
      if (rawTasks is List) {
        final db = TaskDatabaseService();
        for (final rawTask in rawTasks) {
          if (rawTask is! Map<String, dynamic>) continue;
          try {
            final task = WorkflowTask.fromJson(rawTask);
            await db.saveTask(task);
            importedTasks++;
          } catch (e) {
            log.warning('[Import] Skipped task: $e');
            errors.add('Task skipped: $e');
          }
        }
        log.info('[Import] Imported $importedTasks tasks');
      }

      // ── 4. Import external MCP servers ──────────────────────────────────
      final rawServers = json['external_mcp_servers'];
      if (rawServers is List) {
        final extService = ExternalToolsSettingsService.instance;
        for (final rawServer in rawServers) {
          if (rawServer is! Map<String, dynamic>) continue;
          try {
            final server = McpToolConfig.fromJson(rawServer);
            await extService.upsertSelectedServer(server);
            importedServers++;
          } catch (e) {
            log.warning('[Import] Skipped MCP server: $e');
            errors.add('Server skipped: $e');
          }
        }
        log.info('[Import] Imported $importedServers MCP servers');
      }

      // ── 5. Import shell scripts ─────────────────────────────────────────
      int importedScripts = 0;
      final rawScripts = json['scripts'];
      if (rawScripts is List) {
        final svc = ScriptLibraryService.instance;
        await svc.load();
        final count = await svc.importFromJson(rawScripts.whereType<Map<String, dynamic>>().toList());
        importedScripts = count;
        log.info('[Import] Imported $importedScripts scripts');
      }

      // ── 6. Import JS tools ─────────────────────────────────────────────
      int importedJsTools = 0;
      final rawJsTools = json['js_tools'];
      if (rawJsTools is List) {
        final svc = JsToolLibraryService.instance;
        await svc.load();
        final count = await svc.importFromJson(rawJsTools.whereType<Map<String, dynamic>>().toList());
        importedJsTools = count;
        log.info('[Import] Imported $importedJsTools JS tools');
      }

      // ── 7. Import Skills ───────────────────────────────────────────────
      int importedSkills = 0;
      final rawSkillDefs = json['skills'] ?? json['skill_defs'];
      if (rawSkillDefs is List) {
        for (final rawSkill in rawSkillDefs) {
          if (rawSkill is! Map<String, dynamic>) continue;
          try {
            final skill = SkillDef.fromJson(rawSkill);
            await SkillDefDatabaseService.instance.saveSkill(skill);
            importedSkills++;
          } catch (e) {
            log.warning('[Import] Skipped skill: $e');
          }
        }
        log.info('[Import] Imported $importedSkills skills');
      }

      return ImportResult.success(
        importedTasks: importedTasks,
        importedServers: importedServers,
        importedScripts: importedScripts,
        importedJsTools: importedJsTools,
        errors: errors,
      );
    } catch (e, st) {
      log.error('[Import] failed: $e\n$st');
      return ImportResult.error(e.toString());
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Recursively strips [_sensitiveKeys] from a nested JSON map.
  static Map<String, dynamic> _sanitize(Map<String, dynamic> input) {
    final result = <String, dynamic>{};
    for (final entry in input.entries) {
      if (_sensitiveKeys.contains(entry.key)) continue;
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        result[entry.key] = _sanitize(value);
      } else if (value is List) {
        result[entry.key] = _sanitizeList(value);
      } else {
        result[entry.key] = value;
      }
    }
    return result;
  }

  static List<dynamic> _sanitizeList(List<dynamic> list) {
    return list.map((item) {
      if (item is Map<String, dynamic>) return _sanitize(item);
      if (item is List) return _sanitizeList(item);
      return item;
    }).toList();
  }

  static String _fileTimestamp() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Playground session export / import
  // ─────────────────────────────────────────────────────────────────────────

  /// Internal MCP types that are desktop-only (require local Python/Node.js
  /// installation) and therefore cannot be restored on mobile.
  static const _desktopOnlyTypePrefix = 'gh_mcp_';
  static const _desktopOnlyTypes = <String>{'py_bridge', 'ps_bridge'};

  static bool _isDesktopOnlyType(String type) => type.startsWith(_desktopOnlyTypePrefix) || _desktopOnlyTypes.contains(type);

  /// Exports the current playground session to a JSON file chosen by the user.
  ///
  /// [sessionName]          - user-supplied filename (without extension).
  /// [systemPrompt]         - the system prompt text.
  /// [initialPrompt]        - the initial prompt text.
  /// [selectedMcpTypes]     - all selected internal MCP types (desktop-only are noted but stripped).
  /// [mcpInitParams]        - init params keyed by MCP type.
  /// [externalServerUrls]   - selected external (remote) MCP server URLs.
  /// [messages]             - chat messages to include.
  ///
  /// Returns `({String? error, String? savedPath})`. `savedPath` is set on
  /// mobile success; both null on desktop success (dialog managed path).
  static Future<({String? error, String? savedPath})> exportPlaygroundSession({
    required String sessionName,
    required String systemPrompt,
    required String initialPrompt,
    required Set<String> selectedMcpTypes,
    required Map<String, Map<String, dynamic>> mcpInitParams,
    required Set<String> externalServerUrls,
    required List<ChatMessage> messages,
  }) async {
    try {
      // Split portable vs desktop-only tool types
      final portableTypes = selectedMcpTypes.where((t) => !_isDesktopOnlyType(t)).toList();
      final skippedTypes = selectedMcpTypes.where(_isDesktopOnlyType).toList();

      // Strip init params for desktop-only keys (don't export their config)
      final portableInitParams = {
        for (final e in mcpInitParams.entries)
          if (!_isDesktopOnlyType(e.key)) e.key: e.value,
      };

      // Only export external server definitions (no credentials in URL usually,
      // but sanitise just in case)
      final extService = ExternalToolsSettingsService.instance;
      final serverDefs = externalServerUrls.map((url) {
        final def = extService.selectedServers.where((s) => s.serverUrl == url).firstOrNull;
        if (def != null) return _sanitize(def.toJson());
        return <String, dynamic>{'serverUrl': url};
      }).toList();

      // Export JS tool definitions used by this session (if js_bridge active)
      List<Map<String, dynamic>> jsTools = [];
      if (portableTypes.contains('js_bridge')) {
        await JsToolLibraryService.instance.load();
        jsTools = JsToolLibraryService.instance.exportToJson();
      }

      final payload = <String, dynamic>{
        'export_version': 1,
        'session_type': 'playground_session',
        'exported_at': DateTime.now().toIso8601String(),
        'session_name': sessionName,
        'system_prompt': systemPrompt,
        'initial_prompt': initialPrompt,
        'internal_mcp_types': portableTypes,
        'mcp_init_params': portableInitParams,
        'external_mcp_servers': serverDefs,
        'messages': messages
            .where((m) => m.role != ChatRole.system) // skip injected system messages
            .map((m) => m.toJson())
            .toList(),
        if (jsTools.isNotEmpty) 'js_tools': jsTools,
        if (skippedTypes.isNotEmpty) 'skipped_desktop_only_tools': skippedTypes,
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(payload);
      final jsonBytes = utf8.encode(jsonString);
      final safeName = sessionName.replaceAll(RegExp(r'[^a-zA-Z0-9_\- ]'), '_').trim();
      final fileName = safeName.isEmpty ? 'playground_session_${_fileTimestamp()}' : safeName;
      final fullName = '$fileName.json';

      if (!kIsWeb) {
        final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
        final outputPath = await FilePicker.saveFile(
          dialogTitle: 'Save Playground Session',
          fileName: fullName,
          type: FileType.custom,
          allowedExtensions: ['json'],
          bytes: isMobile ? Uint8List.fromList(jsonBytes) : null,
        );
        if (outputPath == null) return (error: null, savedPath: null); // cancelled
        if (!isMobile) {
          await File(outputPath).writeAsBytes(jsonBytes);
        }
        log.info('[Session Export] Saved to $outputPath');
        return (error: null, savedPath: isMobile ? outputPath : null);
      }
      return (error: 'Export not supported on this platform.', savedPath: null);
    } catch (e, st) {
      log.error('[Session Export] failed: $e\n$st');
      return (error: e.toString(), savedPath: null);
    }
  }

  /// Opens the OS file-picker and imports a playground session from a JSON file.
  ///
  /// Returns a [PlaygroundSessionImport] describing what was loaded.
  static Future<PlaygroundSessionImport> importPlaygroundSession() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Open Playground Session',
      type: FileType.custom,
      allowedExtensions: ['json'],
      allowMultiple: false,
      withData: true,
    );

    if (picked == null || picked.files.isEmpty) {
      return PlaygroundSessionImport.cancelled();
    }

    try {
      final file = picked.files.first;
      final String content;
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        return PlaygroundSessionImport.error('Could not read file content.');
      }

      final json = jsonDecode(content);
      if (json is! Map<String, dynamic>) {
        return PlaygroundSessionImport.error('Invalid session file format.');
      }

      if (json['session_type'] != 'playground_session') {
        return PlaygroundSessionImport.error(
          'This file is not a playground session (found type: ${json['session_type']}).\n'
          'Use "Import Backup" for full backup files.',
        );
      }

      final systemPrompt = json['system_prompt'] as String? ?? '';
      final initialPrompt = json['initial_prompt'] as String? ?? '';
      final sessionName = json['session_name'] as String? ?? '';
      final exportedAt = json['exported_at'] as String? ?? '';

      final rawTypes = json['internal_mcp_types'];
      final internalMcpTypes = rawTypes is List ? rawTypes.cast<String>().toSet() : <String>{};

      final rawInitParams = json['mcp_init_params'];
      final mcpInitParams = <String, Map<String, dynamic>>{};
      if (rawInitParams is Map) {
        for (final e in rawInitParams.entries) {
          if (e.value is Map<String, dynamic>) {
            mcpInitParams[e.key as String] = Map<String, dynamic>.from(e.value as Map);
          }
        }
      }

      // Restore external server definitions (without credentials)
      final rawServers = json['external_mcp_servers'];
      final externalServerUrls = <String>{};
      if (rawServers is List) {
        final extService = ExternalToolsSettingsService.instance;
        for (final s in rawServers) {
          if (s is! Map<String, dynamic>) continue;
          try {
            final url = s['serverUrl'] as String? ?? '';
            if (url.isEmpty) continue;
            final existing = extService.selectedServers.where((x) => x.serverUrl == url).firstOrNull;
            if (existing == null) {
              // Register the server definition (without any credentials)
              await extService.upsertSelectedServer(McpToolConfig.fromJson(s));
            }
            externalServerUrls.add(url);
          } catch (_) {}
        }
      }

      // Restore JS tools if present
      int importedJsTools = 0;
      final rawJsTools = json['js_tools'];
      if (rawJsTools is List) {
        final svc = JsToolLibraryService.instance;
        await svc.load();
        importedJsTools = await svc.importFromJson(rawJsTools.whereType<Map<String, dynamic>>().toList());
      }

      // Restore messages
      final rawMessages = json['messages'];
      final messages = <ChatMessage>[];
      if (rawMessages is List) {
        for (final m in rawMessages) {
          if (m is! Map<String, dynamic>) continue;
          try {
            messages.add(ChatMessage.fromJson(m));
          } catch (_) {}
        }
      }

      final skippedTypes = (json['skipped_desktop_only_tools'] as List?)?.cast<String>() ?? [];

      log.info(
        '[Session Import] Loaded session "$sessionName" from $exportedAt '
        '(${messages.length} messages, ${internalMcpTypes.length} tools, '
        '$importedJsTools JS tools)',
      );

      return PlaygroundSessionImport.success(
        sessionName: sessionName,
        systemPrompt: systemPrompt,
        initialPrompt: initialPrompt,
        internalMcpTypes: internalMcpTypes,
        mcpInitParams: mcpInitParams,
        externalServerUrls: externalServerUrls,
        messages: messages,
        importedJsTools: importedJsTools,
        skippedDesktopOnlyTools: skippedTypes,
      );
    } catch (e, st) {
      log.error('[Session Import] failed: $e\n$st');
      return PlaygroundSessionImport.error(e.toString());
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Result type
// ─────────────────────────────────────────────────────────────────────────────

class ImportResult {
  final bool cancelled;
  final String? error;
  final int importedTasks;
  final int importedServers;
  final int importedScripts;
  final int importedJsTools;
  final List<String> warnings;

  const ImportResult._({
    required this.cancelled,
    this.error,
    this.importedTasks = 0,
    this.importedServers = 0,
    this.importedScripts = 0,
    this.importedJsTools = 0,
    this.warnings = const [],
  });

  factory ImportResult.cancelled() => const ImportResult._(cancelled: true);

  factory ImportResult.error(String msg) => ImportResult._(cancelled: false, error: msg);

  factory ImportResult.success({
    required int importedTasks,
    required int importedServers,
    int importedScripts = 0,
    int importedJsTools = 0,
    List<String> errors = const [],
  }) => ImportResult._(
    cancelled: false,
    importedTasks: importedTasks,
    importedServers: importedServers,
    importedScripts: importedScripts,
    importedJsTools: importedJsTools,
    warnings: errors,
  );

  bool get isSuccess => !cancelled && error == null;

  String get summaryMessage {
    if (cancelled) return 'Import cancelled.';
    if (error != null) return 'Import failed: $error';
    final parts = <String>[];
    if (importedTasks > 0) parts.add('$importedTasks task${importedTasks != 1 ? 's' : ''}');
    if (importedServers > 0) parts.add('$importedServers MCP server${importedServers != 1 ? 's' : ''}');
    if (importedScripts > 0) parts.add('$importedScripts script${importedScripts != 1 ? 's' : ''}');
    if (importedJsTools > 0) parts.add('$importedJsTools JS tool${importedJsTools != 1 ? 's' : ''}');
    if (parts.isEmpty) return 'Nothing imported (file was empty or had no matching data).';
    return 'Imported: ${parts.join(', ')}.';
  }
}
// ─────────────────────────────────────────────────────────────────────────────
// Playground session import result
// ─────────────────────────────────────────────────────────────────────────────

class PlaygroundSessionImport {
  final bool cancelled;
  final String? error;
  final String sessionName;
  final String systemPrompt;
  final String initialPrompt;
  final Set<String> internalMcpTypes;
  final Map<String, Map<String, dynamic>> mcpInitParams;
  final Set<String> externalServerUrls;
  final List<ChatMessage> messages;
  final int importedJsTools;
  final List<String> skippedDesktopOnlyTools;

  const PlaygroundSessionImport._({
    required this.cancelled,
    this.error,
    this.sessionName = '',
    this.systemPrompt = '',
    this.initialPrompt = '',
    this.internalMcpTypes = const {},
    this.mcpInitParams = const {},
    this.externalServerUrls = const {},
    this.messages = const [],
    this.importedJsTools = 0,
    this.skippedDesktopOnlyTools = const [],
  });

  factory PlaygroundSessionImport.cancelled() => const PlaygroundSessionImport._(cancelled: true);

  factory PlaygroundSessionImport.error(String msg) => PlaygroundSessionImport._(cancelled: false, error: msg);

  factory PlaygroundSessionImport.success({
    required String sessionName,
    required String systemPrompt,
    required String initialPrompt,
    required Set<String> internalMcpTypes,
    required Map<String, Map<String, dynamic>> mcpInitParams,
    required Set<String> externalServerUrls,
    required List<ChatMessage> messages,
    int importedJsTools = 0,
    List<String> skippedDesktopOnlyTools = const [],
  }) => PlaygroundSessionImport._(
    cancelled: false,
    sessionName: sessionName,
    systemPrompt: systemPrompt,
    initialPrompt: initialPrompt,
    internalMcpTypes: internalMcpTypes,
    mcpInitParams: mcpInitParams,
    externalServerUrls: externalServerUrls,
    messages: messages,
    importedJsTools: importedJsTools,
    skippedDesktopOnlyTools: skippedDesktopOnlyTools,
  );

  bool get isSuccess => !cancelled && error == null;
}
