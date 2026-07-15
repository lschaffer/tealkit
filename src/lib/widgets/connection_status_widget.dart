import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/active_task_provider.dart';
import '../providers/llm_settings_provider.dart';
import '../services/llm_settings_service.dart';

class ConnectionStatusWidget extends ConsumerWidget {
  const ConnectionStatusWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final taskState = ref.watch(activeTaskProvider);
    final llmSettings = ref.watch(llmSettingsProvider);

    final mcpConnected = taskState?.mcpManager?.isConnected ?? false;
    final llmConfigured = llmSettings.provider != LlmProvider.none;

    // Only show if there are issues
    if (mcpConnected && llmConfigured) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.1),
        border: Border(bottom: BorderSide(color: Colors.amber.withValues(alpha: 0.3), width: 1)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_rounded, color: Colors.amber[700], size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Configuration Required',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber[800], fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(_getStatusMessage(mcpConnected, llmConfigured), style: TextStyle(color: Colors.amber[700], fontSize: 12)),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => _showQuickSetup(context),
            icon: const Icon(Icons.settings, size: 16),
            label: const Text('Setup'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.amber[800],
              backgroundColor: Colors.amber.withValues(alpha: 0.2),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  String _getStatusMessage(bool mcpConnected, bool llmConfigured) {
    if (!mcpConnected && !llmConfigured) {
      return 'MCP server not connected and LLM not configured';
    } else if (!mcpConnected) {
      return 'MCP server not connected to thiescloud.com/wsagrarmcpserver';
    } else if (!llmConfigured) {
      return 'LLM service not configured';
    }
    return '';
  }

  void _showQuickSetup(BuildContext context) {
    showDialog(context: context, builder: (context) => const _QuickSetupDialog());
  }
}

class _QuickSetupDialog extends ConsumerStatefulWidget {
  const _QuickSetupDialog();

  @override
  ConsumerState<_QuickSetupDialog> createState() => _QuickSetupDialogState();
}

class _QuickSetupDialogState extends ConsumerState<_QuickSetupDialog> {
  bool _isConnecting = false;
  bool _isConfiguring = false;

  Future<void> _connectToMCP() async {
    setState(() => _isConnecting = true);

    try {
      final taskState = ref.read(activeTaskProvider);
      final mcpManager = taskState?.mcpManager;
      if (mcpManager == null) throw Exception('No active task');
      await mcpManager.reconnectAll();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Connected to MCP server'), backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to connect: $e'), backgroundColor: Colors.red));
      }
    } finally {
      setState(() => _isConnecting = false);
    }
  }

  Future<void> _configureGemini() async {
    final controller = TextEditingController();

    final apiKey = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Gemini API Key'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter your Gemini API key', border: OutlineInputBorder()),
          obscureText: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Save')),
        ],
      ),
    );

    if (apiKey != null && apiKey.isNotEmpty) {
      setState(() => _isConfiguring = true);

      try {
        if (!mounted) return;
        final taskState = ref.read(activeTaskProvider);
        final llmService = taskState?.llmService;
        if (llmService == null) throw Exception('No active LLM service');
        await llmService.initializeGemini(apiKey: apiKey);

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Gemini configured successfully'), backgroundColor: Colors.green));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to configure Gemini: $e'), backgroundColor: Colors.red));
        }
      } finally {
        setState(() => _isConfiguring = false);
      }
    }
  }

  Future<void> _configureOllama() async {
    setState(() => _isConfiguring = true);

    try {
      final taskState = ref.read(activeTaskProvider);
      final llmService = taskState?.llmService;
      if (llmService == null) throw Exception('No active LLM service');
      await llmService.initializeOllama();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Ollama configured successfully'), backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to configure Ollama: $e'), backgroundColor: Colors.red));
      }
    } finally {
      setState(() => _isConfiguring = false);
    }
  }

  Future<void> _configureMistral() async {
    final apiKeyCtrl = TextEditingController();
    final modelCtrl = TextEditingController(text: 'mistral-large-latest');
    final baseUrlCtrl = TextEditingController(text: 'https://api.mistral.ai/v1');

    final config = await showDialog<(String, String, String)?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mistral AI Configuration'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: apiKeyCtrl,
                decoration: const InputDecoration(labelText: 'API Key', hintText: 'mistral-... or sk-...', border: OutlineInputBorder()),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: modelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Model',
                  hintText: 'mistral-large-latest / mistral-medium-latest / mistral-small-latest',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: baseUrlCtrl,
                decoration: const InputDecoration(labelText: 'Base URL', border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final apiKey = apiKeyCtrl.text.trim();
              final model = modelCtrl.text.trim();
              final baseUrl = baseUrlCtrl.text.trim();
              final uri = Uri.tryParse(baseUrl);

              if (apiKey.isEmpty || model.isEmpty || baseUrl.isEmpty || uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
                return;
              }

              Navigator.of(context).pop((apiKey, model, baseUrl));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (config == null) return;
    final apiKey = config.$1;
    final model = config.$2;
    final baseUrl = config.$3;

    if (!(apiKey.startsWith('mistral-') || apiKey.startsWith('sk-'))) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mistral API key should usually start with mistral- or sk-'), backgroundColor: Colors.orange),
        );
      }
    }

    setState(() => _isConfiguring = true);

    try {
      final taskState = ref.read(activeTaskProvider);
      final llmService = taskState?.llmService;
      if (llmService == null) throw Exception('No active LLM service');

      await llmService.initializeOpenAICompatible(baseUrl: baseUrl, apiKey: apiKey, model: model);

      final settings = ref.read(llmSettingsProvider);
      await settings.save(
        provider: LlmProvider.mistral,
        model: model,
        apiKey: apiKey,
        baseUrl: baseUrl,
        temperature: settings.temperature,
        maxTokens: settings.maxTokens,
        maxToolOutputSize: settings.maxToolOutputSize,
        tokenWarningThreshold: settings.tokenWarningThreshold,
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Mistral configured successfully'), backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to configure Mistral: $e'), backgroundColor: Colors.red));
      }
    } finally {
      setState(() => _isConfiguring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final taskState = ref.watch(activeTaskProvider);
    final mcpConnected = taskState?.mcpManager?.isConnected ?? false;
    final llmConfigured = taskState?.llmService?.isConfigured ?? false;
    final llmService = taskState?.llmService;

    return AlertDialog(
      title: const Text('Quick Setup'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // MCP Connection
            ListTile(
              leading: Icon(
                mcpConnected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: mcpConnected ? Colors.green : Colors.grey,
              ),
              title: const Text('MCP Server Connection'),
              subtitle: Text(mcpConnected ? 'Connected to servers' : 'Disconnected from MCP servers'),
              trailing: mcpConnected
                  ? null
                  : _isConnecting
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
                      ),
                    )
                  : IconButton(onPressed: _connectToMCP, icon: const Icon(Icons.refresh), tooltip: 'Connect'),
            ),

            const Divider(),

            // LLM Configuration
            ListTile(
              leading: Icon(
                llmConfigured ? Icons.check_circle : Icons.radio_button_unchecked,
                color: llmConfigured ? Colors.green : Colors.grey,
              ),
              title: const Text('LLM Configuration'),
              subtitle: Text(
                llmConfigured && llmService != null
                    ? '${llmService.currentProvider.name} - ${llmService.currentModel}'
                    : 'Choose an LLM provider',
              ),
            ),

            if (!llmConfigured) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isConfiguring ? null : _configureGemini,
                      icon: const Icon(Icons.cloud, size: 16),
                      label: const Text('Gemini'),
                      style: ElevatedButton.styleFrom(minimumSize: const Size(0, 36)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isConfiguring ? null : _configureOllama,
                      icon: const Icon(Icons.computer, size: 16),
                      label: const Text('Ollama'),
                      style: ElevatedButton.styleFrom(minimumSize: const Size(0, 36)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isConfiguring ? null : _configureMistral,
                  icon: const Icon(Icons.rocket_launch, size: 16),
                  label: const Text('Mistral'),
                  style: ElevatedButton.styleFrom(minimumSize: const Size(0, 36)),
                ),
              ),
            ],

            if (_isConfiguring) ...[
              const SizedBox(height: 16),
              Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary))),
            ],
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    );
  }
}
