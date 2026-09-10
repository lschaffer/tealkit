import 'dart:io';

import 'package:tealkit_api/tealkit_api.dart';
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
}

