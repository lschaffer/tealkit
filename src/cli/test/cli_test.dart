import 'dart:io';

import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:tealkit_api/tealkit_api.dart' hide ChatMessage, ChatRole;
import 'package:tealkit_cli/tealkit_cli.dart';
import 'package:test/test.dart';

void main() {
  group('ServerConfigManager', () {
    late Directory tempDir;
    late String serverYamlPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('tealkit_test_');
      serverYamlPath = '${tempDir.path}/server.yaml';
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('creates default server.yaml when missing', () {
      final manager = ServerConfigManager(serverYamlPath);
      final profiles = manager.loadProfiles();
      expect(profiles, isNotEmpty);
      expect(profiles.first.name, 'Local Dev');
      expect(File(serverYamlPath).existsSync(), isTrue);
    });

    test('can activate profile by 1-based index and name', () {
      final manager = ServerConfigManager(serverYamlPath);
      manager.ensureConfigFile();

      // Activate production (2nd profile)
      final activated = manager.activateProfile('2');
      expect(activated, isTrue);

      final active = manager.getActiveProfile();
      expect(active?.name, 'Production');
      expect(active?.isActive, isTrue);

      // Activate Local Dev by name
      final activatedByName = manager.activateProfile('Local Dev');
      expect(activatedByName, isTrue);
      expect(manager.getActiveProfile()?.name, 'Local Dev');
    });
  });

  group('EnvLoader', () {
    test('substitutes environment variable syntax', () {
      final input = 'api_key: "\${MY_TEST_KEY}"';
      final output = EnvLoader.substitute(input);
      // If MY_TEST_KEY is not in env, it should be empty string
      expect(output, 'api_key: ""');
    });

    test('loads from directory-specific .env file', () {
      final tempDir = Directory.systemTemp.createTempSync('env_test_');
      try {
        final envFile = File('${tempDir.path}/.env');
        envFile.writeAsStringSync('OPENAI_API_KEY=sk-test-123456\nMY_CUSTOM_VAR="hello_world"');

        final parsed = EnvLoader.parseEnvFile(envFile);
        expect(parsed['OPENAI_API_KEY'], 'sk-test-123456');
        expect(parsed['MY_CUSTOM_VAR'], 'hello_world');

        final substituted = EnvLoader.substitute('key: \${OPENAI_API_KEY}', tempDir);
        expect(substituted, 'key: sk-test-123456');
      } finally {
        tempDir.deleteSync(recursive: true);
        EnvLoader.clearCache();
      }
    });
  });

  group('CommandRunner', () {
    test('builds runner with all expected subcommands', () {
      final runner = buildTealKitCommandRunner();
      final commandNames = runner.commands.keys.toList();

      expect(commandNames, contains('server'));
      expect(commandNames, contains('ping'));
      expect(commandNames, contains('auto-discover'));
      expect(commandNames, contains('workflow'));
      expect(runner.commands['workflow']?.aliases, contains('agent'));
      expect(runner.commands['workflow']?.aliases, contains('task'));
      expect(runner.commands['workflow']?.subcommands.keys,
          containsAll(['list', 'run', 'status', 'cancel', 'logs', 'download']));
      expect(commandNames, contains('skill'));
      expect(commandNames, contains('prompt'));
      expect(commandNames, contains('chat'));
      expect(commandNames, contains('code'));
    });
  });

  group('SkillRunner parsing', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('skill_test_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('parses standard SKILL.md format', () {
      final skillFile = File('${tempDir.path}/test_skill.md');
      skillFile.writeAsStringSync('''---
name: sample-device-audit
description: Sample audit skill
version: 1.0.0
system_prompt: You are a system auditor.
prompts:
  - text: Check telemetry and CPU cores.
    tools: [get_device_telemetry]
  - text: Export diagnostic report.
tools:
  - name: get_device_telemetry
    tier: capability
---

# Instructions
Follow the instructions carefully.
''');

      final runner = SkillRunner();
      final manifest = runner.parseSkillFile(skillFile.path);

      expect(manifest.name, 'sample-device-audit');
      expect(manifest.description, 'Sample audit skill');
      expect(manifest.systemPrompt, 'You are a system auditor.');
      expect(manifest.promptSteps.length, 2);
      expect(manifest.promptSteps[0].text, 'Check telemetry and CPU cores.');
      expect(manifest.promptSteps[0].enabledToolNames, ['get_device_telemetry']);
      expect(manifest.promptSteps[1].text, 'Export diagnostic report.');
    });
  });

  group('Workflow resolution and matching', () {
    const dummyPlan = ExecutionPlan(cronExpression: '');
    final sampleTasks = [
      WorkflowTask(
        id: '904a50d7-818d-4ac6-a491-d6ef01e5e064',
        name: 'Tokens Verbrauch TaskAI',
        executionPlan: dummyPlan,
      ),
      WorkflowTask(
        id: '4d219d6f-4d97-46ef-b4c9-305b8c077e87',
        name: 'containers stats',
        executionPlan: dummyPlan,
      ),
      WorkflowTask(
        id: '7f2aa88a-bdff-435e-9cb8-1c68b7353d9f',
        name: 'latest news',
        executionPlan: dummyPlan,
      ),
      WorkflowTask(
        id: '1bd48cdf-ba93-4225-b94d-5998410483ce',
        name: 'disk usage (chain) tcloud',
        executionPlan: dummyPlan,
      ),
      WorkflowTask(
        id: '7e7350da-0ae8-4171-a178-5401753afdb2',
        name: 'Conditional Task (Weather + Flights)',
        executionPlan: dummyPlan,
      ),
    ];

    test('resolves by exact UUID', () {
      final res = matchWorkflow(sampleTasks, '7f2aa88a-bdff-435e-9cb8-1c68b7353d9f');
      expect(res, isNotNull);
      expect(res!.id, '7f2aa88a-bdff-435e-9cb8-1c68b7353d9f');
      expect(res.name, 'latest news');
    });

    test('resolves by exact name', () {
      final res = matchWorkflow(sampleTasks, 'latest news');
      expect(res, isNotNull);
      expect(res!.id, '7f2aa88a-bdff-435e-9cb8-1c68b7353d9f');
    });

    test('resolves by name with underscores instead of spaces', () {
      final res = matchWorkflow(sampleTasks, 'latest_news');
      expect(res, isNotNull);
      expect(res!.id, '7f2aa88a-bdff-435e-9cb8-1c68b7353d9f');
    });

    test('resolves case-insensitively with mixed casing and spaces', () {
      final res = matchWorkflow(sampleTasks, 'Latest News');
      expect(res, isNotNull);
      expect(res!.id, '7f2aa88a-bdff-435e-9cb8-1c68b7353d9f');
    });

    test('resolves by unique prefix or substring', () {
      final res = matchWorkflow(sampleTasks, 'containers');
      expect(res, isNotNull);
      expect(res!.id, '4d219d6f-4d97-46ef-b4c9-305b8c077e87');
      expect(res.name, 'containers stats');
    });

    test('returns null for unknown workflow', () {
      final res = matchWorkflow(sampleTasks, 'unknown_task');
      expect(res, isNull);
    });
  });

  group('Coding Tools Unit Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('coding_tools_test_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('FsWriteFileTool and FsReadFileTool work correctly', () async {
      final writeTool = FsWriteFileTool(workingDirectory: tempDir.path);
      final readTool = FsReadFileTool(workingDirectory: tempDir.path);

      final writeRes = await writeTool.execute({
        'path': 'sub/hello.txt',
        'content': 'Line 1\nLine 2\nLine 3\nLine 4',
      });
      expect(writeRes.isError, isFalse);

      final readRes = await readTool.execute({
        'path': 'sub/hello.txt',
        'startLine': 2,
        'endLine': 3,
      });
      expect(readRes.isError, isFalse);
      expect(readRes.content.first.text, contains('Line 2'));
      expect(readRes.content.first.text, contains('Line 3'));
      expect(readRes.content.first.text, isNot(contains('Line 4')));
    });

    test('FsReplaceTextTool performs exact replacement and errors on missing target', () async {
      final writeTool = FsWriteFileTool(workingDirectory: tempDir.path);
      final replaceTool = FsReplaceTextTool(workingDirectory: tempDir.path);

      await writeTool.execute({
        'path': 'config.json',
        'content': '{\n  "version": "1.0.0",\n  "enabled": true\n}',
      });

      // Successful replace
      final okRes = await replaceTool.execute({
        'path': 'config.json',
        'search': '"version": "1.0.0"',
        'replace': '"version": "2.0.0"',
      });
      expect(okRes.isError, isFalse);

      final updatedContent =
          File('${tempDir.path}/config.json').readAsStringSync();
      expect(updatedContent, contains('"version": "2.0.0"'));

      // Error on missing target
      final failRes = await replaceTool.execute({
        'path': 'config.json',
        'search': '"version": "9.9.9"',
        'replace': '"version": "3.0.0"',
      });
      expect(failRes.isError, isTrue);
    });

    test('FsFindTool finds files matching wildcard pattern', () async {
      final writeTool = FsWriteFileTool(workingDirectory: tempDir.path);
      final findTool = FsFindTool(workingDirectory: tempDir.path);

      await writeTool.execute({
        'path': 'src/MyProject.csproj',
        'content': '<Project />',
      });
      await writeTool.execute({
        'path': 'tasks.md',
        'content': '# Tasks',
      });

      final findRes = await findTool.execute({'pattern': '*.csproj'});
      expect(findRes.isError, isFalse);
      expect(findRes.content.first.text, contains('MyProject.csproj'));
      expect(findRes.content.first.text, isNot(contains('tasks.md')));
    });
  });

  group('GlobalConfigLocator', () {
    test('resolves local file first when present', () {
      final file = GlobalConfigLocator.resolveConfigFile('pubspec.yaml');
      expect(file.existsSync(), isTrue);
    });

    test('returns non-empty globalDir string', () {
      expect(GlobalConfigLocator.globalDir, isNotEmpty);
      expect(GlobalConfigLocator.globalSkillsDir, contains('.tealkit'));
    });
  });

  group('ToolPermissionSettings', () {
    test('default permissions require confirmation for write, exec, and network', () {
      final perms = ToolPermissionSettings();
      expect(perms.autoApproveRead, isTrue);
      expect(perms.autoApproveWrite, isFalse);
      expect(perms.autoApproveExecute, isFalse);
      expect(perms.autoApproveNetwork, isFalse);

      expect(perms.isAutoApproved(ToolRiskLevel.read), isTrue);
      expect(perms.isAutoApproved(ToolRiskLevel.write), isFalse);
      expect(perms.isAutoApproved(ToolRiskLevel.execute), isFalse);
      expect(perms.isAutoApproved(ToolRiskLevel.network), isFalse);
    });

    test('setting permissions enables auto-approval', () {
      final perms = ToolPermissionSettings(
        autoApproveRead: true,
        autoApproveWrite: true,
        autoApproveExecute: true,
        autoApproveNetwork: true,
      );
      expect(perms.isAutoApproved(ToolRiskLevel.write), isTrue);
      expect(perms.isAutoApproved(ToolRiskLevel.execute), isTrue);
      expect(perms.isAutoApproved(ToolRiskLevel.network), isTrue);
    });
  });

  group('LlmConfigManager (Multi-LLM & Global Params)', () {
    late Directory tempDir;
    late String llmYamlPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('llm_test_');
      llmYamlPath = '${tempDir.path}/llm.yaml';
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('parses multi-LLM array and inherits global temperature and max_tokens', () {
      File(llmYamlPath).writeAsStringSync('''
temperature: 0.15
max_tokens: 2048

llms:
  - name: "ollama"
    provider: "ollama"
    model: "llama3"
    base_url: "http://localhost:11434"

  - name: "deepseek"
    provider: "openai_compatible"
    model: "deepseek-ai/DeepSeek-V4.1-Flash"
    api_key: "test_key"
    base_url: "https://api.deepinfra.com/v1/openai"
    temperature: 0.05
''');

      final profiles = LlmConfigManager.loadAllProfiles(configPath: llmYamlPath);
      expect(profiles.length, 2);

      // Ollama inherits global params
      final ollama = profiles.firstWhere((p) => p.name == 'ollama');
      expect(ollama.config.provider, LlmProvider.ollama);
      expect(ollama.config.model, 'llama3');
      expect(ollama.config.temperature, 0.15);
      expect(ollama.config.maxTokens, 2048);

      // Deepseek overrides temperature
      final deepseek = profiles.firstWhere((p) => p.name == 'deepseek');
      expect(deepseek.config.provider, LlmProvider.openaiCompatible);
      expect(deepseek.config.model, 'deepseek-ai/DeepSeek-V4.1-Flash');
      expect(deepseek.config.temperature, 0.05);
      expect(deepseek.config.maxTokens, 2048);
    });

    test('resolves config by model name or provider', () {
      File(llmYamlPath).writeAsStringSync('''
temperature: 0.2
max_tokens: 4096

llms:
  - name: "mistral"
    provider: "mistral"
    model: "mistral-medium-latest"
    api_key: "mis_key"

  - name: "openai"
    provider: "openai"
    model: "gpt-4o-mini"
    api_key: "oai_key"
''');

      final mistralConfig = LlmConfigManager.resolveConfig(nameOrPath: 'mistral', configPath: llmYamlPath);
      expect(mistralConfig.provider, LlmProvider.mistral);
      expect(mistralConfig.model, 'mistral-medium-latest');

      final openaiConfig = LlmConfigManager.resolveConfig(nameOrPath: 'openai', configPath: llmYamlPath);
      expect(openaiConfig.provider, LlmProvider.openai);
      expect(openaiConfig.model, 'gpt-4o-mini');
    });
  });

  group('SessionManager (JSON and Markdown)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('session_test_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('saves and restores JSON session', () async {
      final jsonPath = '${tempDir.path}/test-session.json';
      final session = SessionData(
        id: 'sess_1',
        title: 'Test Session',
        mode: 'code',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        llmName: 'deepseek',
        messages: [
          ChatMessage(
            id: 'm1',
            content: 'How do I start?',
            role: ChatRole.user,
            timestamp: DateTime.now(),
          ),
          ChatMessage(
            id: 'm2',
            content: 'You can run tealkit code.',
            role: ChatRole.assistant,
            timestamp: DateTime.now(),
          ),
        ],
      );

      await SessionManager.saveSession(session, jsonPath);
      expect(File(jsonPath).existsSync(), isTrue);

      final restored = await SessionManager.loadSession(jsonPath);
      expect(restored.id, 'sess_1');
      expect(restored.mode, 'code');
      expect(restored.llmName, 'deepseek');
      expect(restored.messages.length, 2);
      expect(restored.messages.first.content, 'How do I start?');
      expect(restored.messages.last.content, 'You can run tealkit code.');
    });

    test('saves and restores Markdown session with frontmatter', () async {
      final mdPath = '${tempDir.path}/test-session.md';
      final session = SessionData(
        id: 'sess_md_1',
        title: 'Markdown Session',
        mode: 'architect',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        llmName: 'ollama',
        messages: [
          ChatMessage(
            id: 'm1',
            content: 'Draft the architecture.',
            role: ChatRole.user,
            timestamp: DateTime.now(),
          ),
          ChatMessage(
            id: 'm2',
            content: 'Here is the architectural plan.',
            role: ChatRole.assistant,
            timestamp: DateTime.now(),
          ),
        ],
      );

      await SessionManager.saveSession(session, mdPath);
      expect(File(mdPath).existsSync(), isTrue);

      final content = File(mdPath).readAsStringSync();
      expect(content, contains('title: "Markdown Session"'));
      expect(content, contains('### 👤 User'));
      expect(content, contains('Draft the architecture.'));

      final restored = await SessionManager.loadSession(mdPath);
      expect(restored.mode, 'architect');
      expect(restored.llmName, 'ollama');
      expect(restored.messages.length, 2);
      expect(restored.messages.first.content, contains('Draft the architecture.'));
      expect(restored.messages.last.content, contains('Here is the architectural plan.'));
    });
  });

  group('McpManagerHelper', () {
    test('filters servers for uninstall by query and all_mcp', () async {
      final mcpManager = MultiMCPManager();
      final servers = [
        const McpServerConfig(
          id: 's1',
          name: 'mcp-server-fetch',
          url: '',
          isLocal: true,
          localType: 'python',
          localInstallMethod: 'uvx',
          localPackage: 'mcp-server-fetch',
        ),
        const McpServerConfig(
          id: 's2',
          name: 'mcp-server-puppeteer',
          url: '',
          isLocal: true,
          localType: 'nodejs',
          localInstallMethod: 'npx',
          localPackage: '@modelcontextprotocol/server-puppeteer',
        ),
      ];

      // Uninstall single
      final results1 = await McpManagerHelper.uninstallServers(
        targetQuery: 'fetch',
        configuredServers: servers,
        mcpManager: mcpManager,
      );
      expect(results1.length, 1);
      expect(results1.first.serverName, 'mcp-server-fetch');

      // Uninstall all
      final resultsAll = await McpManagerHelper.uninstallServers(
        targetQuery: 'all_mcp',
        configuredServers: servers,
        mcpManager: mcpManager,
      );
      expect(resultsAll.length, 2);
    });
  });

  group('TokenUsageTracker', () {
    test('accumulates tokens, calculates cost, and resets', () {
      final tracker = TokenUsageTracker();
      tracker.recordUsage(prompt: 10000, completion: 2000);
      tracker.recordUsage(prompt: 5000, completion: 1000);

      expect(tracker.promptTokens, 15000);
      expect(tracker.completionTokens, 3000);
      expect(tracker.totalTokens, 18000);
      expect(tracker.turnsCount, 2);

      const deepseekConfig = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        model: 'deepseek-ai/DeepSeek-V4.1-Flash',
        apiKey: 'key',
      );

      final cost = tracker.calculateEstimatedCost(deepseekConfig);
      // (15000/1M * 0.14) + (3000/1M * 0.28) = 0.0021 + 0.00084 = 0.00294
      expect(cost, closeTo(0.00294, 0.00001));

      final report = tracker.formatReport(deepseekConfig);
      expect(report, contains('Token Usage & Estimated Cost'));
      expect(report, contains('18,000'));
      expect(report, contains('\$0.002940'));

      tracker.reset();
      expect(tracker.totalTokens, 0);
      expect(tracker.turnsCount, 0);
    });
  });
}


