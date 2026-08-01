// ignore_for_file: unused_import

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_theme.dart';
import '../mcp/internal_mcp_server.dart';
import '../models/workflow_task.dart';
import '../models/function_hint.dart';
import '../providers/server_mode_provider.dart';
import '../services/app_logger.dart';
import '../services/external_tools_settings_service.dart';
import '../services/server_api_client.dart';
import '../services/function_hint_database_service.dart';
import '../services/function_hint_generation_service.dart';
import '../widgets/tool_list_export_sheet.dart';
import '../widgets/function_hint_build_progress_dialog.dart';

/// Derives a stable, DB-safe mcpType key for a remote/external MCP server.
String _mcpTypeForRemoteServer(McpToolConfig server) {
  final raw = server.serverUrl.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  return 'ext_${raw.length > 40 ? raw.substring(0, 40) : raw}';
}

/// Opens the MCP tools viewer screen for [server] as a full-screen dialog.
/// Call this from any screen that has a reference to a [McpToolConfig].
/// Set [autoGenerateSkills] to immediately generate skills for discovered tools.
Future<void> showMcpToolsViewerScreen(BuildContext context, McpToolConfig server, {bool autoGenerateSkills = false}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _McpToolsViewerScreen(server: server, autoGenerateSkills: autoGenerateSkills),
    ),
  );
}

class ExternalToolsSettingsScreen extends ConsumerStatefulWidget {
  final ExternalToolsSettingsService service;

  const ExternalToolsSettingsScreen({super.key, required this.service});

  static Future<bool?> show(BuildContext context, ExternalToolsSettingsService service) {
    return Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => ExternalToolsSettingsScreen(service: service)));
  }

  @override
  ConsumerState<ExternalToolsSettingsScreen> createState() => _ExternalToolsSettingsScreenState();
}

class _ExternalToolsSettingsScreenState extends ConsumerState<ExternalToolsSettingsScreen> {
  bool _loading = true;
  bool _savingUrl = false;
  bool _testingCustom = false;
  bool _addingCustom = false;
  String? _customTestMessage;
  bool _customTestOk = false;
  final _catalogUrlCtrl = TextEditingController();
  final _smitheryKeyCtrl = TextEditingController();
  bool _savingSmitheryKey = false;
  String _catalogSource = 'pulsemcp'; // 'pulsemcp' | 'smithery' | 'custom'
  final _customNameCtrl = TextEditingController();
  final _customUrlCtrl = TextEditingController();
  final _customEndpointCtrl = TextEditingController(text: '/mcp');
  final _customApiKeyCtrl = TextEditingController();
  final _customApiPasswordCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  bool get _isRemote => ref.read(serverModeProvider).value?.isRemote ?? false;

  ServerApiClient? get _serverClient => _isRemote ? ref.read(serverApiClientProvider) : null;

  Future<void> _refreshRemoteState() async {
    final client = _serverClient;
    if (client == null) return;
    final data = await client.getExternalToolsSettings();
    final servers = (data['selected_servers'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .map(McpToolConfig.fromJson)
        .toList();
    widget.service.applyInMemory(
      catalogBaseUrl: data['catalog_base_url'] as String?,
      catalogSource: data['catalog_source'] as String?,
      selectedServers: servers,
      smitheryApiKey: data['smithery_api_key'] as String?,
    );
  }

  Future<void> _saveSelectedServers(List<McpToolConfig> servers) async {
    final client = _serverClient;
    if (client != null) {
      await client.putExternalToolsSettings({'selected_servers': servers.map((server) => server.toJson()).toList()});
      widget.service.applyInMemory(selectedServers: servers);
      return;
    }
    await widget.service.saveSelectedServers(servers);
  }

  Future<void> _upsertSelectedServer(McpToolConfig server, {String? oldServerUrl}) async {
    final client = _serverClient;
    if (client != null) {
      final normalizedUrl = server.serverUrl.trim();
      final lookupUrl = (oldServerUrl ?? normalizedUrl).trim();
      final current = List<McpToolConfig>.from(widget.service.selectedServers);
      final index = current.indexWhere((entry) => entry.serverUrl.trim() == lookupUrl);
      if (index >= 0) {
        current[index] = server;
      } else {
        current.add(server);
      }
      current.sort(
        (a, b) => (a.name?.trim().isNotEmpty == true ? a.name!.trim() : a.serverUrl).compareTo(
          b.name?.trim().isNotEmpty == true ? b.name!.trim() : b.serverUrl,
        ),
      );
      await _saveSelectedServers(current);
      return;
    }
    await widget.service.upsertSelectedServer(server, oldServerUrl: oldServerUrl);
  }

  Future<void> _init() async {
    if (_isRemote) {
      await _refreshRemoteState();
    } else {
      // Always reload from local storage so remote-injected in-memory state
      // from a previous server-mode session is never shown in local mode.
      await widget.service.load();
    }
    if (!mounted) return;
    _catalogUrlCtrl.text = widget.service.catalogBaseUrl;
    _smitheryKeyCtrl.text = widget.service.smitheryApiKey;
    _catalogSource = widget.service.catalogSource;
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _catalogUrlCtrl.dispose();
    _smitheryKeyCtrl.dispose();
    _customNameCtrl.dispose();
    _customUrlCtrl.dispose();
    _customEndpointCtrl.dispose();
    _customApiKeyCtrl.dispose();
    _customApiPasswordCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveCatalogUrl() async {
    setState(() => _savingUrl = true);
    try {
      final client = _serverClient;
      if (client != null) {
        await client.putExternalToolsSettings({'catalog_base_url': _catalogUrlCtrl.text});
        widget.service.applyInMemory(catalogBaseUrl: _catalogUrlCtrl.text);
      } else {
        await widget.service.saveCatalogBaseUrl(_catalogUrlCtrl.text);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L.of(context).catalogUrlSaved)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L.of(context).failedToSaveUrl(e.toString())), backgroundColor: AppTheme.error));
    } finally {
      if (mounted) setState(() => _savingUrl = false);
    }
  }

  Future<void> _openCatalog() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _ExternalToolsCatalogScreen(service: widget.service, serverClient: _serverClient),
      ),
    );
    if (changed == true && mounted) {
      setState(() {});
    }
  }

  Future<void> _removeServer(String url) async {
    final updated = widget.service.selectedServers.where((e) => e.serverUrl != url).toList();
    await _saveSelectedServers(updated);
    if (mounted) setState(() {});
  }

  Future<void> _editSelectedServer(McpToolConfig server) async {
    final result = await showDialog<McpToolConfig>(
      context: context,
      builder: (ctx) => _EditMcpServerDialog(server: server),
    );

    if (result != null) {
      // Pass the original URL so upsertSelectedServer can locate the right
      // entry even when the user changed the URL in the dialog.
      await _upsertSelectedServer(result, oldServerUrl: server.serverUrl);
      if (mounted) setState(() {});
    }
  }

  String _statusLabel(McpToolConfig s) {
    final l = L.of(context);
    if (s.isOnline == true) return l.statusOnline;
    if (s.isOnline == false) return l.statusOffline;
    return l.statusUnknown;
  }

  Color _statusColor(McpToolConfig s) {
    if (s.isOnline == true) return AppTheme.success;
    if (s.isOnline == false) return AppTheme.error;
    return Colors.grey;
  }

  Future<void> _testSelectedServer(McpToolConfig server) async {
    final messenger = ScaffoldMessenger.of(context);
    final displayName = server.name?.trim().isNotEmpty == true ? server.name!.trim() : server.serverUrl;
    messenger.showSnackBar(
      SnackBar(
        content: Text(L.of(context).testingServerMsg(displayName)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final result = await widget.service.testMcpServer(
        serverUrl: server.serverUrl,
        mcpEndpoint: server.mcpEndpoint,
        apiKey: server.apiKey,
        apiPassword: server.apiPassword,
      );
      if (!mounted) return;
      final success = result['success'] == true;
      final message = (result['message'] ?? '').toString();
      messenger.showSnackBar(
        SnackBar(
          content: Text(success ? L.of(context).mcpTestSuccessMsg(message) : message),
          backgroundColor: success ? AppTheme.success : AppTheme.error,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(L.of(context).mcpTestFailedMsg(e.toString())),
          backgroundColor: AppTheme.error,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> _openServerTools(McpToolConfig server) async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _McpToolsViewerScreen(server: server)));
  }

  Future<void> _testCustomServer() async {
    final rawUrl = _customUrlCtrl.text.trim();
    final rawEndpoint = _customEndpointCtrl.text.trim();
    final rawApiKey = _customApiKeyCtrl.text.trim();
    final rawApiPassword = _customApiPasswordCtrl.text.trim();
    if (rawUrl.isEmpty) {
      setState(() {
        _customTestOk = false;
        _customTestMessage = L.of(context).serverUrlRequiredForTest;
      });
      return;
    }

    setState(() {
      _testingCustom = true;
      _customTestMessage = null;
    });

    try {
      final result = await widget.service.testMcpServer(
        serverUrl: rawUrl,
        mcpEndpoint: rawEndpoint.isNotEmpty ? rawEndpoint : '/mcp',
        apiKey: rawApiKey.isNotEmpty ? rawApiKey : null,
        apiPassword: rawApiPassword.isNotEmpty ? rawApiPassword : null,
      );
      if (!mounted) return;
      setState(() {
        _customTestOk = result['success'] == true;
        _customTestMessage = (result['message'] ?? '').toString();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _customTestOk = false;
        _customTestMessage = L.of(context).mcpTestFailedMsg(e.toString());
      });
    } finally {
      if (mounted) setState(() => _testingCustom = false);
    }
  }

  Future<void> _addCustomServer() async {
    final rawUrl = _customUrlCtrl.text.trim();
    final rawName = _customNameCtrl.text.trim();
    final rawEndpoint = _customEndpointCtrl.text.trim();
    final rawApiKey = _customApiKeyCtrl.text.trim();
    final rawApiPassword = _customApiPasswordCtrl.text.trim();
    if (rawUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L.of(context).urlRequired), backgroundColor: AppTheme.error));
      return;
    }

    setState(() => _addingCustom = true);
    try {
      await _upsertSelectedServer(
        McpToolConfig(
          serverUrl: rawUrl,
          name: rawName.isNotEmpty ? rawName : rawUrl,
          mcpEndpoint: rawEndpoint.isNotEmpty ? rawEndpoint : '/mcp',
          apiKey: rawApiKey.isNotEmpty ? rawApiKey : null,
          apiPassword: rawApiPassword.isNotEmpty ? rawApiPassword : null,
        ),
      );
      if (!mounted) return;
      _customNameCtrl.clear();
      _customUrlCtrl.clear();
      _customEndpointCtrl.text = '/mcp';
      _customApiKeyCtrl.clear();
      _customApiPasswordCtrl.clear();
      setState(() {
        _customTestMessage = null;
        _customTestOk = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L.of(context).customServerAdded)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L.of(context).failedToAddCustomServer(e.toString())), backgroundColor: AppTheme.error));
    } finally {
      if (mounted) setState(() => _addingCustom = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L.of(context).externalToolsScreenTitle),
        actions: [
          IconButton(
            onPressed: _loading ? null : _openCatalog,
            icon: const Icon(Icons.search),
            tooltip: L.of(context).searchMcpCatalogTooltip,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: AppTheme.primaryBlue.withValues(alpha: 0.08),
                  child: Padding(padding: const EdgeInsets.all(12), child: Text(L.of(context).externalToolsGlobalInfo)),
                ),
                const SizedBox(height: 16),
                // ── Catalog source selector ────────────────────────────────
                Text('MCP Catalog Source', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                Theme(
                  data: Theme.of(context).copyWith(
                    textTheme: Theme.of(
                      context,
                    ).textTheme.copyWith(labelLarge: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12)),
                  ),
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'pulsemcp', label: Text('PulseMCP'), icon: Icon(Icons.bolt, size: 14)),
                      ButtonSegment(value: 'smithery', label: Text('Smithery'), icon: Icon(Icons.cloud, size: 14)),
                      ButtonSegment(value: 'custom', label: Text('Custom'), icon: Icon(Icons.link, size: 14)),
                    ],
                    selected: {_catalogSource},
                    onSelectionChanged: (s) async {
                      final src = s.first;
                      setState(() => _catalogSource = src);
                      final client = _serverClient;
                      if (client != null) {
                        await client.putExternalToolsSettings({'catalog_source': src});
                        widget.service.applyInMemory(catalogSource: src);
                      } else {
                        await widget.service.saveCatalogSource(src);
                      }
                    },
                    style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.compact),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _catalogSource == 'pulsemcp'
                      ? 'Browse remote MCP servers from pulsemcp.com (primary)'
                      : _catalogSource == 'smithery'
                      ? 'Browse remote MCP servers from registry.smithery.ai (fallback)'
                      : 'Enter a custom catalog API URL below',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                if (_catalogSource == 'custom') ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _catalogUrlCtrl,
                    decoration: InputDecoration(
                      labelText: L.of(context).catalogUrlLabel,
                      hintText: 'https://registry.smithery.ai',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _savingUrl ? null : _saveCatalogUrl,
                    icon: _savingUrl
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save),
                    label: Text(L.of(context).saveUrlButton),
                  ),
                ],
                if (_catalogSource == 'smithery' || _catalogSource == 'custom') ...[
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _smitheryKeyCtrl,
                    decoration: const InputDecoration(
                      labelText: 'API Key (optional)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.key),
                    ),
                    obscureText: true,
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _smitheryKeyCtrl,
                    builder: (_, v, _) => v.text.trim().isEmpty
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 6, left: 4),
                            child: Text(
                              L.of(context).smitheryApiKeyHelper,
                              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                          ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _savingSmitheryKey
                        ? null
                        : () async {
                            setState(() => _savingSmitheryKey = true);
                            final messenger = ScaffoldMessenger.of(context);
                            try {
                              final client = _serverClient;
                              if (client != null) {
                                await client.putExternalToolsSettings({'smithery_api_key': _smitheryKeyCtrl.text});
                                widget.service.applyInMemory(smitheryApiKey: _smitheryKeyCtrl.text);
                              } else {
                                await widget.service.saveSmitheryApiKey(_smitheryKeyCtrl.text);
                              }
                              if (!mounted) return;
                              messenger.showSnackBar(
                                SnackBar(content: Text(L.of(context).smitheryApiKeySaved), behavior: SnackBarBehavior.floating),
                              );
                            } finally {
                              if (mounted) setState(() => _savingSmitheryKey = false);
                            }
                          },
                    icon: _savingSmitheryKey
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save),
                    label: const Text('Save API Key'),
                  ),
                ],
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(L.of(context).addCustomMcpServerTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _customNameCtrl,
                          decoration: InputDecoration(
                            labelText: L.of(context).serverName,
                            hintText: L.of(context).serverNameHint,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.badge),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _customUrlCtrl,
                          decoration: InputDecoration(
                            labelText: L.of(context).serverUrl,
                            hintText: 'https://example.com',
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.link),
                          ),
                          keyboardType: TextInputType.url,
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _customEndpointCtrl,
                          decoration: InputDecoration(
                            labelText: L.of(context).mcpEndpoint,
                            hintText: '/mcp',
                            helperText: 'JSON-RPC endpoint path',
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.route),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _customApiKeyCtrl,
                          decoration: InputDecoration(
                            labelText: L.of(context).mcpApiKeyOptionalLabel,
                            hintText: L.of(context).mcpApiKeyBearerHint,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.key),
                          ),
                          obscureText: true,
                        ),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _customApiKeyCtrl,
                          builder: (_, v, _) => v.text.trim().isEmpty
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(top: 6, left: 4),
                                  child: Text(
                                    L.of(context).mcpApiKeyBearerHelper,
                                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                  ),
                                ),
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _customApiPasswordCtrl,
                          decoration: InputDecoration(
                            labelText: L.of(context).apiPasswordOptionalLabel,
                            hintText: L.of(context).mcpApiPasswordOptionalHint,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.password),
                          ),
                          obscureText: true,
                        ),
                        if (_customTestMessage != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _customTestMessage!,
                            style: TextStyle(color: _customTestOk ? AppTheme.success : AppTheme.error, fontSize: 12),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _testingCustom ? null : _testCustomServer,
                                icon: _testingCustom
                                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.wifi_tethering),
                                label: Text(L.of(context).testButton),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _addingCustom ? null : _addCustomServer,
                                icon: _addingCustom
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      )
                                    : const Icon(Icons.add),
                                label: Text(L.of(context).addButton),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Text(L.of(context).selectedMcpServersTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Text(
                      L.of(context).selectedServersCount(widget.service.selectedCount),
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (widget.service.selectedServers.isEmpty)
                  Text(L.of(context).noExternalToolsYet, style: TextStyle(color: Colors.grey[600]))
                else
                  ...widget.service.selectedServers.map(
                    (s) => Card(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Tooltip(
                                  message: L.of(context).serverStatusTooltip(_statusLabel(s)),
                                  child: Icon(Icons.circle, size: 10, color: _statusColor(s)),
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: const Icon(Icons.list_alt, size: 20),
                                  tooltip: L.of(context).discoverTools,
                                  onPressed: () => _openServerTools(s),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.psychology_outlined, size: 20),
                                  tooltip: 'Generate & view Tool Hints',
                                  onPressed: () => Navigator.of(context).push<void>(
                                    MaterialPageRoute(
                                      fullscreenDialog: true,
                                      builder: (_) => _McpToolsViewerScreen(server: s, autoGenerateSkills: true),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit, size: 20),
                                  tooltip: L.of(context).editMcpServer,
                                  onPressed: () => _editSelectedServer(s),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.wifi_tethering, size: 20),
                                  tooltip: L.of(context).testButton,
                                  onPressed: () => _testSelectedServer(s),
                                ),
                                IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _removeServer(s.serverUrl)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              s.name?.trim().isNotEmpty == true ? s.name!.trim() : s.serverUrl,
                              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              [
                                if (s.description?.trim().isNotEmpty == true) s.description!.trim(),
                                s.serverUrl,
                                L.of(context).cloudMcpStatusLabel(_statusLabel(s)),
                                if ((s.apiKey ?? '').trim().isNotEmpty)
                                  L.of(context).apiKeyConfiguredLabel
                                else
                                  L.of(context).apiKeyMissingLabel,
                              ].join('\n'),
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _EditMcpServerDialog extends StatefulWidget {
  final McpToolConfig server;

  const _EditMcpServerDialog({required this.server});

  @override
  State<_EditMcpServerDialog> createState() => _EditMcpServerDialogState();
}

class _EditMcpServerDialogState extends State<_EditMcpServerDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _endpointCtrl;
  late final TextEditingController _keyCtrl;
  late final TextEditingController _pwdCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.server.name ?? '');
    _urlCtrl = TextEditingController(text: widget.server.serverUrl);
    _endpointCtrl = TextEditingController(text: widget.server.mcpEndpoint ?? '/mcp');
    _keyCtrl = TextEditingController(text: widget.server.apiKey ?? '');
    _pwdCtrl = TextEditingController(text: widget.server.apiPassword ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _endpointCtrl.dispose();
    _keyCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isMobile = screenSize.width < 600;

    return Dialog(
      insetPadding: isMobile ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      clipBehavior: Clip.antiAlias,
      shape: isMobile ? const RoundedRectangleBorder() : RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SizedBox(
        width: isMobile ? screenSize.width : 420,
        height: isMobile ? screenSize.height : null,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(L.of(context).editMcpServer, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w500)),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: _nameCtrl,
                        decoration: InputDecoration(labelText: L.of(context).serverName, border: const OutlineInputBorder()),
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _urlCtrl,
                        decoration: InputDecoration(labelText: L.of(context).serverUrl, border: const OutlineInputBorder()),
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _endpointCtrl,
                        decoration: InputDecoration(
                          labelText: L.of(context).mcpEndpoint,
                          hintText: '/mcp',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _keyCtrl,
                        decoration: InputDecoration(
                          labelText: L.of(context).mcpApiKeyOptionalLabel,
                          hintText: L.of(context).mcpApiKeyBearerHint,
                          border: const OutlineInputBorder(),
                        ),
                        obscureText: true,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _pwdCtrl,
                        decoration: InputDecoration(
                          labelText: L.of(context).apiPasswordOptionalLabel,
                          hintText: L.of(context).mcpApiPasswordOptionalHint,
                          border: const OutlineInputBorder(),
                        ),
                        obscureText: true,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: Text(L.of(context).cancel)),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      final edited = widget.server.copyWith(
                        name: _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : null,
                        serverUrl: _urlCtrl.text.trim(),
                        mcpEndpoint: _endpointCtrl.text.trim().isNotEmpty ? _endpointCtrl.text.trim() : '/mcp',
                        apiKey: _keyCtrl.text.trim().isNotEmpty ? _keyCtrl.text.trim() : null,
                        apiPassword: _pwdCtrl.text.trim().isNotEmpty ? _pwdCtrl.text.trim() : null,
                      );
                      Navigator.pop(context, edited);
                    },
                    child: Text(L.of(context).save),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _McpToolEntry {
  final String name;
  final String description;
  final Map<String, dynamic>? inputSchema;
  final Map<String, dynamic> raw;

  const _McpToolEntry({required this.name, required this.description, this.inputSchema, required this.raw});

  factory _McpToolEntry.fromJson(Map<String, dynamic> json) {
    final schema = json['inputSchema'];
    return _McpToolEntry(
      name: (json['name'] ?? 'unnamed_tool').toString(),
      description: (json['description'] ?? '').toString(),
      inputSchema: schema is Map<String, dynamic> ? schema : null,
      raw: json,
    );
  }
}

class _McpToolsViewerScreen extends ConsumerStatefulWidget {
  final McpToolConfig server;
  final bool autoGenerateSkills;

  const _McpToolsViewerScreen({required this.server, this.autoGenerateSkills = false});

  @override
  ConsumerState<_McpToolsViewerScreen> createState() => _McpToolsViewerScreenState();
}

class _McpToolsViewerScreenState extends ConsumerState<_McpToolsViewerScreen> {
  bool _loading = true;
  String? _error;
  List<_McpToolEntry> _tools = const [];
  String? _resolvedUrl;
  Map<String, String> _resolvedHeaders = {};
  Map<String, FunctionHint> _skillsByToolName = {};

  @override
  void initState() {
    super.initState();
    _loadTools();
  }

  String get _displayName => widget.server.name?.trim().isNotEmpty == true ? widget.server.name!.trim() : widget.server.serverUrl;

  String get _mcpType => _mcpTypeForRemoteServer(widget.server);

  Future<void> _loadSkills() async {
    final skills = await FunctionHintDatabaseService().getAll(mcpType: _mcpType);
    if (mounted) {
      setState(() {
        _skillsByToolName = {for (final s in skills) s.toolName: s};
      });
    }
  }

  Future<void> _generateAllSkills() async {
    if (_tools.isEmpty) return;
    final client = ref.read(serverApiClientProvider);
    final descriptors = _tools
        .map(
          (t) => McpToolDescriptor(
            name: t.name,
            description: t.description,
            inputSchema: t.inputSchema ?? const {'type': 'object', 'properties': {}},
          ),
        )
        .toList();

    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => FunctionHintBuildProgressDialog(
          progressNotifier: FunctionHintGenerationService().progressNotifier,
          onCancel: FunctionHintGenerationService().cancelGeneration,
        ),
      ),
    );
    try {
      final generated = await FunctionHintGenerationService().generateSkillsForTools(descriptors, _mcpType);
      // In server mode: push generated skills to the server as well.
      if (client != null) {
        for (final s in generated) {
          await client.saveSkill(s.toJson());
        }
      }
      if (!mounted) return;
      setState(() {
        for (final s in generated) {
          _skillsByToolName[s.toolName] = s;
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Generated ${generated.length} skill${generated.length == 1 ? '' : 's'}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Skill generation failed: $e'), backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  Uri _resolveRpcUri(String baseUrl, String endpoint) {
    // Use proper URI path manipulation so any query parameters (e.g. ?api_key=)
    // already embedded in baseUrl are preserved correctly instead of being
    // corrupted by naive string concatenation.
    final uri = Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), ''));
    if (uri.path.toLowerCase().endsWith('/mcp')) return uri;
    final normalizedEndpoint = endpoint.startsWith('/') ? endpoint : '/$endpoint';
    return uri.replace(path: uri.path + normalizedEndpoint);
  }

  /// Extracts the JSON payload from the first `data:` line of an SSE body.
  /// Used when the server responds with Content-Type: text/event-stream
  /// (Streamable HTTP transport, MCP 2025).
  static String _extractFirstSseData(String sseBody) {
    for (final line in sseBody.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('data: ') && trimmed.length > 6) {
        final json = trimmed.substring(6).trim();
        if (json.isNotEmpty && json != '[DONE]') return json;
      }
    }
    return sseBody;
  }

  /// POST JSON-RPC to [uri], following 301/302 redirects manually (http.post
  /// does not auto-follow redirects for safety).
  Future<List<_McpToolEntry>> _fetchViaJsonRpc(Uri uri, Map<String, String> headers) async {
    // MCP Streamable HTTP transport (2025) requires an initialize handshake
    // before tools/list.  The server may also return an Mcp-Session-Id that
    // must be forwarded so subsequent requests are associated with the session.
    final effectiveHeaders = Map<String, String>.from(headers);
    final initBody = jsonEncode({
      'jsonrpc': '2.0',
      'id': 0,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'Flutter MCP Client', 'version': '1.0.0'},
      },
    });
    try {
      final initResp = await http.post(uri, headers: effectiveHeaders, body: initBody).timeout(const Duration(seconds: 15));
      final sessionId = initResp.headers['mcp-session-id'];
      if (sessionId != null && sessionId.isNotEmpty) {
        effectiveHeaders['Mcp-Session-Id'] = sessionId;
        log.info('[MCP Tools Viewer] Session established: $sessionId');
      }
    } catch (e) {
      // Initialize failures are non-fatal — proceed to tools/list anyway.
      log.warning('[MCP Tools Viewer] Initialize failed (non-fatal): $e');
    }

    final body = jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list', 'params': {}});
    http.Response resp = await http.post(uri, headers: effectiveHeaders, body: body).timeout(const Duration(seconds: 12));

    // Follow 301/302 redirect manually (re-POST to Location)
    if (resp.statusCode == 301 || resp.statusCode == 302 || resp.statusCode == 307 || resp.statusCode == 308) {
      final location = resp.headers['location'];
      if (location != null && location.isNotEmpty) {
        final redirectUri = uri.resolve(location);
        log.info('[MCP Tools Viewer] Following redirect to $redirectUri');
        resp = await http.post(redirectUri, headers: effectiveHeaders, body: body).timeout(const Duration(seconds: 12));
      }
    }

    // Free servers (e.g. Smithery free tier) may reject auth headers with 401.
    // Retry without Authorization so free servers are accessible even when a
    // global Smithery key is configured.
    if (resp.statusCode == 401 && effectiveHeaders.containsKey('Authorization')) {
      log.info('[MCP Tools Viewer] Got 401, retrying without auth for $uri');
      final noAuthHeaders = Map<String, String>.from(effectiveHeaders)..remove('Authorization');
      resp = await http.post(uri, headers: noAuthHeaders, body: body).timeout(const Duration(seconds: 12));
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}');
    }

    // Handle Streamable HTTP (SSE) responses transparently.
    final contentType = resp.headers['content-type'] ?? '';
    final rawBody = contentType.contains('text/event-stream')
        ? _extractFirstSseData(utf8.decode(resp.bodyBytes))
        : utf8.decode(resp.bodyBytes);
    final payload = jsonDecode(rawBody);
    final result = payload is Map<String, dynamic> ? payload['result'] : null;
    final toolsArray = result is Map<String, dynamic> ? result['tools'] : null;

    if (toolsArray is! List) return const [];
    return toolsArray.whereType<Map<String, dynamic>>().map(_McpToolEntry.fromJson).toList();
  }

  Future<void> _loadTools() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final svc = ExternalToolsSettingsService.instance;
      if (!svc.isLoaded) await svc.load();

      final rawBaseUrl = widget.server.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final rawEndpoint = widget.server.mcpEndpoint?.trim() ?? '/mcp';
      final endpoint = rawEndpoint.isEmpty ? '/mcp' : rawEndpoint;

      // For Smithery servers, resolve the API key (URL is returned unchanged).
      final (resolvedBase, resolvedKey) = await svc.resolveSmitheryEndpoint(rawBaseUrl, widget.server.apiKey);

      final headers = <String, String>{'Accept': 'application/json, text/event-stream', 'Content-Type': 'application/json'};
      if (resolvedKey != null && resolvedKey.isNotEmpty) headers['Authorization'] = 'Bearer $resolvedKey';

      final parsedBase = Uri.parse(resolvedBase);
      final basePathEndsMcp = parsedBase.path.toLowerCase().endsWith('/mcp');
      final candidates = <Uri>[
        _resolveRpcUri(resolvedBase, endpoint),
        if (!basePathEndsMcp) parsedBase,
        // Append /sse to the path (not as a string suffix) so any embedded
        // query params (e.g. ?api_key=) are correctly preserved.
        parsedBase.replace(path: '${parsedBase.path}/sse'),
      ];

      Object? lastError;
      for (final uri in candidates) {
        try {
          log.info('[MCP Tools Viewer] Trying $uri');
          final tools = await _fetchViaJsonRpc(uri, headers);
          if (!mounted) return;

          final toolNames = tools.map((t) => t.name).toList();
          final toolSchemas = tools
              .map(
                (t) => {
                  'name': t.name,
                  if (t.description.isNotEmpty) 'description': t.description,
                  if (t.inputSchema != null) 'inputSchema': t.inputSchema,
                },
              )
              .toList();

          final updatedServer = widget.server.copyWith(
            discoveredTools: toolNames,
            discoveredToolSchemas: toolSchemas,
          );
          await ExternalToolsSettingsService.instance.upsertSelectedServer(updatedServer);

          setState(() {
            _tools = tools;
            _resolvedUrl = uri.toString();
            _resolvedHeaders = Map.from(headers);
          });
          await _loadSkills();
          if (widget.autoGenerateSkills && _tools.isNotEmpty && _skillsByToolName.isEmpty) {
            unawaited(_generateAllSkills());
          }
          return;
        } catch (e) {
          log.warning('[MCP Tools Viewer] $uri failed: $e');
          lastError = e;
        }
      }

      if (!mounted) return;
      final isSmithery = rawBaseUrl.toLowerCase().contains('server.smithery.ai');
      final missingSmitheryKey = isSmithery && !resolvedBase.contains('api_key=');
      String errorMsg = 'Failed to load tools: $lastError';
      if (missingSmitheryKey) {
        errorMsg += '\n\nSmithery servers require an API key. Add yours in Settings → External MCP Servers (Smithery API Key field).';
      }
      setState(() => _error = errorMsg);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load tools: $e';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildToolTile(_McpToolEntry tool) {
    final schemaText = tool.inputSchema == null ? '{}' : const JsonEncoder.withIndent('  ').convert(tool.inputSchema);
    return Card(
      child: ExpansionTile(
        title: Text(tool.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(tool.description.isNotEmpty ? tool.description : 'No description', maxLines: 2, overflow: TextOverflow.ellipsis),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          if (tool.description.isNotEmpty) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Description:', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 4),
            Align(alignment: Alignment.centerLeft, child: Text(tool.description)),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              const Expanded(
                child: Text('Input Schema:', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              IconButton(
                tooltip: 'Copy JSON',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: schemaText));
                  if (!mounted) return;
                  final messenger = ScaffoldMessenger.of(context);
                  messenger.showSnackBar(const SnackBar(content: Text('Schema copied to clipboard')));
                },
                icon: const Icon(Icons.copy, size: 18),
              ),
            ],
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(8)),
            child: SelectableText(schemaText, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _resolvedUrl == null
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (_) => _ToolCallDialog(tool: tool, serverUrl: _resolvedUrl!, headers: _resolvedHeaders),
                    ),
              icon: const Icon(Icons.play_circle_outline, size: 18),
              label: const Text('Test'),
            ),
          ),
          if (_skillsByToolName.containsKey(tool.name)) ...[
            const SizedBox(height: 12),
            const Row(
              children: [
                Icon(Icons.psychology_outlined, size: 16),
                SizedBox(width: 4),
                Text('Skill:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: AppTheme.primaryBlue.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(6)),
              child: SelectableText(_skillsByToolName[tool.name]!.skillText, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (!_loading && _error == null && _tools.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.model_training),
              tooltip: 'Export for training',
              onPressed: () => ToolListExportSheet.show(
                context,
                serverName: _displayName,
                tools: _tools
                    .map((t) => {'name': t.name, 'description': t.description, if (t.inputSchema != null) 'inputSchema': t.inputSchema!})
                    .toList(),
              ),
            ),
          if (!_loading && _error == null && _tools.isNotEmpty)
            IconButton(icon: const Icon(Icons.psychology_outlined), tooltip: 'Generate Tool Hints', onPressed: _generateAllSkills),
          IconButton(onPressed: _loading ? null : _loadTools, icon: const Icon(Icons.refresh), tooltip: 'Refresh tools'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  color: AppTheme.primaryBlue.withValues(alpha: 0.08),
                  child: Text('Available tools (${_tools.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  child: _tools.isEmpty
                      ? const Center(child: Text('No tools reported by this MCP server.'))
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _tools.length,
                          itemBuilder: (_, i) => _buildToolTile(_tools[i]),
                        ),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tool call test dialog
// ---------------------------------------------------------------------------

class _ToolCallDialog extends StatefulWidget {
  final _McpToolEntry tool;
  final String serverUrl;
  final Map<String, String> headers;

  const _ToolCallDialog({required this.tool, required this.serverUrl, required this.headers});

  @override
  State<_ToolCallDialog> createState() => _ToolCallDialogState();
}

class _ToolCallDialogState extends State<_ToolCallDialog> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _paramTypes = {};
  List<String> _required = [];
  bool _calling = false;
  String? _result;
  String? _callError;

  @override
  void initState() {
    super.initState();
    final schema = widget.tool.inputSchema;
    if (schema != null) {
      final props = schema['properties'];
      if (props is Map<String, dynamic>) {
        for (final key in props.keys) {
          _controllers[key] = TextEditingController();
          final def = props[key];
          _paramTypes[key] = (def is Map<String, dynamic> ? def['type'] ?? 'string' : 'string').toString();
        }
      }
      final req = schema['required'];
      if (req is List) _required = req.whereType<String>().toList();
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _call() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _calling = true;
      _result = null;
      _callError = null;
    });
    try {
      final args = <String, dynamic>{};
      for (final entry in _controllers.entries) {
        final raw = entry.value.text.trim();
        if (raw.isEmpty) continue;
        args[entry.key] = switch (_paramTypes[entry.key] ?? 'string') {
          'integer' => int.tryParse(raw) ?? raw,
          'number' => double.tryParse(raw) ?? raw,
          'boolean' => raw.toLowerCase() == 'true',
          'array' || 'object' => jsonDecode(raw),
          _ => raw,
        };
      }
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {'name': widget.tool.name, 'arguments': args},
      });
      final resp = await http.post(Uri.parse(widget.serverUrl), headers: widget.headers, body: body).timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        setState(() => _callError = 'HTTP ${resp.statusCode}: ${resp.body}');
        return;
      }
      final payload = jsonDecode(utf8.decode(resp.bodyBytes));
      if (payload is Map<String, dynamic> && payload.containsKey('error')) {
        final err = payload['error'];
        setState(() => _callError = 'Server error: ${err is Map ? err['message'] ?? err : err}');
        return;
      }
      final result = payload is Map<String, dynamic> ? payload['result'] : payload;
      String resultText;
      if (result is Map<String, dynamic>) {
        final content = result['content'];
        if (content is List && content.isNotEmpty) {
          resultText = content.whereType<Map<String, dynamic>>().map((c) => (c['text'] ?? c).toString()).join('\n');
        } else {
          resultText = const JsonEncoder.withIndent('  ').convert(result);
        }
      } else {
        resultText = const JsonEncoder.withIndent('  ').convert(result);
      }
      setState(() => _result = resultText);
    } on FormatException catch (e) {
      setState(() => _callError = 'JSON parse error: $e');
    } catch (e) {
      setState(() => _callError = e.toString());
    } finally {
      if (mounted) setState(() => _calling = false);
    }
  }

  Widget _buildParamField(String param) {
    final type = _paramTypes[param] ?? 'string';
    final isRequired = _required.contains(param);
    final propDef = widget.tool.inputSchema?['properties'] is Map
        ? (widget.tool.inputSchema!['properties'] as Map<String, dynamic>)[param]
        : null;
    final description = propDef is Map<String, dynamic> ? (propDef['description'] ?? '').toString() : '';
    final enumValues = propDef is Map<String, dynamic> ? (propDef['enum'] as List?)?.whereType<String>().toList() : null;

    if (enumValues != null && enumValues.isNotEmpty) {
      return DropdownButtonFormField<String>(
        decoration: InputDecoration(
          labelText: '$param${isRequired ? ' *' : ''}',
          helperText: description.isNotEmpty ? description : null,
          border: const OutlineInputBorder(),
        ),
        items: enumValues.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
        onChanged: (v) => _controllers[param]!.text = v ?? '',
        validator: isRequired ? (v) => (v == null || v.isEmpty) ? 'Required' : null : null,
      );
    }
    if (type == 'boolean') {
      return DropdownButtonFormField<String>(
        decoration: InputDecoration(
          labelText: '$param${isRequired ? ' *' : ''}',
          helperText: description.isNotEmpty ? description : null,
          border: const OutlineInputBorder(),
        ),
        items: const [
          DropdownMenuItem(value: 'true', child: Text('true')),
          DropdownMenuItem(value: 'false', child: Text('false')),
        ],
        onChanged: (v) => _controllers[param]!.text = v ?? 'true',
        validator: isRequired ? (v) => (v == null || v.isEmpty) ? 'Required' : null : null,
      );
    }
    return TextFormField(
      controller: _controllers[param],
      keyboardType: (type == 'integer' || type == 'number') ? TextInputType.number : TextInputType.multiline,
      maxLines: (type == 'array' || type == 'object') ? 4 : 1,
      decoration: InputDecoration(
        labelText: '$param${isRequired ? ' *' : ''}',
        hintText: type != 'string' ? type : null,
        helperText: description.isNotEmpty ? description : null,
        border: const OutlineInputBorder(),
      ),
      validator: isRequired ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final params = _controllers.keys.toList();
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.play_circle_outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(widget.tool.name, style: const TextStyle(fontFamily: 'monospace', fontSize: 15)),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.65, maxWidth: 480),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.tool.description.isNotEmpty) ...[
                  Text(widget.tool.description, style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 14),
                ],
                if (params.isEmpty)
                  Text('This tool takes no parameters.', style: TextStyle(color: theme.colorScheme.onSurfaceVariant))
                else
                  for (final param in params) ...[_buildParamField(param), const SizedBox(height: 10)],
                if (_result != null) ...[
                  const Divider(height: 24),
                  Text(
                    'Result:',
                    style: TextStyle(fontWeight: FontWeight.w600, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(8)),
                    child: SelectableText(_result!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ),
                ],
                if (_callError != null) ...[
                  const Divider(height: 24),
                  Text(
                    'Error:',
                    style: TextStyle(fontWeight: FontWeight.w600, color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 6),
                  Text(_callError!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton.icon(
          onPressed: _calling ? null : _call,
          icon: _calling
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.send, size: 18),
          label: Text(_calling ? 'Calling…' : 'Call'),
        ),
      ],
    );
  }
}

class _ExternalToolsCatalogScreen extends StatefulWidget {
  final ExternalToolsSettingsService service;
  final ServerApiClient? serverClient;

  const _ExternalToolsCatalogScreen({required this.service, this.serverClient});

  @override
  State<_ExternalToolsCatalogScreen> createState() => _ExternalToolsCatalogScreenState();
}

class _ExternalToolsCatalogScreenState extends State<_ExternalToolsCatalogScreen> {
  final _queryCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  List<McpToolConfig> _results = const [];
  final Map<String, McpToolConfig> _seen = {};
  late Set<String> _selectedUrls;
  final Map<String, String> _authNotes = {};

  /// 'pulsemcp' (primary) | 'smithery' (fallback)
  late String _source;

  @override
  void initState() {
    super.initState();
    // Default to the persisted preference from the settings service,
    // but treat 'custom' as 'smithery' since the catalog only supports these two.
    final svcSource = widget.service.catalogSource;
    _source = svcSource == 'smithery' ? 'smithery' : 'pulsemcp';
    _selectedUrls = widget.service.selectedServers.map((e) => e.serverUrl).toSet();
    for (final s in widget.service.selectedServers) {
      _seen[s.serverUrl] = s;
    }
    // Defer to post-frame so MediaQuery is available.
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final isMobile = MediaQuery.sizeOf(context).width < 600;
      final List<McpToolConfig> res;
      if (_source == 'pulsemcp') {
        res = await widget.service.searchPulseMcp(query: _queryCtrl.text, remoteOnly: isMobile);
      } else {
        res = await widget.service.searchCatalog(query: _queryCtrl.text, source: 'smithery');
      }
      final filtered = _filterCatalogResults(res, _queryCtrl.text);
      for (final item in res) {
        final existing = _seen[item.serverUrl];
        if (existing != null) {
          // Preserve locally stored credentials/endpoint when catalog refreshes metadata
          _seen[item.serverUrl] = item.copyWith(
            mcpEndpoint: (existing.mcpEndpoint ?? '').trim().isNotEmpty ? existing.mcpEndpoint : item.mcpEndpoint,
            apiKey: existing.apiKey,
            apiPassword: existing.apiPassword,
            enabledTools: existing.enabledTools,
            discoveredTools: existing.discoveredTools,
            discoveredPrompts: existing.discoveredPrompts,
            discoveredResources: existing.discoveredResources,
          );
        } else {
          _seen[item.serverUrl] = item;
        }
      }
      if (!mounted) return;
      setState(() => _results = filtered);
      if (_source == 'smithery') _fetchAuthNotes(filtered);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _fetchAuthNotes(List<McpToolConfig> servers) {
    for (final server in servers) {
      final url = server.serverUrl;
      if (_authNotes.containsKey(url)) continue;
      // Extract qualifiedName from proxy or real URL.
      final qn = url.toLowerCase().contains('server.smithery.ai')
          ? (Uri.tryParse(url)?.pathSegments.firstOrNull ?? '')
          : (server.catalogPageUrl != null ? Uri.tryParse(server.catalogPageUrl!)?.pathSegments.lastOrNull ?? '' : '');
      if (qn.isEmpty) continue;
      final name = server.name ?? '';
      widget.service.fetchSmitheryAuthNote(qn, name).then((note) {
        if (!mounted) return;
        if (note != null && note.isNotEmpty) {
          setState(() => _authNotes[url] = note);
        }
      });
    }
  }

  List<McpToolConfig> _filterCatalogResults(List<McpToolConfig> input, String query) {
    final tokens = query.toLowerCase().split(RegExp(r'\s+')).map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

    return input.where((server) {
      final text = '${server.name ?? ''} ${server.description ?? ''} ${server.serverUrl}'.toLowerCase();
      final matchesQuery = tokens.every(text.contains);
      if (!matchesQuery) return false;

      final cloud = _isLikelyCloudServer(server);
      if (!cloud) return false;

      // If catalog provides explicit health status, hide offline entries.
      if (server.isOnline == false) return false;

      return true;
    }).toList();
  }

  bool _isLikelyCloudServer(McpToolConfig server) {
    final url = server.serverUrl.toLowerCase();
    final text = '${server.name ?? ''} ${server.description ?? ''} ${server.serverUrl}'.toLowerCase();

    final localHints = [
      'localhost',
      '127.0.0.1',
      '0.0.0.0',
      'file://',
      'stdio',
      'local only',
      'desktop only',
      'mac only',
      'windows only',
      'linux only',
      'offline',
    ];

    if (localHints.any((h) => text.contains(h) || url.contains(h))) {
      return false;
    }

    return url.startsWith('https://') || url.startsWith('http://');
  }

  Widget? _buildStatusLed(McpToolConfig server) {
    if (server.isOnline == null) return null;
    return Icon(Icons.circle, size: 10, color: server.isOnline! ? AppTheme.success : AppTheme.error);
  }

  String _catalogStatusText(McpToolConfig server) {
    if (server.isOnline == true) return 'Catalog status: Online';
    if (server.isOnline == false) return 'Catalog status: Offline';
    return 'Catalog status: Unknown';
  }

  Future<void> _saveSelection() async {
    final resolved = <McpToolConfig>[];
    for (final u in _selectedUrls) {
      var server = _seen[u] ?? McpToolConfig(serverUrl: u, name: u, mcpEndpoint: '/mcp');

      // Smithery proxy URLs (server.smithery.ai) are NOT the real server
      // endpoint for self-hosted servers.  Fetch the registry detail to
      // obtain the actual connection URL before persisting.
      if (u.toLowerCase().contains('server.smithery.ai')) {
        final qualifiedName = Uri.parse(u).pathSegments.firstOrNull ?? '';
        if (qualifiedName.isNotEmpty) {
          final realUrl = await widget.service.fetchSmitheryConnectionUrl(qualifiedName);
          if (realUrl != null) {
            String baseUrl = realUrl;
            String endpoint = '/mcp';
            for (final suffix in ['/mcp', '/sse', '/v1/mcp']) {
              if (realUrl.toLowerCase().endsWith(suffix)) {
                baseUrl = realUrl.substring(0, realUrl.length - suffix.length);
                endpoint = suffix;
                break;
              }
            }
            server = server.copyWith(serverUrl: baseUrl, mcpEndpoint: endpoint);
          }
        }
      }

      resolved.add(server);
    }
    resolved.sort((a, b) => (a.name ?? a.serverUrl).compareTo(b.name ?? b.serverUrl));

    if (widget.serverClient != null) {
      await widget.serverClient!.putExternalToolsSettings({'selected_servers': resolved.map((server) => server.toJson()).toList()});
      widget.service.applyInMemory(selectedServers: resolved);
    } else {
      await widget.service.saveSelectedServers(resolved);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP Server List'),
        actions: [IconButton(onPressed: _loading ? null : _search, icon: const Icon(Icons.refresh))],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _queryCtrl,
              decoration: InputDecoration(
                hintText: 'Search servers...',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(onPressed: _loading ? null : _search, icon: const Icon(Icons.arrow_forward)),
              ),
              onSubmitted: (_) => _search(),
            ),
          ),
          // Info banner
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.15),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 16, color: Colors.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _source == 'pulsemcp'
                        ? isMobile
                              ? 'Showing remote-only MCP servers from the Official MCP Registry (registry.modelcontextprotocol.io). Some require an API key — tap the \u{1F517} icon to visit the server page.'
                              : 'Showing live remote-hosted servers from the Official MCP Registry (registry.modelcontextprotocol.io). Some require an API key — tap the \u{1F517} icon to visit the server page.'
                        : 'Showing live remote-hosted servers from Smithery.ai. Some require an API key — tap the \u{1F517} icon to visit the server page.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, index) {
                final s = _results[index];
                final selected = _selectedUrls.contains(s.serverUrl);
                return CheckboxListTile(
                  value: selected,
                  onChanged: (v) async {
                    if (v == true) {
                      setState(() => _selectedUrls.add(s.serverUrl));
                    } else {
                      setState(() => _selectedUrls.remove(s.serverUrl));
                    }
                  },
                  title: Row(
                    children: [
                      const Icon(Icons.cloud, size: 14, color: Colors.blueGrey),
                      const SizedBox(width: 6),
                      Expanded(child: Text(s.name?.trim().isNotEmpty == true ? s.name!.trim() : s.serverUrl)),
                      if (s.catalogPageUrl?.isNotEmpty == true)
                        IconButton(
                          icon: const Icon(Icons.link, size: 18),
                          tooltip: _source == 'pulsemcp' ? 'Open PulseMCP page' : 'Open Smithery page',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          onPressed: () async {
                            final url = Uri.parse(s.catalogPageUrl!);
                            if (await canLaunchUrl(url)) await launchUrl(url, mode: LaunchMode.externalApplication);
                          },
                        ),
                      if (_buildStatusLed(s) != null) ...[const SizedBox(width: 4), _buildStatusLed(s)!],
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.description?.trim().isNotEmpty == true
                            ? '${s.description!.trim()}\n${s.serverUrl}\n${_catalogStatusText(s)}'
                            : '${s.serverUrl}\n${_catalogStatusText(s)}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_authNotes[s.serverUrl]?.isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.15),
                            border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.lock_outline, size: 12, color: Colors.amber),
                              const SizedBox(width: 4),
                              Expanded(child: Text(_authNotes[s.serverUrl]!, style: const TextStyle(fontSize: 11))),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  isThreeLine: true,
                  controlAffinity: ListTileControlAffinity.leading,
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: EdgeInsets.only(bottom: MediaQuery.of(context).viewPadding.bottom),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: FilledButton.icon(onPressed: _saveSelection, icon: const Icon(Icons.save), label: const Text('Use selected servers')),
        ),
      ),
    );
  }
}
