import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../models/workflow_task.dart';
import '../models/github_mcp_server_definition.dart';
import '../services/external_tools_settings_service.dart';
import '../services/github_mcp_library_service.dart';
import '../services/github_mcp_registry_service.dart';
import '../services/github_mcp_runtime_service.dart';
import '../mcp/internal_mcp_registry.dart';
import '../mcp/internal_mcp_server.dart';
import '../services/function_hint_database_service.dart';
import '../services/function_hint_generation_service.dart';
import '../widgets/mcp_discovery_dialog.dart';
import '../widgets/function_hint_build_progress_dialog.dart';
import '../widgets/tool_list_export_sheet.dart';
import '../providers/server_mode_provider.dart';
import '../services/llm_settings_service.dart';

/// Browse, install and configure GitHub-sourced MCP servers.
///
/// Desktop-only (Windows, macOS, Linux).
class GithubMcpRegistryScreen extends ConsumerStatefulWidget {
  const GithubMcpRegistryScreen({super.key});

  @override
  ConsumerState<GithubMcpRegistryScreen> createState() => _GithubMcpRegistryScreenState();
}

class _GithubMcpRegistryScreenState extends ConsumerState<GithubMcpRegistryScreen> {
  final _registry = GithubMcpRegistryService.instance;
  final _runtime = GithubMcpRuntimeService.instance;

  bool _loading = true;
  String? _error;
  String _selectedCategory = 'all';
  String _search = '';
  final _searchController = TextEditingController();

  // Local overrides applied on top of the registry catalog (e.g. after install/uninstall)
  final Map<String, GithubMcpServerDefinition> _overrides = {};
  final Map<String, GithubMcpServerDefinition> _overridesByPackage = {};

  // Source selector: 'manual' | 'tealkit' | 'glama' | 'pulsemcp' | 'smithery'
  String _selectedSource = 'manual';

  // Manually-installed / library servers (shown in "My Servers" tab)
  List<GithubMcpServerDefinition> _myServers = [];

  // Install type filter (GitHub tab only): 'all' | 'uvx' | 'pip'
  String _installTypeFilter = 'all';

  // Glama state
  List<_GlamaServer> _glamaServers = [];
  bool _glamaLoading = false;
  String? _glamaError;
  String? _glamaEndCursor;
  bool _glamaHasMore = true;

  // PulseMCP / Official MCP Registry state
  List<_McpRegistryServer> _mcpRegServers = [];
  bool _mcpRegLoading = false;
  String? _mcpRegError;
  String? _mcpRegNextCursor;
  bool _mcpRegHasMore = true;

  // Tool availability
  bool? _uvAvailable;
  bool? _nodeAvailable;

  // Smithery state
  List<_SmitheryServer> _smitheryServers = [];
  bool _smitheryLoading = false;
  String? _smitheryError;
  int _smitheryPage = 1;
  bool _smitheryHasMore = true;
  late final TextEditingController _smitheryApiKeyCtrl;
  bool _smitheryApiKeyVisible = false;

  // Debounce timers for search-on-type
  Timer? _glamaSearchDebounce;
  Timer? _mcpRegSearchDebounce;
  Timer? _smitherySearchDebounce;

  @override
  void initState() {
    super.initState();
    _load();
    _loadMyServers();
    _checkUv();
    _checkNode();
    _smitheryApiKeyCtrl = TextEditingController(text: ExternalToolsSettingsService.instance.smitheryApiKey);
  }

  Future<void> _load({bool forceRefresh = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _registry.load(forceRefresh: forceRefresh);
      // Restore installed state from local library (desktop/local mode) or
      // from the remote server (server mode).
      final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
      if (isRemote) {
        final client = ref.read(serverApiClientProvider);
        if (client != null) {
          final installed = await client.listRegistryServers();
          if (mounted) {
            setState(() {
              // Clear first so deleted entries don't persist across reloads.
              _overrides.clear();
              _overridesByPackage.clear();
              // Populate from server list.
              for (final json in installed) {
                final def = GithubMcpServerDefinition.fromJson(json);
                _overrides[def.id] = def;
                _overridesByPackage[def.packageName] = def;
              }
              // Suppress stale local-library entries: if the catalog has an
              // entry with isInstalled=true (from old local-DB mirroring) but
              // the server didn't return it, add an explicit "not installed"
              // override so the fallback in _filtered won't show it as installed.
              for (final s in _registry.catalog) {
                if (s.isInstalled && !_overridesByPackage.containsKey(s.packageName)) {
                  _overridesByPackage[s.packageName] = s.copyWith(isInstalled: false, isActive: false);
                }
              }
            });
          }
        }
      } else {
        // Local mode: merge persisted library entries into overrides so that
        // previously-installed servers show the "installed" badge and appear
        // in My Servers after an app restart.
        final libServers = GithubMcpLibraryService.instance.servers;
        if (mounted) {
          setState(() {
            // Clear first so deleted entries don't persist across reloads.
            _overrides.clear();
            _overridesByPackage.clear();
            for (final def in libServers) {
              _overrides[def.id] = def;
              _overridesByPackage[def.packageName] = def;
            }
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    _loadMyServers();
  }

  void _loadMyServers() {
    if (!mounted) return;
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    final List<GithubMcpServerDefinition> all;
    if (isRemote) {
      // In server mode the authoritative data comes from the server via _overrides.
      all = _overrides.values.where((s) => s.isManual).toList();
    } else {
      all = GithubMcpLibraryService.instance.servers.where((s) => s.isManual).toList();
    }
    all.sort((a, b) {
      final ta = a.installedAt ?? a.createdAt;
      final tb = b.installedAt ?? b.createdAt;
      return tb.compareTo(ta);
    });
    setState(() => _myServers = all);
  }

  Future<void> _checkUv() async {
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (isRemote) {
      if (mounted) setState(() => _uvAvailable = true);
      return;
    }
    final uv = await _runtime.detectUvTool();
    if (mounted) setState(() => _uvAvailable = uv != null);
  }

  Future<void> _checkNode() async {
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (isRemote) {
      if (mounted) setState(() => _nodeAvailable = true);
      return;
    }
    final node = await _runtime.detectNode();
    if (mounted) setState(() => _nodeAvailable = node != null);
  }

  Future<void> _loadGlama({bool reset = false}) async {
    if (!mounted) return;
    if (reset) {
      setState(() {
        _glamaServers = [];
        _glamaEndCursor = null;
        _glamaHasMore = true;
        _glamaError = null;
      });
    }
    if (!_glamaHasMore && !reset) return;
    setState(() {
      _glamaLoading = true;
      _glamaError = null;
    });
    try {
      final q = _search.trim();
      final params = <String, String>{'first': '30'};
      if (q.isNotEmpty) params['q'] = q;
      if (_glamaEndCursor != null && !reset) params['after'] = _glamaEndCursor!;
      final uri = Uri.parse('https://glama.ai/api/mcp/v1/servers').replace(queryParameters: params);
      final resp = await http.get(uri, headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final pageInfo = data['pageInfo'] as Map<String, dynamic>? ?? {};
        final list = (data['servers'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(_GlamaServer.fromJson)
            .where((s) => !s.isRemoteOnly)
            .toList();
        if (mounted) {
          setState(() {
            _glamaServers = reset ? list : [..._glamaServers, ...list];
            _glamaEndCursor = pageInfo['endCursor'] as String?;
            _glamaHasMore = pageInfo['hasNextPage'] as bool? ?? false;
          });
        }
      } else {
        if (mounted) setState(() => _glamaError = 'HTTP ${resp.statusCode}');
      }
    } catch (e) {
      if (mounted) setState(() => _glamaError = e.toString());
    } finally {
      if (mounted) setState(() => _glamaLoading = false);
    }
  }

  List<GithubMcpServerDefinition> get _filtered {
    var list = _registry
        .filterByCategory(_selectedCategory)
        .map((s) => _overrides[s.id] ?? _overridesByPackage[s.packageName] ?? s)
        .toList();
    if (_installTypeFilter != 'all') {
      list = list.where((s) => s.installType == _installTypeFilter).toList();
    }
    final q = _search.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((s) {
        return s.displayName.toLowerCase().contains(q) ||
            s.description.toLowerCase().contains(q) ||
            s.packageName.toLowerCase().contains(q);
      }).toList();
    }
    return list;
  }

  // All installable TealKit registry servers, filtered only by current search query.
  // Used in Glama / PulseMCP tabs to surface installable servers alongside remote ones.
  List<GithubMcpServerDefinition> get _filteredInstallable {
    if (_loading || _error != null) return [];
    var list = _registry.filterByCategory('all').map((s) => _overrides[s.id] ?? _overridesByPackage[s.packageName] ?? s).toList();
    final q = _search.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((s) {
        return s.displayName.toLowerCase().contains(q) ||
            s.description.toLowerCase().contains(q) ||
            s.packageName.toLowerCase().contains(q);
      }).toList();
    }
    return list;
  }

  Future<void> _loadMcpRegistry({bool reset = false}) async {
    if (!mounted) return;
    if (reset) {
      setState(() {
        _mcpRegServers = [];
        _mcpRegNextCursor = null;
        _mcpRegHasMore = true;
        _mcpRegError = null;
      });
    }
    if (!_mcpRegHasMore && !reset) return;
    setState(() {
      _mcpRegLoading = true;
      _mcpRegError = null;
    });
    try {
      final q = _search.trim();
      final params = <String, String>{'limit': '50'};
      if (q.isNotEmpty) params['q'] = q;
      if (_mcpRegNextCursor != null && !reset) {
        params['cursor'] = _mcpRegNextCursor!;
      }
      final uri = Uri.parse('https://registry.modelcontextprotocol.io/v0/servers').replace(queryParameters: params);
      final resp = await http
          .get(uri, headers: {'Accept': 'application/json', 'User-Agent': 'mobile-ai-agent/1.0'})
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final meta = data['metadata'] as Map<String, dynamic>? ?? {};
        final list = (data['servers'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(_McpRegistryServer.fromJson)
            .where((s) => s.remoteUrl != null)
            .toList();
        if (mounted) {
          setState(() {
            _mcpRegServers = reset ? list : [..._mcpRegServers, ...list];
            _mcpRegNextCursor = meta['nextCursor'] as String?;
            _mcpRegHasMore = _mcpRegNextCursor != null && _mcpRegNextCursor!.isNotEmpty;
          });
        }
      } else {
        if (mounted) setState(() => _mcpRegError = 'HTTP ${resp.statusCode}');
      }
    } catch (e) {
      if (mounted) setState(() => _mcpRegError = e.toString());
    } finally {
      if (mounted) setState(() => _mcpRegLoading = false);
    }
  }

  Future<void> _loadSmithery({bool reset = false}) async {
    if (!mounted) return;
    if (reset) {
      setState(() {
        _smitheryServers = [];
        _smitheryPage = 1;
        _smitheryHasMore = true;
        _smitheryError = null;
      });
    }
    if (!_smitheryHasMore && !reset) return;
    setState(() {
      _smitheryLoading = true;
      _smitheryError = null;
    });
    try {
      final q = _search.trim();
      final params = <String, String>{'pageSize': '50', 'page': '$_smitheryPage'};
      if (q.isNotEmpty) params['q'] = q;
      final uri = Uri.parse('https://registry.smithery.ai/servers').replace(queryParameters: params);
      final resp = await http
          .get(uri, headers: {'Accept': 'application/json', 'User-Agent': 'mobile-ai-agent/1.0'})
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final pagination = data['pagination'] as Map<String, dynamic>? ?? {};
        final totalPages = (pagination['totalPages'] as num?)?.toInt() ?? 1;
        final list = (data['servers'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .where((s) => (s['remote'] as bool? ?? false) && (s['isDeployed'] as bool? ?? false))
            .map(_SmitheryServer.fromJson)
            .where((s) => s.qualifiedName.isNotEmpty)
            .toList();
        if (mounted) {
          setState(() {
            _smitheryServers = reset ? list : [..._smitheryServers, ...list];
            _smitheryPage++;
            _smitheryHasMore = _smitheryPage <= totalPages;
          });
        }
      } else {
        if (mounted) setState(() => _smitheryError = 'HTTP ${resp.statusCode}');
      }
    } catch (e) {
      if (mounted) setState(() => _smitheryError = e.toString());
    } finally {
      if (mounted) setState(() => _smitheryLoading = false);
    }
  }

  @override
  void dispose() {
    _glamaSearchDebounce?.cancel();
    _mcpRegSearchDebounce?.cancel();
    _smitherySearchDebounce?.cancel();
    _searchController.dispose();
    _smitheryApiKeyCtrl.dispose();
    super.dispose();
  }

  // ─── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP Server Registry'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () {
              if (_selectedSource == 'glama') {
                _loadGlama(reset: true);
              } else if (_selectedSource == 'pulsemcp') {
                _loadMcpRegistry(reset: true);
              } else if (_selectedSource == 'smithery') {
                _loadSmithery(reset: true);
              } else if (_selectedSource == 'manual') {
                _loadMyServers();
              } else {
                _load(forceRefresh: true);
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // uv missing banner
          if (_uvAvailable == false && _selectedSource == 'tealkit') _buildUvBanner(theme),

          // Node.js missing banner
          if (_nodeAvailable == false && _selectedSource == 'tealkit') _buildNodeBanner(theme),

          // Source selector
          _buildSourceSelector(theme),

          // Search bar
          // Filter chips (TealKit only) — merged into one row on wide screens
          if (_selectedSource == 'tealkit' && !_loading && _error == null)
            _buildFilterChips(theme, MediaQuery.sizeOf(context).width >= 600),

          // Search bar (hidden for My Servers tab)
          if (_selectedSource != 'manual')
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: _selectedSource == 'glama'
                      ? 'Search Glama...'
                      : _selectedSource == 'pulsemcp'
                      ? 'Search MCP Registry...'
                      : _selectedSource == 'smithery'
                      ? 'Search Smithery...'
                      : 'Search servers...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _search = '');
                            if (_selectedSource == 'glama') {
                              _loadGlama(reset: true);
                            }
                            if (_selectedSource == 'pulsemcp') {
                              _loadMcpRegistry(reset: true);
                            }
                            if (_selectedSource == 'smithery') {
                              _loadSmithery(reset: true);
                            }
                          },
                        )
                      : null,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
                onChanged: (v) {
                  setState(() => _search = v);
                  if (_selectedSource == 'glama') {
                    _glamaSearchDebounce?.cancel();
                    _glamaSearchDebounce = Timer(const Duration(milliseconds: 500), () {
                      _loadGlama(reset: true);
                    });
                  } else if (_selectedSource == 'pulsemcp') {
                    _mcpRegSearchDebounce?.cancel();
                    _mcpRegSearchDebounce = Timer(const Duration(milliseconds: 500), () {
                      _loadMcpRegistry(reset: true);
                    });
                  } else if (_selectedSource == 'smithery') {
                    _smitherySearchDebounce?.cancel();
                    _smitherySearchDebounce = Timer(const Duration(milliseconds: 500), () {
                      _loadSmithery(reset: true);
                    });
                  }
                },
                onSubmitted: (_) {
                  if (_selectedSource == 'glama') _loadGlama(reset: true);
                  if (_selectedSource == 'pulsemcp') {
                    _loadMcpRegistry(reset: true);
                  }
                  if (_selectedSource == 'smithery') _loadSmithery(reset: true);
                },
              ),
            ),

          const SizedBox(height: 4),

          // Content
          Expanded(
            child: _selectedSource == 'manual'
                ? _buildManualContent(theme)
                : _selectedSource == 'glama'
                ? _buildGlamaContent(theme)
                : _selectedSource == 'pulsemcp'
                ? _buildMcpRegistryContent(theme)
                : _selectedSource == 'smithery'
                ? _buildSmitheryContent(theme)
                : _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? _buildError(theme)
                : _filtered.isEmpty
                ? _buildEmpty(theme)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: _filtered.length,
                    itemBuilder: (ctx, i) => _ServerCard(
                      def: _filtered[i],
                      onStateChanged: (updated) {
                        setState(() {
                          _overrides[updated.id] = updated;
                          _overridesByPackage[updated.packageName] = updated;
                        });
                        _loadMyServers();
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildUvBanner(ThemeData theme) {
    final isSandboxed = Platform.isMacOS && Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID');
    return Container(
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isSandboxed
                  ? 'uv not found on PATH. Sandboxed Mac App Store apps cannot run local tools.\n'
                    'Please use the Direct Download version to run local Python or Node.js MCP servers.'
                  : 'uv not found on PATH. Most servers use uvx for installation.\n'
                    'Install from astral.sh/uv and restart the app.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          if (isSandboxed)
            TextButton(
              onPressed: () => launchUrl(Uri.parse('https://tealkit.dev/download/TealKit-macos-direct.dmg')),
              child: const Text('Download Direct Version'),
            ),
          TextButton(onPressed: _checkUv, child: const Text('Re-check')),
        ],
      ),
    );
  }

  Widget _buildNodeBanner(ThemeData theme) {
    final isSandboxed = Platform.isMacOS && Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID');
    return Container(
      color: Colors.amber.withAlpha(40),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.amber.shade700),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isSandboxed
                  ? 'Node.js 18+ not found on PATH. Sandboxed Mac App Store apps cannot run local tools.\n'
                    'Please use the Direct Download version to run local Python or Node.js MCP servers.'
                  : 'Node.js 18+ not found on PATH. Node.js MCP servers require Node.js.\n'
                    'Install from nodejs.org and restart the app.',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.amber.shade900),
            ),
          ),
          if (isSandboxed)
            TextButton(
              onPressed: () => launchUrl(Uri.parse('https://tealkit.dev/download/TealKit-macos-direct.dmg')),
              child: const Text('Download Direct Version'),
            ),
          TextButton(onPressed: _checkNode, child: const Text('Re-check')),
        ],
      ),
    );
  }

  /// Builds the filter chip rows. On wide screens (desktop) both category and
  /// install-type chips are merged into a single scrollable row with a divider
  /// so the duplicate "All" chip is eliminated.
  Widget _buildFilterChips(ThemeData theme, bool wide) {
    final cats = _registry.categories;
    const types = ['all', 'uvx', 'pip', 'npm'];
    const typeLabels = {'all': 'All', 'uvx': 'uvx', 'pip': 'pip', 'npm': 'npm'};

    List<Widget> catChips = [
      for (int i = 0; i < cats.length; i++) ...[
        if (i > 0) const SizedBox(width: 6),
        ChoiceChip(
          label: Text(_categoryLabel(cats[i])),
          selected: _selectedCategory == cats[i],
          onSelected: (_) => setState(() => _selectedCategory = cats[i]),
        ),
      ],
    ];

    // On desktop we skip the redundant "All" for install type since category
    // row already provides an "All" chip.
    final shownTypes = wide ? types.where((t) => t != 'all').toList() : types;
    List<Widget> typeChips = [
      for (int i = 0; i < shownTypes.length; i++) ...[
        if (i > 0) const SizedBox(width: 6),
        ChoiceChip(
          label: Text(typeLabels[shownTypes[i]]!),
          selected: _installTypeFilter == shownTypes[i],
          onSelected: (_) => setState(() => _installTypeFilter = shownTypes[i]),
          visualDensity: VisualDensity.compact,
        ),
      ],
    ];

    if (wide) {
      // Single merged row with a divider between the two groups.
      return SizedBox(
        height: 42,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            ...catChips,
            const SizedBox(width: 8),
            VerticalDivider(width: 1, indent: 6, endIndent: 6, color: theme.dividerColor),
            const SizedBox(width: 8),
            ...typeChips,
          ],
        ),
      );
    }

    // Narrow / mobile: two stacked scrollable rows.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 40,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: catChips),
        ),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: typeChips.map((w) => Padding(padding: const EdgeInsets.only(top: 4), child: w)).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildError(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 48, color: theme.colorScheme.error),
          const SizedBox(height: 12),
          Text('Failed to load registry', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(_error!, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: () => _load(), icon: const Icon(Icons.refresh), label: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off, size: 48),
          const SizedBox(height: 8),
          Text('No servers found', style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }

  Widget _buildSourceSelector(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final purpleFg = isDark ? Colors.deepPurple.shade200 : Colors.deepPurple.shade700;
    final purpleBg = isDark ? Colors.deepPurple.shade900.withAlpha(153) : Colors.deepPurple.shade50;

    void selectSource(String src) {
      if (_selectedSource == src) return;
      setState(() {
        _selectedSource = src;
        _search = '';
        _searchController.clear();
      });
      if (src == 'glama' && _glamaServers.isEmpty && !_glamaLoading) {
        _loadGlama();
      } else if (src == 'pulsemcp' && _mcpRegServers.isEmpty && !_mcpRegLoading) {
        _loadMcpRegistry();
      } else if (src == 'smithery' && _smitheryServers.isEmpty && !_smitheryLoading) {
        _loadSmithery();
      } else if (src == 'manual') {
        _loadMyServers();
      }
    }

    const regSources = <({String value, String label, IconData icon})>[
      (value: 'tealkit', label: 'GitHub', icon: Icons.code),
      (value: 'glama', label: 'Glama', icon: Icons.explore),
      (value: 'pulsemcp', label: 'Pulse MCP', icon: Icons.cloud_outlined),
      (value: 'smithery', label: 'Smithery', icon: Icons.hub_outlined),
    ];

    final manualSelected = _selectedSource == 'manual';

    Widget myServersChip = ChoiceChip(
      selected: manualSelected,
      onSelected: (_) => selectSource('manual'),
      avatar: Icon(Icons.inventory_2_outlined, size: 16, color: manualSelected ? purpleFg : null),
      label: Text(
        'My Servers',
        style: manualSelected ? TextStyle(color: purpleFg, fontWeight: FontWeight.w600) : null,
      ),
      selectedColor: purpleBg,
      side: manualSelected ? BorderSide(color: purpleFg, width: 1.5) : null,
      showCheckmark: false,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 580;

        if (isNarrow) {
          final allSources = [(value: 'manual', label: 'My Servers', icon: Icons.inventory_2_outlined), ...regSources];
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: allSources.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final src = allSources[index];
                  final isManual = src.value == 'manual';
                  final isSelected = _selectedSource == src.value;
                  return ChoiceChip(
                    selected: isSelected,
                    onSelected: (_) => selectSource(src.value),
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(src.icon, size: 16, color: isSelected && isManual ? purpleFg : null),
                    label: Text(
                      src.label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: isSelected && isManual ? TextStyle(color: purpleFg, fontWeight: FontWeight.w600) : null,
                    ),
                    selectedColor: isManual ? purpleBg : null,
                    side: isSelected && isManual ? BorderSide(color: purpleFg, width: 1.5) : null,
                    showCheckmark: false,
                  );
                },
              ),
            ),
          );
        }

        // Wide layout: purple "My Servers" chip + SegmentedButton for registries
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              myServersChip,
              const SizedBox(width: 10),
              Expanded(
                child: SegmentedButton<String>(
                  emptySelectionAllowed: true,
                  segments: const [
                    ButtonSegment(value: 'tealkit', label: Text('GitHub'), icon: Icon(Icons.code, size: 16)),
                    ButtonSegment(value: 'glama', label: Text('Glama'), icon: Icon(Icons.explore, size: 16)),
                    ButtonSegment(value: 'pulsemcp', label: Text('Pulse MCP'), icon: Icon(Icons.cloud_outlined, size: 16)),
                    ButtonSegment(value: 'smithery', label: Text('Smithery'), icon: Icon(Icons.hub_outlined, size: 16)),
                  ],
                  selected: manualSelected ? const <String>{} : {_selectedSource},
                  onSelectionChanged: (s) {
                    if (s.isNotEmpty) selectSource(s.first);
                  },
                  style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.compact),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGlamaContent(ThemeData theme) {
    final q = _search.trim().toLowerCase();
    final installable = _filteredInstallable;
    final visibleServers = q.isEmpty
        ? _glamaServers
        : _glamaServers.where((s) {
            return s.name.toLowerCase().contains(q) || s.description.toLowerCase().contains(q) || s.slug.toLowerCase().contains(q);
          }).toList();

    // Pure loading — nothing at all to show yet
    if (_glamaLoading && _glamaServers.isEmpty && installable.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    // Fatal error with nothing to show
    if (_glamaError != null && _glamaServers.isEmpty && installable.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text('Failed to load Glama', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(_glamaError!, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: () => _loadGlama(reset: true), icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        // ── Installable servers (TealKit / GitHub registry) ────────────────
        if (installable.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            sliver: SliverToBoxAdapter(
              child: Text('Installable Servers', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _ServerCard(
                  def: installable[i],
                  onStateChanged: (updated) {
                    setState(() {
                      _overrides[updated.id] = updated;
                      _overridesByPackage[updated.packageName] = updated;
                    });
                    _loadMyServers();
                  },
                ),
                childCount: installable.length,
              ),
            ),
          ),
        ],

        // ── Glama section header ───────────────────────────────────────────
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Text('Glama Registry', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ),

        // ── Glama — empty / load prompt ────────────────────────────────────
        if (_glamaServers.isEmpty && !_glamaLoading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.explore_outlined, size: 48),
                  const SizedBox(height: 12),
                  Text('Browse Glama Registry', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('Community installable Python & Node.js MCP servers'),
                  const SizedBox(height: 12),
                  FilledButton.icon(onPressed: _loadGlama, icon: const Icon(Icons.search), label: const Text('Browse servers')),
                ],
              ),
            ),
          )
        else if (_glamaServers.isEmpty && _glamaLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (visibleServers.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No Glama servers matched', style: theme.textTheme.bodyMedium)),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((ctx, i) {
                if (i == visibleServers.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: _glamaLoading
                          ? const CircularProgressIndicator()
                          : FilledButton.tonal(onPressed: _loadGlama, child: const Text('Load more')),
                    ),
                  );
                }
                return _GlamaServerCard(server: visibleServers[i]);
              }, childCount: visibleServers.length + (_glamaHasMore && q.isEmpty ? 1 : 0)),
            ),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _buildMcpRegistryContent(ThemeData theme) {
    final q = _search.trim().toLowerCase();
    final installable = _filteredInstallable;
    final visible = q.isEmpty
        ? _mcpRegServers
        : _mcpRegServers.where((s) {
            return s.name.toLowerCase().contains(q) || s.description.toLowerCase().contains(q);
          }).toList();

    // Pure loading — nothing at all to show yet
    if (_mcpRegLoading && _mcpRegServers.isEmpty && installable.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    // Fatal error with nothing to show
    if (_mcpRegError != null && _mcpRegServers.isEmpty && installable.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text('Failed to load MCP Registry', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(_mcpRegError!, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: () => _loadMcpRegistry(reset: true), icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        // ── Installable servers (TealKit / GitHub registry) ────────────────
        if (installable.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            sliver: SliverToBoxAdapter(
              child: Text('Installable Servers', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _ServerCard(
                  def: installable[i],
                  onStateChanged: (updated) {
                    setState(() {
                      _overrides[updated.id] = updated;
                      _overridesByPackage[updated.packageName] = updated;
                    });
                    _loadMyServers();
                  },
                ),
                childCount: installable.length,
              ),
            ),
          ),
        ],

        // ── PulseMCP / Official Registry section header ────────────────────
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Text(
              'PulseMCP — Remote Servers',
              style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),

        // ── PulseMCP — empty / load prompt ────────────────────────────────
        if (_mcpRegServers.isEmpty && !_mcpRegLoading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_outlined, size: 48),
                  const SizedBox(height: 12),
                  Text('Browse Official MCP Registry', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('Remote-hosted MCP servers from registry.modelcontextprotocol.io'),
                  const SizedBox(height: 12),
                  FilledButton.icon(onPressed: _loadMcpRegistry, icon: const Icon(Icons.search), label: const Text('Browse servers')),
                ],
              ),
            ),
          )
        else if (_mcpRegServers.isEmpty && _mcpRegLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (visible.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No remote servers matched', style: theme.textTheme.bodyMedium)),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((ctx, i) {
                if (i == visible.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: _mcpRegLoading
                          ? const CircularProgressIndicator()
                          : FilledButton.tonal(onPressed: _loadMcpRegistry, child: const Text('Load more')),
                    ),
                  );
                }
                return _McpRegistryServerCard(server: visible[i]);
              }, childCount: visible.length + (_mcpRegHasMore && q.isEmpty ? 1 : 0)),
            ),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _buildSmitheryContent(ThemeData theme) {
    final q = _search.trim().toLowerCase();
    final visible = q.isEmpty
        ? _smitheryServers
        : _smitheryServers.where((s) {
            return s.name.toLowerCase().contains(q) || s.description.toLowerCase().contains(q) || s.qualifiedName.toLowerCase().contains(q);
          }).toList();

    if (_smitheryLoading && _smitheryServers.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_smitheryError != null && _smitheryServers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text('Failed to load Smithery', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(_smitheryError!, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: () => _loadSmithery(reset: true), icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        // ── Smithery API key ──────────────────────────────────────────────────
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverToBoxAdapter(
            child: TextField(
              controller: _smitheryApiKeyCtrl,
              obscureText: !_smitheryApiKeyVisible,
              decoration: InputDecoration(
                labelText: 'Smithery API Key',
                hintText: 'Get yours at smithery.ai/account/api-keys',
                helperText: 'Used for Install and Add to External Tools',
                helperMaxLines: 2,
                prefixIcon: const Icon(Icons.vpn_key_outlined),
                suffixIcon: IconButton(
                  icon: Icon(_smitheryApiKeyVisible ? Icons.visibility_off : Icons.visibility),
                  tooltip: _smitheryApiKeyVisible ? 'Hide' : 'Show',
                  onPressed: () => setState(() => _smitheryApiKeyVisible = !_smitheryApiKeyVisible),
                ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                isDense: true,
              ),
              onChanged: (v) {
                ExternalToolsSettingsService.instance.saveSmitheryApiKey(v.trim());
              },
            ),
          ),
        ),

        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Smithery — Remote Servers',
              style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),

        if (_smitheryServers.isEmpty && !_smitheryLoading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.hub_outlined, size: 48),
                  const SizedBox(height: 12),
                  Text('Browse Smithery Registry', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('Remote-hosted MCP servers from registry.smithery.ai'),
                  const SizedBox(height: 12),
                  FilledButton.icon(onPressed: _loadSmithery, icon: const Icon(Icons.search), label: const Text('Browse servers')),
                ],
              ),
            ),
          )
        else if (_smitheryServers.isEmpty && _smitheryLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (visible.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No remote servers matched', style: theme.textTheme.bodyMedium)),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((ctx, i) {
                if (i == visible.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: _smitheryLoading
                          ? const CircularProgressIndicator()
                          : FilledButton.tonal(onPressed: _loadSmithery, child: const Text('Load more')),
                    ),
                  );
                }
                return _SmitheryServerCard(server: visible[i]);
              }, childCount: visible.length + (_smitheryHasMore && q.isEmpty ? 1 : 0)),
            ),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  static String _categoryLabel(String cat) {
    switch (cat) {
      case 'all':
        return 'All';
      case 'files':
        return 'Files';
      case 'web':
        return 'Web';
      case 'databases':
        return 'Databases';
      case 'productivity':
        return 'Productivity';
      default:
        return cat[0].toUpperCase() + cat.substring(1);
    }
  }

  Future<void> _showManualInstallDialog({GithubMcpServerDefinition? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ManualInstallDialog(existing: existing),
    );
    if (saved == true && mounted) {
      await _load();
      if (mounted) {
        _loadMyServers();
        setState(() => _selectedSource = 'manual');
      }
    }
  }

  Future<void> _deleteMyServer(GithubMcpServerDefinition server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove Server'),
        content: Text('Remove "${server.displayName}" from My Servers?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
      if (isRemote) {
        await ref.read(serverApiClientProvider)!.removeRegistryServer(server.id);
        if (mounted) {
          setState(() {
            _overrides.remove(server.id);
            _overridesByPackage.remove(server.packageName);
          });
        }
      } else {
        await GithubMcpLibraryService.instance.delete(server.id);
        InternalMcpRegistry().unregisterGithubMcpServer(server.id);
        if (mounted) {
          setState(() {
            _overrides.remove(server.id);
            _overridesByPackage.remove(server.packageName);
          });
        }
      }
      if (mounted) _loadMyServers();
    }
  }

  Widget _buildManualContent(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final purpleFg = isDark ? Colors.deepPurple.shade200 : Colors.deepPurple.shade700;

    if (_myServers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 56, color: purpleFg.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text('No servers installed yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Install MCP servers from any registry tab,\nor tap + to add one manually.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: purpleFg),
              onPressed: _showManualInstallDialog,
              icon: const Icon(Icons.add),
              label: const Text('Install Manually'),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
          itemCount: _myServers.length,
          itemBuilder: (ctx, i) {
            final server = _myServers[i];
            return _MyServerCard(
              def: server,
              onEdit: () => _showManualInstallDialog(existing: server),
              onDelete: () => _deleteMyServer(server),
              onToggleActive: (active) async {
                await GithubMcpLibraryService.instance.setActive(server.id, active: active);
                InternalMcpRegistry().registerGithubMcpServers();
                _loadMyServers();
              },
            );
          },
        ),
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton(
            backgroundColor: purpleFg,
            foregroundColor: Colors.white,
            onPressed: _showManualInstallDialog,
            tooltip: 'Install server manually',
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }
}

// ─── Server Card ──────────────────────────────────────────────────────────────

class _ServerCard extends ConsumerStatefulWidget {
  final GithubMcpServerDefinition def;
  final void Function(GithubMcpServerDefinition) onStateChanged;

  const _ServerCard({required this.def, required this.onStateChanged});

  @override
  ConsumerState<_ServerCard> createState() => _ServerCardState();
}

class _ServerCardState extends ConsumerState<_ServerCard> {
  bool _expanded = false;
  bool _installing = false;
  bool _discovering = false;
  bool _buildingSkills = false;
  String? _installError;
  final List<String> _installLog = [];
  final Map<String, TextEditingController> _envControllers = {};

  GithubMcpServerDefinition get def => widget.def;

  @override
  void initState() {
    super.initState();
    _initEnvControllers();
  }

  @override
  void didUpdateWidget(_ServerCard old) {
    super.didUpdateWidget(old);
    if (old.def.id != def.id) _initEnvControllers();
  }

  void _initEnvControllers() {
    for (final c in _envControllers.values) {
      c.dispose();
    }
    _envControllers.clear();
    for (final key in def.requiredEnvVars) {
      _envControllers[key] = TextEditingController(text: def.envVars[key] ?? '');
    }
    // Also add launch arg placeholders
    for (final arg in def.launchArgs) {
      final matches = RegExp(r'\{\{(\w+)\}\}').allMatches(arg);
      for (final m in matches) {
        final key = m.group(1)!;
        if (!_envControllers.containsKey(key)) {
          _envControllers[key] = TextEditingController(text: def.envVars[key] ?? '');
        }
      }
    }
  }

  @override
  void dispose() {
    for (final c in _envControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ─── Actions ─────────────────────────────────────────────────────────────

  Future<void> _install() async {
    setState(() {
      _installing = true;
      _installError = null;
      _installLog.clear();
    });

    // Server mode: delegate install to the remote server.
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (isRemote) {
      final client = ref.read(serverApiClientProvider)!;
      final envVars = {for (final e in _envControllers.entries) e.key: e.value.text.trim()};
      try {
        final result = await client.installRegistryServer(def.copyWith(envVars: envVars).toJson());
        if (!mounted) return;
        if (result['success'] == true) {
          final updated = GithubMcpServerDefinition.fromJson(result['server'] as Map<String, dynamic>);
          widget.onStateChanged(updated);
          final logs = (result['logs'] as List<dynamic>? ?? []).cast<String>();
          setState(() {
            _installing = false;
            _installLog.addAll(logs);
          });
        } else {
          setState(() {
            _installing = false;
            _installError = result['error'] as String? ?? 'Install failed';
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _installing = false;
            _installError = e.toString();
          });
        }
      }
      return;
    }

    final lib = GithubMcpLibraryService.instance;
    final runtime = GithubMcpRuntimeService.instance;

    // Save env vars first
    final envVars = {for (final e in _envControllers.entries) e.key: e.value.text.trim()};

    // Add to library if not known
    GithubMcpServerDefinition working = def;
    if (!lib.isKnown(def.packageName)) {
      working = await lib.save(def.copyWith(envVars: envVars));
    } else {
      working = await lib.updateEnvVars(def.id, envVars);
    }

    final error = await runtime.install(
      working,
      onProgress: (p) {
        if (mounted) {
          setState(() => _installLog.add(p.message));
        }
      },
    );

    if (!mounted) return;

    if (error == null) {
      await lib.markInstalled(working.id, envVars: envVars, activate: true);
      InternalMcpRegistry().registerGithubMcpServers();
      final updated = lib.findById(working.id)!;
      widget.onStateChanged(updated);
      setState(() => _installing = false);
    } else {
      setState(() {
        _installing = false;
        _installError = error;
      });
    }
  }

  Future<void> _discoverTools() async {
    setState(() => _discovering = true);

    // Server mode: ask the server to test/discover tools.
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (isRemote) {
      List<McpToolDescriptor> tools = [];
      String? error;
      try {
        final client = ref.read(serverApiClientProvider)!;
        final result = await client.testRegistryServer(def.id);
        if (!mounted) {
          setState(() => _discovering = false);
          return;
        }
        final rawTools = (result['tools'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>();
        tools = rawTools
            .map(
              (t) => McpToolDescriptor(
                name: t['name'] as String,
                description: t['description'] as String? ?? '',
                inputSchema: (t['inputSchema'] as Map<String, dynamic>?) ?? {'type': 'object', 'properties': {}},
              ),
            )
            .toList();
        if (result['success'] != true) error = result['error'] as String?;
      } catch (e) {
        error = e.toString();
      } finally {
        if (mounted) setState(() => _discovering = false);
      }
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (_) => _DiscoverSheet(serverName: def.displayName, tools: tools, error: error),
      );
      return;
    }

    List<McpToolDescriptor> tools = [];
    String? error;
    StdioMcpClient? client;
    try {
      final process = await GithubMcpRuntimeService.instance.launch(def);
      client = StdioMcpClient(process);

      // MCP handshake
      final initResp = await client.request('initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'TealKit', 'version': '1.0'},
      }, timeout: const Duration(seconds: 30));
      if (initResp.containsKey('error')) {
        error = 'Handshake error: ${initResp['error']}';
      } else {
        await client.notify('notifications/initialized', null);

        // Discover tools
        final resp = await client.request('tools/list', null, timeout: const Duration(seconds: 30));
        final rawList = resp['result']?['tools'] as List<dynamic>? ?? resp['result'] as List<dynamic>? ?? [];
        tools = rawList.whereType<Map<String, dynamic>>().map((t) {
          return McpToolDescriptor(
            name: t['name'] as String,
            description: t['description'] as String? ?? '',
            inputSchema: (t['inputSchema'] as Map<String, dynamic>?) ?? {'type': 'object', 'properties': {}},
          );
        }).toList();
        if (tools.isEmpty && resp.containsKey('error')) {
          error = 'tools/list error: ${resp['error']}';
        }
      }
    } on TimeoutException catch (e) {
      error =
          'Server did not respond in time (${e.duration?.inSeconds ?? 30}s).\nMake sure the server is installed and its dependencies are available.';
    } catch (e) {
      error = e.toString();
    } finally {
      await client?.dispose();
      if (mounted) setState(() => _discovering = false);
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _DiscoverSheet(serverName: def.displayName, tools: tools, error: error),
    );
  }

  Future<void> _buildSkills() async {
    final llmSettings = LlmSettingsService.instance;
    if (!llmSettings.isLoaded) await llmSettings.load();
    if (!llmSettings.isConfigured) {
      if (mounted) {
        setState(() => _buildingSkills = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('LLM 1 (Primary Model) must be configured/accepted in Settings to build skills.'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }

    // First, get the list of tools from the server (local or remote).
    setState(() => _buildingSkills = true);
    List<McpToolDescriptor> tools = [];
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;

    try {
      if (isRemote) {
        final client = ref.read(serverApiClientProvider)!;
        final result = await client.testRegistryServer(def.id);
        final rawTools = (result['tools'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>();
        tools = rawTools
            .map(
              (t) => McpToolDescriptor(
                name: t['name'] as String,
                description: t['description'] as String? ?? '',
                inputSchema: (t['inputSchema'] as Map<String, dynamic>?) ?? const {'type': 'object', 'properties': {}},
              ),
            )
            .toList();
      } else {
        StdioMcpClient? stdioClient;
        try {
          final process = await GithubMcpRuntimeService.instance.launch(def);
          stdioClient = StdioMcpClient(process);
          await stdioClient.request('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'TealKit', 'version': '1.0'},
          }, timeout: const Duration(seconds: 30));
          await stdioClient.notify('notifications/initialized', null);
          final resp = await stdioClient.request('tools/list', null, timeout: const Duration(seconds: 30));
          final rawList = resp['result']?['tools'] as List<dynamic>? ?? [];
          tools = rawList.whereType<Map<String, dynamic>>().map((t) {
            return McpToolDescriptor(
              name: t['name'] as String,
              description: t['description'] as String? ?? '',
              inputSchema: (t['inputSchema'] as Map<String, dynamic>?) ?? const {'type': 'object', 'properties': {}},
            );
          }).toList();
        } finally {
          await stdioClient?.dispose();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _buildingSkills = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load tools: $e'), backgroundColor: Theme.of(context).colorScheme.error));
      }
      return;
    }

    if (tools.isEmpty) {
      if (mounted) {
        setState(() => _buildingSkills = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No tools found for this server.')));
      }
      return;
    }

    // mcpType key for GitHub MCP servers matches the registry convention.
    final mcpType = 'gh_mcp_${def.id}';
    final client = isRemote ? ref.read(serverApiClientProvider) : null;

    if (!mounted) {
      setState(() => _buildingSkills = false);
      return;
    }

    // Show progress dialog and generate skills.
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
      final generated = await FunctionHintGenerationService().generateSkillsForTools(tools, mcpType);
      // Persist locally.
      final db = FunctionHintDatabaseService();
      for (final s in generated) {
        await db.save(s);
      }
      // In server mode: push skills to the server too.
      if (client != null) {
        for (final s in generated) {
          await client.saveSkill(s.toJson());
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Generated ${generated.length} skill${generated.length == 1 ? '' : 's'} for ${def.displayName}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Skill generation failed: $e'), backgroundColor: Theme.of(context).colorScheme.error));
      }
    } finally {
      if (mounted) {
        setState(() => _buildingSkills = false);
        Navigator.of(context).pop(); // close progress dialog
      }
    }
  }

  Future<void> _uninstall() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${def.displayName}?'),
        content: const Text('This will remove it from your active server list and uninstall the package where applicable.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;

    // Server mode: delegate uninstall to the remote server.
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (isRemote) {
      await ref.read(serverApiClientProvider)!.removeRegistryServer(def.id);
      widget.onStateChanged(def.copyWith(isInstalled: false, isActive: false));
      return;
    }

    await GithubMcpRuntimeService.instance.uninstall(def);
    InternalMcpRegistry().unregisterGithubMcpServer(def.id);
    widget.onStateChanged(def.copyWith(isInstalled: false, isActive: false));
  }

  Future<void> _toggleActive(bool value) async {
    // Server mode: delegate to remote server.
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (isRemote) {
      await ref.read(serverApiClientProvider)!.updateRegistryServer(def.id, isActive: value);
      widget.onStateChanged(def.copyWith(isActive: value));
      return;
    }

    final updated = await GithubMcpLibraryService.instance.setActive(def.id, active: value);
    if (value) {
      InternalMcpRegistry().registerGithubMcpServers();
    } else {
      InternalMcpRegistry().unregisterGithubMcpServer(def.id);
    }
    widget.onStateChanged(updated);
  }

  Future<void> _saveEnvVars() async {
    final envVars = {for (final e in _envControllers.entries) e.key: e.value.text.trim()};

    // Server mode: delegate to remote server.
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (isRemote) {
      await ref.read(serverApiClientProvider)!.updateRegistryServer(def.id, envVars: envVars);
      widget.onStateChanged(def.copyWith(envVars: envVars));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved'), duration: Duration(seconds: 2)));
      }
      return;
    }

    final updated = await GithubMcpLibraryService.instance.updateEnvVars(def.id, envVars);
    widget.onStateChanged(updated);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved'), duration: Duration(seconds: 2)));
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      elevation: def.isActive ? 2 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: def.isActive ? BorderSide(color: colorScheme.primary, width: 1.5) : BorderSide.none,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header row ──────────────────────────────────────────────────
          ListTile(
            leading: CircleAvatar(
              backgroundColor: colorScheme.primaryContainer,
              child: Icon(_categoryIcon(def.category), color: colorScheme.onPrimaryContainer, size: 20),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(def.displayName, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    _Chip(def.language, colorScheme.tertiaryContainer, colorScheme.onTertiaryContainer),
                    _Chip(def.installType, colorScheme.secondaryContainer, colorScheme.onSecondaryContainer),
                    if (def.isInstalled) _Chip('installed', Colors.green.shade100, Colors.green.shade900),
                  ],
                ),
              ],
            ),
            subtitle: Text(def.description, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (def.isInstalled) Switch(value: def.isActive, onChanged: _toggleActive),
                IconButton(
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ),
          ),

          // ── Expandable body ─────────────────────────────────────────────
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // GitHub link
                  if (def.githubUrl.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GestureDetector(
                        onTap: () => launchUrl(Uri.parse(def.githubUrl), mode: LaunchMode.externalApplication),
                        onLongPress: () {
                          Clipboard.setData(ClipboardData(text: def.githubUrl));
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(const SnackBar(content: Text('URL copied'), duration: Duration(seconds: 1)));
                        },
                        child: Text(
                          def.githubUrl,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.primary,
                            decoration: TextDecoration.underline,
                            decorationColor: colorScheme.primary,
                          ),
                        ),
                      ),
                    ),

                  // Env vars & arg placeholders
                  if (_envControllers.isNotEmpty) ...[
                    Text('Configuration', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    ..._envControllers.entries.map((e) {
                      final isSecret =
                          e.key.toLowerCase().contains('key') ||
                          e.key.toLowerCase().contains('token') ||
                          e.key.toLowerCase().contains('secret') ||
                          e.key.toLowerCase().contains('password');
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: TextField(
                          controller: e.value,
                          obscureText: isSecret,
                          decoration: InputDecoration(
                            labelText: e.key,
                            hintText: def.requiredEnvVars.contains(e.key) ? 'Required' : 'Optional path / value',
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      );
                    }),
                    if (def.isInstalled)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          icon: const Icon(Icons.save, size: 16),
                          label: const Text('Save settings'),
                          onPressed: _saveEnvVars,
                        ),
                      ),
                    const SizedBox(height: 4),
                  ],

                  // Install log
                  if (_installLog.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: _installLog.map((l) => Text(l, style: theme.textTheme.bodySmall)).toList(),
                      ),
                    ),

                  // Error
                  if (_installError != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: colorScheme.errorContainer, borderRadius: BorderRadius.circular(8)),
                      child: Text(_installError!, style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onErrorContainer)),
                    ),

                  // Action buttons
                  if (def.isInstalled)
                    Wrap(
                      spacing: 4,
                      runSpacing: 0,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.delete_outline, size: 16),
                          label: const Text('Remove'),
                          style: TextButton.styleFrom(foregroundColor: colorScheme.error),
                          onPressed: _uninstall,
                        ),
                        TextButton.icon(
                          icon: _discovering
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.search, size: 16),
                          label: Text(_discovering ? 'Loading...' : 'Discover tools'),
                          onPressed: (_discovering || _buildingSkills) ? null : _discoverTools,
                        ),
                        TextButton.icon(
                          icon: _buildingSkills
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.psychology_outlined, size: 16),
                          label: Text(_buildingSkills ? 'Building...' : 'Build skills'),
                          onPressed: (_buildingSkills || _discovering) ? null : _buildSkills,
                        ),
                      ],
                    )
                  else
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        icon: _installing
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.download, size: 16),
                        label: Text(_installing ? 'Installing...' : 'Install'),
                        onPressed: _installing ? null : _install,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static IconData _categoryIcon(String cat) {
    switch (cat) {
      case 'files':
        return Icons.folder_open;
      case 'databases':
        return Icons.storage;
      case 'web':
        return Icons.language;
      case 'productivity':
        return Icons.work_outline;
      default:
        return Icons.extension;
    }
  }
}

// ─── Discover Sheet ───────────────────────────────────────────────────────────

class _DiscoverSheet extends StatelessWidget {
  final String serverName;
  final List<McpToolDescriptor> tools;
  final String? error;

  const _DiscoverSheet({required this.serverName, required this.tools, this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, controller) => Column(
        children: [
          // Handle
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: colorScheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                const Icon(Icons.search, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Tools: $serverName', style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                ),
                Text('${tools.length} tools', style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.outline)),
                if (tools.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.model_training, size: 18),
                    tooltip: 'Export for training',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: () => ToolListExportSheet.show(
                      context,
                      serverName: serverName,
                      tools: tools.map((t) => {'name': t.name, 'description': t.description, 'inputSchema': t.inputSchema}).toList(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error: $error', style: TextStyle(color: colorScheme.error)),
            )
          else if (tools.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('No tools found.'))
          else
            Expanded(
              child: ListView.separated(
                controller: controller,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: tools.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
                itemBuilder: (_, i) {
                  final t = tools[i];
                  final props = (t.inputSchema['properties'] as Map?)?.keys.toList() ?? <String>[];
                  final required = (t.inputSchema['required'] as List?)?.cast<String>() ?? <String>[];
                  // Build a natural-language example prompt
                  final example = _buildExamplePrompt(t.name, props, required);
                  return ListTile(
                    dense: true,
                    title: Text(
                      t.name,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFamily: 'monospace'),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (t.description.isNotEmpty) ...[const SizedBox(height: 2), Text(t.description, style: theme.textTheme.bodySmall)],
                        if (props.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: props.map((p) {
                              final isReq = required.contains(p);
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: isReq ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  p,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: isReq ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                        if (example != null) ...[
                          const SizedBox(height: 6),
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: example));
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)));
                            },
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(example, style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(Icons.copy, size: 12, color: colorScheme.outline),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    isThreeLine: false,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  static String? _buildExamplePrompt(String toolName, List props, List<String> required) {
    if (props.isEmpty) return 'Call $toolName';
    // Build a simple natural-language prompt using required params
    final paramHints = required.isNotEmpty ? required : props.take(2).toList();
    final paramStr = paramHints.map((p) => '$p="<value>"').join(', ');
    return 'Call $toolName with $paramStr';
  }
}

// ─── Chip ─────────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;

  const _Chip(this.label, this.bg, this.fg);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(
        label,
        style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ─── MCP Registry model ───────────────────────────────────────────────────────

class _McpRegistryServer {
  final String name;
  final String description;
  final String? remoteUrl;
  final String? remoteType;
  final String? repositoryUrl;
  final String? websiteUrl;

  const _McpRegistryServer({
    required this.name,
    required this.description,
    this.remoteUrl,
    this.remoteType,
    this.repositoryUrl,
    this.websiteUrl,
  });

  factory _McpRegistryServer.fromJson(Map<String, dynamic> entry) {
    final sv = entry['server'] is Map<String, dynamic> ? entry['server'] as Map<String, dynamic> : entry;
    final title = (sv['title'] ?? sv['name'] ?? '').toString();
    final desc = (sv['description'] ?? '').toString();

    // Remote endpoint
    String? remoteUrl;
    String? remoteType;
    final remotes = sv['remotes'];
    if (remotes is List) {
      for (final r in remotes.whereType<Map<String, dynamic>>()) {
        final u = (r['url'] ?? '').toString().trim();
        if (u.startsWith('https://')) {
          remoteUrl = u;
          remoteType = (r['type'] ?? '').toString();
          break;
        }
      }
    }

    // Repository URL
    String? repoUrl;
    final repo = sv['repository'];
    if (repo is Map<String, dynamic>) {
      repoUrl = (repo['url'] ?? '').toString().trim();
    }
    if (repoUrl?.isEmpty ?? true) repoUrl = null;

    final websiteUrl = (sv['websiteUrl'] ?? '').toString().trim();

    return _McpRegistryServer(
      name: title.isNotEmpty ? title : (remoteUrl ?? ''),
      description: desc,
      remoteUrl: remoteUrl,
      remoteType: remoteType,
      repositoryUrl: repoUrl,
      websiteUrl: websiteUrl.isNotEmpty ? websiteUrl : null,
    );
  }
}

// ─── MCP Registry Server Card ─────────────────────────────────────────────────

class _McpRegistryServerCard extends StatefulWidget {
  final _McpRegistryServer server;
  const _McpRegistryServerCard({required this.server});
  @override
  State<_McpRegistryServerCard> createState() => _McpRegistryServerCardState();
}

class _McpRegistryServerCardState extends State<_McpRegistryServerCard> {
  bool _expanded = false;

  _McpRegistryServer get s => widget.server;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final typeLabel = (s.remoteType ?? '').isNotEmpty ? s.remoteType! : 'remote';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: cs.primaryContainer,
              child: Icon(Icons.cloud_outlined, color: cs.onPrimaryContainer, size: 20),
            ),
            title: Row(
              children: [
                Flexible(child: Text(s.name, style: theme.textTheme.titleSmall)),
                const SizedBox(width: 6),
                _Chip(typeLabel, cs.tertiaryContainer, cs.onTertiaryContainer),
              ],
            ),
            subtitle: Text(
              s.description.isEmpty ? (s.remoteUrl ?? '') : s.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            trailing: IconButton(
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s.remoteUrl != null) ...[
                    Text('MCP Endpoint', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onLongPress: () {
                        Clipboard.setData(ClipboardData(text: s.remoteUrl!));
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('URL copied'), duration: Duration(seconds: 1)));
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
                        child: Text(s.remoteUrl!, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (s.websiteUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: GestureDetector(
                        onTap: () => launchUrl(Uri.parse(s.websiteUrl!), mode: LaunchMode.externalApplication),
                        child: Text(
                          s.websiteUrl!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.primary,
                            decoration: TextDecoration.underline,
                            decorationColor: cs.primary,
                          ),
                        ),
                      ),
                    ),
                  if (s.repositoryUrl != null)
                    GestureDetector(
                      onTap: () => launchUrl(Uri.parse(s.repositoryUrl!), mode: LaunchMode.externalApplication),
                      child: Text(
                        s.repositoryUrl!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.primary,
                          decoration: TextDecoration.underline,
                          decorationColor: cs.primary,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: s.remoteUrl == null
                          ? null
                          : () {
                              Clipboard.setData(ClipboardData(text: s.remoteUrl!));
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(const SnackBar(content: Text('MCP endpoint URL copied'), duration: Duration(seconds: 2)));
                            },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy MCP URL'),
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

// ─── Glama model ──────────────────────────────────────────────────────────────

class _GlamaServer {
  final String id;
  final String name;
  final String slug;
  final String namespace;
  final String description;
  final String? repositoryUrl;
  final List<String> attributes;
  final Map<String, Map<String, dynamic>> envProperties;
  final List<String> requiredEnv;

  _GlamaServer({
    required this.id,
    required this.name,
    required this.slug,
    required this.namespace,
    required this.description,
    this.repositoryUrl,
    required this.attributes,
    required this.envProperties,
    required this.requiredEnv,
  });

  /// True when the server can be installed and run locally (stdio).
  bool get isLocallyInstallable => attributes.any((a) => a == 'hosting:local-only' || a == 'hosting:hybrid');

  /// True when no local install is possible.
  bool get isRemoteOnly => !isLocallyInstallable;

  String get glamaUrl => 'https://glama.ai/mcp/servers/$id';

  /// Best-guess PyPI package name from the slug (lowercase, safe chars).
  String get suggestedPackageName {
    final s = slug.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\-_.]'), '-').replaceAll(RegExp(r'-+'), '-');
    return s.replaceAll(RegExp(r'^-+|-+$'), '');
  }

  factory _GlamaServer.fromJson(Map<String, dynamic> json) {
    final envSchema = json['environmentVariablesJsonSchema'] as Map<String, dynamic>? ?? {};
    final rawProps = envSchema['properties'] as Map<String, dynamic>? ?? {};
    final props = rawProps.map((k, v) => MapEntry(k, v is Map<String, dynamic> ? v : <String, dynamic>{}));
    final required = (envSchema['required'] as List<dynamic>? ?? []).cast<String>();
    return _GlamaServer(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      namespace: json['namespace'] as String? ?? '',
      description: json['description'] as String? ?? '',
      repositoryUrl: (json['repository'] as Map<String, dynamic>?)?['url'] as String?,
      attributes: (json['attributes'] as List<dynamic>? ?? []).cast<String>(),
      envProperties: props,
      requiredEnv: required,
    );
  }
}

// ─── Glama Server Card ────────────────────────────────────────────────────────

class _GlamaServerCard extends StatefulWidget {
  final _GlamaServer server;
  const _GlamaServerCard({required this.server});

  @override
  State<_GlamaServerCard> createState() => _GlamaServerCardState();
}

class _GlamaServerCardState extends State<_GlamaServerCard> {
  bool _expanded = false;
  bool _installing = false;
  String? _installError;
  final List<String> _installLog = [];
  late final TextEditingController _pkgCtrl;
  String _installType = 'uvx';
  late final Map<String, TextEditingController> _envCtrl;
  GithubMcpServerDefinition? _installed;

  _GlamaServer get s => widget.server;

  @override
  void initState() {
    super.initState();
    _pkgCtrl = TextEditingController(text: s.suggestedPackageName);
    _envCtrl = {for (final e in s.envProperties.entries) e.key: TextEditingController(text: (e.value['default'] as String?) ?? '')};
    _installed = GithubMcpLibraryService.instance.findByPackage(s.suggestedPackageName);
  }

  @override
  void dispose() {
    _pkgCtrl.dispose();
    for (final c in _envCtrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _install() async {
    final pkgName = _pkgCtrl.text.trim();
    if (pkgName.isEmpty) return;
    setState(() {
      _installing = true;
      _installError = null;
      _installLog.clear();
    });
    final lib = GithubMcpLibraryService.instance;
    final runtime = GithubMcpRuntimeService.instance;
    final envVars = {for (final e in _envCtrl.entries) e.key: e.value.text.trim()};

    var def = GithubMcpServerDefinition(
      id: const Uuid().v4(),
      name: s.slug.isEmpty ? pkgName : s.slug,
      displayName: s.name.isEmpty ? pkgName : s.name,
      description: s.description,
      githubUrl: s.repositoryUrl ?? '',
      language: 'python',
      installType: _installType,
      packageName: pkgName,
      entryPoint: pkgName,
      requiredEnvVars: s.requiredEnv,
      envVars: envVars,
      category: 'other',
      createdAt: DateTime.now(),
    );
    def = await lib.save(def);
    final error = await runtime.install(
      def,
      onProgress: (p) {
        if (mounted) setState(() => _installLog.add(p.message));
      },
    );
    if (!mounted) return;
    if (error == null) {
      await lib.markInstalled(def.id, envVars: envVars, activate: true);
      InternalMcpRegistry().registerGithubMcpServers();
      setState(() {
        _installing = false;
        _installed = lib.findById(def.id);
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${s.name} installed'), behavior: SnackBarBehavior.floating));
    } else {
      setState(() {
        _installing = false;
        _installError = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isInstalled = _installed != null;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      elevation: isInstalled ? 2 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isInstalled ? BorderSide(color: cs.primary, width: 1.5) : BorderSide.none,
      ),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: cs.tertiaryContainer,
              child: Icon(Icons.extension_outlined, color: cs.onTertiaryContainer, size: 20),
            ),
            title: Row(
              children: [
                Flexible(child: Text(s.name.isEmpty ? s.slug : s.name, style: theme.textTheme.titleSmall)),
                const SizedBox(width: 6),
                _Chip('installable', cs.secondaryContainer, cs.onSecondaryContainer),
                if (isInstalled) ...[const SizedBox(width: 4), _Chip('installed', Colors.green.shade100, Colors.green.shade900)],
              ],
            ),
            subtitle: Text(
              s.description.isEmpty ? s.namespace : s.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            trailing: IconButton(
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Repo link
                  if (s.repositoryUrl != null && s.repositoryUrl!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GestureDetector(
                        onTap: () => launchUrl(Uri.parse(s.repositoryUrl!), mode: LaunchMode.externalApplication),
                        child: Text(
                          s.repositoryUrl!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.primary,
                            decoration: TextDecoration.underline,
                            decorationColor: cs.primary,
                          ),
                        ),
                      ),
                    ),

                  // Package name + install type
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _pkgCtrl,
                          enabled: !isInstalled,
                          decoration: const InputDecoration(
                            labelText: 'PyPI package name',
                            hintText: 'e.g. mcp-server-fetch',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      DropdownButton<String>(
                        value: _installType,
                        isDense: true,
                        items: const [
                          DropdownMenuItem(value: 'uvx', child: Text('uvx')),
                          DropdownMenuItem(value: 'pip', child: Text('pip')),
                        ],
                        onChanged: isInstalled ? null : (v) => setState(() => _installType = v!),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Env vars
                  if (_envCtrl.isNotEmpty) ...[
                    Text('Configuration', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    ..._envCtrl.entries.map((e) {
                      final isReq = s.requiredEnv.contains(e.key);
                      final desc = (s.envProperties[e.key]?['description'] as String?) ?? '';
                      final isSecret =
                          e.key.toLowerCase().contains('key') ||
                          e.key.toLowerCase().contains('token') ||
                          e.key.toLowerCase().contains('secret');
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(
                          controller: e.value,
                          obscureText: isSecret,
                          decoration: InputDecoration(
                            labelText: e.key,
                            hintText: isReq ? 'Required${desc.isNotEmpty ? ' - $desc' : ''}' : desc,
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 4),
                  ],

                  // Install log
                  if (_installLog.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: _installLog.map((l) => Text(l, style: theme.textTheme.bodySmall)).toList(),
                      ),
                    ),

                  // Error
                  if (_installError != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(8)),
                      child: Text(_installError!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onErrorContainer)),
                    ),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: const Text('Glama'),
                        onPressed: () => launchUrl(Uri.parse(s.glamaUrl), mode: LaunchMode.externalApplication),
                      ),
                      if (!isInstalled)
                        FilledButton.icon(
                          icon: _installing
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.download, size: 16),
                          label: Text(_installing ? 'Installing...' : 'Install'),
                          onPressed: _installing ? null : _install,
                        )
                      else
                        _Chip('installed', Colors.green.shade100, Colors.green.shade900),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Smithery model ───────────────────────────────────────────────────────────

class _SmitheryServer {
  final String qualifiedName;
  final String name;
  final String description;
  final String? homepage;
  final bool isDeployed;

  const _SmitheryServer({
    required this.qualifiedName,
    required this.name,
    required this.description,
    this.homepage,
    this.isDeployed = false,
  });

  factory _SmitheryServer.fromJson(Map<String, dynamic> json) {
    final qn = (json['qualifiedName'] ?? '').toString();
    final displayName = (json['displayName'] ?? '').toString();
    return _SmitheryServer(
      qualifiedName: qn,
      name: displayName.isNotEmpty ? displayName : qn,
      description: (json['description'] ?? '').toString(),
      homepage: ((json['homepage'] ?? '').toString()).isNotEmpty ? json['homepage'].toString() : null,
      isDeployed: json['isDeployed'] as bool? ?? false,
    );
  }
}

// ─── Smithery Server Card ─────────────────────────────────────────────────────

class _SmitheryServerCard extends StatefulWidget {
  final _SmitheryServer server;
  const _SmitheryServerCard({required this.server});
  @override
  State<_SmitheryServerCard> createState() => _SmitheryServerCardState();
}

class _SmitheryServerCardState extends State<_SmitheryServerCard> {
  bool _expanded = false;
  bool _adding = false;
  bool _installing = false;
  bool _installed = false;
  bool _discovering = false;
  String? _installError;
  final List<String> _installLog = [];

  // Auth note: null=not fetched, ''=no special auth, non-empty=note to display
  String? _authNote;
  bool _fetchingDetail = false;

  _SmitheryServer get s => widget.server;

  String get _proxyUrl => 'https://server.smithery.ai/${s.qualifiedName}';

  @override
  void initState() {
    super.initState();
    _installed = GithubMcpLibraryService.instance.findByPackage(s.qualifiedName)?.isInstalled ?? false;
  }

  Future<void> _fetchDetailIfNeeded() async {
    if (_authNote != null || _fetchingDetail) return;
    setState(() => _fetchingDetail = true);
    try {
      final uri = Uri.parse('https://registry.smithery.ai/servers/${Uri.encodeComponent(s.qualifiedName)}');
      final resp = await http
          .get(uri, headers: const {'Accept': 'application/json', 'User-Agent': 'mobile-ai-agent/1.0'})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        if (mounted) setState(() => _authNote = '');
        return;
      }
      final data = jsonDecode(resp.body);
      if (data is! Map<String, dynamic>) {
        if (mounted) setState(() => _authNote = '');
        return;
      }

      // Try to derive auth note from configSchema inside connections.
      String note = '';
      String? realUrl;
      final connections = data['connections'];
      if (connections is List) {
        for (final conn in connections.whereType<Map<String, dynamic>>()) {
          // Capture the real deployment URL for the probe below.
          final du = (conn['deploymentUrl'] ?? conn['url'] ?? '').toString().trim();
          if (du.startsWith('https://')) realUrl ??= du;

          final schema = conn['configSchema'];
          if (schema is! Map<String, dynamic>) continue;
          final props = schema['properties'] as Map<String, dynamic>?;
          if (props == null || props.isEmpty) continue;

          // Scan property keys + descriptions for auth hints.
          final oauthKeys = ['oauth', 'scope', 'client_id', 'client_secret', 'access_token', 'authorization_url'];
          for (final entry in props.entries) {
            final keyLower = entry.key.toLowerCase();
            final desc = (entry.value is Map ? (entry.value as Map)['description'] ?? '' : '').toString().toLowerCase();
            if (oauthKeys.any((k) => keyLower.contains(k) || desc.contains(k))) {
              if (desc.contains('microsoft') || (realUrl ?? '').contains('microsoft') || s.name.toLowerCase().contains('excel')) {
                note = 'Requires Microsoft 365 OAuth authentication';
              } else if (desc.contains('google')) {
                note = 'Requires Google OAuth authentication';
              } else {
                note = 'Requires OAuth authentication';
              }
              break;
            }
            // Simple API key declared in schema — extract label from description.
            if (note.isEmpty && entry.value is Map) {
              final d = (entry.value as Map)['description']?.toString() ?? '';
              if (d.isNotEmpty) note = 'Requires API key — $d';
            }
          }
          if (note.isNotEmpty) break;
        }
      }

      // If schema gave no info, probe the real endpoint for a 401/403.
      if (note.isEmpty && realUrl != null) {
        try {
          // Probe the root of the deployment URL (Excel root returns 401, not /mcp).
          final probeUri = Uri.parse(realUrl);
          final probe = await http.get(probeUri, headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 5));
          if (probe.statusCode == 401 || probe.statusCode == 403) {
            // Check for Microsoft-specific clues in the response.
            final body = probe.body.toLowerCase();
            if (body.contains('microsoft') ||
                body.contains('azure') ||
                body.contains('msal') ||
                realUrl.contains('microsoft') ||
                s.name.toLowerCase().contains('excel')) {
              note = 'Requires Microsoft 365 OAuth authentication';
            } else {
              note = 'Requires authentication — visit the server page for credentials';
            }
          }
        } catch (_) {}
      }

      // Fallback: probe the Smithery proxy URL.
      if (note.isEmpty) {
        try {
          final proxyProbe = await http
              .get(Uri.parse('$_proxyUrl/mcp'), headers: const {'Accept': 'application/json'})
              .timeout(const Duration(seconds: 5));
          if (proxyProbe.statusCode == 401 || proxyProbe.statusCode == 403) {
            note = 'Requires authentication — visit the server page for credentials';
          }
        } catch (_) {}
      }

      if (mounted) setState(() => _authNote = note);
    } catch (_) {
      if (mounted) setState(() => _authNote = '');
    } finally {
      if (mounted) setState(() => _fetchingDetail = false);
    }
  }

  Future<void> _install() async {
    // Gate: free tier allows only _kFreeInstalledServerLimit installed server(s).
    setState(() {
      _installing = true;
      _installError = null;
      _installLog.clear();
    });
    final apiKey = ExternalToolsSettingsService.instance.smitheryApiKey.trim();
    final error = await GithubMcpRuntimeService.instance.installSmithery(
      s.qualifiedName,
      apiKey: apiKey.isNotEmpty ? apiKey : null,
      onProgress: (p) {
        if (mounted) setState(() => _installLog.add(p.message));
      },
    );
    if (!mounted) return;
    if (error == null) {
      // Persist the Smithery server in the local library so it appears in
      // My Servers and survives app restarts.
      final lib = GithubMcpLibraryService.instance;
      var def = GithubMcpServerDefinition(
        id: const Uuid().v4(),
        name: s.qualifiedName,
        displayName: s.name.isEmpty ? s.qualifiedName : s.name,
        description: s.description,
        githubUrl: s.homepage ?? '',
        language: 'nodejs',
        installType: 'smithery',
        packageName: s.qualifiedName,
        entryPoint: s.qualifiedName,
        category: 'other',
        createdAt: DateTime.now(),
      );
      def = await lib.save(def);
      await lib.markInstalled(def.id, envVars: const {}, activate: true);
      InternalMcpRegistry().registerGithubMcpServers();
      setState(() {
        _installing = false;
        _installed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${s.name}" installed via Smithery CLI')));
    } else {
      setState(() {
        _installing = false;
        _installError = error;
      });
    }
  }

  Future<void> _discoverTools() async {
    setState(() => _discovering = true);
    try {
      final svc = ExternalToolsSettingsService.instance;
      final apiKey = svc.smitheryApiKey.trim().isNotEmpty ? svc.smitheryApiKey.trim() : null;
      final server = McpToolConfig(
        serverUrl: 'https://server.smithery.ai',
        mcpEndpoint: '/${s.qualifiedName}/mcp',
        name: s.name,
        apiKey: apiKey,
      );
      if (!mounted) return;
      await showDialog<McpToolConfig>(
        context: context,
        builder: (_) => McpDiscoveryDialog(server: server),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Discovery failed: $e'), backgroundColor: Theme.of(context).colorScheme.error));
      }
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _addToExternalTools() async {
    setState(() => _adding = true);
    try {
      final svc = ExternalToolsSettingsService.instance;
      final resolvedUrl = await svc.fetchSmitheryConnectionUrl(s.qualifiedName);
      final serverUrl = resolvedUrl ?? _proxyUrl;
      final uri = Uri.tryParse(serverUrl);
      final baseUrl = uri != null ? '${uri.scheme}://${uri.authority}' : serverUrl;
      final endpoint = (uri != null && uri.path.isNotEmpty) ? uri.path : '/mcp';
      await svc.upsertSelectedServer(
        McpToolConfig(
          serverUrl: baseUrl,
          mcpEndpoint: endpoint,
          name: s.name,
          description: s.description.isNotEmpty ? s.description : null,
          catalogPageUrl: s.homepage ?? 'https://smithery.ai/server/${s.qualifiedName}',
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${s.name}" added to External Tools')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to add: $e'), backgroundColor: Theme.of(context).colorScheme.error));
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: cs.secondaryContainer,
              child: Icon(Icons.hub_outlined, color: cs.onSecondaryContainer, size: 20),
            ),
            title: Row(
              children: [
                Flexible(child: Text(s.name, style: theme.textTheme.titleSmall)),
                const SizedBox(width: 6),
                _Chip('remote', cs.primaryContainer, cs.onPrimaryContainer),
                const SizedBox(width: 4),
                _Chip('nodejs', cs.tertiaryContainer, cs.onTertiaryContainer),
                if (_installed) ...[const SizedBox(width: 4), _Chip('installed', Colors.green.shade100, Colors.green.shade900)],
              ],
            ),
            subtitle: s.description.isNotEmpty
                ? Text(s.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)
                : null,
            trailing: IconButton(
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              onPressed: () {
                setState(() => _expanded = !_expanded);
                if (_expanded) _fetchDetailIfNeeded();
              },
            ),
            onTap: () {
              setState(() => _expanded = !_expanded);
              if (_expanded) _fetchDetailIfNeeded();
            },
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Smithery proxy URL', style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _proxyUrl,
                          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: 'Copy URL',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _proxyUrl));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('URL copied')));
                        },
                      ),
                    ],
                  ),
                  if (s.homepage != null) ...[
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () => launchUrl(Uri.parse(s.homepage!), mode: LaunchMode.externalApplication),
                      child: Text(
                        s.homepage!,
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.primary, decoration: TextDecoration.underline),
                      ),
                    ),
                  ],
                  if (_fetchingDetail) ...[
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(minHeight: 1),
                  ] else if (_authNote != null && _authNote!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.15),
                        border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.lock_outline, size: 14, color: Colors.amber),
                          const SizedBox(width: 6),
                          Expanded(child: Text(_authNote!, style: theme.textTheme.bodySmall)),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text('Install via Smithery CLI', style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'npx -y @smithery/cli@latest mcp add ${s.qualifiedName}',
                            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          tooltip: 'Copy command',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: 'npx -y @smithery/cli@latest mcp add ${s.qualifiedName}'));
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Install command copied')));
                          },
                        ),
                      ],
                    ),
                  ),
                  if (_installLog.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        _installLog.join('\n'),
                        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontSize: 11),
                      ),
                    ),
                  ],
                  if (_installError != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(8)),
                      child: Text(_installError!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onErrorContainer)),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (_installed)
                        TextButton.icon(
                          icon: _discovering
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.search, size: 16),
                          label: Text(_discovering ? 'Loading...' : 'Discover tools'),
                          onPressed: _discovering ? null : _discoverTools,
                        ),
                      const Spacer(),
                      FilledButton.tonal(
                        onPressed: (_installing || _installed) ? null : _install,
                        child: _installing
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(_installed ? 'Installed' : 'Install'),
                      ),
                      if (s.isDeployed) ...[
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: _adding ? null : _addToExternalTools,
                          icon: _adding
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.add_link),
                          label: Text(_adding ? 'Adding...' : 'Add to External Tools'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Manual Install Dialog ────────────────────────────────────────────────────

/// Dialog that lets the user install an MCP server that is not in any registry
/// by providing a package name and choosing the install method.
class _ManualInstallDialog extends ConsumerStatefulWidget {
  const _ManualInstallDialog({this.existing});
  final GithubMcpServerDefinition? existing;

  @override
  ConsumerState<_ManualInstallDialog> createState() => _ManualInstallDialogState();
}

class _ManualInstallDialogState extends ConsumerState<_ManualInstallDialog> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _packageCtrl = TextEditingController();
  final _commandCtrl = TextEditingController();
  final _outputScrollCtrl = ScrollController();

  String _type = 'nodejs'; // 'nodejs' | 'python'
  String _nodeMethod = 'npm'; // 'npm' | 'npx'
  String _pyMethod = 'uvx'; // 'uvx' | 'pip'

  bool _running = false;
  bool _success = false;
  String? _saveError;
  final List<String> _outputLines = [];

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      _nameCtrl.text = ex.displayName;
      _urlCtrl.text = ex.githubUrl;
      _packageCtrl.text = ex.packageName;
      _type = (ex.language == 'python') ? 'python' : 'nodejs';
      if (ex.language == 'python') {
        _pyMethod = (ex.installType == 'pip') ? 'pip' : 'uvx';
      } else {
        _nodeMethod = (ex.installType == 'npx') ? 'npx' : 'npm';
      }
      _commandCtrl.text = _generateCommand(ex.packageName);
    }
    _packageCtrl.addListener(_onPackageChanged);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _packageCtrl.dispose();
    _commandCtrl.dispose();
    _outputScrollCtrl.dispose();
    super.dispose();
  }

  // ─── Command generation ───────────────────────────────────────────────────

  String get _effectiveInstallType => _type == 'nodejs' ? _nodeMethod : _pyMethod;

  String _normalizeGithubBlobToRaw(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return value.trim();
    if ((uri.host == 'github.com' || uri.host == 'www.github.com') && uri.pathSegments.length >= 5) {
      final s = uri.pathSegments;
      if (s[2] == 'blob') {
        final owner = s[0];
        final repo = s[1];
        final ref = s[3];
        final rest = s.sublist(4).join('/');
        final rawPath = '/$owner/$repo/$ref/$rest';
        return Uri(scheme: 'https', host: 'raw.githubusercontent.com', path: rawPath).toString();
      }
    }
    return value.trim();
  }

  bool _looksLikeRequirementsSpec(String value) {
    final v = value.trim().toLowerCase();
    if (v.isEmpty) return false;
    return v.endsWith('requirements.txt') || v.endsWith('.txt') || v.contains('/requirements');
  }

  String _generateCommand(String pkg) {
    if (pkg.isEmpty) return '';
    switch (_effectiveInstallType) {
      case 'npm':
        return 'npm install -g --force $pkg';
      case 'npx':
        return '# npx runs packages on-demand — no separate install step needed.\n'
            '# The server will be launched with: npx $pkg\n'
            '# Click "Execute & Save" to register it without installing.';
      case 'uvx':
        return 'uvx tool install $pkg';
      case 'pip':
        final normalized = _normalizeGithubBlobToRaw(pkg);
        if (_looksLikeRequirementsSpec(normalized)) {
          return 'pip install -r $normalized';
        }
        return 'pip install $normalized';
      default:
        return '';
    }
  }

  void _onPackageChanged() {
    if (!_running && !_success) {
      setState(() {
        _commandCtrl.text = _generateCommand(_packageCtrl.text.trim());
      });
    }
  }

  void _regenerateCommand() {
    _commandCtrl.text = _generateCommand(_packageCtrl.text.trim());
  }

  // ─── Execution ────────────────────────────────────────────────────────────

  Future<void> _execute() async {
    final pkg = _packageCtrl.text.trim();
    if (pkg.isEmpty) return;

    setState(() {
      _running = true;
      _success = false;
      _saveError = null;
      _outputLines.clear();
    });

    // ── Server mode: delegate install to the remote server ────────────────
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    if (isRemote) {
      await _executeRemote();
      return;
    }

    // ── Local mode: run shell commands on this machine ────────────────────
    final rawLines = _commandCtrl.text.split('\n').map((l) => l.trim()).toList();
    final execLines = rawLines.where((l) => l.isNotEmpty && !l.startsWith('#')).toList();

    bool allOk = true;

    if (execLines.isEmpty) {
      // npx or comment-only: nothing to install, proceed to register.
      _appendOutput('No install commands to run (on-demand launcher). Registering server…');
    } else {
      for (var line in execLines) {
        _appendOutput('> $line');
        var exitCode = await _runCmd(line);
        _appendOutput('Exit code: $exitCode');

        if (exitCode != 0) {
          // Auto-retry npm global installs that fail due to an already-existing
          // launcher file (EEXIST).
          final hasEexist = _outputLines.any((l) => l.contains('EEXIST'));
          if (hasEexist && line.trimLeft().startsWith('npm install')) {
            final forcedLine = line.trimRight().endsWith('--force') ? line : '$line --force';
            _appendOutput('⚠ File conflict (EEXIST). Retrying with --force…');
            _appendOutput('> $forcedLine');
            exitCode = await _runCmd(forcedLine);
            _appendOutput('Exit code: $exitCode');
          }

          if (exitCode != 0) {
            allOk = false;
            break;
          }
        }
      }
    }

    if (!mounted) return;

    if (allOk) {
      _appendOutput('✓ Install succeeded. Saving server…');
      await _saveServer();
    } else {
      setState(() => _running = false);
    }
  }

  /// Installs the server on the remote TealKit server, then mirrors the entry
  /// to the local library so it appears in My Servers.
  Future<void> _executeRemote() async {
    final def = _buildDef();
    _appendOutput('→ Sending install request to server…');
    try {
      final client = ref.read(serverApiClientProvider)!;
      final result = await client.installRegistryServer(def.toJson());
      if (!mounted) return;

      final logs = (result['logs'] as List? ?? []).cast<String>();
      for (final l in logs) {
        _appendOutput(l);
      }

      if (result['success'] == true) {
        if (!mounted) return;
        setState(() {
          _running = false;
          _success = true;
        });
        _appendOutput('✓ Server "${def.displayName}" installed and registered.');
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) Navigator.of(context).pop(true);
      } else {
        setState(() {
          _running = false;
          _saveError = result['error'] as String? ?? 'Install failed on server';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _saveError = e.toString();
      });
    }
  }

  /// Builds the server definition from the current form state.
  GithubMcpServerDefinition _buildDef() {
    final pkg = _packageCtrl.text.trim();
    final displayName = _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : pkg;
    return GithubMcpServerDefinition(
      id: widget.existing?.id ?? const Uuid().v4(),
      name: pkg.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '-').toLowerCase(),
      displayName: displayName,
      description: widget.existing?.description ?? '',
      githubUrl: _urlCtrl.text.trim(),
      language: _type == 'nodejs' ? 'nodejs' : 'python',
      installType: _effectiveInstallType,
      packageName: pkg,
      entryPoint: widget.existing?.entryPoint ?? pkg,
      launchArgs: widget.existing?.launchArgs ?? const [],
      requiredEnvVars: widget.existing?.requiredEnvVars ?? const [],
      envVars: widget.existing?.envVars ?? const {},
      category: widget.existing?.category ?? 'other',
      isInstalled: widget.existing?.isInstalled ?? false,
      isActive: widget.existing?.isActive ?? false,
      isManual: true,
      installedAt: widget.existing?.installedAt,
      createdAt: widget.existing?.createdAt ?? DateTime.now(),
    );
  }

  /// Runs [cmd] as a shell command, streaming stdout/stderr to the output
  /// console. Returns the process exit code.
  Future<int> _runCmd(String cmd) async {
    try {
      final process = await Process.start(Platform.isWindows ? 'cmd' : '/bin/sh', Platform.isWindows ? ['/c', cmd] : ['-c', cmd]);

      final stdoutDone = process.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach((l) {
        if (l.trim().isNotEmpty) _appendOutput(l);
      });

      final stderrDone = process.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach((l) {
        if (l.trim().isNotEmpty) _appendOutput(l);
      });

      await Future.wait([stdoutDone, stderrDone]);
      return await process.exitCode;
    } catch (e) {
      _appendOutput('Error: $e');
      return 1;
    }
  }

  void _appendOutput(String line) {
    if (!mounted) return;
    setState(() => _outputLines.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_outputScrollCtrl.hasClients) {
        _outputScrollCtrl.animateTo(
          _outputScrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _saveServer() async {
    final def = _buildDef();

    try {
      final lib = GithubMcpLibraryService.instance;
      GithubMcpServerDefinition saved;
      if (!lib.isKnown(def.packageName)) {
        saved = await lib.save(def); // def already has isManual: true
      } else {
        // Promote to isManual: true so it appears in My Servers even if it
        // was previously installed via a registry tab (isManual: false).
        final existing = lib.findByPackage(def.packageName);
        saved = await lib.save(existing != null ? existing.copyWith(isManual: true) : def);
      }
      await lib.markInstalled(saved.id, envVars: {}, activate: true);
      InternalMcpRegistry().registerGithubMcpServers();
      if (!mounted) return;
      setState(() {
        _running = false;
        _success = true;
      });
      _appendOutput('✓ Server "${def.displayName}" registered and activated.');
      // Auto-close after a short delay so the user can see the success message.
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _saveError = e.toString();
      });
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final canExecute = !_running && !_success && _packageCtrl.text.trim().isNotEmpty;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, minWidth: 320),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──────────────────────────────────────────────────
              Row(
                children: [
                  Icon(Icons.build_circle_outlined, size: 22, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.existing != null ? 'Edit MCP Server' : 'Install MCP Server Manually',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Cancel',
                    onPressed: _running ? null : () => Navigator.of(context).pop(false),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Install an MCP server that is not listed in any registry.',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 18),

              // ── Name ────────────────────────────────────────────────────
              TextField(
                controller: _nameCtrl,
                enabled: !_running && !_success,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Puppeteer MCP',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),

              // ── URL ─────────────────────────────────────────────────────
              TextField(
                controller: _urlCtrl,
                enabled: !_running && !_success,
                decoration: const InputDecoration(
                  labelText: 'URL (optional)',
                  hintText: 'https://github.com/…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),

              // ── Type + method row ────────────────────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _type,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Type',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'nodejs', child: Text('Node.js')),
                        DropdownMenuItem(value: 'python', child: Text('Python')),
                      ],
                      onChanged: (_running || _success)
                          ? null
                          : (v) {
                              setState(() => _type = v!);
                              _regenerateCommand();
                            },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _type == 'nodejs'
                        ? DropdownButtonFormField<String>(
                            initialValue: _nodeMethod,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Method',
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                            items: const [
                              DropdownMenuItem(value: 'npm', child: Text('npm install -g')),
                              DropdownMenuItem(value: 'npx', child: Text('npx')),
                            ],
                            onChanged: (_running || _success)
                                ? null
                                : (v) {
                                    setState(() => _nodeMethod = v!);
                                    _regenerateCommand();
                                  },
                          )
                        : DropdownButtonFormField<String>(
                            initialValue: _pyMethod,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Method',
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                            items: const [
                              DropdownMenuItem(value: 'uvx', child: Text('uvx (recommended)')),
                              DropdownMenuItem(value: 'pip', child: Text('pip install')),
                            ],
                            onChanged: (_running || _success)
                                ? null
                                : (v) {
                                    setState(() => _pyMethod = v!);
                                    _regenerateCommand();
                                  },
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // ── Package name ─────────────────────────────────────────────
              TextField(
                controller: _packageCtrl,
                enabled: !_running && !_success,
                decoration: const InputDecoration(
                  labelText: 'Package / server name',
                  hintText: 'e.g. puppeteer-mcp-server',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),

              // ── Command box ───────────────────────────────────────────────
              TextField(
                controller: _commandCtrl,
                enabled: !_running && !_success,
                maxLines: 4,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: 'Install command(s)',
                  hintText: 'One command per line. Lines starting with # are comments.',
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: Tooltip(
                    message: 'Re-generate command',
                    child: IconButton(
                      icon: const Icon(Icons.autorenew, size: 18),
                      onPressed: (_running || _success) ? null : _regenerateCommand,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // ── Output console ────────────────────────────────────────────
              if (_outputLines.isNotEmpty)
                Container(
                  height: 180,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: _success
                        ? Border.all(color: Colors.green.shade400, width: 1.5)
                        : _saveError != null
                        ? Border.all(color: cs.error, width: 1.5)
                        : null,
                  ),
                  child: Stack(
                    children: [
                      SelectionArea(
                        child: ListView.builder(
                          controller: _outputScrollCtrl,
                          padding: const EdgeInsets.fromLTRB(10, 10, 32, 10),
                          itemCount: _outputLines.length,
                          itemBuilder: (_, i) {
                            final line = _outputLines[i];
                            final isSuccess = line.startsWith('✓');
                            final isCmd = line.startsWith('>');
                            final isWarn = line.startsWith('⚠');
                            final isError = line.toLowerCase().contains('npm error') || line.toLowerCase().contains('error:');
                            return Text(
                              line,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                color: isSuccess
                                    ? Colors.green.shade700
                                    : isCmd
                                    ? cs.primary
                                    : isWarn
                                    ? Colors.orange.shade700
                                    : isError
                                    ? cs.error
                                    : null,
                              ),
                            );
                          },
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: Tooltip(
                          message: 'Copy output',
                          child: IconButton(
                            icon: const Icon(Icons.copy, size: 14),
                            onPressed: () => Clipboard.setData(ClipboardData(text: _outputLines.join('\n'))),
                            padding: const EdgeInsets.all(4),
                            constraints: const BoxConstraints(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              if (_saveError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('Save failed: $_saveError', style: theme.textTheme.bodySmall?.copyWith(color: cs.error)),
                ),

              // ── Buttons ───────────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _running ? null : () => Navigator.of(context).pop(_success),
                    child: Text(_success ? 'Close' : 'Cancel'),
                  ),
                  if (widget.existing != null && !_success && !_running) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.save_outlined, size: 16),
                      label: const Text('Save Info'),
                      onPressed: _packageCtrl.text.trim().isNotEmpty ? _saveInfoOnly : null,
                    ),
                  ],
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: _running
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : _success
                        ? const Icon(Icons.check, size: 16)
                        : const Icon(Icons.play_arrow, size: 16),
                    label: Text(
                      _running
                          ? 'Running…'
                          : _success
                          ? 'Done'
                          : 'Execute & Save',
                    ),
                    onPressed: canExecute ? _execute : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveInfoOnly() async {
    setState(() => _running = true);
    await _saveServer();
  }
}

// ─── My Servers card ────────────────────────────────────────────────────────

class _MyServerCard extends ConsumerStatefulWidget {
  const _MyServerCard({required this.def, required this.onEdit, required this.onDelete, required this.onToggleActive});

  final GithubMcpServerDefinition def;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final void Function(bool) onToggleActive;

  @override
  ConsumerState<_MyServerCard> createState() => _MyServerCardState();
}

class _MyServerCardState extends ConsumerState<_MyServerCard> {
  bool _discovering = false;
  bool _buildingSkills = false;

  GithubMcpServerDefinition get def => widget.def;

  Future<void> _discoverTools() async {
    setState(() => _discovering = true);
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    List<McpToolDescriptor> tools = [];
    String? error;
    try {
      if (isRemote) {
        final client = ref.read(serverApiClientProvider)!;
        final result = await client.testRegistryServer(def.id);
        final rawTools = (result['tools'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>();
        tools = rawTools
            .map(
              (t) => McpToolDescriptor(
                name: t['name'] as String,
                description: t['description'] as String? ?? '',
                inputSchema: (t['inputSchema'] as Map<String, dynamic>?) ?? const {'type': 'object', 'properties': {}},
              ),
            )
            .toList();
        if (result['success'] != true) error = result['error'] as String?;
      } else {
        StdioMcpClient? client;
        try {
          final process = await GithubMcpRuntimeService.instance.launch(def);
          client = StdioMcpClient(process);
          final initResp = await client.request('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'TealKit', 'version': '1.0'},
          }, timeout: const Duration(seconds: 30));
          if (initResp.containsKey('error')) {
            error = 'Handshake error: ${initResp['error']}';
          } else {
            await client.notify('notifications/initialized', null);
            final resp = await client.request('tools/list', null, timeout: const Duration(seconds: 30));
            final rawList = resp['result']?['tools'] as List<dynamic>? ?? resp['result'] as List<dynamic>? ?? [];
            tools = rawList
                .whereType<Map<String, dynamic>>()
                .map(
                  (t) => McpToolDescriptor(
                    name: t['name'] as String,
                    description: t['description'] as String? ?? '',
                    inputSchema: (t['inputSchema'] as Map<String, dynamic>?) ?? const {'type': 'object', 'properties': {}},
                  ),
                )
                .toList();
            if (tools.isEmpty && resp.containsKey('error')) {
              error = 'tools/list error: ${resp['error']}';
            }
          }
        } on TimeoutException catch (e) {
          error = 'Server did not respond in time (${e.duration?.inSeconds ?? 30}s).\nMake sure the server is installed.';
        } finally {
          await client?.dispose();
        }
      }
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _DiscoverSheet(serverName: def.displayName, tools: tools, error: error),
    );
  }

  Future<void> _buildSkills() async {
    final llmSettings = LlmSettingsService.instance;
    if (!llmSettings.isLoaded) await llmSettings.load();
    if (!llmSettings.isConfigured) {
      if (mounted) {
        setState(() => _buildingSkills = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('LLM 1 (Primary Model) must be configured/accepted in Settings to build skills.'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }

    setState(() => _buildingSkills = true);
    final isRemote = ref.read(serverModeProvider).value?.isRemote ?? false;
    List<McpToolDescriptor> tools = [];
    try {
      if (isRemote) {
        final client = ref.read(serverApiClientProvider)!;
        final result = await client.testRegistryServer(def.id);
        final rawTools = (result['tools'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>();
        tools = rawTools
            .map(
              (t) => McpToolDescriptor(
                name: t['name'] as String,
                description: t['description'] as String? ?? '',
                inputSchema: (t['inputSchema'] as Map<String, dynamic>?) ?? const {'type': 'object', 'properties': {}},
              ),
            )
            .toList();
      } else {
        StdioMcpClient? stdioClient;
        try {
          final process = await GithubMcpRuntimeService.instance.launch(def);
          stdioClient = StdioMcpClient(process);
          await stdioClient.request('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'TealKit', 'version': '1.0'},
          }, timeout: const Duration(seconds: 30));
          await stdioClient.notify('notifications/initialized', null);
          final resp = await stdioClient.request('tools/list', null, timeout: const Duration(seconds: 30));
          final rawList = resp['result']?['tools'] as List<dynamic>? ?? [];
          tools = rawList
              .whereType<Map<String, dynamic>>()
              .map(
                (t) => McpToolDescriptor(
                  name: t['name'] as String,
                  description: t['description'] as String? ?? '',
                  inputSchema: (t['inputSchema'] as Map<String, dynamic>?) ?? const {'type': 'object', 'properties': {}},
                ),
              )
              .toList();
        } finally {
          await stdioClient?.dispose();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _buildingSkills = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load tools: $e'), backgroundColor: Theme.of(context).colorScheme.error));
      }
      return;
    }

    if (tools.isEmpty) {
      if (mounted) {
        setState(() => _buildingSkills = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No tools found for this server.')));
      }
      return;
    }

    final mcpType = 'gh_mcp_${def.id}';
    final remoteClient = isRemote ? ref.read(serverApiClientProvider) : null;
    if (!mounted) {
      setState(() => _buildingSkills = false);
      return;
    }

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
      final generated = await FunctionHintGenerationService().generateSkillsForTools(tools, mcpType);
      final db = FunctionHintDatabaseService();
      for (final s in generated) {
        await db.save(s);
      }
      if (remoteClient != null) {
        for (final s in generated) {
          await remoteClient.saveSkill(s.toJson());
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Generated ${generated.length} skill${generated.length == 1 ? '' : 's'} for ${def.displayName}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Skill generation failed: $e'), backgroundColor: Theme.of(context).colorScheme.error));
      }
    } finally {
      if (mounted) {
        setState(() => _buildingSkills = false);
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final purpleFg = isDark ? Colors.deepPurple.shade200 : Colors.deepPurple.shade700;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            leading: CircleAvatar(
              backgroundColor: purpleFg.withValues(alpha: 0.15),
              child: Icon(Icons.extension, color: purpleFg, size: 20),
            ),
            title: Text(def.displayName, style: theme.textTheme.titleSmall),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(
                  def.packageName,
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _InstallTypeBadge(type: def.installType, color: purpleFg),
                    if (def.isInstalled) ...[const SizedBox(width: 6), _InstallTypeBadge(type: 'installed', color: cs.primary)],
                    if (def.githubUrl.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => launchUrl(Uri.parse(def.githubUrl)),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(Icons.open_in_new, size: 13, color: cs.primary),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: def.isActive,
                  onChanged: def.isInstalled ? widget.onToggleActive : null,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: 'Edit',
                  onPressed: widget.onEdit,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  padding: EdgeInsets.zero,
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, size: 20, color: cs.error),
                  tooltip: 'Remove',
                  onPressed: widget.onDelete,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
            isThreeLine: true,
          ),
          if (def.isInstalled)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  TextButton.icon(
                    icon: _discovering
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.search, size: 16),
                    label: Text(_discovering ? 'Loading…' : 'Discover tools'),
                    onPressed: (_discovering || _buildingSkills) ? null : _discoverTools,
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    icon: _buildingSkills
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.psychology_outlined, size: 16),
                    label: Text(_buildingSkills ? 'Building…' : 'Build skills'),
                    onPressed: (_buildingSkills || _discovering) ? null : _buildSkills,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _InstallTypeBadge extends StatelessWidget {
  const _InstallTypeBadge({required this.type, required this.color});
  final String type;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        type,
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
