import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

import '../models/workflow_task.dart';
import '../models/mcp_models.dart';
import 'app_logger.dart';
import 'data_sources_settings_service.dart';
import 'llm_service.dart';

class EmailDeliveryOutcome {
  final bool attempted;
  final bool sent;
  final String? message;

  const EmailDeliveryOutcome({required this.attempted, required this.sent, this.message});

  const EmailDeliveryOutcome.skipped([String? reason]) : attempted = false, sent = false, message = reason;

  const EmailDeliveryOutcome.success([String? info]) : attempted = true, sent = true, message = info;

  const EmailDeliveryOutcome.failed([String? error]) : attempted = true, sent = false, message = error;
}

class EmailAttachmentPayload {
  final String fileName;
  final String mimeType;
  final Uint8List bytes;

  const EmailAttachmentPayload({required this.fileName, required this.mimeType, required this.bytes});
}

class EmailDeliveryService {
  static const String _gmailSendEndpoint = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send';

  Future<EmailDeliveryOutcome> sendTestEmail({required String recipient, String? subject, String? body, String via = 'gmail'}) async {
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) {
      await ds.load();
    }

    if (recipient.trim().isEmpty) {
      return const EmailDeliveryOutcome.failed('Recipient email is required.');
    }

    final emailSubject = subject?.trim().isNotEmpty == true ? subject!.trim() : 'Test Email from Mobile AI Agent';
    final emailBody = body?.trim().isNotEmpty == true
        ? body!.trim()
        : 'This is a test email sent at ${DateTime.now().toIso8601String()} by Mobile AI Agent.';

    // ── Route: IMAP/SMTP ──
    if (via == 'imap') {
      return _sendViaSmtp(
        smtpHost: ds.smtpHost,
        smtpPort: ds.smtpPort,
        username: ds.imapUsername,
        password: ds.imapPassword,
        useSsl: ds.imapUseSsl,
        from: ds.smtpSender,
        recipients: [recipient.trim()],
        subject: emailSubject,
        bodyText: emailBody,
      );
    }

    // ── Route: Gmail OAuth API ──
    final hasAnyClientId = ds.gmailClientId.trim().isNotEmpty;
    if (!hasAnyClientId) {
      return const EmailDeliveryOutcome.failed('Gmail OAuth client ID is missing. Provide it via settings or --dart-define.');
    }

    if (ds.gmailRefreshToken.trim().isEmpty && ds.gmailAccessToken.trim().isEmpty) {
      return const EmailDeliveryOutcome.failed('OAuth token not connected. Authorize Gmail first.');
    }

    final task = WorkflowTask(
      id: 'email-test-${DateTime.now().millisecondsSinceEpoch}',
      name: 'Email Delivery Test',
      prompt: '',
      executionPlan: const ExecutionPlan(cronExpression: '0 0 * * *'),
      providers: TaskProviders(
        email: EmailProviderConfig(
          type: 'google',
          authData: EmailAuthData(
            data: {
              'client_id': ds.gmailClientId,
              'client_secret': ds.gmailClientSecret,
              'access_token': ds.gmailAccessToken,
              'refresh_token': ds.gmailRefreshToken,
              if (ds.gmailTokenExpiry != null) 'expires_at': ds.gmailTokenExpiry!.toIso8601String(),
              if (ds.gmailAccountEmail.isNotEmpty) 'email': ds.gmailAccountEmail,
            },
          ),
        ),
      ),
      notification: TaskNotification(
        email: EmailNotification(recipients: [recipient.trim()], subject: emailSubject, sendCondition: 'always'),
      ),
    );

    return sendTaskResult(task: task, taskSuccess: true, resultText: emailBody, errorText: null);
  }

  Future<EmailDeliveryOutcome> sendTaskResult({
    required WorkflowTask task,
    required bool taskSuccess,
    String? resultText,
    String? errorText,
    List<EmailAttachmentPayload> attachments = const [],
  }) async {
    final notification = task.notification.email;
    if (notification == null || notification.recipients.isEmpty) {
      return const EmailDeliveryOutcome.skipped('No email notification configured.');
    }

    final shouldSend = await _shouldSend(notification, taskSuccess: taskSuccess, resultText: resultText, task: task);
    if (!shouldSend) {
      return const EmailDeliveryOutcome.skipped('Send condition not met.');
    }

    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) await ds.load();

    final subject = _buildEmailSubject(notification, task);
    final sanitizedResultText = resultText != null ? _sanitizeHtmlForEmailBody(resultText) : null;
    final bodyText = _buildEmailBody(task, taskSuccess, sanitizedResultText, errorText);
    final errors = StringBuffer();

    // ─── Priority 1: Global SMTP (always tried first when configured) ────────
    if (ds.smtpHost.trim().isNotEmpty) {
      final smtpOutcome = await _sendViaSmtp(
        smtpHost: ds.smtpHost,
        smtpPort: ds.smtpPort,
        username: ds.imapUsername,
        password: ds.imapPassword,
        useSsl: ds.imapUseSsl,
        from: ds.smtpSender.isNotEmpty ? ds.smtpSender : ds.imapUsername,
        recipients: notification.recipients,
        subject: subject,
        bodyText: bodyText,
        attachments: attachments,
      );
      if (smtpOutcome.sent) return smtpOutcome;
      errors.writeln('[SMTP] ${smtpOutcome.message ?? "Unknown SMTP error"}');
      log.warning('[EmailDelivery] SMTP failed: ${smtpOutcome.message} — trying Gmail OAuth fallback');
    }

    // ─── Priority 2: Gmail OAuth (per-task provider or global settings) ──────
    final provider = task.providers.email;
    final providerType = provider?.type.trim().toLowerCase() ?? '';

    // Build an effective Gmail provider: prefer per-task config, fall back to global DS tokens
    final EmailProviderConfig effectiveGmailProvider;
    if (providerType == 'google' || providerType == 'gmail') {
      effectiveGmailProvider = provider!;
    } else {
      effectiveGmailProvider = _buildGlobalGmailProvider(ds);
    }

    final hasGmailTokens =
        effectiveGmailProvider.authData.accessToken?.trim().isNotEmpty == true ||
        effectiveGmailProvider.authData.refreshToken?.trim().isNotEmpty == true;

    if (hasGmailTokens) {
      final gmailOutcome = await _sendViaGmailApi(
        task: task,
        notification: notification,
        provider: effectiveGmailProvider,
        taskSuccess: taskSuccess,
        resultText: resultText,
        errorText: errorText,
        attachments: attachments,
      );
      if (gmailOutcome.sent) return gmailOutcome;
      errors.writeln('[Gmail] ${gmailOutcome.message ?? "Unknown Gmail error"}');
    }

    // ─── Fallback: explicit per-task IMAP/SMTP provider ───────────────────────
    if (providerType == 'imap' || providerType == 'smtp') {
      final auth = provider!.authData;
      final username = (auth.data['username'] as String?)?.trim().isNotEmpty == true
          ? (auth.data['username'] as String).trim()
          : ds.imapUsername;
      final password = (auth.data['password'] as String?)?.trim().isNotEmpty == true
          ? (auth.data['password'] as String).trim()
          : ds.imapPassword;
      final smtpOutcome = await _sendViaSmtp(
        smtpHost: ds.smtpHost,
        smtpPort: ds.smtpPort,
        username: username,
        password: password,
        useSsl: ds.imapUseSsl,
        from: ds.smtpSender,
        recipients: notification.recipients,
        subject: subject,
        bodyText: bodyText,
        attachments: attachments,
      );
      if (smtpOutcome.sent) return smtpOutcome;
      errors.writeln('[IMAP/SMTP] ${smtpOutcome.message ?? "Unknown error"}');
    }

    final errStr = errors.toString().trim();
    if (errStr.isNotEmpty) return EmailDeliveryOutcome.failed(errStr);
    return const EmailDeliveryOutcome.failed('No email delivery method configured. Add SMTP or Gmail OAuth in Data Sources settings.');
  }

  Future<EmailDeliveryOutcome> sendExecutorResult({
    required WorkflowTask task,
    required Agent executor,
    required bool taskSuccess,
    String? resultText,
    String? errorText,
    List<EmailAttachmentPayload> attachments = const [],
  }) async {
    final notification = executor.notification.email;
    if (notification == null || notification.recipients.isEmpty) {
      return const EmailDeliveryOutcome.skipped('No email notification configured.');
    }

    final shouldSend = await _shouldSend(notification, taskSuccess: taskSuccess, resultText: resultText, task: task);
    if (!shouldSend) {
      return const EmailDeliveryOutcome.skipped('Send condition not met.');
    }

    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) await ds.load();

    final subject = notification.subject?.trim().isNotEmpty == true
        ? notification.subject!.trim()
        : 'Agent [${executor.name}] run details for: ${task.name}';
    final sanitizedResultText = resultText != null ? _sanitizeHtmlForEmailBody(resultText) : null;
    final bodyText = _buildEmailBody(task, taskSuccess, sanitizedResultText, errorText);
    final errors = StringBuffer();

    // ─── Priority 1: Global SMTP ────────────────────────
    if (ds.smtpHost.trim().isNotEmpty) {
      final smtpOutcome = await _sendViaSmtp(
        smtpHost: ds.smtpHost,
        smtpPort: ds.smtpPort,
        username: ds.imapUsername,
        password: ds.imapPassword,
        useSsl: ds.imapUseSsl,
        from: ds.smtpSender.isNotEmpty ? ds.smtpSender : ds.imapUsername,
        recipients: notification.recipients,
        subject: subject,
        bodyText: bodyText,
        attachments: attachments,
      );
      if (smtpOutcome.sent) return smtpOutcome;
      errors.writeln('[SMTP] ${smtpOutcome.message ?? "Unknown SMTP error"}');
    }

    // ─── Priority 2: Gmail OAuth ────────────────────────
    final provider = task.providers.email;
    final providerType = provider?.type.trim().toLowerCase() ?? '';
    final EmailProviderConfig effectiveGmailProvider;
    if (providerType == 'google' || providerType == 'gmail') {
      effectiveGmailProvider = provider!;
    } else {
      effectiveGmailProvider = _buildGlobalGmailProvider(ds);
    }

    final hasGmailTokens =
        effectiveGmailProvider.authData.accessToken?.trim().isNotEmpty == true ||
        effectiveGmailProvider.authData.refreshToken?.trim().isNotEmpty == true;

    if (hasGmailTokens) {
      final gmailOutcome = await _sendViaGmailApi(
        task: task,
        notification: notification,
        provider: effectiveGmailProvider,
        taskSuccess: taskSuccess,
        resultText: resultText,
        errorText: errorText,
        attachments: attachments,
      );
      if (gmailOutcome.sent) return gmailOutcome;
      errors.writeln('[Gmail] ${gmailOutcome.message ?? "Unknown Gmail API error"}');
    }

    // ─── Fallback: explicit per-task IMAP/SMTP provider ───────────────────────
    if (providerType == 'imap' || providerType == 'smtp') {
      final auth = provider!.authData;
      final username = (auth.data['username'] as String?)?.trim().isNotEmpty == true
          ? (auth.data['username'] as String).trim()
          : ds.imapUsername;
      final password = (auth.data['password'] as String?)?.trim().isNotEmpty == true
          ? (auth.data['password'] as String).trim()
          : ds.imapPassword;
      final smtpOutcome = await _sendViaSmtp(
        smtpHost: ds.smtpHost,
        smtpPort: ds.smtpPort,
        username: username,
        password: password,
        useSsl: ds.imapUseSsl,
        from: ds.smtpSender,
        recipients: notification.recipients,
        subject: subject,
        bodyText: bodyText,
        attachments: attachments,
      );
      if (smtpOutcome.sent) return smtpOutcome;
      errors.writeln('[IMAP/SMTP] ${smtpOutcome.message ?? "Unknown error"}');
    }

    final errStr = errors.toString().trim();
    if (errStr.isNotEmpty) return EmailDeliveryOutcome.failed(errStr);
    return const EmailDeliveryOutcome.failed('No email delivery method configured. Add SMTP or Gmail OAuth in Data Sources settings.');
  }

  /// Builds the email subject from the notification config.
  String _buildEmailSubject(EmailNotification notification, WorkflowTask task) {
    return (notification.subject?.trim().isNotEmpty ?? false)
        ? notification.subject!.trim().replaceAll('[task_name]', task.name)
        : 'Task Result: ${task.name}';
  }

  /// Builds the plain-text email body.
  String _buildEmailBody(WorkflowTask task, bool taskSuccess, String? resultText, String? errorText) {
    final buf = StringBuffer()
      ..writeln('Task: ${task.name}')
      ..writeln('Status: ${taskSuccess ? 'Success' : 'Failure'}')
      ..writeln('Time: ${DateTime.now().toIso8601String()}')
      ..writeln();
    if (taskSuccess && (resultText?.trim().isNotEmpty ?? false)) {
      buf
        ..writeln('Result:')
        ..writeln(resultText!.trim());
    } else if (!taskSuccess && (errorText?.trim().isNotEmpty ?? false)) {
      buf
        ..writeln('Error:')
        ..writeln(errorText!.trim());
    } else if (resultText?.trim().isNotEmpty ?? false) {
      buf.writeln(resultText!.trim());
    }
    return buf.toString();
  }

  String _sanitizeHtmlForEmailBody(String text) {
    var sanitized = text;

    // 1. Replace ```html\n...\n``` code fences
    final fenceRegex = RegExp(
      r'```html\s*\n[\s\S]*?\n?```',
      caseSensitive: false,
    );
    if (fenceRegex.hasMatch(sanitized)) {
      sanitized = sanitized.replaceAll(fenceRegex, '[HTML Content Omitted - See Attachment]');
    }

    // 2. Replace raw HTML blocks starting with <!DOCTYPE html> or <html... to </html>
    final rawHtmlRegex = RegExp(
      r'(?:<!doctype\s+html[^>]*>\s*)?<html[\s\S]*?</html>',
      caseSensitive: false,
    );
    if (rawHtmlRegex.hasMatch(sanitized)) {
      sanitized = sanitized.replaceAll(rawHtmlRegex, '[HTML Content Omitted - See Attachment]');
    }

    // 3. Replace typical tag blocks like <table...</table>, <div...</div>, <ol...</ol>, <ul...</ul>
    final tagBlocksRegex = RegExp(
      r'<(table|div|ol|ul|body|html)[^>]*>[\s\S]*?</\1>',
      caseSensitive: false,
    );
    if (tagBlocksRegex.hasMatch(sanitized)) {
      sanitized = sanitized.replaceAll(tagBlocksRegex, '[HTML Content Omitted - See Attachment]');
    }

    return sanitized;
  }

  /// Builds a temporary Gmail [EmailProviderConfig] from global DataSourcesSettings,
  /// used as a fallback when the task has no per-task email provider.
  EmailProviderConfig _buildGlobalGmailProvider(DataSourcesSettingsService ds) {
    return EmailProviderConfig(
      type: 'google',
      authData: EmailAuthData(
        data: {
          'client_id': ds.gmailClientId,
          'client_secret': ds.gmailClientSecret,
          'access_token': ds.gmailAccessToken,
          'refresh_token': ds.gmailRefreshToken,
          if (ds.gmailTokenExpiry != null) 'expires_at': ds.gmailTokenExpiry!.toIso8601String(),
          if (ds.gmailAccountEmail.isNotEmpty) 'email': ds.gmailAccountEmail,
        },
      ),
    );
  }

  Future<bool> _shouldSend(
    EmailNotification notification, {
    required bool taskSuccess,
    required String? resultText,
    required WorkflowTask task,
  }) async {
    final normalized = notification.sendCondition.trim().toLowerCase();
    switch (normalized) {
      case 'always':
        return true;
      case 'on_success':
        return taskSuccess;
      case 'on_failure':
      case 'on_error':
        return !taskSuccess;
      case 'on_change':
        final previous = (task.execution.lastResult ?? '').trim();
        final current = (resultText ?? '').trim();
        return previous != current;
      case 'conditional':
        final expr = (notification.conditionExpression ?? '').trim();
        if (expr.isEmpty) return false;
        return await _evaluateCustomCondition(expr, resultText ?? '');
      default:
        return false;
    }
  }

  Future<bool> _evaluateCustomCondition(String expression, String resultText) async {
    try {
      final llmService = LLMService();
      await llmService.loadSavedProviderAndModel();

      if (!llmService.isConfigured) {
        log.warning('[EmailDelivery] Conditional evaluation skipped: no LLM configured (verdict=FALSE)');
        return false;
      }

      final prompt =
          'Check this condition against the task output.\n'
          'Return ONLY TRUE if it matches, otherwise ONLY FALSE.\n\n'
          'Condition: $expression\n\n'
          'Task output:\n$resultText';

      final res = await llmService.generateChatCompletion(
        messages: [
          ChatMessage(
            id: 'cond-system',
            content: 'You are a strict condition evaluator. Reply with ONLY TRUE or ONLY FALSE.',
            role: ChatRole.system,
            timestamp: DateTime.now(),
          ),
          ChatMessage(id: 'cond-user', content: prompt, role: ChatRole.user, timestamp: DateTime.now()),
        ],
        availableTools: null,
        forceNoToolCalls: true,
      );

      final ans = res.content.trim().toLowerCase();
      final firstToken = RegExp(r'\b(true|false)\b', caseSensitive: false).firstMatch(ans)?.group(1)?.toLowerCase();
      if (firstToken == null) {
        log.warning('[EmailDelivery] Conditional evaluation returned non-boolean response: ${res.content}');
        return false;
      }

      final matched = firstToken == 'true';
      log.info('[EmailDelivery] Condition verdict=$firstToken send=$matched expr="$expression"');
      log.info('[EmailDelivery] Conditional evaluation: "$expression" => $firstToken (send=$matched)');
      return matched;
    } catch (e) {
      log.warning('[EmailDelivery] Conditional evaluation failed: $e');
      return false;
    }
  }

  Future<EmailDeliveryOutcome> _sendViaGmailApi({
    required WorkflowTask task,
    required EmailNotification notification,
    required EmailProviderConfig provider,
    required bool taskSuccess,
    required String? resultText,
    required String? errorText,
    required List<EmailAttachmentPayload> attachments,
  }) async {
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) {
      await ds.load();
    }

    final auth = provider.authData;
    final clientId = (auth.data['client_id'] as String?)?.trim().isNotEmpty == true
        ? (auth.data['client_id'] as String).trim()
        : ds.gmailClientId;
    final clientSecret = (auth.data['client_secret'] as String?)?.trim().isNotEmpty == true
        ? (auth.data['client_secret'] as String).trim()
        : ds.gmailClientSecret;
    var accessToken = auth.accessToken?.trim();
    var refreshToken = auth.refreshToken?.trim();
    DateTime? expiresAt = auth.expiresAt;

    final dsAccessToken = ds.gmailAccessToken.trim();
    final dsRefreshToken = ds.gmailRefreshToken.trim();

    if (dsAccessToken.isNotEmpty) {
      accessToken = dsAccessToken;
    } else if (accessToken == null || accessToken.isEmpty) {
      accessToken = dsAccessToken;
    }

    if (dsRefreshToken.isNotEmpty) {
      refreshToken = dsRefreshToken;
    } else if (refreshToken == null || refreshToken.isEmpty) {
      refreshToken = dsRefreshToken;
    }

    expiresAt = ds.gmailTokenExpiry ?? expiresAt;

    // If no OAuth tokens are configured at all, skip delivery gracefully
    // instead of showing a hard failure. The user likely hasn't authorized
    // Gmail yet — this is a config issue, not a task execution error.
    if (accessToken.isEmpty && refreshToken.isEmpty) {
      return const EmailDeliveryOutcome.skipped(
        'Gmail OAuth not configured. Authorize Gmail in Settings → Data Sources → Email to enable delivery.',
      );
    }

    final tokenOutcome = await _ensureValidAccessToken(
      clientId: clientId,
      clientSecret: clientSecret,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      ds: ds,
    );

    if (!tokenOutcome.success || tokenOutcome.accessToken == null || tokenOutcome.accessToken!.isEmpty) {
      return EmailDeliveryOutcome.failed(tokenOutcome.error ?? 'Missing Gmail OAuth access token.');
    }

    accessToken = tokenOutcome.accessToken;
    refreshToken = tokenOutcome.refreshToken ?? refreshToken;

    final subject = (notification.subject?.trim().isNotEmpty ?? false)
        ? notification.subject!.trim().replaceAll('[task_name]', task.name)
        : 'Task Result: ${task.name}';

    final senderFallback = DataSourcesSettingsService.instance.imapUsername.trim();
    final fromAddress = (provider.authData.email?.trim().isNotEmpty ?? false)
        ? provider.authData.email!.trim()
        : (senderFallback.isNotEmpty ? senderFallback : null);

    final bodyBuffer = StringBuffer()
      ..writeln('Task: ${task.name}')
      ..writeln('Status: ${taskSuccess ? 'Success' : 'Failure'}')
      ..writeln('Time: ${DateTime.now().toIso8601String()}')
      ..writeln();

    if (taskSuccess && (resultText?.trim().isNotEmpty ?? false)) {
      bodyBuffer.writeln('Result:');
      bodyBuffer.writeln(resultText!.trim());
    } else if (!taskSuccess && (errorText?.trim().isNotEmpty ?? false)) {
      bodyBuffer.writeln('Error:');
      bodyBuffer.writeln(errorText!.trim());
    } else if ((resultText?.trim().isNotEmpty ?? false)) {
      bodyBuffer.writeln(resultText!.trim());
    }

    final mimeMessage = _buildGmailMimeMessage(
      fromAddress: fromAddress,
      recipients: notification.recipients,
      subject: subject,
      bodyText: bodyBuffer.toString(),
      attachments: attachments,
    );
    final raw = base64Url.encode(utf8.encode(mimeMessage));

    try {
      var response = await http.post(
        Uri.parse(_gmailSendEndpoint),
        headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: jsonEncode({'raw': raw}),
      );

      if (response.statusCode == 401 && refreshToken.isNotEmpty) {
        final refreshed = await _refreshAccessToken(clientId: clientId, clientSecret: clientSecret, refreshToken: refreshToken, ds: ds);
        if (refreshed.success && refreshed.accessToken != null && refreshed.accessToken!.isNotEmpty) {
          accessToken = refreshed.accessToken;
          response = await http.post(
            Uri.parse(_gmailSendEndpoint),
            headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({'raw': raw}),
          );
        }
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const EmailDeliveryOutcome.success('Email sent via Gmail API.');
      }

      final parsed = response.body.isNotEmpty ? jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic> : <String, dynamic>{};
      final err = parsed['error'];
      log.warning('[EmailDelivery] Gmail send failed ${response.statusCode}: $err');
      return EmailDeliveryOutcome.failed('Gmail send failed (${response.statusCode}): ${err ?? response.reasonPhrase}');
    } catch (e) {
      log.error('[EmailDelivery] Gmail send exception: $e');
      return EmailDeliveryOutcome.failed('Email delivery failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════
  // SMTP Sending (for IMAP/SMTP provider)
  // ═══════════════════════════════════════════════════

  Future<EmailDeliveryOutcome> _sendViaSmtp({
    required String smtpHost,
    required int smtpPort,
    required String username,
    required String password,
    required bool useSsl,
    required String from,
    required List<String> recipients,
    required String subject,
    required String bodyText,
    List<EmailAttachmentPayload> attachments = const [],
  }) async {
    if (smtpHost.trim().isEmpty) {
      return const EmailDeliveryOutcome.failed('SMTP host is not configured. Set it in Data Sources → IMAP (Send) settings.');
    }
    if (username.trim().isEmpty || password.trim().isEmpty) {
      return const EmailDeliveryOutcome.failed('SMTP username or password is missing.');
    }

    try {
      // Build the SmtpServer configuration
      final SmtpServer server;
      if (useSsl && smtpPort == 465) {
        // Direct SSL (port 465)
        server = SmtpServer(
          smtpHost.trim(),
          port: smtpPort,
          ssl: true,
          allowInsecure: false,
          username: username.trim(),
          password: password.trim(),
        );
      } else {
        // STARTTLS (port 587 typical) or plain
        server = SmtpServer(
          smtpHost.trim(),
          port: smtpPort,
          ssl: false,
          allowInsecure: smtpPort != 587, // allow plain for non-standard ports
          username: username.trim(),
          password: password.trim(),
        );
      }

      final message = Message()
        ..from = Address(from.trim())
        ..recipients.addAll(recipients.map((r) => r.trim()))
        ..subject = subject
        ..text = bodyText;

      final tempFiles = <File>[];
      try {
        for (final attachment in attachments) {
          final tempFile = File('${Directory.systemTemp.path}/${DateTime.now().microsecondsSinceEpoch}_${attachment.fileName}');
          await tempFile.writeAsBytes(attachment.bytes, flush: true);
          tempFiles.add(tempFile);
          message.attachments.add(FileAttachment(tempFile, fileName: attachment.fileName));
        }

        final sendReport = await send(message, server);
        log.info('[EmailDelivery] SMTP send success: $sendReport');
        return const EmailDeliveryOutcome.success('Email sent via SMTP.');
      } finally {
        for (final file in tempFiles) {
          try {
            if (await file.exists()) {
              await file.delete();
            }
          } catch (_) {}
        }
      }
    } on MailerException catch (e) {
      log.error('[EmailDelivery] SMTP send failed: ${e.message}');
      final problems = e.problems.map((p) => '${p.code}: ${p.msg}').join('; ');
      return EmailDeliveryOutcome.failed('SMTP send failed: ${e.message}${problems.isNotEmpty ? ' ($problems)' : ''}');
    } catch (e) {
      log.error('[EmailDelivery] SMTP send exception: $e');
      return EmailDeliveryOutcome.failed('SMTP delivery failed: $e');
    }
  }

  String _buildGmailMimeMessage({
    required String? fromAddress,
    required List<String> recipients,
    required String subject,
    required String bodyText,
    required List<EmailAttachmentPayload> attachments,
  }) {
    if (attachments.isEmpty) {
      final headers = <String>[
        if (fromAddress != null) 'From: $fromAddress',
        'To: ${recipients.join(', ')}',
        'Subject: $subject',
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset="UTF-8"',
        '',
        bodyText,
      ];
      return headers.join('\r\n');
    }

    final boundary = '----mobile-ai-agent-${DateTime.now().millisecondsSinceEpoch}';
    final sb = StringBuffer();
    if (fromAddress != null) sb.writeln('From: $fromAddress');
    sb.writeln('To: ${recipients.join(', ')}');
    sb.writeln('Subject: $subject');
    sb.writeln('MIME-Version: 1.0');
    sb.writeln('Content-Type: multipart/mixed; boundary="$boundary"');
    sb.writeln();
    sb.writeln('--$boundary');
    sb.writeln('Content-Type: text/plain; charset="UTF-8"');
    sb.writeln('Content-Transfer-Encoding: 7bit');
    sb.writeln();
    sb.writeln(bodyText);

    for (final attachment in attachments) {
      sb.writeln('--$boundary');
      sb.writeln('Content-Type: ${attachment.mimeType}; name="${attachment.fileName}"');
      sb.writeln('Content-Disposition: attachment; filename="${attachment.fileName}"');
      sb.writeln('Content-Transfer-Encoding: base64');
      sb.writeln();
      sb.writeln(_splitBase64(base64Encode(attachment.bytes)));
    }

    sb.writeln('--$boundary--');
    return sb.toString();
  }

  String _splitBase64(String value) {
    const chunk = 76;
    final out = StringBuffer();
    for (var i = 0; i < value.length; i += chunk) {
      final end = (i + chunk < value.length) ? i + chunk : value.length;
      out.writeln(value.substring(i, end));
    }
    return out.toString();
  }

  Future<_TokenOutcome> _ensureValidAccessToken({
    required String clientId,
    required String clientSecret,
    required String? accessToken,
    required String? refreshToken,
    required DateTime? expiresAt,
    required DataSourcesSettingsService ds,
  }) async {
    if ((accessToken ?? '').isNotEmpty && !_isExpired(expiresAt)) {
      return _TokenOutcome.success(accessToken!, refreshToken: refreshToken, expiresAt: expiresAt);
    }
    if ((refreshToken ?? '').isEmpty) {
      return const _TokenOutcome.failure('Missing Gmail OAuth refresh token. Please authorize Gmail in Data Sources settings.');
    }
    return _refreshAccessToken(clientId: clientId, clientSecret: clientSecret, refreshToken: refreshToken!, ds: ds);
  }

  bool _isExpired(DateTime? expiresAt) {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 1)));
  }

  Future<_TokenOutcome> _refreshAccessToken({
    required String clientId,
    required String clientSecret,
    required String refreshToken,
    required DataSourcesSettingsService ds,
  }) async {
    if (clientId.trim().isEmpty) {
      return const _TokenOutcome.failure('Gmail OAuth client id missing.');
    }

    try {
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          if (clientSecret.trim().isNotEmpty) 'client_secret': clientSecret,
          'refresh_token': refreshToken,
          'grant_type': 'refresh_token',
        },
      );

      final payload = response.body.isNotEmpty ? jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic> : <String, dynamic>{};

      if (response.statusCode < 200 || response.statusCode >= 300 || payload['access_token'] == null) {
        return _TokenOutcome.failure(payload['error_description']?.toString() ?? payload['error']?.toString() ?? 'Token refresh failed.');
      }

      final newAccessToken = payload['access_token'] as String;
      final expiresIn = (payload['expires_in'] as num?)?.toInt() ?? 3600;
      final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

      await ds.saveGmailOAuthTokens(accessToken: newAccessToken, refreshToken: refreshToken, expiresAt: expiresAt);

      return _TokenOutcome.success(newAccessToken, refreshToken: refreshToken, expiresAt: expiresAt);
    } catch (e) {
      return _TokenOutcome.failure('Token refresh failed: $e');
    }
  }
}

class _TokenOutcome {
  final bool success;
  final String? accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final String? error;

  const _TokenOutcome._({required this.success, this.accessToken, this.refreshToken, this.expiresAt, this.error});

  const _TokenOutcome.success(String accessToken, {String? refreshToken, DateTime? expiresAt})
    : this._(success: true, accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt);

  const _TokenOutcome.failure(String error) : this._(success: false, error: error);
}
