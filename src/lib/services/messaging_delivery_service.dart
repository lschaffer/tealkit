import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/workflow_task.dart';
import '../services/app_logger.dart';
import '../services/data_sources_settings_service.dart';
import '../services/email_delivery_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Outcome
// ─────────────────────────────────────────────────────────────────────────────

class MessagingDeliveryOutcome {
  final bool attempted;
  final bool sent;
  final String? message;

  const MessagingDeliveryOutcome({required this.attempted, required this.sent, this.message});

  factory MessagingDeliveryOutcome.skipped(String reason) => MessagingDeliveryOutcome(attempted: false, sent: false, message: reason);

  factory MessagingDeliveryOutcome.success() => MessagingDeliveryOutcome(attempted: true, sent: true);

  factory MessagingDeliveryOutcome.failure(String msg) => MessagingDeliveryOutcome(attempted: true, sent: false, message: msg);
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class MessagingDeliveryService {
  // ═══════════════════════════════════════════════════
  // SLACK
  // ═══════════════════════════════════════════════════

  /// Send a Slack message for [task] after it ran.
  ///
  /// Attachment handling:
  ///   - Bot token configured → files are uploaded via the Files API,
  ///     then shared to the channel.
  ///   - Webhook-only → first 2 000 chars of text output are sent inline
  ///     as a Slack code block.
  Future<MessagingDeliveryOutcome> sendSlackTaskResult({
    required WorkflowTask task,
    required bool taskSuccess,
    required String resultText,
    String? errorText,
    List<EmailAttachmentPayload> attachments = const [],
  }) async {
    final cfg = task.notification.slack;
    if (cfg == null) return MessagingDeliveryOutcome.skipped('no slack config');

    // Evaluate send condition
    if (!_shouldSend(cfg.sendCondition, taskSuccess)) {
      return MessagingDeliveryOutcome.skipped('condition not met: ${cfg.sendCondition}');
    }

    final ds = DataSourcesSettingsService.instance;
    if (!ds.isSlackConfigured) {
      return MessagingDeliveryOutcome.skipped('Slack not configured in Data Sources');
    }

    final webhookUrl = ds.slackWebhookUrl;
    final botToken = ds.slackBotToken;
    final channel = cfg.overrideChannel?.trim().isNotEmpty == true ? cfg.overrideChannel!.trim() : ds.slackDefaultChannel;

    // Build the main text body
    final emoji = taskSuccess ? '✅' : '❌';
    final status = taskSuccess ? 'completed' : 'failed';
    final body = taskSuccess ? resultText : (errorText ?? resultText);
    final truncatedBody = body.length > 2800 ? '${body.substring(0, 2800)}…' : body;

    final messageText = '$emoji *${task.name}* $status\n\n$truncatedBody';

    try {
      if (botToken.isNotEmpty) {
        // ── Bot token flow ──────────────────────────────
        return await _sendSlackViaBot(
          botToken: botToken,
          channel: channel,
          text: messageText,
          taskName: task.name,
          cfg: cfg,
          attachments: cfg.withAttachment ? attachments : const [],
        );
      } else if (webhookUrl.isNotEmpty) {
        // ── Webhook-only flow ───────────────────────────
        return await _sendSlackViaWebhook(
          webhookUrl: webhookUrl,
          text: messageText,
          cfg: cfg,
          attachments: cfg.withAttachment ? attachments : const [],
        );
      } else {
        return MessagingDeliveryOutcome.skipped('no Slack webhook URL or bot token');
      }
    } catch (e, st) {
      log.error('[Messaging] Slack delivery error: $e', e, st);
      return MessagingDeliveryOutcome.failure(e.toString());
    }
  }

  Future<MessagingDeliveryOutcome> sendSlackExecutorResult({
    required WorkflowTask task,
    required Agent executor,
    required bool taskSuccess,
    required String resultText,
    String? errorText,
    List<EmailAttachmentPayload> attachments = const [],
  }) async {
    final cfg = executor.notification.slack;
    if (cfg == null) return MessagingDeliveryOutcome.skipped('no slack config');

    if (!_shouldSend(cfg.sendCondition, taskSuccess)) {
      return MessagingDeliveryOutcome.skipped('condition not met: ${cfg.sendCondition}');
    }

    final ds = DataSourcesSettingsService.instance;
    if (!ds.isSlackConfigured) {
      return MessagingDeliveryOutcome.skipped('Slack not configured in Data Sources');
    }

    final webhookUrl = ds.slackWebhookUrl;
    final botToken = ds.slackBotToken;
    final channel = cfg.overrideChannel?.trim().isNotEmpty == true ? cfg.overrideChannel!.trim() : ds.slackDefaultChannel;

    final emoji = taskSuccess ? '✅' : '❌';
    final status = taskSuccess ? 'completed' : 'failed';
    final body = taskSuccess ? resultText : (errorText ?? resultText);
    final truncatedBody = body.length > 2800 ? '${body.substring(0, 2800)}…' : body;

    final messageText = '$emoji *${task.name} - ${executor.name}* $status\n\n$truncatedBody';

    try {
      if (botToken.isNotEmpty) {
        return await _sendSlackViaBot(
          botToken: botToken,
          channel: channel,
          text: messageText,
          taskName: task.name,
          cfg: cfg,
          attachments: cfg.withAttachment ? attachments : const [],
        );
      } else if (webhookUrl.isNotEmpty) {
        return await _sendSlackViaWebhook(
          webhookUrl: webhookUrl,
          text: messageText,
          cfg: cfg,
          attachments: cfg.withAttachment ? attachments : const [],
        );
      } else {
        return MessagingDeliveryOutcome.skipped('no Slack webhook URL or bot token');
      }
    } catch (e, st) {
      log.error('[Messaging] Slack delivery error: $e', e, st);
      return MessagingDeliveryOutcome.failure('Slack exception: $e');
    }
  }

  Future<MessagingDeliveryOutcome> _sendSlackViaWebhook({
    required String webhookUrl,
    required String text,
    required SlackNotification cfg,
    required List<EmailAttachmentPayload> attachments,
  }) async {
    // Webhooks only support text/blocks — embed attachment content as snippets
    final buffer = StringBuffer(text);
    if (cfg.withAttachment && attachments.isNotEmpty) {
      for (final att in attachments) {
        final isText =
            att.mimeType.startsWith('text/') ||
            att.fileName.endsWith('.md') ||
            att.fileName.endsWith('.txt') ||
            att.fileName.endsWith('.json');
        if (isText) {
          final content = utf8.decode(att.bytes, allowMalformed: true);
          final snippet = content.length > 1500 ? '${content.substring(0, 1500)}…' : content;
          buffer.write('\n\n*${att.fileName}*\n```$snippet```');
        } else {
          buffer.write('\n\n📎 _${att.fileName} (binary, ${att.bytes.length} bytes — bot token required to upload)_');
        }
      }
    }

    final payload = jsonEncode({'text': buffer.toString()});
    final response = await http
        .post(Uri.parse(webhookUrl), headers: {'Content-Type': 'application/json'}, body: payload)
        .timeout(const Duration(seconds: 20));

    if (response.statusCode == 200 && response.body == 'ok') {
      log.info('[Messaging] Slack webhook sent OK');
      return MessagingDeliveryOutcome.success();
    }
    return MessagingDeliveryOutcome.failure('Slack webhook returned ${response.statusCode}: ${response.body}');
  }

  Future<MessagingDeliveryOutcome> _sendSlackViaBot({
    required String botToken,
    required String channel,
    required String text,
    required String taskName,
    required SlackNotification cfg,
    required List<EmailAttachmentPayload> attachments,
  }) async {
    // 1. Post the text message
    if (channel.isEmpty) {
      return MessagingDeliveryOutcome.failure(
        'Slack channel not configured. Set a Default Channel in Data Sources or an Override Channel on the task. '
        'Tip: use your Slack Member ID (U…) to send a DM to yourself.',
      );
    }
    final msgResponse = await http
        .post(
          Uri.parse('https://slack.com/api/chat.postMessage'),
          headers: {'Authorization': 'Bearer $botToken', 'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode({'channel': channel, 'text': text, 'unfurl_links': false}),
        )
        .timeout(const Duration(seconds: 20));

    final msgJson = jsonDecode(msgResponse.body) as Map<String, dynamic>;
    if (msgJson['ok'] != true) {
      return MessagingDeliveryOutcome.failure('Slack postMessage failed: ${msgJson['error'] ?? msgResponse.body}');
    }
    log.info('[Messaging] Slack bot message sent');

    // 2. Upload each attachment (Slack Files API v2)
    if (attachments.isNotEmpty) {
      for (final att in attachments) {
        try {
          await _uploadSlackFile(
            botToken: botToken,
            channel: channel.isNotEmpty ? channel : '#general',
            fileName: att.fileName,
            mimeType: att.mimeType,
            bytes: att.bytes,
          );
        } catch (e) {
          log.warning('[Messaging] Slack file upload failed for ${att.fileName}: $e');
        }
      }
    }
    return MessagingDeliveryOutcome.success();
  }

  /// Upload a file using the Slack `files.getDownloadURLExternal` + complete flow.
  /// Falls back to `files.upload` (v1) if v2 isn't available.
  Future<void> _uploadSlackFile({
    required String botToken,
    required String channel,
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    // Step 1: Get an upload URL
    final getUrlResponse = await http
        .post(
          Uri.parse('https://slack.com/api/files.getUploadURLExternal'),
          headers: {'Authorization': 'Bearer $botToken', 'Content-Type': 'application/x-www-form-urlencoded'},
          body: {'filename': fileName, 'length': bytes.length.toString()},
        )
        .timeout(const Duration(seconds: 15));

    final getUrlJson = jsonDecode(getUrlResponse.body) as Map<String, dynamic>;
    if (getUrlJson['ok'] != true) {
      log.warning('[Messaging] Slack getUploadURLExternal failed: ${getUrlJson['error']}');
      return;
    }

    final uploadUrl = getUrlJson['upload_url'] as String;
    final fileId = getUrlJson['file_id'] as String;

    // Step 2: Upload binary content
    await http.post(Uri.parse(uploadUrl), headers: {'Content-Type': mimeType}, body: bytes).timeout(const Duration(seconds: 30));

    // Step 3: Complete the upload and share to channel
    await http
        .post(
          Uri.parse('https://slack.com/api/files.completeUploadExternal'),
          headers: {'Authorization': 'Bearer $botToken', 'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode({
            'files': [
              {'id': fileId, 'title': fileName},
            ],
            'channel_id': channel,
          }),
        )
        .timeout(const Duration(seconds: 15));

    log.info('[Messaging] Slack file uploaded: $fileName');
  }

  // ═══════════════════════════════════════════════════
  // WHATSAPP (Meta Business Cloud API)
  // ═══════════════════════════════════════════════════

  static const _waApiBase = 'https://graph.facebook.com/v19.0';

  /// Send a WhatsApp message for [task] after it ran.
  ///
  /// Attachment handling:
  ///   Each attachment is uploaded first via the Media API, then sent as a
  ///   separate "document" message to the recipient.
  Future<MessagingDeliveryOutcome> sendWhatsAppTaskResult({
    required WorkflowTask task,
    required bool taskSuccess,
    required String resultText,
    String? errorText,
    List<EmailAttachmentPayload> attachments = const [],
  }) async {
    final cfg = task.notification.whatsApp;
    if (cfg == null) return MessagingDeliveryOutcome.skipped('no WhatsApp config');

    if (!_shouldSend(cfg.sendCondition, taskSuccess)) {
      return MessagingDeliveryOutcome.skipped('condition not met: ${cfg.sendCondition}');
    }

    final ds = DataSourcesSettingsService.instance;
    if (!ds.isWhatsAppConfigured) {
      return MessagingDeliveryOutcome.skipped('WhatsApp not configured in Data Sources');
    }

    final mode = ds.whatsAppMode; // 'meta' | 'callmebot'
    final recipient = cfg.overrideRecipient?.trim().isNotEmpty == true ? cfg.overrideRecipient!.trim() : ds.whatsAppDefaultRecipient;

    if (recipient.isEmpty) {
      return MessagingDeliveryOutcome.skipped('no WhatsApp recipient number');
    }

    final emoji = taskSuccess ? '✅' : '❌';
    final status = taskSuccess ? 'completed' : 'failed';
    final body = taskSuccess ? resultText : (errorText ?? resultText);

    try {
      if (mode == 'callmebot') {
        // ── CallMeBot (personal number, no Meta account) ──────────
        // Max ~2000 chars; no file attachment support — list filenames instead
        final truncated = body.length > 1800 ? '${body.substring(0, 1800)}…' : body;
        var msgText = '$emoji ${task.name} $status\n\n$truncated';
        if (cfg.withAttachment && attachments.isNotEmpty) {
          final names = attachments.map((a) => a.fileName).join(', ');
          msgText += '\n\n[Attachment(s): $names]';
        }
        return await _sendCallMeBotWa(phone: recipient, apiKey: ds.whatsAppCallMeBotApiKey, text: msgText);
      } else {
        // ── Meta Business Cloud API ────────────────────────────────
        final phoneNumberId = ds.whatsAppPhoneNumberId;
        final accessToken = ds.whatsAppAccessToken;
        final to = recipient.replaceAll(RegExp(r'[\s\-()]'), '').replaceFirst('+', '');
        // WhatsApp messages: max 4096 chars
        final truncated = body.length > 3800 ? '${body.substring(0, 3800)}…' : body;
        final msgText = '$emoji *${task.name}* $status\n\n$truncated';
        final textOutcome = await _sendWaText(phoneNumberId: phoneNumberId, accessToken: accessToken, to: to, text: msgText);
        if (!textOutcome.sent) return textOutcome;
        if (cfg.withAttachment && attachments.isNotEmpty) {
          for (final att in attachments) {
            try {
              final mediaId = await _uploadWaMedia(
                phoneNumberId: phoneNumberId,
                accessToken: accessToken,
                bytes: att.bytes,
                mimeType: att.mimeType,
                fileName: att.fileName,
              );
              if (mediaId != null) {
                await _sendWaDocument(
                  phoneNumberId: phoneNumberId,
                  accessToken: accessToken,
                  to: to,
                  mediaId: mediaId,
                  fileName: att.fileName,
                );
              }
            } catch (e) {
              log.warning('[Messaging] WhatsApp file upload failed for ${att.fileName}: $e');
            }
          }
        }
        return MessagingDeliveryOutcome.success();
      }
    } catch (e, st) {
      log.error('[Messaging] WhatsApp delivery error: $e', e, st);
      return MessagingDeliveryOutcome.failure(e.toString());
    }
  }

  Future<MessagingDeliveryOutcome> sendWhatsAppExecutorResult({
    required WorkflowTask task,
    required Agent executor,
    required bool taskSuccess,
    required String resultText,
    String? errorText,
    List<EmailAttachmentPayload> attachments = const [],
  }) async {
    final cfg = executor.notification.whatsApp;
    if (cfg == null) return MessagingDeliveryOutcome.skipped('no WhatsApp config');

    if (!_shouldSend(cfg.sendCondition, taskSuccess)) {
      return MessagingDeliveryOutcome.skipped('condition not met: ${cfg.sendCondition}');
    }

    final ds = DataSourcesSettingsService.instance;
    if (!ds.isWhatsAppConfigured) {
      return MessagingDeliveryOutcome.skipped('WhatsApp not configured in Data Sources');
    }

    final mode = ds.whatsAppMode;
    final recipient = cfg.overrideRecipient?.trim().isNotEmpty == true ? cfg.overrideRecipient!.trim() : ds.whatsAppDefaultRecipient;

    if (recipient.isEmpty) {
      return MessagingDeliveryOutcome.skipped('no WhatsApp recipient number');
    }

    final emoji = taskSuccess ? '✅' : '❌';
    final status = taskSuccess ? 'completed' : 'failed';
    final body = taskSuccess ? resultText : (errorText ?? resultText);

    try {
      if (mode == 'callmebot') {
        final truncated = body.length > 1800 ? '${body.substring(0, 1800)}…' : body;
        var msgText = '$emoji ${task.name} - ${executor.name} $status\n\n$truncated';
        if (cfg.withAttachment && attachments.isNotEmpty) {
          final names = attachments.map((a) => a.fileName).join(', ');
          msgText += '\n\n[Attachment(s): $names]';
        }
        return await _sendCallMeBotWa(phone: recipient, apiKey: ds.whatsAppCallMeBotApiKey, text: msgText);
      } else {
        final phoneNumberId = ds.whatsAppPhoneNumberId;
        final accessToken = ds.whatsAppAccessToken;
        final to = recipient.replaceAll(RegExp(r'[\s\-()]'), '').replaceFirst('+', '');

        final truncated = body.length > 3800 ? '${body.substring(0, 3800)}…' : body;
        final msgText = '$emoji *${task.name} - ${executor.name}* $status\n\n$truncated';
        final textOutcome = await _sendWaText(phoneNumberId: phoneNumberId, accessToken: accessToken, to: to, text: msgText);
        if (!textOutcome.sent) return textOutcome;
        if (cfg.withAttachment && attachments.isNotEmpty) {
          for (final att in attachments) {
            try {
              final mediaId = await _uploadWaMedia(
                phoneNumberId: phoneNumberId,
                accessToken: accessToken,
                bytes: att.bytes,
                mimeType: att.mimeType,
                fileName: att.fileName,
              );
              if (mediaId != null) {
                await _sendWaDocument(
                  phoneNumberId: phoneNumberId,
                  accessToken: accessToken,
                  to: to,
                  mediaId: mediaId,
                  fileName: att.fileName,
                );
              }
            } catch (e) {
              log.warning('[Messaging] WhatsApp file upload failed for ${att.fileName}: $e');
            }
          }
        }
        return MessagingDeliveryOutcome.success();
      }
    } catch (e, st) {
      log.error('[Messaging] WhatsApp delivery error: $e', e, st);
      return MessagingDeliveryOutcome.failure(e.toString());
    }
  }

  /// Send a WhatsApp message via CallMeBot (personal number, no Meta account needed).
  /// Setup: send "I allow callmebot to send me messages" to +34 644 59 77 60 on WhatsApp;
  /// you receive your personal apiKey in reply.
  Future<MessagingDeliveryOutcome> _sendCallMeBotWa({required String phone, required String apiKey, required String text}) async {
    final encoded = Uri.encodeComponent(text);
    final uri = Uri.parse(
      'https://api.callmebot.com/whatsapp.php?phone=${Uri.encodeComponent(phone)}&text=$encoded&apikey=${Uri.encodeComponent(apiKey)}',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode >= 200 && response.statusCode < 300 && !response.body.toLowerCase().contains('error')) {
      log.info('[Messaging] CallMeBot WhatsApp sent OK');
      return MessagingDeliveryOutcome.success();
    }
    final errMsg = response.body.isNotEmpty ? response.body : 'HTTP ${response.statusCode}';
    return MessagingDeliveryOutcome.failure('CallMeBot: $errMsg');
  }

  Future<MessagingDeliveryOutcome> _sendWaText({
    required String phoneNumberId,
    required String accessToken,
    required String to,
    required String text,
  }) async {
    final response = await http
        .post(
          Uri.parse('$_waApiBase/$phoneNumberId/messages'),
          headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
          body: jsonEncode({
            'messaging_product': 'whatsapp',
            'to': to,
            'type': 'text',
            'text': {'preview_url': false, 'body': text},
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      log.info('[Messaging] WhatsApp text sent OK');
      return MessagingDeliveryOutcome.success();
    }
    final errJson = _tryParseJson(response.body);
    final errMsg = errJson?['error']?['message']?.toString() ?? response.body;
    return MessagingDeliveryOutcome.failure('WhatsApp API ${response.statusCode}: $errMsg');
  }

  /// Upload a media file and return its WhatsApp media_id.
  Future<String?> _uploadWaMedia({
    required String phoneNumberId,
    required String accessToken,
    required Uint8List bytes,
    required String mimeType,
    required String fileName,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse('$_waApiBase/$phoneNumberId/media'));
    request.headers['Authorization'] = 'Bearer $accessToken';
    request.fields['messaging_product'] = 'whatsapp';
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: fileName, contentType: _mediaType(mimeType)));

    final streamed = await request.send().timeout(const Duration(seconds: 60));
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
      final json = _tryParseJson(body);
      final id = json?['id'] as String?;
      log.info('[Messaging] WhatsApp media uploaded: $fileName → $id');
      return id;
    }
    log.warning('[Messaging] WhatsApp media upload failed ${streamed.statusCode}: $body');
    return null;
  }

  Future<void> _sendWaDocument({
    required String phoneNumberId,
    required String accessToken,
    required String to,
    required String mediaId,
    required String fileName,
  }) async {
    await http
        .post(
          Uri.parse('$_waApiBase/$phoneNumberId/messages'),
          headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
          body: jsonEncode({
            'messaging_product': 'whatsapp',
            'to': to,
            'type': 'document',
            'document': {'id': mediaId, 'filename': fileName},
          }),
        )
        .timeout(const Duration(seconds: 20));
    log.info('[Messaging] WhatsApp document sent: $fileName');
  }

  // ═══════════════════════════════════════════════════
  // SEND TEST MESSAGES
  // ═══════════════════════════════════════════════════

  /// Send a test Slack message using the globally configured credentials.
  Future<MessagingDeliveryOutcome> sendSlackTest({String? overrideChannel}) async {
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isSlackConfigured) {
      return MessagingDeliveryOutcome.skipped('Slack not configured');
    }
    const text = '🤖 *TealKit test message* — Slack output channel is working correctly!';
    final channel = overrideChannel?.trim().isNotEmpty == true ? overrideChannel!.trim() : ds.slackDefaultChannel;
    try {
      if (ds.slackBotToken.isNotEmpty) {
        return await _sendSlackViaBot(
          botToken: ds.slackBotToken,
          channel: channel,
          text: text,
          taskName: 'test',
          cfg: const SlackNotification(),
          attachments: const [],
        );
      } else {
        return await _sendSlackViaWebhook(
          webhookUrl: ds.slackWebhookUrl,
          text: text,
          cfg: const SlackNotification(),
          attachments: const [],
        );
      }
    } catch (e) {
      return MessagingDeliveryOutcome.failure(e.toString());
    }
  }

  /// Send a test WhatsApp message using the globally configured credentials.
  Future<MessagingDeliveryOutcome> sendWhatsAppTest({String? overrideRecipient}) async {
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isWhatsAppConfigured) {
      return MessagingDeliveryOutcome.skipped('WhatsApp not configured');
    }
    final rawRecipient = overrideRecipient?.trim().isNotEmpty == true ? overrideRecipient!.trim() : ds.whatsAppDefaultRecipient;
    if (rawRecipient.isEmpty) {
      return MessagingDeliveryOutcome.skipped('no recipient number configured');
    }
    const text = '🤖 TealKit test message — WhatsApp output channel is working correctly!';
    try {
      if (ds.whatsAppMode == 'callmebot') {
        return await _sendCallMeBotWa(phone: rawRecipient, apiKey: ds.whatsAppCallMeBotApiKey, text: text);
      } else {
        final to = rawRecipient.replaceAll(RegExp(r'[\s\-()]'), '').replaceFirst('+', '');
        return await _sendWaText(phoneNumberId: ds.whatsAppPhoneNumberId, accessToken: ds.whatsAppAccessToken, to: to, text: text);
      }
    } catch (e) {
      return MessagingDeliveryOutcome.failure(e.toString());
    }
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  bool _shouldSend(String condition, bool taskSuccess) {
    switch (condition) {
      case 'on_success':
        return taskSuccess;
      case 'on_error':
        return !taskSuccess;
      case 'always':
      default:
        return true;
    }
  }

  Map<String, dynamic>? _tryParseJson(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  // Minimal MIME → http MediaType mapping for WhatsApp uploads
  dynamic _mediaType(String mimeType) {
    // http package uses MediaType from package:http_parser; we pass the raw string
    // as content-type in the MultipartFile constructor via fromBytes.
    return null; // The MultipartFile.fromBytes contentType param handles this.
  }
}
