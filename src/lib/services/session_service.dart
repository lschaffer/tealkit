import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_logger.dart';

/// Represents a serialized conversation session for saving/loading.
class SessionData {
  final String version;
  final String id;
  final String title;
  final String mode;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? llmName;
  final String? llmProvider;
  final String? llmModel;
  final List<ChatMessage> messages;

  SessionData({
    this.version = '1.0',
    required this.id,
    required this.title,
    this.mode = 'code',
    required this.createdAt,
    required this.updatedAt,
    this.llmName,
    this.llmProvider,
    this.llmModel,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'id': id,
    'title': title,
    'mode': mode,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (llmName != null) 'llmName': llmName,
    if (llmProvider != null) 'llmProvider': llmProvider,
    if (llmModel != null) 'llmModel': llmModel,
    'messages': messages.map((m) => m.toJson()).toList(),
  };

  factory SessionData.fromJson(Map<String, dynamic> json) {
    final rawMsgs = (json['messages'] as List?) ?? [];
    return SessionData(
      version: json['version'] as String? ?? '1.0',
      id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
      title: json['title'] as String? ?? 'TealKit Session',
      mode: json['mode'] as String? ?? 'code',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
      llmName: json['llmName'] as String?,
      llmProvider: json['llmProvider'] as String?,
      llmModel: json['llmModel'] as String?,
      messages: rawMsgs
          .whereType<Map<String, dynamic>>()
          .map((e) => ChatMessage.fromJson(e))
          .toList(),
    );
  }
}

/// Service managing saving, loading, auto-saving, and continuing sessions.
class SessionService extends ChangeNotifier {
  static final SessionService instance = SessionService._internal();
  SessionService._internal();

  static const String _keyAutoSaveEnabled = 'session_auto_save_enabled';
  static const String _keyAutoSaveDir = 'session_auto_save_dir';
  static const String _keyAutoSavePattern = 'session_auto_save_pattern';
  static const String _keyPromptContinue = 'session_prompt_continue_last';
  static const String _keyMaxSessionSizeMb = 'session_max_size_mb';
  static const String _keyMaxSessionTurns = 'session_max_turns';

  bool _initialized = false;
  bool _autoSaveEnabled = true;
  String _autoSaveDir = '';
  String _autoSavePattern = 'session_{timestamp}.json';
  bool _promptContinueLastSession = true;
  int _maxSessionSizeMb = 10;
  int _maxSessionTurns = 200;

  String? _activeSessionFilePath;
  bool _isSaving = false;
  bool _pendingSave = false;

  bool get autoSaveEnabled => _autoSaveEnabled;
  String get autoSaveDir => _autoSaveDir;
  String get autoSavePattern => _autoSavePattern;
  bool get promptContinueLastSession => _promptContinueLastSession;
  int get maxSessionSizeMb => _maxSessionSizeMb;
  int get maxSessionTurns => _maxSessionTurns;
  String? get activeSessionFilePath => _activeSessionFilePath;

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoSaveEnabled = prefs.getBool(_keyAutoSaveEnabled) ?? true;
      _autoSaveDir = prefs.getString(_keyAutoSaveDir) ?? '';
      _autoSavePattern = prefs.getString(_keyAutoSavePattern) ?? 'session_{timestamp}.json';
      _promptContinueLastSession = prefs.getBool(_keyPromptContinue) ?? true;
      _maxSessionSizeMb = prefs.getInt(_keyMaxSessionSizeMb) ?? 10;
      _maxSessionTurns = prefs.getInt(_keyMaxSessionTurns) ?? 200;
      _initialized = true;
      notifyListeners();
    } catch (e) {
      log.warning('[SessionService] init error: $e');
    }
  }

  Future<void> updateSettings({
    required bool autoSaveEnabled,
    required String autoSaveDir,
    required String autoSavePattern,
    required bool promptContinueLastSession,
    required int maxSessionSizeMb,
    required int maxSessionTurns,
  }) async {
    _autoSaveEnabled = autoSaveEnabled;
    _autoSaveDir = autoSaveDir.trim();
    _autoSavePattern = autoSavePattern.trim().isEmpty ? 'session_{timestamp}.json' : autoSavePattern.trim();
    _promptContinueLastSession = promptContinueLastSession;
    _maxSessionSizeMb = maxSessionSizeMb;
    _maxSessionTurns = maxSessionTurns;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyAutoSaveEnabled, _autoSaveEnabled);
      await prefs.setString(_keyAutoSaveDir, _autoSaveDir);
      await prefs.setString(_keyAutoSavePattern, _autoSavePattern);
      await prefs.setBool(_keyPromptContinue, _promptContinueLastSession);
      await prefs.setInt(_keyMaxSessionSizeMb, _maxSessionSizeMb);
      await prefs.setInt(_keyMaxSessionTurns, _maxSessionTurns);
    } catch (_) {}
    notifyListeners();
  }

  /// Saves a session object to [targetPath].
  Future<File> saveSession(SessionData session, String targetPath) async {
    final file = File(p.normalize(targetPath));
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }

    final jsonStr = const JsonEncoder.withIndent('  ').convert(session.toJson());
    final tmpFile = File('${file.path}.tmp_${DateTime.now().microsecondsSinceEpoch}');
    await tmpFile.writeAsString(jsonStr, flush: true);

    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    try {
      await tmpFile.rename(file.path);
    } catch (_) {
      await tmpFile.copy(file.path);
      try {
        await tmpFile.delete();
      } catch (_) {}
    }

    _activeSessionFilePath = file.path;
    return file;
  }

  /// Loads session data from JSON file.
  Future<SessionData> loadSession(String filePath) async {
    final file = File(p.normalize(filePath));
    if (!file.existsSync()) {
      throw FileSystemException('Session file not found', filePath);
    }
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;
    final session = SessionData.fromJson(json);
    _activeSessionFilePath = file.path;
    return session;
  }

  /// Resolves effective sessions directory for saving.
  String resolveSessionsDirectory({String? workspaceDirectory}) {
    if (_autoSaveDir.isNotEmpty && Directory(_autoSaveDir).existsSync()) {
      return _autoSaveDir;
    }
    if (workspaceDirectory != null && workspaceDirectory.isNotEmpty) {
      return p.join(workspaceDirectory, '.tealkit', 'sessions');
    }
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.current.path;
    return p.join(home, '.tealkit', 'sessions');
  }

  String generateFilename() {
    final ts = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-')
        .replaceAll('T', '_');
    return _autoSavePattern
        .replaceAll('{timestamp}', ts)
        .replaceAll('{id}', const Uuid().v4().substring(0, 8));
  }

  /// Searches for the most recently modified session file.
  File? findLastSessionFile({String? workspaceDirectory}) {
    final candidateDirs = <String>{};
    if (_autoSaveDir.isNotEmpty) {
      candidateDirs.add(_autoSaveDir);
    }
    if (workspaceDirectory != null && workspaceDirectory.isNotEmpty) {
      candidateDirs.add(p.join(workspaceDirectory, '.tealkit', 'sessions'));
      candidateDirs.add(p.join(workspaceDirectory, 'sessions'));
    }
    candidateDirs.add(p.join(Directory.current.path, '.tealkit', 'sessions'));
    candidateDirs.add(p.join(Directory.current.path, 'sessions'));

    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty) {
      candidateDirs.add(p.join(home, '.tealkit', 'sessions'));
    }

    final files = <File>[];
    for (final d in candidateDirs) {
      final dir = Directory(d);
      if (!dir.existsSync()) continue;
      try {
        final entries = dir.listSync();
        for (final entry in entries) {
          if (entry is File) {
            final ext = p.extension(entry.path).toLowerCase();
            if ((ext == '.json' || ext == '.md') && entry.lengthSync() > 10) {
              files.add(entry);
            }
          }
        }
      } catch (_) {}
    }

    if (files.isEmpty) return null;

    files.sort((a, b) {
      try {
        return b.lastModifiedSync().compareTo(a.lastModifiedSync());
      } catch (_) {
        return 0;
      }
    });

    return files.first;
  }

  /// Trigger auto-save of current session messages.
  Future<void> autoSaveSession({
    required List<ChatMessage> messages,
    required String mode,
    required String? llmModel,
    String? workspaceDirectory,
  }) async {
    if (!_autoSaveEnabled || messages.isEmpty) return;
    if (_isSaving) {
      _pendingSave = true;
      return;
    }
    _isSaving = true;

    try {
      final dirPath = resolveSessionsDirectory(workspaceDirectory: workspaceDirectory);
      final dir = Directory(dirPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      bool needsRotation = false;
      if (_activeSessionFilePath != null) {
        final existingFile = File(_activeSessionFilePath!);
        if (existingFile.existsSync()) {
          final maxBytes = _maxSessionSizeMb * 1024 * 1024;
          if (existingFile.lengthSync() >= maxBytes) {
            needsRotation = true;
          }
        }
      }
      if (messages.length >= _maxSessionTurns) {
        needsRotation = true;
      }

      if (_activeSessionFilePath == null || needsRotation) {
        final ts = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-').replaceAll('T', '_');
        final fileName = _autoSavePattern
            .replaceAll('{timestamp}', ts)
            .replaceAll('{id}', const Uuid().v4().substring(0, 8));
        _activeSessionFilePath = p.join(dirPath, fileName);
      }

      final session = SessionData(
        id: const Uuid().v4(),
        title: 'TealKit Coding Session',
        mode: mode,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        llmModel: llmModel,
        messages: messages,
      );

      await saveSession(session, _activeSessionFilePath!);
    } catch (e) {
      log.warning('[SessionService] autoSaveSession failed: $e');
    } finally {
      _isSaving = false;
      if (_pendingSave) {
        _pendingSave = false;
        await autoSaveSession(
          messages: messages,
          mode: mode,
          llmModel: llmModel,
          workspaceDirectory: workspaceDirectory,
        );
      }
    }
  }
}
