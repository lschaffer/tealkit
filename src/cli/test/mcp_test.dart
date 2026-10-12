import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tealkit_cli/tealkit_cli.dart';
import 'package:test/test.dart';

void main() {
  group('WorkflowSchemaGenerator', () {
    test('sanitizes tool names to MCP compliant identifiers', () {
      expect(WorkflowSchemaGenerator.sanitizeToolName('Deploy Production Server'),
          'wf_deploy_production_server');
      expect(WorkflowSchemaGenerator.sanitizeToolName('test---run___123'),
          'wf_test_run_123');
      expect(WorkflowSchemaGenerator.sanitizeToolName('   ###Special@@Chars!!   '),
          'wf_special_chars');
      expect(WorkflowSchemaGenerator.sanitizeToolName(''),
          'wf_workflow');
    });

    test('generates valid MCP tool schema with variables', () {
      final wf = TealKitWorkflow(
        id: 'wf_1',
        name: 'Generate Docs',
        description: 'Generates API documentation',
        variables: [
          WorkflowVariable(
            key: 'target_dir',
            description: 'Target directory path',
            type: 'string',
            required: true,
          ),
          WorkflowVariable(
            key: 'verbose',
            description: 'Enable verbose logging',
            type: 'boolean',
            required: false,
            defaultValue: false,
          ),
        ],
        runner: (args) async => 'Docs generated',
      );

      final tool = WorkflowSchemaGenerator.toMcpTool(wf);
      expect(tool['name'], 'wf_generate_docs');
      expect(tool['description'], 'Generates API documentation');
      final schema = tool['inputSchema'] as Map<String, dynamic>;
      expect(schema['type'], 'object');
      final props = schema['properties'] as Map<String, dynamic>;
      expect(props['target_dir']['type'], 'string');
      expect(props['verbose']['type'], 'boolean');
      expect(props['verbose']['default'], false);
      expect(schema['required'], contains('target_dir'));
      expect(schema['required'], isNot(contains('verbose')));
    });

    test('provides fallback input property when no variables defined', () {
      final wf = TealKitWorkflow(
        id: 'wf_2',
        name: 'Quick Ping',
        description: '',
        variables: const [],
        runner: (args) async => 'Pong',
      );

      final tool = WorkflowSchemaGenerator.toMcpTool(wf);
      final schema = tool['inputSchema'] as Map<String, dynamic>;
      final props = schema['properties'] as Map<String, dynamic>;
      expect(props.containsKey('input'), isTrue);
      expect(schema['required'], contains('input'));
    });
  });

  group('McpStdioServer JSON-RPC Protocol', () {
    late McpStdioServer server;
    late List<TealKitWorkflow> testWorkflows;

    setUp(() {
      testWorkflows = [
        TealKitWorkflow(
          id: 'wf_test',
          name: 'Echo Payload',
          description: 'Echoes the given message',
          variables: [
            WorkflowVariable(
              key: 'message',
              description: 'Text to echo',
              type: 'string',
              required: true,
            ),
          ],
          runner: (args) async => 'Echo: ${args["message"]}',
        ),
      ];
      server = McpStdioServer(workflows: testWorkflows);
    });

    Future<Map<String, dynamic>> sendRpc(Map<String, dynamic> request) async {
      final responses = <String>[];
      await server.handleRawMessage(
        jsonEncode(request),
        writer: (line) => responses.add(line),
      );
      expect(responses, isNotEmpty, reason: 'Expected at least one response');
      return jsonDecode(responses.first) as Map<String, dynamic>;
    }

    test('initialize returns protocol version and capabilities', () async {
      final res = await sendRpc({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2024-11-05',
          'capabilities': {},
        },
      });

      expect(res['jsonrpc'], '2.0');
      expect(res['id'], 1);
      final result = res['result'] as Map<String, dynamic>;
      expect(result['protocolVersion'], '2024-11-05');
      expect(result['serverInfo']['name'], 'tealkit-mcp-server');
      expect(result['serverInfo']['version'], '1.3.0');
      expect(result['capabilities']['tools']['listChanged'], true);
      expect(result['capabilities']['resources']['listChanged'], true);
      expect(result['capabilities']['prompts']['listChanged'], true);
    });

    test('ping returns empty result', () async {
      final res = await sendRpc({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'ping',
      });
      expect(res['id'], 2);
      expect(res['result'], isEmpty);
    });

    test('tools/list returns both built-in and dynamic workflow tools', () async {
      final res = await sendRpc({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/list',
      });

      final result = res['result'] as Map<String, dynamic>;
      final tools = result['tools'] as List;
      final toolNames = tools.map((t) => t['name']).toList();

      expect(toolNames, contains('tealkit_rag_query'));
      expect(toolNames, contains('tealkit_run_workflow'));
      expect(toolNames, contains('tealkit_run_skill'));
      expect(toolNames, contains('tealkit_slm_process'));
      expect(toolNames, contains('wf_echo_payload'));
    });

    test('tools/call executes dynamic workflow tool', () async {
      final res = await sendRpc({
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {
          'name': 'wf_echo_payload',
          'arguments': {'message': 'Hello MCP!'},
        },
      });

      final result = res['result'] as Map<String, dynamic>;
      final content = result['content'] as List;
      expect(content.first['type'], 'text');
      expect(content.first['text'], 'Echo: Hello MCP!');
    });

    test('tools/call executes tealkit_rag_query', () async {
      final res = await sendRpc({
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'tools/call',
        'params': {
          'name': 'tealkit_rag_query',
          'arguments': {'query': 'authentication setup', 'limit': 3},
        },
      });

      final result = res['result'] as Map<String, dynamic>;
      final content = result['content'] as List;
      expect(content.first['text'], contains('TealKit RAG'));
    });

    test('tools/call handles unknown tool name with error', () async {
      final res = await sendRpc({
        'jsonrpc': '2.0',
        'id': 6,
        'method': 'tools/call',
        'params': {
          'name': 'non_existent_tool',
        },
      });

      final result = res['result'] as Map<String, dynamic>;
      expect(result['isError'], isTrue);
      expect(result['content'].first['text'], contains('Unknown tool'));
    });

    test('resources/list and resources/read work correctly', () async {
      final listRes = await sendRpc({
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'resources/list',
      });
      final resources = listRes['result']['resources'] as List;
      expect(resources.any((r) => r['uri'] == 'tealkit://workflows'), isTrue);

      final readRes = await sendRpc({
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'resources/read',
        'params': {'uri': 'tealkit://workflows'},
      });
      final contents = readRes['result']['contents'] as List;
      expect(contents.first['uri'], 'tealkit://workflows');
      expect(contents.first['text'], contains('Echo Payload'));
    });

    test('prompts/list and prompts/get format messages', () async {
      final listRes = await sendRpc({
        'jsonrpc': '2.0',
        'id': 9,
        'method': 'prompts/list',
      });
      final prompts = listRes['result']['prompts'] as List;
      expect(prompts.any((p) => p['name'] == 'tealkit_code_review'), isTrue);

      final getRes = await sendRpc({
        'jsonrpc': '2.0',
        'id': 10,
        'method': 'prompts/get',
        'params': {
          'name': 'tealkit_code_review',
          'arguments': {'diff': '+ int x = 42;'},
        },
      });
      final messages = getRes['result']['messages'] as List;
      expect(messages.first['role'], 'user');
      expect(messages.first['content']['text'], contains('+ int x = 42;'));
    });

    test('returns standard method not found error (-32601)', () async {
      final res = await sendRpc({
        'jsonrpc': '2.0',
        'id': 99,
        'method': 'unknown_method_xyz',
      });
      expect(res['error']['code'], -32601);
      expect(res['error']['message'], contains('Method not found'));
    });

    test('ignores initialized notification without crashing', () async {
      final responses = <String>[];
      await server.handleRawMessage(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        }),
        writer: (line) => responses.add(line),
      );
      expect(responses, isEmpty);
    });
  });

  group('McpConfigInstaller', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('tealkit_mcp_test_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('generates valid server definitions', () {
      final config = McpConfigInstaller.generateServerConfig(
        customCommand: 'C:\\bin\\tealkit.exe',
      );
      expect(config['command'], 'C:\\bin\\tealkit.exe');
      expect(config['args'], ['mcp-serve']);

      final cursorConfig = McpConfigInstaller.generateCursorConfig();
      expect(cursorConfig['mcpServers']['tealkit']['args'], ['mcp-serve']);

      final rooConfig = McpConfigInstaller.generateRooCodeConfig();
      expect(rooConfig['mcpServers']['tealkit']['disabled'], false);
    });

    test('installs and updates Claude Desktop config safely', () {
      final targetFile = '${tempDir.path}/claude_desktop_config.json';
      File(targetFile).writeAsStringSync(jsonEncode({
        'mcpServers': {
          'existing_server': {
            'command': 'npx',
            'args': ['-y', 'existing-pkg'],
          }
        }
      }));

      final result = McpConfigInstaller.installToClaudeDesktop(
        configPath: targetFile,
        customCommand: 'tealkit.exe',
      );

      expect(result.success, isTrue);
      final updatedContent = File(targetFile).readAsStringSync();
      final updatedJson = jsonDecode(updatedContent) as Map<String, dynamic>;
      final servers = updatedJson['mcpServers'] as Map<String, dynamic>;

      // Existing server must be preserved
      expect(servers.containsKey('existing_server'), isTrue);
      // TealKit must be added
      expect(servers.containsKey('tealkit'), isTrue);
      expect(servers['tealkit']['command'], 'tealkit.exe');
      expect(servers['tealkit']['args'], ['mcp-serve']);
    });
  });

  group('McpSseServer HTTP and SSE Transport', () {
    late McpSseServer sseServer;
    late int serverPort;
    late HttpClient httpClient;

    setUp(() async {
      httpClient = HttpClient();
      final stdio = McpStdioServer(workflows: [
        TealKitWorkflow(
          id: 'wf_sse_test',
          name: 'SSE Test Workflow',
          description: 'Tests SSE workflow execution',
          runner: (args) async => 'SSE Workflow Executed',
        ),
      ]);

      sseServer = McpSseServer(
        mcpServer: stdio,
        host: '127.0.0.1',
        port: 0, // OS assigns available ephemeral port
        apiKey: 'secret_mcp_token',
      );
      final http = await sseServer.start();
      serverPort = http.port;
    });

    tearDown(() async {
      httpClient.close(force: true);
      await sseServer.stop();
    });

    test('health endpoint reports service status without auth', () async {
      final req = await httpClient.get('127.0.0.1', serverPort, '/health');
      final resp = await req.close();
      expect(resp.statusCode, HttpStatus.ok);
      final bodyStr = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(bodyStr) as Map<String, dynamic>;
      expect(json['status'], 'healthy');
      expect(json['protocol'], 'mcp-sse');
    });

    test('rejects unauthorized SSE requests when apiKey configured', () async {
      final req = await httpClient.get('127.0.0.1', serverPort, '/sse');
      final resp = await req.close();
      expect(resp.statusCode, HttpStatus.unauthorized);
    });

    test('connects to SSE stream and dispatches JSON-RPC POST messages', () async {
      final sseReq = await httpClient.get('127.0.0.1', serverPort, '/sse');
      sseReq.headers.set('Authorization', 'Bearer secret_mcp_token');
      final sseResp = await sseReq.close();
      expect(sseResp.statusCode, HttpStatus.ok);
      expect(sseResp.headers.contentType?.mimeType, 'text/event-stream');

      final sseCompleter = Completer<String>();
      final postResponseCompleter = Completer<String>();
      String? sessionId;

      final sseSubscription = sseResp
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.startsWith('data: /message?sessionId=')) {
          sessionId = line.substring('data: /message?sessionId='.length).trim();
          if (!sseCompleter.isCompleted) {
            sseCompleter.complete(sessionId);
          }
        } else if (line.startsWith('data: {"jsonrpc"')) {
          final payload = line.substring('data: '.length).trim();
          if (!postResponseCompleter.isCompleted) {
            postResponseCompleter.complete(payload);
          }
        }
      });

      // Wait for initial endpoint event
      final resolvedSessionId = await sseCompleter.future.timeout(const Duration(seconds: 4));
      expect(resolvedSessionId, isNotEmpty);

      // Now send a JSON-RPC tools/list request via POST
      final postReq = await httpClient.post(
        '127.0.0.1',
        serverPort,
        '/message?sessionId=$resolvedSessionId',
      );
      postReq.headers.set('Authorization', 'Bearer secret_mcp_token');
      postReq.headers.contentType = ContentType.json;
      postReq.write(jsonEncode({
        'jsonrpc': '2.0',
        'id': 101,
        'method': 'tools/list',
      }));
      final postResp = await postReq.close();
      expect(postResp.statusCode, HttpStatus.accepted);

      // Verify the response arrived over the SSE stream
      final sseMessage = await postResponseCompleter.future.timeout(const Duration(seconds: 4));
      final decodedResponse = jsonDecode(sseMessage) as Map<String, dynamic>;
      expect(decodedResponse['jsonrpc'], '2.0');
      expect(decodedResponse['id'], 101);
      final tools = decodedResponse['result']['tools'] as List;
      expect(tools.any((t) => t['name'] == 'tealkit_rag_query'), isTrue);
      expect(tools.any((t) => t['name'] == 'wf_sse_test_workflow'), isTrue);

      await sseSubscription.cancel();
    });
  });

  group('CommandRunner MCP registration', () {
    test('buildTealKitCommandRunner includes mcp and mcp-serve', () {
      final runner = buildTealKitCommandRunner();
      final commands = runner.commands.keys.toList();
      expect(commands, contains('mcp'));
      expect(commands, contains('mcp-serve'));

      final mcpSubcommands = runner.commands['mcp']!.subcommands.keys.toList();
      expect(mcpSubcommands, contains('serve'));
      expect(mcpSubcommands, contains('install-claude'));
      expect(mcpSubcommands, contains('config'));
    });
  });
}

