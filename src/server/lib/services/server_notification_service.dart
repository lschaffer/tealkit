import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../database/server_duckdb_service.dart';
import '../models/agentic_task.dart';
import '../runner/server_llm_runner.dart';
import '../runner/server_task_runner.dart';
import '../runner/server_tool_registry.dart';
import '../services/server_data_sources_service.dart';
import '../services/server_email_service.dart';
import '../services/server_llm_settings_service.dart';
import '../utils/server_logger.dart';

/// Complete notification and task chaining handler for the server.
///
/// Orchestrates all post-execution actions:
/// - Email notifications
/// - Slack message
/// - WhatsApp messages
/// - SFTP uploads
/// - Cloud storage uploads (Google Drive, OneDrive)
/// - Task chaining (running subsequent tasks with result injection)
class ServerNotificationService {
  static final ServerNotificationService _instance = ServerNotificationService._();
  factory ServerNotificationService() => _instance;
  ServerNotificationService._();

  final _db = ServerDuckDbService();

  /// Handle all post-task-execution notifications and chaining.
  Future<void> handleTaskCompletion({
    required AgenticTask task,
    required bool success,
    required String resultText,
    required String? errorText,
  }) async {
    log.info('[Notifications] Processing task "${task.name}" completion (success=$success)');

    final previousResult = (task.execution.lastResult ?? '').trim();

    List<File> latestOutputFiles = const [];
    try {
      latestOutputFiles = await _collectLatestRunFiles(task.id);
    } catch (e) {
      log.warning('[Notifications] Failed to collect output files: $e');
    }

    String bodyText = resultText;
    try {
      final outputLogFile = latestOutputFiles.firstWhere((f) => p.basename(f.path) == 'output.log');
      bodyText = await outputLogFile.readAsString();
    } catch (_) {
      // fallback to resultText
    }

    List<File> emailAttachments = const [];
    try {
      emailAttachments = await _prepareEmailAttachments(task: task, files: latestOutputFiles);
    } catch (e) {
      log.warning('[Notifications] Failed to prepare email attachments: $e');
    }

    // 1. Send email if configured
    try {
      await ServerEmailService().sendTaskNotification(
        task: task,
        success: success,
        resultText: bodyText,
        errorText: errorText,
        attachments: emailAttachments,
        previousResult: previousResult,
      );
    } catch (e) {
      log.warning('[Notifications] Email sending failed: $e');
    }

    // 2. Send Slack notification if configured
    try {
      await _sendSlackNotification(
        task: task,
        success: success,
        resultText: bodyText,
        errorText: errorText,
        previousResult: previousResult,
      );
    } catch (e) {
      log.warning('[Notifications] Slack sending failed: $e');
    }

    // 3. Send WhatsApp notification if configured
    try {
      await _sendWhatsAppNotification(
        task: task,
        success: success,
        resultText: bodyText,
        errorText: errorText,
        previousResult: previousResult,
      );
    } catch (e) {
      log.warning('[Notifications] WhatsApp sending failed: $e');
    }

    // 4. Upload output via SFTP if configured
    try {
      await _uploadSftpOutput(task: task, success: success, resultText: bodyText, errorText: errorText);
    } catch (e) {
      log.warning('[Notifications] SFTP upload failed: $e');
    }

    // 5. Process task chaining if configured
    try {
      await _handleTaskChaining(task: task, success: success, resultText: bodyText);
    } catch (e) {
      log.error('[Notifications] Task chaining failed: $e');
    }
  }

  /// Evaluate send condition for a notification.
  bool _shouldSend(String sendCondition, {required bool success, required String resultText, String? previousResult}) {
    switch (sendCondition.toLowerCase().trim()) {
      case 'always':
        return true;
      case 'on_success':
        return success;
      case 'on_failure':
      case 'on_error':
        return !success;
      case 'on_change':
        return (previousResult ?? '').trim() != resultText.trim();
      default:
        return false;
    }
  }

  Future<List<File>> _collectLatestRunFiles(String taskId) async {
    final outputRoot = Directory(p.join(_db.dataDir, 'output', taskId));
    if (!await outputRoot.exists()) return const [];

    final runDirs = await outputRoot.list().where((entity) => entity is Directory).cast<Directory>().toList();
    if (runDirs.isEmpty) return const [];

    runDirs.sort((a, b) => b.path.compareTo(a.path));
    for (final runDir in runDirs) {
      final files = await runDir.list().where((entity) => entity is File).cast<File>().toList();
      if (files.isNotEmpty) return files;
    }

    return const [];
  }

  Future<List<File>> _prepareEmailAttachments({required AgenticTask task, required List<File> files}) async {
    final emailCfg = task.notification.email;
    if (emailCfg == null || files.isEmpty) return const [];

    final filteredFiles = files.where((file) {
      final name = p.basename(file.path);
      if (name == 'output.log') {
        return false;
      }
      if (name == 'execution.log') {
        return task.notification.addExecutionLog;
      }
      if (name.endsWith('_output.log')) {
        return false; // Omit step logs
      }
      final ext = p.extension(file.path).toLowerCase();
      final isAllowed = ext == '.png' || ext == '.jpg' || ext == '.jpeg' || ext == '.gif' || ext == '.webp' || // pictures
                        ext == '.xlsx' || ext == '.xls' || // excel
                        ext == '.html' || ext == '.htm' || // html
                        ext == '.json'; // json
      return isAllowed;
    }).toList();

    if (filteredFiles.isEmpty) return const [];

    if (!task.notification.zipOutputFiles) {
      return filteredFiles;
    }

    final archive = Archive();
    for (final file in filteredFiles) {
      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile(p.basename(file.path), bytes.length, bytes));
    }

    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes.isEmpty) return filteredFiles;

    final taskSlug = task.name.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]+'), '_');
    final zipName = '${taskSlug}_${DateTime.now().millisecondsSinceEpoch}.zip';
    final zipPath = p.join(Directory.systemTemp.path, zipName);
    final zipFile = File(zipPath);
    await zipFile.writeAsBytes(zipBytes, flush: true);
    return [zipFile];
  }

  // ── Slack Notification ──────────────────────────────

  Future<void> _sendSlackNotification({
    required AgenticTask task,
    required bool success,
    required String resultText,
    required String? errorText,
    String? previousResult,
  }) async {
    final notification = task.notification.slack;
    if (notification == null) return;

    if (!_shouldSend(notification.sendCondition, success: success, resultText: resultText, previousResult: previousResult)) {
      log.debug('[Slack] Send condition not met: ${notification.sendCondition}');
      return;
    }

    final ds = ServerDataSourcesService.instance;
    if (!ds.isSlackConfigured) {
      log.debug('[Slack] Slack not configured');
      return;
    }

    final webhook = ds.slackWebhookUrl;
    if (webhook.trim().isEmpty) {
      log.warning('[Slack] Webhook URL not set');
      return;
    }

    try {
      final emoji = success ? '✅' : '❌';
      final status = success ? 'completed' : 'failed';
      final body = success ? resultText : (errorText ?? resultText);
      final truncated = body.length > 2800 ? '${body.substring(0, 2800)}…' : body;

      final message = '$emoji *${task.name}* $status\n\n$truncated';

      final response = await http
          .post(Uri.parse(webhook), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'text': message}))
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200 && response.body == 'ok') {
        log.info('[Slack] Notification sent successfully');
      } else {
        log.warning('[Slack] Webhook returned ${response.statusCode}: ${response.body}');
      }
    } catch (e, st) {
      log.error('[Slack] Notification failed: $e', e, st);
    }
  }

  // ── WhatsApp Notification ───────────────────────────

  Future<void> _sendWhatsAppNotification({
    required AgenticTask task,
    required bool success,
    required String resultText,
    required String? errorText,
    String? previousResult,
  }) async {
    final notification = task.notification.whatsApp;
    if (notification == null) return;

    if (!_shouldSend(notification.sendCondition, success: success, resultText: resultText, previousResult: previousResult)) {
      log.debug('[WhatsApp] Send condition not met: ${notification.sendCondition}');
      return;
    }

    final ds = ServerDataSourcesService.instance;
    if (!ds.isWhatsAppConfigured) {
      log.debug('[WhatsApp] WhatsApp not configured');
      return;
    }

    try {
      final mode = ds.whatsAppMode;

      if (mode == 'callmebot') {
        await _sendWhatsAppViaCallMeBot(
          apiKey: ds.whatsAppCallMeBotApiKey,
          recipient: notification.overrideRecipient?.trim().isNotEmpty == true
              ? notification.overrideRecipient!.trim()
              : ds.whatsAppDefaultRecipient,
          task: task,
          success: success,
          resultText: resultText,
          errorText: errorText,
        );
      } else if (mode == 'meta') {
        await _sendWhatsAppViaMeta(
          phoneNumberId: ds.whatsAppPhoneNumberId,
          accessToken: ds.whatsAppAccessToken,
          recipient: notification.overrideRecipient?.trim().isNotEmpty == true
              ? notification.overrideRecipient!.trim()
              : ds.whatsAppDefaultRecipient,
          task: task,
          success: success,
          resultText: resultText,
          errorText: errorText,
        );
      }
    } catch (e, st) {
      log.error('[WhatsApp] Notification failed: $e', e, st);
    }
  }

  Future<void> _sendWhatsAppViaCallMeBot({
    required String apiKey,
    required String recipient,
    required AgenticTask task,
    required bool success,
    required String resultText,
    required String? errorText,
  }) async {
    if (apiKey.isEmpty || recipient.isEmpty) {
      log.warning('[WhatsApp/CallMeBot] API key or recipient empty');
      return;
    }

    final status = success ? '✅' : '❌';
    final body = success ? resultText : (errorText ?? resultText);
    final truncated = body.length > 1000 ? '${body.substring(0, 1000)}…' : body;
    final message = '$status *${task.name}* $status\n\n$truncated';

    final response = await http
        .get(
          Uri.parse(
            'https://api.callmebot.com/whatsapp.php',
          ).replace(queryParameters: {'phone': recipient, 'text': message, 'apikey': apiKey}),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode == 200) {
      log.info('[WhatsApp/CallMeBot] Message sent successfully');
    } else {
      log.warning('[WhatsApp/CallMeBot] Returned ${response.statusCode}');
    }
  }

  Future<void> _sendWhatsAppViaMeta({
    required String phoneNumberId,
    required String accessToken,
    required String recipient,
    required AgenticTask task,
    required bool success,
    required String resultText,
    required String? errorText,
  }) async {
    if (phoneNumberId.isEmpty || accessToken.isEmpty || recipient.isEmpty) {
      log.warning('[WhatsApp/Meta] Phone ID, token, or recipient empty');
      return;
    }

    try {
      final status = success ? '✅ completed' : '❌ failed';
      final body = success ? resultText : (errorText ?? resultText);
      final truncated = body.length > 1000 ? '${body.substring(0, 1000)}…' : body;
      final message = '*${task.name}* $status\n\n$truncated';

      final response = await http
          .post(
            Uri.parse('https://graph.instagram.com/v18.0/$phoneNumberId/messages'),
            headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
            body: jsonEncode({
              'messaging_product': 'whatsapp',
              'to': recipient,
              'type': 'text',
              'text': {'body': message},
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        log.info('[WhatsApp/Meta] Message sent successfully');
      } else {
        log.warning('[WhatsApp/Meta] Returned ${response.statusCode}: ${response.body}');
      }
    } catch (e, st) {
      log.error('[WhatsApp/Meta] Failed: $e', e, st);
    }
  }

  // ── SFTP Upload ─────────────────────────────────────

  Future<void> _uploadSftpOutput({
    required AgenticTask task,
    required bool success,
    required String resultText,
    required String? errorText,
  }) async {
    final cfg = task.notification.sftpOutput;
    if (cfg == null) return;

    final ds = ServerDataSourcesService.instance;

    final host = cfg.useConfiguredSshServer ? ds.sshHost.trim() : cfg.host.trim();
    final port = cfg.useConfiguredSshServer ? ds.sshPort : cfg.port;
    final username = cfg.useConfiguredSshServer ? ds.sshUsername.trim() : cfg.username.trim();
    final password = cfg.useConfiguredSshServer ? ds.sshPassword : (cfg.password ?? '');
    final privateKeyPem = cfg.useConfiguredSshServer ? ds.sshPrivateKey.trim() : (cfg.privateKey?.trim() ?? '');

    if (host.isEmpty || username.isEmpty) {
      log.warning('[SFTP] Skipping upload for task "${task.name}": host or username is missing');
      return;
    }

    final outputRoot = Directory(p.join(_db.dataDir, 'output', task.id));
    if (!await outputRoot.exists()) {
      log.warning('[SFTP] Skipping upload for task "${task.name}": no local output directory found');
      return;
    }

    final runDirs = await outputRoot.list().where((entity) => entity is Directory).cast<Directory>().toList();
    if (runDirs.isEmpty) {
      log.warning('[SFTP] Skipping upload for task "${task.name}": no execution artifact directory found');
      return;
    }
    runDirs.sort((a, b) => b.path.compareTo(a.path));
    final latestRunDir = runDirs.first;
    final runDirName = latestRunDir.uri.pathSegments.where((segment) => segment.isNotEmpty).last;

    final baseRemoteDir = (cfg.remotePath.trim().isEmpty ? '/' : cfg.remotePath.trim()).replaceAll('\\', '/');
    final remoteDir = baseRemoteDir.endsWith('/') ? '$baseRemoteDir$runDirName' : '$baseRemoteDir/$runDirName';
    final uploadAsZip = task.notification.zipOutputFiles;

    SSHClient? client;
    SftpClient? sftp;
    try {
      final identities = privateKeyPem.isNotEmpty ? SSHKeyPair.fromPem(privateKeyPem) : null;

      client = SSHClient(
        await SSHSocket.connect(host, port),
        username: username,
        identities: identities,
        onPasswordRequest: () => password,
      );
      await client.authenticated;

      // Ensure the per-run target directory exists before upload.
      await _runSshCommand(client, 'mkdir -p ${_shellEscape(remoteDir)}');

      sftp = await client.sftp();

      final localFiles = await latestRunDir.list().where((entity) => entity is File).cast<File>().toList();
      final filteredFiles = localFiles.where((file) {
        final name = p.basename(file.path);
        if (name == 'output.log') {
          return true; // Keep output.log for SFTP output!
        }
        if (name == 'execution.log') {
          return task.notification.addExecutionLog;
        }
        if (name.endsWith('_output.log')) {
          return false; // Omit step logs
        }
        final ext = p.extension(file.path).toLowerCase();
        final isAllowed = ext == '.png' || ext == '.jpg' || ext == '.jpeg' || ext == '.gif' || ext == '.webp' || // pictures
                          ext == '.xlsx' || ext == '.xls' || // excel
                          ext == '.html' || ext == '.htm' || // html
                          ext == '.json'; // json
        return isAllowed;
      }).toList();

      if (filteredFiles.isEmpty) {
        log.warning('[SFTP] Skipping upload for task "${task.name}": latest execution produced no files');
        return;
      }

      if (uploadAsZip) {
        final archive = Archive();
        for (final localFile in filteredFiles) {
          final fileName = p.basename(localFile.path);
          final bytes = await localFile.readAsBytes();
          archive.addFile(ArchiveFile(fileName, bytes.length, bytes));
        }
        final zipped = ZipEncoder().encode(archive);
        final remoteZipPath = remoteDir.endsWith('/') ? '${remoteDir}output.zip' : '$remoteDir/output.zip';
        final zipFile = await sftp.open(remoteZipPath, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
        await zipFile.writeBytes(Uint8List.fromList(zipped));
        await zipFile.close();
        log.info('[SFTP] Uploaded zipped output for task "${task.name}" to $host:$remoteZipPath');
      } else {
        for (final localFile in filteredFiles) {
          final fileName = p.basename(localFile.path);
          final remotePath = remoteDir.endsWith('/') ? '$remoteDir$fileName' : '$remoteDir/$fileName';
          final bytes = await localFile.readAsBytes();
          final file = await sftp.open(remotePath, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
          await file.writeBytes(bytes);
          await file.close();
        }
        log.info('[SFTP] Uploaded ${filteredFiles.length} output file(s) for task "${task.name}" to $host:$remoteDir');
      }
    } finally {
      try {
        sftp?.close();
      } catch (_) {}
      try {
        client?.close();
      } catch (_) {}
    }
  }

  Future<void> _runSshCommand(SSHClient client, String command) async {
    final session = await client.execute(command);
    await session.stdout.drain<void>();
    await session.stderr.drain<void>();
  }

  static String _shellEscape(String s) => "'${s.replaceAll("'", "'\\''")}'";

  // ── Task Chaining ───────────────────────────────────

  Future<void> _handleTaskChaining({required AgenticTask task, required bool success, required String resultText}) async {
    final chainConfig = task.chainConfig;
    if (chainConfig == null) {
      return;
    }

    log.info('[Chaining] Evaluating chain conditions for "${task.name}"');

    // Determine which chain to follow.
    // TaskChainConfig on the server supports triggerCondition +
    // onMatchTaskId/onNoMatchTaskId.
    String? targetTaskId;

    if (chainConfig.triggerCondition != null && chainConfig.triggerCondition!.trim().isNotEmpty) {
      // Evaluate condition when configured and route to onMatch/onNoMatch.
      try {
        final shouldMatch = await _evaluateCondition(condition: chainConfig.triggerCondition!, taskResult: resultText, parentTask: task);
        if (shouldMatch) {
          targetTaskId = chainConfig.onMatchTaskId;
          log.info('[Chaining] Condition matched, following chain to $targetTaskId');
        } else {
          targetTaskId = chainConfig.onNoMatchTaskId;
          log.info('[Chaining] Condition not matched, following chain to $targetTaskId');
        }
      } catch (e) {
        log.warning('[Chaining] Condition evaluation failed: $e');
      }
    } else {
      // No condition: default to onMatchTaskId as the direct chain target.
      targetTaskId = chainConfig.onMatchTaskId;
    }

    if (targetTaskId == null || targetTaskId.trim().isEmpty) {
      log.debug('[Chaining] No chain target configured or condition not met');
      return;
    }

    // Get the chained task
    try {
      final chainedTask = await _db.getTask(targetTaskId);
      if (chainedTask == null) {
        log.warning('[Chaining] Target task not found: $targetTaskId');
        return;
      }

      // Inject parent result into the chained task's prompt
      final injectedPrompt = chainedTask.prompt
          .replaceAll(r'${task_result}', resultText.trim())
          .replaceAll('[task_result]', resultText.trim())
          .replaceAll(r'$(task_result)', resultText.trim())
          .replaceAll(r'${task_output}', resultText.trim())
          .replaceAll('[task_output]', resultText.trim())
          .replaceAll(r'$(task_output)', resultText.trim())
          .replaceAll(r'${tool_result}', resultText.trim())
          .replaceAll('[tool_result]', resultText.trim())
          .replaceAll(r'$(tool_result)', resultText.trim())
          .replaceAll(r'${tool_output}', resultText.trim())
          .replaceAll('[tool_output]', resultText.trim())
          .replaceAll(r'$(tool_output)', resultText.trim());
      final taskToRun = chainedTask.copyWith(prompt: injectedPrompt);

      log.info('[Chaining] Running chained task "${chainedTask.name}" (id=$targetTaskId)');

      // FIXED: Actually execute the chained task instead of just queuing it.
      // This matches the local mode behavior where TaskRunnerService().run(taskToRun) is called recursively.
      try {
        final llmSettings = ServerLlmSettingsService.instance;
        final runner = ServerTaskRunner(db: _db, llmSettings: llmSettings);
        final chainedResult = await runner.runTask(taskToRun);

        if (chainedResult.success) {
          log.info('[Chaining] Chained task "${chainedTask.name}" completed successfully');
        } else {
          log.warning('[Chaining] Chained task "${chainedTask.name}" completed with error: ${chainedResult.error}');
        }
      } catch (e, st) {
        log.error('[Chaining] Failed to execute chained task: $e', e, st);
      }
    } catch (e, st) {
      log.error('[Chaining] Failed: $e', e, st);
    }
  }

  Future<bool> _evaluateCondition({required String condition, required String taskResult, required AgenticTask parentTask}) async {
    // Improved condition evaluator: use LLM for natural language conditions (like local mode)
    // Falls back to string matching if LLM evaluation fails

    try {
      final llmSettings = ServerLlmSettingsService.instance;
      final runner = ServerLlmRunner(llmSettings);
      final emptyRegistry = ServerToolRegistry(_db);

      // Ask the LLM whether the condition is satisfied.
      final evaluationPrompt =
          'Analyze the following Task Result and check if the given Condition is met.\n'
          'Provide a brief one-line reasoning (perform any math/checks step-by-step), and then conclude with exactly "RESULT: TRUE" or "RESULT: FALSE".\n\n'
          'Condition: $condition\n\n'
          'Task Result:\n$taskResult\n\n'
          'Format:\n'
          'Reasoning: <brief reasoning>\n'
          'RESULT: <TRUE or FALSE>';

      final result = await runner.run(
        systemPrompt: 'You are a strict logic evaluator. Reply with step-by-step reasoning first, then conclude with RESULT: TRUE or RESULT: FALSE.',
        userPrompt: evaluationPrompt,
        registry: emptyRegistry,
      );

      if (result.success && result.content.isNotEmpty) {
        final responseText = result.content.trim();

        // 1. Look for explicit RESULT: TRUE/FALSE (from CoT prompt format)
        final explicitMatch = RegExp(
          r'RESULT:\s*(TRUE|FALSE)',
          caseSensitive: false,
        ).firstMatch(responseText);

        if (explicitMatch != null) {
          return explicitMatch.group(1)!.toUpperCase() == 'TRUE';
        }

        // 2. Look for JSON output if model outputted JSON
        if (responseText.contains('"result"')) {
          final jsonMatch = RegExp(
            r'"result"\s*:\s*(true|false)',
            caseSensitive: false,
          ).firstMatch(responseText);
          if (jsonMatch != null) {
            return jsonMatch.group(1)!.toLowerCase() == 'true';
          }
        }

        // 3. Fallback: check the last non-empty line
        final lines = responseText
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .toList();
        if (lines.isNotEmpty) {
          final lastLine = lines.last.toLowerCase();
          if (lastLine.contains('true') && !lastLine.contains('false')) {
            return true;
          }
          if (lastLine.contains('false') && !lastLine.contains('true')) {
            return false;
          }
        }

        // 4. Default legacy fallback: match first true/false word token
        final firstToken = RegExp(
          r'\b(true|false)\b',
          caseSensitive: false,
        ).firstMatch(responseText.toLowerCase())?.group(1)?.toLowerCase();
        if (firstToken != null) {
          return firstToken == 'true';
        }
      }
    } catch (e) {
      log.warning('[Chaining] LLM condition evaluation failed, falling back to pattern matching: $e');
    }

    // ── Fallback: Simple pattern matching ──
    final lower = condition.toLowerCase();
    final result = taskResult.toLowerCase();

    // Match common patterns
    if (lower.contains('contains') || lower.contains('includes')) {
      // Extract the keyword to search for
      final pattern = RegExp(r'''contains.*?["']([^"']+)["']''', caseSensitive: false);
      final match = pattern.firstMatch(condition);
      if (match != null) {
        final keyword = match.group(1)?.toLowerCase() ?? '';
        return result.contains(keyword);
      }
    }

    if (lower.contains('success') || lower.contains('successful')) {
      return !result.contains('error') && !result.contains('failed');
    }

    if (lower.contains('error') || lower.contains('fail')) {
      return result.contains('error') || result.contains('failed');
    }

    // Unknown expression format in fallback path: fail closed.
    return false;
  }

  /// Deliver subagent-specific notification if defined.
  Future<void> deliverExecutorNotification({
    required String taskId,
    required String executorName,
    required TaskNotification notification,
    required bool success,
    required String resultText,
    required String? errorText,
  }) async {
    log.info('[Notifications] Delivering executor notification for "$executorName" in task "$taskId"');
    
    final dummyTask = AgenticTask(
      id: taskId,
      name: executorName,
      notification: notification,
      executionPlan: const ExecutionPlan(cronExpression: ''),
    );

    // Call the respective notifications based on the subagent's settings!
    // 1. Email
    if (notification.email != null) {
      try {
        final latestOutputFiles = await _collectLatestRunFiles(taskId);
        final emailAttachments = await _prepareEmailAttachments(task: dummyTask, files: latestOutputFiles);
        
        await ServerEmailService().sendTaskNotification(
          task: dummyTask,
          success: success,
          resultText: resultText,
          errorText: errorText,
          attachments: emailAttachments,
          previousResult: '',
        );
      } catch (e) {
        log.warning('[Notifications] Executor Email delivery failed: $e');
      }
    }

    // 2. Slack
    if (notification.slack != null) {
      try {
        await _sendSlackNotification(
          task: dummyTask,
          success: success,
          resultText: resultText,
          errorText: errorText,
          previousResult: '',
        );
      } catch (e) {
        log.warning('[Notifications] Executor Slack delivery failed: $e');
      }
    }

    // 3. WhatsApp
    if (notification.whatsApp != null) {
      try {
        await _sendWhatsAppNotification(
          task: dummyTask,
          success: success,
          resultText: resultText,
          errorText: errorText,
          previousResult: '',
        );
      } catch (e) {
        log.warning('[Notifications] Executor WhatsApp delivery failed: $e');
      }
    }

    // 4. SFTP
    if (notification.sftpOutput != null) {
      try {
        await _uploadSftpOutput(
          task: dummyTask,
          success: success,
          resultText: resultText,
          errorText: errorText,
        );
      } catch (e) {
        log.warning('[Notifications] Executor SFTP delivery failed: $e');
      }
    }
  }
}
