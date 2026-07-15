// ignore_for_file: use_build_context_synchronously

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:highlight/languages/bash.dart' as hl_bash;
import 'package:highlight/languages/css.dart' as hl_css;
import 'package:highlight/languages/dart.dart' as hl_dart;
import 'package:highlight/languages/javascript.dart' as hl_js;
import 'package:highlight/languages/json.dart' as hl_json;
import 'package:highlight/languages/markdown.dart' as hl_md;
import 'package:highlight/languages/python.dart' as hl_py;
import 'package:highlight/languages/typescript.dart' as hl_ts;
import 'package:highlight/languages/xml.dart' as hl_xml;
import 'package:highlight/languages/yaml.dart' as hl_yaml;
import 'package:file_picker/file_picker.dart';
import 'package:open_file/open_file.dart';

import '../models/mcp_models.dart';
import '../services/multi_mcp_manager.dart';
import '../utils/logger.dart';

/// Full-screen SFTP file explorer dialog.
///
/// Opens as a full-screen dialog. Uses [MultiMCPManager.callTool] to call
/// `list_files`, `download_file`, and `read_file` directly — no LLM involved.
///
/// Usage:
/// ```dart
/// SftpExplorerDialog.show(context, mcpManager, initialPath: '/');
/// ```
class SftpExplorerDialog extends StatefulWidget {
  final MultiMCPManager mcpManager;
  final String initialPath;
  final bool isServerMode;

  const SftpExplorerDialog({super.key, required this.mcpManager, this.initialPath = '/', this.isServerMode = false});

  /// Show the SFTP explorer as a full-screen dialog.
  static Future<void> show(BuildContext context, MultiMCPManager mcpManager, {String initialPath = '/', bool isServerMode = false}) {
    return showDialog<void>(
      context: context,
      builder: (_) => SftpExplorerDialog(mcpManager: mcpManager, initialPath: initialPath, isServerMode: isServerMode),
    );
  }

  @override
  State<SftpExplorerDialog> createState() => _SftpExplorerDialogState();
}

class _SftpExplorerDialogState extends State<SftpExplorerDialog> {
  // Navigation history: each entry is a path
  final List<String> _history = [];
  String _currentPath = '/';

  List<Map<String, dynamic>> _entries = [];
  bool _loading = false;
  String? _error;

  static const _readableExtensions = {
    '.txt',
    '.md',
    '.html',
    '.htm',
    '.sh',
    '.log',
    '.yaml',
    '.yml',
    '.json',
    '.conf',
    '.ini',
    '.env',
    '.py',
    '.dart',
    '.js',
    '.ts',
    '.css',
    '.xml',
  };

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath;
    _loadDirectory(_currentPath);
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.mcpManager.callTool('list_directory', {'path': path});
      final text = result.content.firstOrNull?.text ?? '{}';
      final data = jsonDecode(text) as Map<String, dynamic>;

      if (data['error'] != null) throw Exception(data['error'].toString());

      final rawEntries = data['entries'] as List? ?? [];
      final entries = rawEntries.cast<Map<String, dynamic>>();

      // Sort: directories first, then files, both alphabetically
      entries.sort((a, b) {
        final aIsDir = a['isDirectory'] as bool? ?? false;
        final bIsDir = b['isDirectory'] as bool? ?? false;
        if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
        return (a['name'] as String? ?? '').toLowerCase().compareTo((b['name'] as String? ?? '').toLowerCase());
      });

      if (mounted) {
        setState(() {
          _currentPath = path;
          _entries = entries;
          _loading = false;
        });
      }
    } catch (e) {
      talker.error('SftpExplorer: failed to list $path: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  void _navigateTo(String path) {
    _history.add(_currentPath);
    _loadDirectory(path);
  }

  void _navigateBack() {
    if (_history.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final prev = _history.removeLast();
    _loadDirectory(prev);
  }

  String _normalizePath(String dir, String name) {
    final clean = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
    return '$clean/$name';
  }

  // ── Folder actions ────────────────────────────────────────────

  void _createFolder() {
    final controller = TextEditingController();
    showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('Create')),
        ],
      ),
    ).then((name) async {
      if (name == null || name.isEmpty) return;
      final dirPath = _normalizePath(_currentPath, name);
      try {
        final result = await widget.mcpManager.callTool('make_directory', {'path': dirPath});
        final text = result.content.firstOrNull?.text ?? '';
        Map<String, dynamic>? json;
        try {
          json = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {}
        if (result.isError || json?['error'] != null) {
          throw Exception(json?['error'] ?? 'mkdir failed');
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Created folder: $name'), backgroundColor: Colors.green));
          _loadDirectory(_currentPath);
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Create folder failed: $e'), backgroundColor: Colors.red));
        }
      }
    });
  }

  void _onDirectoryLongPress(Map<String, dynamic> entry) {
    final name = entry['name'] as String? ?? '';
    final fullPath = _normalizePath(_currentPath, name);
    final theme = Theme.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.folder, size: 20, color: const Color(0xFFFFB300)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(name, style: const TextStyle(fontSize: 15), overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('Open'),
              onTap: () {
                Navigator.of(ctx).pop();
                _navigateTo(fullPath);
              },
            ),
            ListTile(
              leading: Icon(Icons.folder_delete_outlined, color: theme.colorScheme.error),
              title: Text('Delete (only if empty)', style: TextStyle(color: theme.colorScheme.error)),
              onTap: () {
                Navigator.of(ctx).pop();
                _deleteFolderIfEmpty(name, fullPath);
              },
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel'))],
      ),
    );
  }

  void _deleteFolderIfEmpty(String folderName, String fullPath) {
    final theme = Theme.of(context);
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete empty folder'),
        content: Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'Remove '),
              TextSpan(
                text: folderName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const TextSpan(text: '?\nThis will fail if the folder is not empty.'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete', style: TextStyle(color: theme.colorScheme.error)),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed != true) return;
      try {
        final result = await widget.mcpManager.callTool('remove_directory', {'path': fullPath});
        final text = result.content.firstOrNull?.text ?? '';
        Map<String, dynamic>? json;
        try {
          json = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {}
        if (result.isError || json?['error'] != null) {
          throw Exception(json?['error'] ?? 'rmdir failed');
        }
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Deleted folder: $folderName'), backgroundColor: Colors.orange));
          _loadDirectory(_currentPath);
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.red));
        }
      }
    });
  }

  void _uploadToRemote() {
    if (widget.isServerMode) {
      // Server mode: use a text field for the local path (no file picker)
      _uploadFromPath();
    } else {
      // Local / desktop mode: use file picker
      _uploadWithFilePicker();
    }
  }

  void _uploadFromPath() {
    final controller = TextEditingController();
    showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Upload file'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Remote target: $_currentPath', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Source path', hintText: '/home/user/file.txt'),
              onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('Upload')),
        ],
      ),
    ).then((sourcePath) async {
      if (sourcePath == null || sourcePath.isEmpty) return;
      final fileName = sourcePath.split(RegExp(r'[/\\]')).last;
      final remotePath = _normalizePath(_currentPath, fileName);
      await _doUploadViaSource(sourcePath: sourcePath, remotePath: remotePath, fileName: fileName);
    });
  }

  void _uploadWithFilePicker() {
    () async {
      try {
        final result = await FilePicker.pickFiles(withData: true);
        if (result == null || result.files.isEmpty) return;
        final picked = result.files.first;
        final bytes = picked.bytes;
        if (bytes == null) return;
        if (!context.mounted) return;
        final fileName = picked.name;
        final remotePath = _normalizePath(_currentPath, fileName);
        await _doUploadBytes(bytes: bytes, remotePath: remotePath, fileName: fileName);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('File pick failed: $e'), backgroundColor: Colors.red));
        }
      }
    }();
  }

  Future<void> _doUploadViaSource({required String sourcePath, required String remotePath, required String fileName}) async {
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: SizedBox(
          height: 60,
          child: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text('Uploading $fileName...')),
            ],
          ),
        ),
      ),
    );
    try {
      final mcpResult = await widget.mcpManager.callTool('upload_file', {'path': remotePath, 'source': sourcePath});
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      final text = mcpResult.content.firstOrNull?.text ?? '';
      Map<String, dynamic>? json;
      try {
        json = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {}
      if (mcpResult.isError || json?['error'] != null) throw Exception(json?['error'] ?? 'upload failed');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Uploaded $fileName to $_currentPath'), backgroundColor: Colors.green));
      _loadDirectory(_currentPath);
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _doUploadBytes({required Uint8List bytes, required String remotePath, required String fileName}) async {
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: SizedBox(
          height: 60,
          child: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text('Uploading $fileName...')),
            ],
          ),
        ),
      ),
    );
    try {
      final b64 = base64Encode(bytes);
      final mcpResult = await widget.mcpManager.callTool('upload_file', {'path': remotePath, 'content': b64, 'encoding': 'base64'});
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      final text = mcpResult.content.firstOrNull?.text ?? '';
      Map<String, dynamic>? json;
      try {
        json = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {}
      if (mcpResult.isError || json?['error'] != null) throw Exception(json?['error'] ?? 'upload failed');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Uploaded $fileName (${_formatSize(bytes.length)}) to $_currentPath'), backgroundColor: Colors.green),
      );
      _loadDirectory(_currentPath);
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red));
    }
  }

  // ── File actions ──────────────────────────────────────────────

  void _onFileTap(Map<String, dynamic> entry) {
    final name = entry['name'] as String? ?? '';
    final fullPath = _normalizePath(_currentPath, name);
    final ext = name.contains('.') ? '.${name.split('.').last.toLowerCase()}' : '';
    final canRead = _readableExtensions.contains(ext);
    final size = entry['size'] as int? ?? 0;
    final modLabel = _formatModified(entry['modified']);

    showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.insert_drive_file, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(name, style: const TextStyle(fontSize: 15), overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Metadata row: size + modified
              if (size > 0 || modLabel != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 14, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text(
                        [if (size > 0) _formatSize(size), if (modLabel != null) 'modified $modLabel'].join('  ·  '),
                        style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                subtitle: Text(fullPath, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _downloadFile(name, fullPath);
                },
              ),
              if (canRead)
                ListTile(
                  leading: const Icon(Icons.edit_document),
                  title: const Text('Edit / View'),
                  subtitle: const Text('Open with code editor'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _openEditorWithLoad(name, fullPath);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('Rename'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _renameFile(name, fullPath);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                title: Text('Delete', style: TextStyle(color: theme.colorScheme.error)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _deleteFile(name, fullPath);
                },
              ),
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel'))],
        );
      },
    );
  }

  void _renameFile(String fileName, String fullPath) {
    final controller = TextEditingController(text: fileName);
    showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename file'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'New name'),
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('Rename')),
        ],
      ),
    ).then((newName) async {
      if (newName == null || newName.isEmpty || newName == fileName) return;
      final dir = _currentPath.endsWith('/') ? _currentPath.substring(0, _currentPath.length - 1) : _currentPath;
      final newPath = '$dir/$newName';
      try {
        final result = await widget.mcpManager.callTool('execute_command', {'command': 'mv -- ${_sq(fullPath)} ${_sq(newPath)}'});
        final text = result.content.firstOrNull?.text ?? '';
        Map<String, dynamic>? json;
        try {
          json = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {}
        final exitCode = json?['exit_code'] as int? ?? json?['exitCode'] as int? ?? 0;
        if (result.isError || exitCode != 0) {
          throw Exception(json?['stderr'] ?? json?['error'] ?? 'rename failed');
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Renamed to $newName'), backgroundColor: Colors.green));
          _loadDirectory(_currentPath);
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rename failed: $e'), backgroundColor: Colors.red));
        }
      }
    });
  }

  void _deleteFile(String fileName, String fullPath) {
    showDialog<bool>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('Delete file'),
          content: Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Permanently delete '),
                TextSpan(
                  text: fileName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: '?'),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Delete', style: TextStyle(color: theme.colorScheme.error)),
            ),
          ],
        );
      },
    ).then((confirmed) async {
      if (confirmed != true) return;
      try {
        final result = await widget.mcpManager.callTool('execute_command', {'command': 'rm -f -- ${_sq(fullPath)}'});
        final text = result.content.firstOrNull?.text ?? '';
        Map<String, dynamic>? json;
        try {
          json = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {}
        final exitCode = json?['exit_code'] as int? ?? json?['exitCode'] as int? ?? 0;
        if (result.isError || exitCode != 0) {
          throw Exception(json?['stderr'] ?? json?['error'] ?? 'delete failed');
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted $fileName'), backgroundColor: Colors.orange));
          _loadDirectory(_currentPath);
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.red));
        }
      }
    });
  }

  void _downloadFile(String fileName, String fullPath) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: SizedBox(
          height: 60,
          child: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text('Downloading $fileName...')),
            ],
          ),
        ),
      ),
    );

    () async {
      try {
        final result = await widget.mcpManager.callTool('download_file', {'path': fullPath});
        if (!context.mounted) return;
        Navigator.of(context, rootNavigator: true).pop(); // close loading

        // The adapter puts base64 in MCPContent.data (type:'file') when
        // the server returns {encoding:'base64', content:..., mimeType:...}.
        // Fall back to JSON text path for other server implementations.
        String? b64;
        String? saveName;

        final fileContent = result.content.firstWhere(
          (c) => c.type == 'file' && c.data != null && c.data!.isNotEmpty,
          orElse: () => MCPContent(type: 'text', text: null),
        );

        if (fileContent.data != null) {
          // Direct base64 from adapter
          b64 = fileContent.data;
          saveName = fileName;
        } else {
          // Fallback: JSON text response
          final text = result.content.firstOrNull?.text ?? '';
          if (text.isEmpty) throw Exception('Empty response from download_file');
          final json = jsonDecode(text) as Map<String, dynamic>;
          if (json['error'] != null) throw Exception(json['error'].toString());
          b64 = json['content'] as String?;
          saveName = (json['fileName'] as String?) ?? fileName;
        }

        if (b64 == null || b64.isEmpty) throw Exception('No file content in response');
        final bytes = base64Decode(b64);
        final savedPath = await _saveFile(bytes, saveName);

        if (context.mounted) {
          if (savedPath != null) {
            final isMobile = Platform.isAndroid || Platform.isIOS;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Saved: $saveName'),
                backgroundColor: Colors.green,
                action: isMobile
                    ? null // SAF path unknown on mobile; skip Open button
                    : SnackBarAction(label: 'Open', textColor: Colors.white, onPressed: () => OpenFile.open(savedPath)),
              ),
            );
          } else {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Save cancelled or failed'), backgroundColor: Colors.red));
          }
        }
      } catch (e) {
        if (!context.mounted) return;
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e'), backgroundColor: Colors.red));
      }
    }();
  }

  void _openEditorWithLoad(String fileName, String fullPath) {
    final ext = fileName.contains('.') ? '.${fileName.split('.').last.toLowerCase()}' : '';

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [CircularProgressIndicator(), SizedBox(width: 16), Text('Loading...')],
          ),
        ),
      ),
    );

    () async {
      try {
        final result = await widget.mcpManager.callTool('read_file', {'path': fullPath});
        if (!context.mounted) return;
        Navigator.of(context, rootNavigator: true).pop();

        final raw = result.content.firstOrNull?.text ?? '{}';
        String content;
        try {
          final json = jsonDecode(raw) as Map;
          if (json['error'] != null) throw Exception(json['error'].toString());
          content = (json['content'] as String?) ?? raw;
        } catch (_) {
          content = raw;
        }

        if (!context.mounted) return;
        showDialog<void>(
          context: context,
          builder: (_) => _SftpFileEditorDialog(
            fileName: fileName,
            remotePath: fullPath,
            initialContent: content,
            ext: ext,
            mcpManager: widget.mcpManager,
          ),
        );
      } catch (e) {
        if (!context.mounted) return;
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Read failed: $e'), backgroundColor: Colors.red));
      }
    }();
  }

  // ── Save helper ───────────────────────────────────────────────

  Future<String?> _saveFile(Uint8List bytes, String fileName) async {
    try {
      final isMobile = Platform.isAndroid || Platform.isIOS;
      if (isMobile) {
        // On Android 10+ direct writes to /Download are blocked without
        // MANAGE_EXTERNAL_STORAGE.  Use the SAF picker (file_picker passes
        // bytes directly so no separate write is needed; null return is normal).
        await FilePicker.saveFile(dialogTitle: 'Save $fileName', fileName: fileName, bytes: bytes);
        // SAF always writes the file even when null is returned; treat as success.
        return fileName;
      } else {
        // Desktop: show OS save dialog, then write ourselves.
        final pickedPath = await FilePicker.saveFile(dialogTitle: 'Save $fileName', fileName: fileName);
        if (pickedPath == null) return null; // user cancelled
        await File(pickedPath).writeAsBytes(bytes, flush: true);
        return pickedPath;
      }
    } catch (e) {
      talker.error('SftpExplorer: save failed: $e');
      return null;
    }
  }

  // ── UI ────────────────────────────────────────────────────────

  /// Wrap a path in single quotes, escaping any embedded single quotes.
  String _sq(String path) => "'${path.replaceAll("'", "'\\''")}'";

  String _formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}M';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}G';
  }

  /// Format a `modified` value from a directory entry.
  /// The SSH server typically returns an ISO-8601 string or epoch-ms int.
  /// Returns a short relative label e.g. "today", "yesterday", "Jan 15", "Jan 15 2024".
  String? _formatModified(dynamic raw) {
    if (raw == null) return null;
    DateTime? dt;
    if (raw is int) {
      dt = DateTime.fromMillisecondsSinceEpoch(raw);
    } else if (raw is String && raw.isNotEmpty) {
      dt = DateTime.tryParse(raw);
    }
    if (dt == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (diff == 1) return 'yesterday';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final mon = months[dt.month - 1];
    if (dt.year == now.year) return '$mon ${dt.day}';
    return '$mon ${dt.day} ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canGoBack = _history.isNotEmpty;

    return Dialog(
      insetPadding: EdgeInsets.zero,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: canGoBack ? IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Back', onPressed: _navigateBack) : null,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('SFTP Explorer', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Text(
                _currentPath,
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withValues(alpha: 0.7), fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          actions: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: () => _loadDirectory(_currentPath)),
            IconButton(icon: const Icon(Icons.create_new_folder_outlined), tooltip: 'New folder', onPressed: _createFolder),
            IconButton(
              icon: const Icon(Icons.upload_file),
              tooltip: widget.isServerMode ? 'Upload (enter source path)' : 'Upload file',
              onPressed: _uploadToRemote,
            ),
            IconButton(icon: const Icon(Icons.close), tooltip: 'Close', onPressed: () => Navigator.of(context).pop()),
          ],
        ),
        body: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                onPressed: () => _loadDirectory(_currentPath),
              ),
            ],
          ),
        ),
      );
    }

    if (_entries.isEmpty) {
      return Center(
        child: Text('(empty directory)', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }

    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: theme.colorScheme.outline.withValues(alpha: 0.15)),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final name = entry['name'] as String? ?? '';
        final isDir = entry['isDirectory'] as bool? ?? false;
        final size = entry['size'] as int? ?? 0;
        final fullPath = _normalizePath(_currentPath, name);
        final modLabel = _formatModified(entry['modified']);

        // Build subtitle: "1.3K · Jan 15" for files, "Jan 15" for dirs
        Widget? subtitle;
        if (isDir) {
          if (modLabel != null) {
            subtitle = Text(modLabel, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant));
          }
        } else {
          final parts = <String>[if (size > 0) _formatSize(size), ?modLabel];
          if (parts.isNotEmpty) subtitle = Text(parts.join(' · '), style: const TextStyle(fontSize: 11));
        }

        return ListTile(
          dense: true,
          leading: Icon(
            isDir ? Icons.folder : Icons.insert_drive_file_outlined,
            size: 22,
            color: isDir ? const Color(0xFFFFB300) : theme.colorScheme.onSurfaceVariant,
          ),
          title: Text(
            name,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isDir ? FontWeight.w500 : FontWeight.normal,
              color: isDir ? theme.colorScheme.primary : theme.colorScheme.onSurface,
            ),
          ),
          subtitle: subtitle,
          trailing: Icon(
            isDir ? Icons.chevron_right : Icons.more_vert,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          onTap: () {
            if (isDir) {
              _navigateTo(fullPath);
            } else {
              _onFileTap(entry);
            }
          },
          onLongPress: isDir ? () => _onDirectoryLongPress(entry) : null,
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SFTP File Editor
// ─────────────────────────────────────────────────────────────────────────────

/// Full-screen code editor dialog with syntax highlighting and SFTP upload.
class _SftpFileEditorDialog extends StatefulWidget {
  final String fileName;
  final String remotePath;
  final String initialContent;
  final String ext;
  final MultiMCPManager mcpManager;

  const _SftpFileEditorDialog({
    required this.fileName,
    required this.remotePath,
    required this.initialContent,
    required this.ext,
    required this.mcpManager,
  });

  @override
  State<_SftpFileEditorDialog> createState() => _SftpFileEditorDialogState();
}

class _SftpFileEditorDialogState extends State<_SftpFileEditorDialog> {
  late final CodeController _controller;
  bool _uploading = false;
  bool _modified = false;

  @override
  void initState() {
    super.initState();
    _controller = CodeController(text: widget.initialContent, language: _languageForExt(widget.ext));
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (!_modified && _controller.text != widget.initialContent) {
      setState(() => _modified = true);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  dynamic _languageForExt(String ext) {
    switch (ext) {
      case '.dart':
        return hl_dart.dart;
      case '.py':
        return hl_py.python;
      case '.js':
        return hl_js.javascript;
      case '.ts':
        return hl_ts.typescript;
      case '.json':
        return hl_json.json;
      case '.sh':
        return hl_bash.bash;
      case '.yaml':
      case '.yml':
        return hl_yaml.yaml;
      case '.html':
      case '.htm':
        return hl_xml.xml;
      case '.css':
        return hl_css.css;
      case '.xml':
        return hl_xml.xml;
      case '.md':
        return hl_md.markdown;
      default:
        return null;
    }
  }

  Future<void> _upload() async {
    setState(() => _uploading = true);
    try {
      final content = _controller.text;
      // Encode as base64 UTF-8 so binary-safe regardless of server implementation
      final b64 = base64Encode(utf8.encode(content));
      final result = await widget.mcpManager.callTool('upload_file', {'path': widget.remotePath, 'content': b64, 'encoding': 'base64'});
      Map<String, dynamic>? responseJson;
      final text = result.content.firstOrNull?.text ?? '';
      try {
        responseJson = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {}
      if (responseJson?['error'] != null) throw Exception(responseJson!['error'].toString());

      if (mounted) {
        setState(() {
          _uploading = false;
          _modified = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('\u2705 Uploaded ${widget.fileName}'), backgroundColor: Colors.green));
      }
    } catch (e) {
      talker.error('SftpEditor: upload failed: $e');
      if (mounted) {
        setState(() => _uploading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final codeStyles = isDark ? atomOneDarkTheme : atomOneLightTheme;

    return Dialog(
      insetPadding: EdgeInsets.zero,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.fileName,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                widget.remotePath,
                style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface.withValues(alpha: 0.65), fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy all',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _controller.text));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)));
              },
            ),
            if (_uploading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              Tooltip(
                message: _modified ? 'Upload to server' : 'No changes',
                child: IconButton(
                  icon: Icon(
                    Icons.upload,
                    color: _modified ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.35),
                  ),
                  onPressed: _modified ? _upload : null,
                ),
              ),
          ],
        ),
        body: CodeTheme(
          data: CodeThemeData(styles: codeStyles),
          child: SingleChildScrollView(
            child: CodeField(
              controller: _controller,
              textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }
}
