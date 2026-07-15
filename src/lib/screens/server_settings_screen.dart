import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../providers/database_providers.dart';
import '../providers/server_mode_provider.dart';
import '../services/server_api_client.dart';
import '../services/server_sync_service.dart';

/// Settings screen for configuring TealKit server connections.
///
/// Allows the user to manage multiple server connection configurations,
/// test their connection, and switch between local and remote mode.
class ServerSettingsScreen extends ConsumerStatefulWidget {
  const ServerSettingsScreen({super.key});

  @override
  ConsumerState<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends ConsumerState<ServerSettingsScreen> {
  bool _connecting = false;
  bool _loadingDialogVisible = false;

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : AppTheme.success,
      ),
    );
  }

  void _showLoadingSettingsDialog() {
    if (!mounted || _loadingDialogVisible) return;
    _loadingDialogVisible = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(L.of(context).serverLoadingSettingsTitle),
        content: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(L.of(context).serverLoadingSettingsBody)),
          ],
        ),
      ),
    ).then((_) {
      _loadingDialogVisible = false;
    });
  }

  void _hideLoadingSettingsDialog() {
    if (!mounted || !_loadingDialogVisible) return;
    Navigator.of(context, rootNavigator: true).pop();
    _loadingDialogVisible = false;
  }

  Future<void> _activateAndConnect(ServerConnectionConfig conn) async {
    final l10n = L.of(context);
    final currentMode = ref.read(serverModeProvider).value;
    if (currentMode == null || !currentMode.isRemote) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.serverSwitchTitle),
          content: Text(l10n.serverSwitchBody),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.serverSwitchAction)),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() => _connecting = true);
    try {
      final ok = await ref.read(serverModeProvider.notifier).connect(
        conn,
        onPhase: (phase) {
          if (!mounted) return;
          if (phase == ServerConnectPhase.loadingSettings) {
            _showLoadingSettingsDialog();
          }
          if (phase == ServerConnectPhase.done) {
            _hideLoadingSettingsDialog();
          }
        },
      );
      if (!mounted) return;
      if (ok) {
        final client = ref.read(serverApiClientProvider);
        if (client != null) {
          await ServerSyncService.syncOnConnect(client);
        }
        _showSnack(l10n.serverConnected);
        ref.invalidate(taskListProvider);
        ref.invalidate(taskRepositoryProvider);
      } else {
        _showSnack(l10n.serverConnectionFailed, isError: true);
      }
    } finally {
      _hideLoadingSettingsDialog();
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _testConn(ServerConnectionConfig conn) async {
    final l10n = L.of(context);
    setState(() => _connecting = true);
    try {
      final client = ServerApiClient(serverUrl: conn.url, apiKey: conn.apiKey.isNotEmpty ? conn.apiKey : null);
      final reachable = await client.ping();
      if (!mounted) return;
      if (!reachable) {
        _showSnack('${conn.name}: ${l10n.serverNotReachable}', isError: true);
        return;
      }

      final authorized = await client.validateAuthorization();
      if (!mounted) return;
      _showSnack(
        authorized 
            ? '${conn.name}: ${l10n.serverReachableAuthorized}' 
            : '${conn.name}: ${l10n.serverReachableUnauthorized}', 
        isError: !authorized,
      );
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _showAddEditConnectionDialog([ServerConnectionConfig? existing]) async {
    final l10n = L.of(context);
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(text: existing?.url ?? '');
    final keyCtrl = TextEditingController(text: existing?.apiKey ?? '');
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<ServerConnectionConfig?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? 'Edit Server Connection' : 'Add Server Connection'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Connection Name',
                    hintText: 'e.g. Home Server',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Name is required';
                    final name = v.trim();
                    final current = ref.read(serverModeProvider).value;
                    if (current != null) {
                      final dup = current.connections.any((c) =>
                          c.name.toLowerCase() == name.toLowerCase() &&
                          (!isEdit || c.name.toLowerCase() != existing.name.toLowerCase()));
                      if (dup) return 'A connection with this name already exists';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'https://...',
                    border: OutlineInputBorder(),
                    helperText: 'Include port; no trailing slash',
                  ),
                  keyboardType: TextInputType.url,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return l10n.urlRequired;
                    final uri = Uri.tryParse(v.trim());
                    if (uri == null || !uri.hasScheme) return l10n.serverSettingsUrlInvalid;
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: keyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'API Key (Optional)',
                    hintText: 'Bearer authentication token',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(ctx).pop(
                  ServerConnectionConfig(
                    name: nameCtrl.text.trim(),
                    url: urlCtrl.text.trim(),
                    apiKey: keyCtrl.text.trim(),
                  ),
                );
              }
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );

    if (result != null) {
      if (isEdit) {
        await ref.read(serverModeProvider.notifier).editConnection(existing.name, result);
        _showSnack('Connection updated');
      } else {
        await ref.read(serverModeProvider.notifier).addConnection(result);
        _showSnack('Connection added');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L.of(context);
    final modeAsync = ref.watch(serverModeProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.serverSettingsTitle)),
      body: modeAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(l10n.serverSettingsError(e.toString()))),
        data: (state) => _buildBody(context, state),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ServerModeState state) {
    final l10n = L.of(context);
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // ── Active Mode Header ──
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: theme.colorScheme.outlineVariant, width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: state.isRemote
                      ? (state.isConnected ? AppTheme.success.withAlpha(40) : AppTheme.error.withAlpha(40))
                      : theme.colorScheme.primaryContainer,
                  child: Icon(
                    state.isRemote ? (state.isConnected ? Icons.cloud_done : Icons.cloud_off) : Icons.phone_android,
                    color: state.isRemote
                        ? (state.isConnected ? AppTheme.success : AppTheme.error)
                        : theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.isRemote
                            ? 'Server Mode: ${state.activeConnectionName ?? "Remote"}'
                            : 'Local Mode',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        state.isRemote
                            ? (state.isConnected
                                ? 'Connected to ${state.serverUrl}'
                                : 'Disconnected from ${state.serverUrl}')
                            : 'All agents and indexing tasks execute locally on this device.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
                      ),
                    ],
                  ),
                ),
                if (state.isRemote)
                  OutlinedButton(
                    onPressed: _connecting ? null : () => ref.read(serverModeProvider.notifier).disconnect(),
                    style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                    child: const Text('Disconnect'),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),

        // ── Configured Servers Title ──
        Row(
          children: [
            Text(
              'Configured Servers',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            IconButton.filledTonal(
              onPressed: () => _showAddEditConnectionDialog(),
              icon: const Icon(Icons.add),
              tooltip: 'Add Connection',
            ),
          ],
        ),
        const SizedBox(height: 12),

        // ── Connections List ──
        if (state.connections.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'No server connections configured.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
              ),
            ),
          )
        else
          ...state.connections.map((conn) {
            final isActive = state.isRemote && state.activeConnectionName == conn.name;
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: isActive ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                  width: isActive ? 2 : 1,
                ),
              ),
              child: ListTile(
                title: Row(
                  children: [
                    Text(
                      conn.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (isActive) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.success.withAlpha(40),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Active',
                          style: TextStyle(color: AppTheme.success, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Text(conn.url, style: theme.textTheme.bodyMedium),
                    if (conn.apiKey.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'API Key: ${conn.apiKey.substring(0, conn.apiKey.length.clamp(0, 8))}••••••••',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                      ),
                    ],
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isActive)
                      IconButton(
                        icon: const Icon(Icons.cloud_upload),
                        tooltip: 'Activate / Connect',
                        onPressed: _connecting ? null : () => _activateAndConnect(conn),
                      ),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert),
                      tooltip: 'Actions',
                      onSelected: (val) async {
                        if (val == 'test') {
                          _testConn(conn);
                        } else if (val == 'edit') {
                          _showAddEditConnectionDialog(conn);
                        } else if (val == 'delete') {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Delete Connection'),
                              content: Text('Are you sure you want to delete "${conn.name}"?'),
                              actions: [
                                TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
                                FilledButton(
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                  style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
                                  child: Text(l10n.delete),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await ref.read(serverModeProvider.notifier).removeConnection(conn.name);
                            _showSnack('Connection deleted');
                          }
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'test',
                          child: Row(
                            children: [
                              const Icon(Icons.network_check, size: 20),
                              const SizedBox(width: 8),
                              Text(l10n.serverTestConnectionButton),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              const Icon(Icons.edit_outlined, size: 20),
                              const SizedBox(width: 8),
                              Text(l10n.edit),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete_outline, size: 20, color: theme.colorScheme.error),
                              const SizedBox(width: 8),
                              Text(l10n.delete, style: TextStyle(color: theme.colorScheme.error)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),

        const SizedBox(height: 24),

        // ── Info card ──
        Card(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.info_outline, size: 18),
                    const SizedBox(width: 8),
                    Text(l10n.serverAboutTitle, style: theme.textTheme.titleSmall),
                  ],
                ),
                const SizedBox(height: 8),
                Text(l10n.serverAboutBody, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
