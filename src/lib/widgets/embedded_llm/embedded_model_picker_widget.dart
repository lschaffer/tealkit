import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import '../../config/app_theme.dart';
import '../../l10n/app_localizations.dart';
import '../../services/embedded_llm/embedded_llm_adapter.dart';
import '../../services/embedded_llm/embedded_model.dart';
import '../../services/embedded_llm/embedded_model_manager.dart';
import '../../services/server_api_client.dart';
import 'add_gguf_dialog.dart';
import 'hf_discover_dialog.dart';


/// Widget shown in the LLM settings dialog when the user picks "Embedded (on-device)".
///
/// It shows:
/// - Any models added via [AddGgufDialog] or [HfDiscoverDialog].
/// - A radio-selection so the user picks which model to activate.
/// - Per-model info: size, RAM requirement, tool-calling badge.
/// - Download / delete controls with a progress indicator.
/// - Buttons to Discover (HuggingFace) or Add GGUF URL.
///
/// [selectedFilename] is the currently saved filename (from LlmSettingsService.model).
/// [onFilenameSelected] is called whenever the user picks a different model filename.
class EmbeddedModelPickerWidget extends StatefulWidget {
  final String selectedFilename;
  final ValueChanged<String> onFilenameSelected;
  final ServerApiClient? serverClient;

  const EmbeddedModelPickerWidget({super.key, required this.selectedFilename, required this.onFilenameSelected, this.serverClient});

  @override
  State<EmbeddedModelPickerWidget> createState() => _EmbeddedModelPickerWidgetState();
}

class _EmbeddedModelPickerWidgetState extends State<EmbeddedModelPickerWidget> {
  List<EmbeddedGgufModel> _customModels = [];
  Set<String> _downloadedFilenames = {};
  bool _loading = true;

  bool get _isServerMode => widget.serverClient != null;

  // Track active download per filename
  final Map<String, double> _downloadProgress = {}; // filename → 0.0–1.0
  final Map<String, DownloadCancelToken> _cancelTokens = {};
  final Map<String, String> _remoteJobByFilename = {}; // filename -> job id
  Timer? _remotePollingTimer;

  // Track loading model into the LlamaEngine (app memory)
  String? _appLoadingFilename; // filename being loaded into app
  double _appLoadProgress = 0.0; // 0.0–1.0
  String? _serverLoadedFilename; // remote server loaded model filename

  // Per-model GPU layers setting (filename → gpuLayers)
  final Map<String, int> _gpuLayersMap = {};

  // GPU support state (checked once on first refresh)
  bool? _gpuSupported; // null = not yet checked
  int _vramFreeBytes = 0;

  // Models > this threshold on CPU-only Android will show a load warning.
  static const int _cpuSizeWarnBytes = 1_500_000_000; // 1.5 GB

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _remotePollingTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final customs = _isServerMode
          ? (await widget.serverClient!.getServerCustomModels())
              .map((e) => EmbeddedGgufModel.fromJson(e))
              .toList()
          : await EmbeddedModelManager.instance.loadCustomModels();
      final downloaded = _isServerMode
          ? await _listRemoteDownloadedFilenames()
          : await EmbeddedModelManager.instance.listDownloadedFilenames();

      final gpuMap = <String, int>{};
      for (final filename in downloaded) {
        gpuMap[filename] = await EmbeddedModelManager.instance.getGpuLayers(filename);
      }

      String? serverLoadedFilename;
      if (_isServerMode) {
        final info = await widget.serverClient!.getServerLoadedModel();
        if (info['loaded'] == true) {
          serverLoadedFilename = info['filename'] as String?;
        }
      }

      bool gpuSupported = false;
      int vramFree = 0;
      if (!_isServerMode) {
        final adapter = EmbeddedLlmAdapter.instance;
        try {
          gpuSupported = await adapter.isGpuSupported();
          if (gpuSupported) {
            final vram = await adapter.getVramInfo();
            vramFree = vram.free;
          }
        } catch (_) {}
      } else {
        try {
          final caps = await widget.serverClient!.getServerGpuCapabilities();
          gpuSupported = caps['supported'] as bool? ?? false;
          vramFree = caps['vram_free'] as int? ?? 0;
        } catch (_) {
          gpuSupported = false;
        }
      }

      if (mounted) {
        setState(() {
          _customModels = customs;
          _downloadedFilenames = downloaded;
          _serverLoadedFilename = serverLoadedFilename;
          _gpuLayersMap
            ..clear()
            ..addAll(gpuMap);
          _gpuSupported = gpuSupported;
          _vramFreeBytes = vramFree;
          _loading = false;
        });
      }

      if (_isServerMode) {
        _startRemotePolling();
      } else {
        _remotePollingTimer?.cancel();
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Set<String>> _listRemoteDownloadedFilenames() async {
    final files = await widget.serverClient!.listServerModelFiles();
    return files.map((file) => (file['filename'] as String? ?? '').trim()).where((name) => name.isNotEmpty).toSet();
  }

  void _startRemotePolling() {
    _remotePollingTimer?.cancel();
    _remotePollingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_isServerMode || _remoteJobByFilename.isEmpty) return;
      _pollRemoteJobs();
    });
  }

  Future<void> _pollRemoteJobs() async {
    final entries = Map<String, String>.from(_remoteJobByFilename);
    for (final entry in entries.entries) {
      final filename = entry.key;
      final jobId = entry.value;
      try {
        final job = await widget.serverClient!.getServerModelDownloadJob(jobId);
        final status = (job['status'] as String? ?? '').toLowerCase();
        final progress = (job['progress'] as num?)?.toDouble() ?? 0.0;

        if (!mounted) return;

        if (status == 'queued' || status == 'downloading') {
          setState(() {
            _downloadProgress[filename] = progress.clamp(0.0, 1.0);
          });
          continue;
        }

        if (status == 'completed') {
          setState(() {
            _downloadProgress.remove(filename);
            _remoteJobByFilename.remove(filename);
            _downloadedFilenames.add(filename);
          });
          widget.onFilenameSelected(filename);
          continue;
        }

        final err = (job['error'] as String?) ?? 'Unknown error';
        if (mounted && (status == 'failed' || status == 'cancelled')) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(status == 'cancelled' ? 'Download cancelled: $filename' : 'Download failed for $filename: $err'),
              backgroundColor: status == 'cancelled' ? Colors.orange : AppTheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        setState(() {
          _downloadProgress.remove(filename);
          _remoteJobByFilename.remove(filename);
        });
      } catch (_) {
        // Keep polling; transient failures should not clear the in-flight job.
      }
    }
  }

  // All models = catalog + custom + any .gguf files already on disk (de-duplicated by filename)
  List<EmbeddedGgufModel> get _allModels {
    final seen = <String>{};
    final combined = <EmbeddedGgufModel>[];
    for (final m in EmbeddedGgufModel.defaultCatalog) {
      if (seen.add(m.filename)) combined.add(m);
    }
    for (final m in _customModels) {
      if (seen.add(m.filename)) combined.add(m);
    }
    // Show any file physically on disk even if not tracked in custom list
    for (final filename in _downloadedFilenames) {
      if (seen.add(filename)) {
        final name = filename.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), '').replaceAll(RegExp(r'[-_]'), ' ');
        combined.add(EmbeddedGgufModel(id: filename, displayName: name, filename: filename, url: '', description: 'Downloaded model.'));
      }
    }
    return combined;
  }

  Future<void> _startDownload(EmbeddedGgufModel model) async {
    if (_downloadProgress.containsKey(model.filename)) return;

    if (_isServerMode) {
      try {
        setState(() => _downloadProgress[model.filename] = 0.0);
        final resp = await widget.serverClient!.startServerModelDownload(
          url: model.url,
          filename: model.filename,
          displayName: model.displayName,
          sizeBytes: model.sizeBytes > 0 ? model.sizeBytes : null,
        );
        final jobId = (resp['job_id'] as String?) ?? '';
        if (jobId.isEmpty) throw Exception('Server did not return a job id');
        setState(() => _remoteJobByFilename[model.filename] = jobId);
        _startRemotePolling();
      } catch (e) {
        if (mounted) {
          setState(() {
            _downloadProgress.remove(model.filename);
            _remoteJobByFilename.remove(model.filename);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Download failed: $e'), backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating),
          );
        }
      }
      return;
    }

    final token = DownloadCancelToken();
    setState(() {
      _cancelTokens[model.filename] = token;
      _downloadProgress[model.filename] = 0.0;
    });
    try {
      await EmbeddedModelManager.instance.downloadModel(
        url: model.url,
        filename: model.filename,
        cancelToken: token,
        onProgress: (p) {
          if (mounted) setState(() => _downloadProgress[model.filename] = p);
        },
      );
      if (!token.isCancelled) {
        await _refresh();
        // Auto-select the just-downloaded model
        if (mounted) widget.onFilenameSelected(model.filename);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e'), backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloadProgress.remove(model.filename);
          _cancelTokens.remove(model.filename);
        });
      }
    }
  }

  void _cancelDownload(String filename) {
    if (_isServerMode) {
      final jobId = _remoteJobByFilename[filename];
      if (jobId != null) {
        unawaited(widget.serverClient!.cancelServerModelDownload(jobId));
      }
      setState(() {
        _downloadProgress.remove(filename);
      });
      return;
    }

    _cancelTokens[filename]?.cancel();
    setState(() {
      _downloadProgress.remove(filename);
      _cancelTokens.remove(filename);
    });
  }

  Future<void> _deleteModel(EmbeddedGgufModel model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete model?'),
        content: Text(
          _isServerMode
              ? 'Remove "${model.displayName}" from server storage (/data/models)?'
              : 'Remove "${model.displayName}" from device storage?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_isServerMode) {
      await widget.serverClient!.deleteServerModelFile(model.filename);
    } else {
      await EmbeddedModelManager.instance.deleteModel(model.filename);
    }
    // If deleted model was selected, clear selection
    if (widget.selectedFilename == model.filename) {
      widget.onFilenameSelected('');
    }
    await _refresh();
  }

  Future<void> _deleteAllModels() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove all models?'),
        content: Text(
          _isServerMode
              ? 'This will delete all downloaded GGUF files from server storage (/data/models).'
              : 'This will delete all downloaded GGUF files from device storage.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove all', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_isServerMode) {
      final names = _downloadedFilenames.toList(growable: false);
      for (final name in names) {
        await widget.serverClient!.deleteServerModelFile(name);
      }
    } else {
      await EmbeddedModelManager.instance.deleteAllModels();
    }
    widget.onFilenameSelected('');
    await _refresh();
  }

  Future<void> _openDiscover() async {
    final added = await HfDiscoverDialog.show(context, serverClient: widget.serverClient);
    if (added != null && added.isNotEmpty) {
      await _refresh();
    }
  }

  Future<void> _openAddGguf() async {
    final model = await AddGgufDialog.show(context, serverClient: widget.serverClient);
    if (model != null) {
      await _refresh();
    }
  }

  Future<void> _openAddFromDisk() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gguf'],
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final path = file.path;
      if (path == null) return;

      setState(() => _loading = true);
      
      final filename = file.name;
      String finalUrl = '';
      
      final isDesktop = !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
      
      if (isDesktop) {
        finalUrl = path;
      } else {
        final modelsDir = await EmbeddedModelManager.instance.getModelsDirectory();
        final destFile = File('${modelsDir.path}/$filename');
        if (!destFile.existsSync()) {
          final sourceFile = File(path);
          await sourceFile.copy(destFile.path);
        }
        finalUrl = destFile.path;
      }

      final model = EmbeddedGgufModel(
        id: 'disk_${DateTime.now().millisecondsSinceEpoch}',
        displayName: filename.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), '').replaceAll(RegExp(r'[-_]'), ' '),
        filename: filename,
        url: finalUrl,
        description: 'Local model added from disk.',
        sizeBytes: file.size,
      );

      await EmbeddedModelManager.instance.addCustomModel(model);
      await _refresh();
      
      widget.onFilenameSelected(model.filename);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added local model "${model.displayName}" from disk.'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add model from disk: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// Removes [model] from the custom model list (without deleting any downloaded file).
  Future<void> _removeFromList(EmbeddedGgufModel model) async {
    if (_isServerMode) {
      final current = (await widget.serverClient!.getServerCustomModels())
          .map((e) => EmbeddedGgufModel.fromJson(e))
          .toList();
      current.removeWhere((m) => m.id == model.id);
      await widget.serverClient!.saveServerCustomModels(current.map((m) => m.toJson()).toList());
    } else {
      await EmbeddedModelManager.instance.removeCustomModel(model.id);
    }
    if (widget.selectedFilename == model.filename) {
      widget.onFilenameSelected('');
    }
    await _refresh();
  }

  /// Saves [gpuLayers] for [filename] and updates state.
  Future<void> _setGpuLayers(String filename, int gpuLayers) async {
    await EmbeddedModelManager.instance.saveGpuLayers(filename, gpuLayers);
    if (mounted) setState(() => _gpuLayersMap[filename] = gpuLayers);
  }

  /// Loads [model] into the LlamaEngine (app memory). Shows progress in-place.
  Future<void> _loadModelIntoApp(EmbeddedGgufModel model) async {
    if (_appLoadingFilename != null) return; // already loading

    // Warn the user when the model is likely too large for CPU-only on Android.
    final bool cpuOnly = (_gpuLayersMap[model.filename] ?? 0) == 0;
    if (! _isServerMode && Platform.isAndroid && cpuOnly && model.sizeBytes > _cpuSizeWarnBytes) {
      if (!context.mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Model may be too large'),
          content: Text(
            '${model.displayName}${model.sizeLabel.isNotEmpty ? ' (${model.sizeLabel})' : ''} '
            'is larger than 1.5 GB. On CPU-only mode this often fails on Android due '
            'to process memory limits.\n\n'
            'Try a smaller quantization (Q2_K or Q3_K_S), or enable GPU layers '
            'if your device supports it.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Load anyway')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    setState(() {
      _appLoadingFilename = model.filename;
      _appLoadProgress = 0.0;
    });
    try {
      if (_isServerMode) {
        final gpuLayers = _gpuLayersMap[model.filename] ?? 0;
        await widget.serverClient!.loadServerModel(model.filename, gpuLayers: gpuLayers);
        _serverLoadedFilename = model.filename;
      } else {
        final gpuLayers = _gpuLayersMap[model.filename] ?? 0;
        final fullPath = await EmbeddedModelManager.instance.fullPathForFilename(model.filename);
        await EmbeddedLlmAdapter.instance.initialize(
          fullPath,
          gpuLayers: gpuLayers,
          contextSize: model.contextSize,
          onProgress: (p) {
            if (mounted) setState(() => _appLoadProgress = p);
          },
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${L.of(context).loadModelFailed}: $e'),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _appLoadingFilename = null);
    }
  }

  /// Unloads the currently loaded model from app memory.
  Future<void> _unloadModelFromApp() async {
    if (_isServerMode) {
      await widget.serverClient!.unloadServerModel();
      _serverLoadedFilename = null;
    } else {
      await EmbeddedLlmAdapter.instance.dispose();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Read current app-loaded model on every build (singleton, no listener needed)
    final appLoadedPath = _isServerMode ? null : EmbeddedLlmAdapter.instance.loadedModelPath;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final models = _allModels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header ──────────────────────────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: Text(
                _isServerMode ? 'Server-hosted models' : 'On-device models',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // ── Model catalog list ───────────────────────────────────────────────
        if (models.isEmpty)
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.explore_outlined, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('Find a model to get started', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use "Discover popular" to browse HuggingFace GGUF repos, or paste a direct download URL with "Add GGUF URL".',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          )
        else
          ...models.map((model) {
            final isDownloaded = _downloadedFilenames.contains(model.filename);
            // Compute full path for comparison (sync fallback: use filename)
            final isAppLoaded = _isServerMode
                ? (_serverLoadedFilename == model.filename)
                : (EmbeddedLlmAdapter.instance.isLoaded && (appLoadedPath?.endsWith(model.filename) ?? false));
            final isAppLoading = _appLoadingFilename == model.filename;
            // Custom models (not default catalog) can be removed from the list.
            final isCustom = _customModels.any((m) => m.id == model.id);
            return _ModelTile(
              key: ValueKey(model.filename),
              model: model,
              isSelected: widget.selectedFilename == model.filename,
              isDownloaded: isDownloaded,
              downloadProgress: _downloadProgress[model.filename],
              onSelect: isDownloaded ? () => widget.onFilenameSelected(model.filename) : null,
              onDownload: () => _startDownload(model),
              onCancelDownload: () => _cancelDownload(model.filename),
              onDelete: isDownloaded ? () => _deleteModel(model) : null,
              onRemoveFromList: (isCustom && !isDownloaded) ? () => _removeFromList(model) : null,
              isAppLoaded: isAppLoaded,
              isAppLoading: isAppLoading,
              appLoadProgress: isAppLoading ? _appLoadProgress : null,
              gpuLayers: _gpuLayersMap[model.filename] ?? 0,
              onGpuLayersChanged: isDownloaded ? (v) => _setGpuLayers(model.filename, v) : null,
              gpuSupported: _gpuSupported ?? true,
              vramFreeBytes: _vramFreeBytes,
              onLoadToApp: (isDownloaded && !isAppLoaded && !isAppLoading && _appLoadingFilename == null)
                  ? () => _loadModelIntoApp(model)
                  : null,
              onUnloadFromApp: isAppLoaded ? _unloadModelFromApp : null,
              showRuntimeControls: true,
              isServerMode: _isServerMode,
            );
          }),
        const SizedBox(height: 16),
        // ── Action buttons ───────────────────────────────────────────────────
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _openDiscover,
              icon: const Icon(Icons.explore_outlined, size: 18),
              label: const Text('Discover popular'),
            ),
            OutlinedButton.icon(onPressed: _openAddGguf, icon: const Icon(Icons.add_link, size: 18), label: const Text('Add GGUF URL')),
            if (!_isServerMode)
              OutlinedButton.icon(
                onPressed: _openAddFromDisk,
                icon: const Icon(Icons.drive_folder_upload, size: 18),
                label: const Text('Add GGUF from Disk'),
              ),
            if (_downloadedFilenames.isNotEmpty)
              OutlinedButton.icon(
                onPressed: _deleteAllModels,
                icon: Icon(Icons.delete_sweep_outlined, size: 18, color: AppTheme.error),
                label: Text('Remove all', style: TextStyle(color: AppTheme.error)),
                style: OutlinedButton.styleFrom(side: BorderSide(color: AppTheme.error.withValues(alpha: 0.5))),
              ),
          ],
        ),
        const SizedBox(height: 8),
        // ── Hint when nothing selected ───────────────────────────────────────
        if (widget.selectedFilename.isEmpty && _downloadedFilenames.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: AppTheme.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Select a downloaded model above to activate it.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.warning, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        if (_downloadedFilenames.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _isServerMode
                  ? 'Download a model to store it on the server host at /data/models.'
                  : 'Download a model to use on-device inference.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

// ── _ModelTile ──────────────────────────────────────────────────────────────

class _ModelTile extends StatelessWidget {
  final EmbeddedGgufModel model;
  final bool isSelected;
  final bool isDownloaded;
  final double? downloadProgress; // null = not downloading
  final VoidCallback? onSelect;
  final VoidCallback onDownload;
  final VoidCallback onCancelDownload;
  final VoidCallback? onDelete;
  // App-load state
  final bool isAppLoaded;
  final bool isAppLoading;
  final double? appLoadProgress; // null unless actively loading into app
  final int gpuLayers;
  final ValueChanged<int>? onGpuLayersChanged;
  final bool gpuSupported;
  final int vramFreeBytes; // 0 = unknown / no dedicated GPU memory
  final VoidCallback? onLoadToApp;
  final VoidCallback? onUnloadFromApp;
  final VoidCallback? onRemoveFromList;
  final bool showRuntimeControls;
  final bool isServerMode;

  const _ModelTile({
    super.key,
    required this.model,
    required this.isSelected,
    required this.isDownloaded,
    required this.downloadProgress,
    required this.onSelect,
    required this.onDownload,
    required this.onCancelDownload,
    required this.onDelete,
    this.isAppLoaded = false,
    this.isAppLoading = false,
    this.appLoadProgress,
    this.gpuLayers = 0,
    this.onGpuLayersChanged,
    this.gpuSupported = true,
    this.vramFreeBytes = 0,
    this.onLoadToApp,
    this.onUnloadFromApp,
    this.onRemoveFromList,
    this.showRuntimeControls = true,
    this.isServerMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDownloading = downloadProgress != null;
    final selectedButMissing = isSelected && !isDownloaded;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: (isSelected && isDownloaded)
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: AppTheme.primaryBlue, width: 2),
            )
          : selectedButMissing
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: AppTheme.warning, width: 2),
            )
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isDownloaded && !isDownloading ? onSelect : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isDownloaded)
                    RadioGroup<bool>(
                      groupValue: isSelected,
                      onChanged: (_) => onSelect?.call(),
                      child: Radio<bool>(
                        value: true,
                        activeColor: AppTheme.primaryBlue,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    )
                  else
                    const SizedBox(width: 24),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(model.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          model.description,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (model.sizeLabel.isNotEmpty) _Chip(label: model.sizeLabel, icon: Icons.sd_card_outlined),
                            _Chip(label: '≥ ${model.minRamGb} GB RAM', icon: Icons.memory_outlined),
                            _Chip(label: '${(model.contextSize / 1024).round()}K ctx', icon: Icons.chat_bubble_outline),
                            if (model.supportsToolCalling)
                              _Chip(label: 'Tool calling', icon: Icons.build_outlined, color: AppTheme.success),
                            // Warn when model is too large for CPU-only on mobile
                            if (!gpuSupported && model.sizeBytes > _EmbeddedModelPickerWidgetState._cpuSizeWarnBytes)
                              _Chip(label: 'May not load on CPU', icon: Icons.warning_amber_rounded, color: AppTheme.warning),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isDownloaded && !isDownloading) ...[
                        IconButton(icon: const Icon(Icons.download_outlined), tooltip: 'Download model', onPressed: onDownload),
                        if (onRemoveFromList != null)
                          IconButton(
                            icon: Icon(Icons.close, size: 18, color: theme.colorScheme.onSurfaceVariant),
                            tooltip: 'Remove from list',
                            onPressed: onRemoveFromList,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          ),
                      ] else if (isDownloading)
                        IconButton(icon: const Icon(Icons.cancel_outlined), tooltip: 'Cancel download', onPressed: onCancelDownload)
                      else if (onDelete != null)
                        IconButton(
                          icon: Icon(Icons.delete_outline, color: theme.colorScheme.onSurfaceVariant),
                          tooltip: 'Delete model',
                          onPressed: onDelete,
                        ),
                    ],
                  ),
                ],
              ),
              // ── Download progress ────────────────────────────────────────
              if (isDownloading) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: downloadProgress,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  color: AppTheme.primaryBlue,
                ),
                const SizedBox(height: 4),
                Text(
                  downloadProgress != null ? 'Downloading… ${(downloadProgress! * 100).toStringAsFixed(0)}%' : 'Starting…',
                  style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.primaryBlue),
                ),
              ],
              if (selectedButMissing) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 14, color: AppTheme.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Selected in settings, but not downloaded yet. Download is required before use.',
                        style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warning),
                      ),
                    ),
                  ],
                ),
              ],
              // ── App-memory load state ────────────────────────────────────
              if (showRuntimeControls && isDownloaded && !isDownloading) ...[
                const SizedBox(height: 8),
                // GPU layers picker
                if (onGpuLayersChanged != null) ...[
                  Row(
                    children: [
                      Icon(Icons.memory_outlined, size: 13, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text('GPU layers:', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 0, label: Text('CPU'), icon: Icon(Icons.computer, size: 13)),
                        ButtonSegment(value: 32, label: Text('Partial'), icon: Icon(Icons.auto_fix_high, size: 13)),
                        ButtonSegment(value: 99, label: Text('Full GPU'), icon: Icon(Icons.bolt, size: 13)),
                      ],
                      selected: {
                        gpuLayers == 0
                            ? 0
                            : gpuLayers <= 32
                            ? 32
                            : 99,
                      },
                      onSelectionChanged: isAppLoaded || isAppLoading
                          ? null
                          : (s) {
                              final v = s.first;
                              if (v != 0 && !gpuSupported) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(isServerMode
                                        ? 'GPU acceleration is not supported on the server host — using CPU only.'
                                        : 'GPU acceleration is not supported on this device — using CPU only.'),
                                    duration: const Duration(seconds: 3),
                                  ),
                                );
                                onGpuLayersChanged!(0);
                              } else {
                                onGpuLayersChanged!(v);
                              }
                            },
                      style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11)),
                        iconSize: WidgetStateProperty.all(13),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // GPU warnings
                  if (gpuLayers > 0 && !gpuSupported)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, size: 14, color: AppTheme.warning),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              isServerMode
                                  ? 'GPU not supported on the server — model will run on CPU.'
                                  : 'GPU not supported on this device — model will run on CPU.',
                              style: TextStyle(fontSize: 11, color: AppTheme.warning),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (gpuLayers > 0 && vramFreeBytes > 0 && model.sizeBytes > vramFreeBytes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, size: 14, color: AppTheme.warning),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Model (~${(model.sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB) may exceed available GPU memory (~${(vramFreeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB free). Consider CPU or Partial GPU.',
                              style: TextStyle(fontSize: 11, color: AppTheme.warning),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                Row(
                  children: [
                    if (isAppLoaded) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.success.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppTheme.success.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.memory, size: 12, color: AppTheme.success),
                            const SizedBox(width: 4),
                            Text(
                              L.of(context).modelLoadedInApp,
                              style: TextStyle(fontSize: 11, color: AppTheme.success, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      if (onUnloadFromApp != null)
                        OutlinedButton.icon(
                          onPressed: onUnloadFromApp,
                          icon: const Icon(Icons.memory_outlined, size: 14),
                          label: Text(L.of(context).unloadModel),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
                            textStyle: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ] else if (isAppLoading) ...[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LinearProgressIndicator(
                              value: (appLoadProgress == null || appLoadProgress == 0.0) ? null : appLoadProgress,
                              backgroundColor: theme.colorScheme.surfaceContainerHighest,
                              color: AppTheme.primaryBlue,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              (appLoadProgress != null && appLoadProgress! > 0.0)
                                  ? L.of(context).loadingModelProgress((appLoadProgress! * 100).round())
                                  : L.of(context).loadingModelIntoApp,
                              style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.primaryBlue),
                            ),
                          ],
                        ),
                      ),
                    ] else if (onLoadToApp != null) ...[
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: onLoadToApp,
                        icon: const Icon(Icons.memory, size: 14),
                        label: Text(L.of(context).loadModelIntoApp),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          backgroundColor: AppTheme.primaryBlue,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── _Chip (small info badge) ─────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color? color;

  const _Chip({required this.label, required this.icon, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: c),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
