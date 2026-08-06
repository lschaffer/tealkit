// ignore_for_file: unintended_html_in_doc_comment

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/duckdb_service.dart';
import '../models/py_tool_definition.dart';
import '../models/py_tool_defaults.dart';
import 'app_logger.dart';
import 'server_api_client.dart';

/// CRUD service for Python tool definitions.
///
/// Persists metadata in DuckDB (py_tools table).
/// Writes/reads source files on disk at:
///   <app-support>/py-tools/<id>/main.py
///   <app-support>/py-tools/<id>/requirements.txt
class PyToolLibraryService {
  PyToolLibraryService._();
  static final instance = PyToolLibraryService._();

  List<PyToolDefinition> _tools = [];

  List<PyToolDefinition> get tools => List.unmodifiable(_tools);
  List<PyToolDefinition> get activeTools =>
      _tools.where((t) => t.isActive).toList();

  // ─── Root dir ─────────────────────────────────────────────────────────────

  Future<String> get _rootDir async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'py-tools'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<String> toolDir(String toolId) async {
    final root = await _rootDir;
    final dir = Directory(p.join(root, toolId));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  // ─── Load ─────────────────────────────────────────────────────────────────

  Future<void> load([ServerApiClient? client]) async {
    if (client != null) {
      try {
        final list = await client.getPyTools();
        _tools = list.map(PyToolDefinition.fromJson).toList();
        log.info('[PyToolLibrary] Loaded ${_tools.length} remote tools');
      } catch (e) {
        log.error('[PyToolLibrary] Failed to load remote tools: $e');
      }
      return;
    }

    try {
      final db = DuckDbService();
      final rows = await db.getAllPyTools();
      final existingIds = rows.map((r) => r['id'] as String).toSet();
      if (existingIds.isEmpty) {
        log.info('[PyToolLibrary] No tools found — seeding all defaults');
        for (final tool in defaultPyTools) {
          await _seedTool(db, tool);
        }
      } else {
        // Ensure all default tools are present (handles newly added defaults)
        for (final tool in defaultPyTools) {
          if (!existingIds.contains(tool.id)) {
            log.info(
              '[PyToolLibrary] Missing default tool — seeding: ${tool.id} "${tool.name}"',
            );
            await _seedTool(db, tool);
          }
        }
      }
      final refreshed = await db.getAllPyTools();
      _tools = refreshed.map(PyToolDefinition.fromJson).toList();
      log.info('[PyToolLibrary] Loaded ${_tools.length} tools');
    } catch (e) {
      log.error('[PyToolLibrary] Failed to load: $e');
    }
  }

  /// Persists a single default tool's DB entry and on-disk files.
  Future<void> _seedTool(DuckDbService db, PyToolDefinition tool) async {
    await db.savePyTool(tool);
    final dir = await toolDir(tool.id);
    await File(p.join(dir, 'main.py')).writeAsString(tool.code, flush: true);
    await File(
      p.join(dir, 'requirements.txt'),
    ).writeAsString(tool.requirements, flush: true);
    log.info('[PyToolLibrary] Seeded default tool: ${tool.id} "${tool.name}"');
  }

  // ─── Save (create / update) ───────────────────────────────────────────────

  Future<PyToolDefinition> save(
    PyToolDefinition def, [
    ServerApiClient? client,
  ]) async {
    // 1. Always persist locally
    try {
      final db = DuckDbService();
      await db.savePyTool(def);

      final dir = await toolDir(def.id);
      await File(p.join(dir, 'main.py')).writeAsString(def.code, flush: true);
      await File(
        p.join(dir, 'requirements.txt'),
      ).writeAsString(def.requirements, flush: true);
    } catch (e) {
      log.error('[PyToolLibrary] Failed local save: $e');
    }

    // 2. Update in-memory cache
    final idx = _tools.indexWhere((t) => t.id == def.id);
    if (idx >= 0) {
      _tools[idx] = def;
    } else {
      _tools.add(def);
    }

    // 3. Remotely sync if server client is provided
    if (client != null) {
      try {
        final exportList = _tools.map((t) => t.toJson()).toList();
        await client.syncPyTools(exportList);
        log.info('[PyToolLibrary] Remotely saved/synced tool: ${def.name}');
      } catch (e) {
        log.error('[PyToolLibrary] Failed to sync remote py_tool save: $e');
      }
    }

    log.info('[PyToolLibrary] Saved tool: ${def.id} "${def.name}"');
    return def;
  }

  /// Mark a tool's venv as ready (or not) in DB + cache.
  Future<void> setVenvReady(String id, {required bool ready}) async {
    final idx = _tools.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final updated = _tools[idx].copyWith(venvReady: ready);
    _tools[idx] = updated;
    await DuckDbService().savePyTool(updated);

    // Also write / remove the .ready marker file
    final dir = await toolDir(id);
    final marker = File(p.join(dir, '.ready'));
    if (ready) {
      await marker.writeAsString('1', flush: true);
    } else if (await marker.exists()) {
      await marker.delete();
    }
    log.info('[PyToolLibrary] setVenvReady $id → $ready');
  }

  // ─── Delete ───────────────────────────────────────────────────────────────

  Future<void> delete(String id, [ServerApiClient? client]) async {
    // 1. Always delete locally
    try {
      await DuckDbService().deletePyTool(id);
      final dir = Directory(p.join(await _rootDir, id));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      log.error('[PyToolLibrary] Failed local delete: $e');
    }

    _tools.removeWhere((t) => t.id == id);

    // 2. Remotely sync if server client is provided
    if (client != null) {
      try {
        final exportList = _tools.map((t) => t.toJson()).toList();
        await client.syncPyTools(exportList);
        log.info('[PyToolLibrary] Remotely deleted/synced tool: $id');
      } catch (e) {
        log.error('[PyToolLibrary] Failed to sync remote py_tool delete: $e');
      }
    }

    log.info('[PyToolLibrary] Deleted tool: $id');
  }

  // ─── Getters ──────────────────────────────────────────────────────────────

  PyToolDefinition? getById(String id) {
    try {
      return _tools.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  PyToolDefinition? getByName(String name) {
    final lower = name.trim().toLowerCase();
    try {
      return _tools.firstWhere((t) => t.name.toLowerCase() == lower);
    } catch (_) {
      return null;
    }
  }
}
