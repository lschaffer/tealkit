import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../providers/database_providers.dart';
import '../providers/server_mode_provider.dart';
import '../services/llm_task_resync_service.dart';
import '../services/settings_vault_service.dart';

/// Full-screen dialog for exporting / importing the encrypted settings vault.
class SettingsVaultScreen extends ConsumerStatefulWidget {
  const SettingsVaultScreen({super.key});

  static Future<void> show(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => const SettingsVaultScreen(),
      fullscreenDialog: true,
    ),
  );

  @override
  ConsumerState<SettingsVaultScreen> createState() =>
      _SettingsVaultScreenState();
}

class _SettingsVaultScreenState extends ConsumerState<SettingsVaultScreen> {
  bool _exporting = false;
  bool _importing = false;

  // ─── Password dialog ───────────────────────────────────────────────────────

  Future<String?> _askPassword({
    required String title,
    bool withConfirm = false,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _VaultPasswordDialog(
        title: title,
        withConfirm: withConfirm,
      ),
    );
  }

  // ─── Export ───────────────────────────────────────────────────────────────

  Future<void> _doExport() async {
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

    if (isMobile) {
      // On Android / iOS, ask for filename, password, and sections FIRST,
      // build encrypted bytes, then use native FilePicker.saveFile (SAF / Files)
      // so Downloads, Documents, Google Drive, and any folder work cleanly.
      final params = await showDialog<(String, String, VaultOptions)>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _VaultExportDialog(),
      );
      if (params == null || !mounted) return;

      setState(() => _exporting = true);
      try {
        final serverClient = ref.read(serverApiClientProvider);
        final rawName = params.$1.trim();
        final fileName = rawName.endsWith('.tkv') ? rawName : '$rawName.tkv';
        final bytes = await SettingsVaultService.instance.buildVaultBytes(
          params.$2,
          params.$3,
          serverClient: serverClient,
        );
        final savedUri = await FilePicker.saveFile(
          dialogTitle: L.of(context).vaultTitle,
          fileName: fileName,
          bytes: bytes,
        );
        if (!mounted) return;
        if (savedUri == null) return; // User cancelled SAF save dialog.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L.of(context).vaultSaved(fileName)),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 4),
          ),
        );
      } on VaultException catch (e) {
        if (mounted) _showError(e.message);
      } catch (e) {
        if (mounted) _showError(L.of(context).vaultExportFailed(e.toString()));
      } finally {
        if (mounted) setState(() => _exporting = false);
      }
      return;
    }

    final String? dirPath;
    try {
      dirPath = await SettingsVaultService.instance.pickExportDirectory();
    } catch (e) {
      if (mounted) _showError(e.toString().replaceFirst('Exception: ', ''));
      return;
    }
    if (dirPath == null || !mounted) return;

    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    final params = await showDialog<(String, String, VaultOptions)>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _VaultExportDialog(),
    );
    if (params == null || !mounted) return;

    setState(() => _exporting = true);
    try {
      final serverClient = ref.read(serverApiClientProvider);
      final path = await SettingsVaultService.instance.exportToDirectory(
        dirPath,
        params.$1,
        params.$2,
        params.$3,
        serverClient: serverClient,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.of(context).vaultSaved(path.split(Platform.pathSeparator).last),
          ),
          backgroundColor: AppTheme.success,
          duration: const Duration(seconds: 4),
        ),
      );
    } on VaultException catch (e) {
      if (mounted) _showError(e.message);
    } catch (e) {
      if (mounted) _showError(L.of(context).vaultExportFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ─── Import ───────────────────────────────────────────────────────────────

  Future<void> _doImport() async {
    final File? file;
    try {
      file = await SettingsVaultService.instance.pickImportFile();
    } catch (e) {
      if (mounted) _showError(e.toString().replaceFirst('Exception: ', ''));
      return;
    }
    if (file == null || !mounted) return;

    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    final pw = await _askPassword(
      title: L.of(context).vaultDialogEnterVaultPassword,
    );
    if (pw == null || !mounted) return;

    setState(() => _importing = true);
    Map<String, dynamic> payload;
    try {
      payload = await SettingsVaultService.instance.decryptPayload(
        await file.readAsBytes(),
        pw,
      );
    } on VaultException catch (e) {
      if (mounted) {
        setState(() => _importing = false);
        _showError(e.message);
      }
      return;
    } catch (e) {
      if (mounted) {
        setState(() => _importing = false);
        _showError(L.of(context).vaultImportFailed(e.toString()));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _importing = false);

    // Let any closing dialog/keyboard transition settle cleanly first.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    final sections =
        (payload['_sections'] as List?)?.cast<String>() ?? ['configuration'];
    final vaultFileName = file.path.split(Platform.pathSeparator).last;
    final options = await showDialog<VaultOptions>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _VaultImportDialog(
        vaultFileName: vaultFileName,
        availableSections: sections,
      ),
    );
    if (options == null || !mounted) return;

    setState(() => _importing = true);
    try {
      final serverClient = ref.read(serverApiClientProvider);
      await SettingsVaultService.instance.restoreFromPayload(
        payload,
        options,
        serverClient: serverClient,
      );
      if (options.includeConfiguration) {
        // ignore: unawaited_futures
        LlmTaskResyncService.resyncLlm2Tasks();
      }
      if (options.includeTasks) {
        ref.invalidate(taskListProvider);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.of(context).vaultRestored(vaultFileName)),
          backgroundColor: AppTheme.success,
          duration: const Duration(seconds: 4),
        ),
      );
    } on VaultException catch (e) {
      if (mounted) _showError(e.message);
    } catch (e) {
      if (mounted) _showError(L.of(context).vaultImportFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppTheme.error),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.vaultTitle), leading: const CloseButton()),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.primaryBlue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.lock_outlined,
                  color: AppTheme.primaryBlue,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.vaultScreenTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l.vaultScreenDesc,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey[400],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _InfoBox(
            icon: Icons.check_circle_outline,
            color: AppTheme.success,
            label: l.vaultIncludedLabel,
            text: l.vaultIncludedText,
          ),
          const SizedBox(height: 8),
          _InfoBox(
            icon: Icons.remove_circle_outline,
            color: Colors.grey,
            label: l.vaultExcludedLabel,
            text: l.vaultExcludedText,
          ),
          const SizedBox(height: 24),
          _SectionHeader(label: l.vaultExportSection, icon: Icons.upload_file),
          const SizedBox(height: 8),
          Text(
            l.vaultExportHint,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[400]),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _exporting ? null : _doExport,
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_alt),
              label: Text(
                _exporting ? l.vaultEncrypting : l.vaultChooseFolderExport,
              ),
            ),
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 24),
          _SectionHeader(
            label: l.vaultImportSection,
            icon: Icons.download_for_offline_outlined,
          ),
          const SizedBox(height: 8),
          Text(
            l.vaultImportHint,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[400]),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.warning),
              onPressed: _importing ? null : _doImport,
              icon: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.folder_open),
              label: Text(
                _importing ? l.vaultDecrypting : l.vaultPickFileImport,
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// ─── Dedicated Stateful Dialogs (proper controller & context lifecycle) ──────

class _VaultPasswordDialog extends StatefulWidget {
  final String title;
  final bool withConfirm;

  const _VaultPasswordDialog({
    required this.title,
    required this.withConfirm,
  });

  @override
  State<_VaultPasswordDialog> createState() => _VaultPasswordDialogState();
}

class _VaultPasswordDialogState extends State<_VaultPasswordDialog> {
  final _pwCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscure = true;
  bool _obscureConfirm = true;
  String? _error;

  @override
  void dispose() {
    _pwCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _cancel() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop();
  }

  void _submit(L l) {
    final pw = _pwCtrl.text.trim();
    if (pw.length < 8) {
      setState(() => _error = l.vaultDialogPasswordShort);
      return;
    }
    if (widget.withConfirm && pw != _confirmCtrl.text.trim()) {
      setState(() => _error = l.vaultPasswordMismatch);
      return;
    }
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(pw);
  }

  Widget _buildFields(L l) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _pwCtrl,
          obscureText: _obscure,
          autofocus: true,
          onSubmitted: (_) => _submit(l),
          decoration: InputDecoration(
            labelText: l.vaultDialogPassword,
            hintText: widget.withConfirm
                ? l.vaultDialogPasswordMin
                : l.vaultDialogPasswordHint,
            errorText: _error,
            suffixIcon: IconButton(
              icon: Icon(
                _obscure ? Icons.visibility_off : Icons.visibility,
                size: 20,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        if (widget.withConfirm) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _confirmCtrl,
            obscureText: _obscureConfirm,
            onSubmitted: (_) => _submit(l),
            decoration: InputDecoration(
              labelText: l.vaultDialogConfirmPassword,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureConfirm ? Icons.visibility_off : Icons.visibility,
                  size: 20,
                ),
                onPressed: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm),
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final isMobile = MediaQuery.sizeOf(context).width < 700;

    if (isMobile) {
      return Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.title),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: _cancel,
            ),
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [_buildFields(l)],
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _cancel,
                      child: Text(l.cancel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _submit(l),
                      child: Text(l.ok),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return AlertDialog(
      title: Text(widget.title),
      content: _buildFields(l),
      actions: [
        TextButton(onPressed: _cancel, child: Text(l.cancel)),
        FilledButton(onPressed: () => _submit(l), child: Text(l.ok)),
      ],
    );
  }
}

class _VaultExportDialog extends StatefulWidget {
  const _VaultExportDialog();

  @override
  State<_VaultExportDialog> createState() => _VaultExportDialogState();
}

class _VaultExportDialogState extends State<_VaultExportDialog> {
  late final TextEditingController _nameCtrl;
  final _pwCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _incConfig = true;
  bool _incScripts = true;
  bool _incTasks = true;
  bool _incSessions = true;
  bool _incSkills = true;
  bool _incServerConns = true;
  bool _obscure = true;
  bool _obscureConfirm = true;
  String? _error;

  static String _td(int n) => n.toString().padLeft(2, '0');

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final defaultName =
        'tealkit_vault_${now.year}${_td(now.month)}${_td(now.day)}_${_td(now.hour)}${_td(now.minute)}';
    _nameCtrl = TextEditingController(text: defaultName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pwCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _cancel() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop();
  }

  void _submit(L l) {
    final name = _nameCtrl.text.trim();
    final pw = _pwCtrl.text;
    if (name.isEmpty) {
      setState(() => _error = l.vaultDialogEnterFilename);
      return;
    }
    if (pw.length < 8) {
      setState(() => _error = l.vaultDialogPasswordShort);
      return;
    }
    if (pw != _confirmCtrl.text) {
      setState(() => _error = l.vaultPasswordMismatch);
      return;
    }
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop((
      name,
      pw,
      VaultOptions(
        includeConfiguration: _incConfig,
        includeScripts: _incScripts,
        includeTasks: _incTasks,
        includePlaygroundSessions: _incSessions,
        includeSkills: _incSkills,
        includeServerConnections: _incServerConns,
      ),
    ));
  }

  Widget _buildContent(L l) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _nameCtrl,
          decoration: InputDecoration(labelText: l.vaultDialogFilenameLabel),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _pwCtrl,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: l.vaultDialogPasswordLabel,
            errorText: _error,
            suffixIcon: IconButton(
              icon: Icon(
                _obscure ? Icons.visibility_off : Icons.visibility,
                size: 20,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _confirmCtrl,
          obscureText: _obscureConfirm,
          decoration: InputDecoration(
            labelText: l.vaultDialogConfirmPassword,
            suffixIcon: IconButton(
              icon: Icon(
                _obscureConfirm ? Icons.visibility_off : Icons.visibility,
                size: 20,
              ),
              onPressed: () =>
                  setState(() => _obscureConfirm = !_obscureConfirm),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          l.vaultDialogIncludeLabel,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionConfiguration),
          subtitle: Text(
            l.vaultSectionConfigurationDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incConfig,
          onChanged: (v) => setState(() => _incConfig = v ?? true),
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionServerConnections),
          subtitle: Text(
            l.vaultSectionServerConnectionsDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incServerConns,
          onChanged: (v) => setState(() => _incServerConns = v ?? true),
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionScripts),
          subtitle: Text(
            l.vaultSectionScriptsDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incScripts,
          onChanged: (v) => setState(() => _incScripts = v ?? true),
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionTasks),
          subtitle: Text(
            l.vaultSectionTasksDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incTasks,
          onChanged: (v) => setState(() => _incTasks = v ?? true),
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionSessions),
          subtitle: Text(
            l.vaultSectionSessionsDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incSessions,
          onChanged: (v) => setState(() => _incSessions = v ?? true),
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionSkills),
          subtitle: Text(
            l.vaultSectionSkillsDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incSkills,
          onChanged: (v) => setState(() => _incSkills = v ?? true),
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final isMobile = MediaQuery.sizeOf(context).width < 700;

    if (isMobile) {
      return Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(l.vaultDialogExportTitle),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: _cancel,
            ),
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _buildContent(l),
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _cancel,
                      child: Text(l.cancel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _submit(l),
                      child: Text(l.vaultExportButton),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return AlertDialog(
      title: Text(l.vaultDialogExportTitle),
      content: SingleChildScrollView(child: _buildContent(l)),
      actions: [
        TextButton(onPressed: _cancel, child: Text(l.cancel)),
        FilledButton(
          onPressed: () => _submit(l),
          child: Text(l.vaultExportButton),
        ),
      ],
    );
  }
}

class _VaultImportDialog extends StatefulWidget {
  final String vaultFileName;
  final List<String> availableSections;

  const _VaultImportDialog({
    required this.vaultFileName,
    required this.availableSections,
  });

  @override
  State<_VaultImportDialog> createState() => _VaultImportDialogState();
}

class _VaultImportDialogState extends State<_VaultImportDialog> {
  late bool _incConfig;
  late bool _incScripts;
  late bool _incTasks;
  late bool _incSessions;
  late bool _incSkills;
  late bool _incServerConns;

  @override
  void initState() {
    super.initState();
    final s = widget.availableSections;
    _incConfig = s.contains('configuration');
    _incScripts = s.contains('scripts');
    _incTasks = s.contains('tasks');
    _incSessions = s.contains('playground_sessions');
    _incSkills = s.contains('skills');
    _incServerConns = s.contains('server_connections');
  }

  VaultOptions _buildOptions() => VaultOptions(
    includeConfiguration: _incConfig,
    includeScripts: _incScripts,
    includeTasks: _incTasks,
    includePlaygroundSessions: _incSessions,
    includeSkills: _incSkills,
    includeServerConnections: _incServerConns,
  );

  Widget _buildContent(L l) {
    final s = widget.availableSections;
    final isMobilePlatform = Platform.isAndroid || Platform.isIOS;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.vaultDialogFrom(widget.vaultFileName),
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 12),
        Text(
          l.vaultDialogSelectRestore,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionConfiguration),
          subtitle: Text(
            l.vaultSectionConfigurationDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incConfig,
          onChanged: s.contains('configuration')
              ? (v) => setState(() => _incConfig = v ?? true)
              : null,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionServerConnections),
          subtitle: Text(
            l.vaultSectionServerConnectionsDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incServerConns,
          onChanged: s.contains('server_connections')
              ? (v) => setState(() => _incServerConns = v ?? true)
              : null,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionScripts),
          subtitle: Text(
            isMobilePlatform
                ? l.vaultSectionScriptsMobileDesc
                : l.vaultSectionScriptsDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incScripts,
          onChanged: s.contains('scripts')
              ? (v) => setState(() => _incScripts = v ?? true)
              : null,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionTasks),
          subtitle: Text(
            l.vaultSectionTasksDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incTasks,
          onChanged: s.contains('tasks')
              ? (v) => setState(() => _incTasks = v ?? true)
              : null,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionSessions),
          subtitle: Text(
            l.vaultSectionSessionsDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incSessions,
          onChanged: s.contains('playground_sessions')
              ? (v) => setState(() => _incSessions = v ?? true)
              : null,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        CheckboxListTile(
          title: Text(l.vaultSectionSkills),
          subtitle: Text(
            l.vaultSectionSkillsDesc,
            style: const TextStyle(fontSize: 11),
          ),
          value: _incSkills,
          onChanged: s.contains('skills')
              ? (v) => setState(() => _incSkills = v ?? true)
              : null,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        if (!s.contains('scripts') || !s.contains('tasks')) ...[
          const SizedBox(height: 8),
          Text(
            l.vaultGreyedNotice,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final isMobile = MediaQuery.sizeOf(context).width < 700;

    if (isMobile) {
      return Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(l.vaultDialogImportTitle),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _buildContent(l),
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l.cancel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.warning,
                      ),
                      onPressed: () =>
                          Navigator.of(context).pop(_buildOptions()),
                      child: Text(l.vaultRestoreButton),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return AlertDialog(
      title: Text(l.vaultDialogImportTitle),
      content: SingleChildScrollView(child: _buildContent(l)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.warning),
          onPressed: () => Navigator.of(context).pop(_buildOptions()),
          child: Text(l.vaultRestoreButton),
        ),
      ],
    );
  }
}

// ─── Supporting widgets ───────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final IconData icon;
  const _SectionHeader({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.primaryBlue),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: AppTheme.primaryBlue,
          ),
        ),
      ],
    );
  }
}

class _InfoBox extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String text;
  const _InfoBox({
    required this.icon,
    required this.color,
    required this.label,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey[400],
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
