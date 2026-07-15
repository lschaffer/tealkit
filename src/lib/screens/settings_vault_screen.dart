import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../providers/server_mode_provider.dart';
import '../services/llm_task_resync_service.dart';
import '../services/settings_vault_service.dart';

/// Full-screen dialog for exporting / importing the encrypted settings vault.
///
/// The vault covers:  LLM keys, email / IMAP / SMTP, SSH, Google Drive,
/// web-search keys, Slack, WhatsApp, Smithery API key, and MCP server list.
///
/// It does NOT include tasks, scripts, or conversation history — use the
/// regular Export Backup for those.
class SettingsVaultScreen extends ConsumerStatefulWidget {
  const SettingsVaultScreen({super.key});

  static Future<void> show(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsVaultScreen(), fullscreenDialog: true));

  @override
  ConsumerState<SettingsVaultScreen> createState() => _SettingsVaultScreenState();
}

class _SettingsVaultScreenState extends ConsumerState<SettingsVaultScreen> {
  bool _exporting = false;
  bool _importing = false;

  @override
  void dispose() => super.dispose();

  // ─── Password dialog ───────────────────────────────────────────────────────

  Future<String?> _askPassword({required String title, bool withConfirm = false}) async {
    final pwCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool obscure = true;
    bool obscureConfirm = true;
    String? error;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pwCtrl,
                obscureText: obscure,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: L.of(context).vaultDialogPassword,
                  hintText: withConfirm ? L.of(context).vaultDialogPasswordMin : L.of(context).vaultDialogPasswordHint,
                  errorText: error,
                  suffixIcon: IconButton(
                    icon: Icon(obscure ? Icons.visibility_off : Icons.visibility, size: 20),
                    onPressed: () => setS(() => obscure = !obscure),
                  ),
                ),
              ),
              if (withConfirm) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: confirmCtrl,
                  obscureText: obscureConfirm,
                  decoration: InputDecoration(
                    labelText: L.of(context).vaultDialogConfirmPassword,
                    suffixIcon: IconButton(
                      icon: Icon(obscureConfirm ? Icons.visibility_off : Icons.visibility, size: 20),
                      onPressed: () => setS(() => obscureConfirm = !obscureConfirm),
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(L.of(context).cancel)),
            FilledButton(
              onPressed: () {
                final pw = pwCtrl.text.trim();
                if (pw.length < 8) {
                  setS(() => error = L.of(context).vaultDialogPasswordShort);
                  return;
                }
                if (withConfirm && pw != confirmCtrl.text.trim()) {
                  setS(() => error = L.of(context).vaultPasswordMismatch);
                  return;
                }
                Navigator.pop(ctx, pw);
              },
              child: Text(L.of(context).ok),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  // ─── Export ───────────────────────────────────────────────────────────────

  Future<void> _doExport() async {
    // Step 1: pick folder
    final String? dirPath;
    try {
      dirPath = await SettingsVaultService.instance.pickExportDirectory();
    } catch (e) {
      if (mounted) _showError(e.toString().replaceFirst('Exception: ', ''));
      return;
    }
    if (dirPath == null || !mounted) return;

    // Let Flutter settle after the SAF picker closes before opening a dialog.
    await Future.delayed(Duration.zero);
    if (!mounted) return;

    // Step 2: show combined dialog (filename + password + section checkboxes)
    final params = await _showExportDialog();
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
          content: Text(L.of(context).vaultSaved(path.split(Platform.pathSeparator).last)),
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

  /// Shows the export dialog. Returns (fileName, password, VaultOptions) or null if cancelled.
  Future<(String, String, VaultOptions)?> _showExportDialog() async {
    final now = DateTime.now();
    final defaultName = 'tealkit_vault_${now.year}${_td(now.month)}${_td(now.day)}_${_td(now.hour)}${_td(now.minute)}';
    final nameCtrl = TextEditingController(text: defaultName);
    final pwCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool incConfig = true;
    bool incScripts = true;
    bool incTasks = true;
    bool incSessions = true;
    bool incSkills = true;
    bool obscure = true;
    bool obscureConfirm = true;
    String? error;

    final result = await showDialog<(String, String, VaultOptions)>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(L.of(context).vaultDialogExportTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(labelText: L.of(context).vaultDialogFilenameLabel),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: pwCtrl,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: L.of(context).vaultDialogPasswordLabel,
                    errorText: error,
                    suffixIcon: IconButton(
                      icon: Icon(obscure ? Icons.visibility_off : Icons.visibility, size: 20),
                      onPressed: () => setS(() => obscure = !obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: confirmCtrl,
                  obscureText: obscureConfirm,
                  decoration: InputDecoration(
                    labelText: L.of(context).vaultDialogConfirmPassword,
                    suffixIcon: IconButton(
                      icon: Icon(obscureConfirm ? Icons.visibility_off : Icons.visibility, size: 20),
                      onPressed: () => setS(() => obscureConfirm = !obscureConfirm),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(L.of(context).vaultDialogIncludeLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
                CheckboxListTile(
                  title: Text(L.of(context).vaultSectionConfiguration),
                  subtitle: Text(L.of(context).vaultSectionConfigurationDesc, style: const TextStyle(fontSize: 11)),
                  value: incConfig,
                  onChanged: (v) => setS(() => incConfig = v ?? true),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  title: Text(L.of(context).vaultSectionScripts),
                  subtitle: Text(L.of(context).vaultSectionScriptsDesc, style: const TextStyle(fontSize: 11)),
                  value: incScripts,
                  onChanged: (v) => setS(() => incScripts = v ?? true),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  title: Text(L.of(context).vaultSectionTasks),
                  subtitle: Text(L.of(context).vaultSectionTasksDesc, style: const TextStyle(fontSize: 11)),
                  value: incTasks,
                  onChanged: (v) => setS(() => incTasks = v ?? true),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  title: Text(L.of(context).vaultSectionSessions),
                  subtitle: Text(L.of(context).vaultSectionSessionsDesc, style: const TextStyle(fontSize: 11)),
                  value: incSessions,
                  onChanged: (v) => setS(() => incSessions = v ?? true),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  title: Text(L.of(context).vaultSectionSkills),
                  subtitle: Text(L.of(context).vaultSectionSkillsDesc, style: const TextStyle(fontSize: 11)),
                  value: incSkills,
                  onChanged: (v) => setS(() => incSkills = v ?? true),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(L.of(context).cancel)),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final pw = pwCtrl.text;
                if (name.isEmpty) {
                  setS(() => error = L.of(context).vaultDialogEnterFilename);
                  return;
                }
                if (pw.length < 8) {
                  setS(() => error = L.of(context).vaultDialogPasswordShort);
                  return;
                }
                if (pw != confirmCtrl.text) {
                  setS(() => error = L.of(context).vaultPasswordMismatch);
                  return;
                }
                Navigator.pop(ctx, (
                  name,
                  pw,
                  VaultOptions(
                    includeConfiguration: incConfig,
                    includeScripts: incScripts,
                    includeTasks: incTasks,
                    includePlaygroundSessions: incSessions,
                    includeSkills: incSkills,
                  ),
                ));
              },
              child: Text(L.of(context).vaultExportButton),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  // ─── Import ───────────────────────────────────────────────────────────────

  Future<void> _doImport() async {
    // Step 1: pick file
    final File? file;
    try {
      file = await SettingsVaultService.instance.pickImportFile();
    } catch (e) {
      if (mounted) _showError(e.toString().replaceFirst('Exception: ', ''));
      return;
    }
    if (file == null || !mounted) return;

    // Step 2: ask password
    final pw = await _askPassword(title: L.of(context).vaultDialogEnterVaultPassword);
    if (pw == null || !mounted) return;

    // Step 3: decrypt to discover available sections    // ignore: unused_local_variable    setState(() => _importing = true);
    Map<String, dynamic> payload;
    try {
      payload = await SettingsVaultService.instance.decryptPayload(await file.readAsBytes(), pw);
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

    // Step 4: show import options dialog
    final sections = (payload['_sections'] as List?)?.cast<String>() ?? ['configuration'];
    final vaultFileName = file.path.split(Platform.pathSeparator).last;
    final options = await _showImportDialog(vaultFileName, sections);
    if (options == null || !mounted) return;

    // Step 5: restore selected sections
    setState(() => _importing = true);
    try {
      final serverClient = ref.read(serverApiClientProvider);
      await SettingsVaultService.instance.restoreFromPayload(payload, options, serverClient: serverClient);
      // If LLM 2 settings were restored, update all tasks that use LLM 2 so
      // their cached model/key snapshot reflects the newly restored config.
      if (options.includeConfiguration) {
        // ignore: unawaited_futures
        LlmTaskResyncService.resyncLlm2Tasks();
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

  /// Shows the import options dialog. Returns VaultOptions or null if cancelled.
  Future<VaultOptions?> _showImportDialog(String vaultFileName, List<String> availableSections) async {
    bool incConfig = availableSections.contains('configuration');
    bool incScripts = availableSections.contains('scripts');
    bool incTasks = availableSections.contains('tasks');
    bool incSessions = availableSections.contains('playground_sessions');
    bool incSkills = availableSections.contains('skills');
    final isMobile = Platform.isAndroid || Platform.isIOS;

    return showDialog<VaultOptions>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(L.of(context).vaultDialogImportTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(L.of(context).vaultDialogFrom(vaultFileName), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 12),
                Text(L.of(context).vaultDialogSelectRestore, style: const TextStyle(fontWeight: FontWeight.w600)),
                CheckboxListTile(
                  title: Text(L.of(context).vaultSectionConfiguration),
                  subtitle: Text(L.of(context).vaultSectionConfigurationDesc, style: const TextStyle(fontSize: 11)),
                  value: incConfig,
                  onChanged: availableSections.contains('configuration') ? (v) => setS(() => incConfig = v ?? true) : null,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  title: Text(L.of(context).vaultSectionScripts),
                  subtitle: Text(
                    isMobile ? L.of(context).vaultSectionScriptsMobileDesc : L.of(context).vaultSectionScriptsDesc,
                    style: const TextStyle(fontSize: 11),
                  ),
                  value: incScripts,
                  onChanged: availableSections.contains('scripts') ? (v) => setS(() => incScripts = v ?? true) : null,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  title: Text(L.of(context).vaultSectionTasks),
                  subtitle: Text(L.of(context).vaultSectionTasksDesc, style: const TextStyle(fontSize: 11)),
                  value: incTasks,
                  onChanged: availableSections.contains('tasks') ? (v) => setS(() => incTasks = v ?? true) : null,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  title: Text(L.of(context).vaultSectionSessions),
                  subtitle: Text(L.of(context).vaultSectionSessionsDesc, style: const TextStyle(fontSize: 11)),
                  value: incSessions,
                  onChanged: availableSections.contains('playground_sessions') ? (v) => setS(() => incSessions = v ?? true) : null,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  title: Text(L.of(context).vaultSectionSkills),
                  subtitle: Text(L.of(context).vaultSectionSkillsDesc, style: const TextStyle(fontSize: 11)),
                  value: incSkills,
                  onChanged: availableSections.contains('skills') ? (v) => setS(() => incSkills = v ?? true) : null,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                if (!availableSections.contains('scripts') || !availableSections.contains('tasks')) ...[
                  const SizedBox(height: 8),
                  Text(L.of(context).vaultGreyedNotice, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(L.of(context).cancel)),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.warning),
              onPressed: () => Navigator.pop(
                ctx,
                VaultOptions(
                  includeConfiguration: incConfig,
                  includeScripts: incScripts,
                  includeTasks: incTasks,
                  includePlaygroundSessions: incSessions,
                  includeSkills: incSkills,
                ),
              ),
              child: Text(L.of(context).vaultRestoreButton),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

  static String _td(int n) => n.toString().padLeft(2, '0');

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppTheme.error));
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(L.of(context).vaultTitle), leading: const CloseButton()),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Header ────────────────────────────────────────────────────────
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppTheme.primaryBlue.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.lock_outlined, color: AppTheme.primaryBlue, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(L.of(context).vaultScreenTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(L.of(context).vaultScreenDesc, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[400])),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Scope info ────────────────────────────────────────────────────
          _InfoBox(
            icon: Icons.check_circle_outline,
            color: AppTheme.success,
            label: L.of(context).vaultIncludedLabel,
            text: L.of(context).vaultIncludedText,
          ),
          const SizedBox(height: 8),
          _InfoBox(
            icon: Icons.remove_circle_outline,
            color: Colors.grey,
            label: L.of(context).vaultExcludedLabel,
            text: L.of(context).vaultExcludedText,
          ),
          const SizedBox(height: 24),

          // ── EXPORT section ────────────────────────────────────────────
          _SectionHeader(label: L.of(context).vaultExportSection, icon: Icons.upload_file),
          const SizedBox(height: 8),
          Text(L.of(context).vaultExportHint, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[400])),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _exporting ? null : _doExport,
              icon: _exporting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_alt),
              label: Text(_exporting ? L.of(context).vaultEncrypting : L.of(context).vaultChooseFolderExport),
            ),
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 24),

          // ── IMPORT section ────────────────────────────────────────────
          _SectionHeader(label: L.of(context).vaultImportSection, icon: Icons.download_for_offline_outlined),
          const SizedBox(height: 8),
          Text(L.of(context).vaultImportHint, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[400])),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.warning),
              onPressed: _importing ? null : _doImport,
              icon: _importing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.folder_open),
              label: Text(_importing ? L.of(context).vaultDecrypting : L.of(context).vaultPickFileImport),
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
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
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: AppTheme.primaryBlue),
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
  const _InfoBox({required this.icon, required this.color, required this.label, required this.text});

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
                  style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(text, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[400], height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
