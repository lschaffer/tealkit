import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import '../models/mcp_models.dart';
import '../services/chat_service.dart';
import '../services/multi_mcp_manager.dart';
import '../services/llm_service.dart';
import '../utils/logger.dart';
import '../services/app_preferences_service.dart';
import 'step_list_editor.dart';

class MultimediaInputWidget extends StatefulWidget {
  final Function(ChatMessage) onSendMessage;
  final ChatService chatService;
  final bool isEnabled;
  final String? statusMessage;
  final ValueNotifier<String?>? promptNotifier;

  /// Pre-fill the input field with this text (does not auto-send).
  final String? initialText;

  /// Optional external controller. When provided, the widget uses this
  /// controller instead of its own private one, so the parent can read
  /// (for saving) and write (for pre-filling) the input text at any time.
  final TextEditingController? controller;

  /// Called when the per-step tool selection changes inside the input editor.
  /// Use this to regenerate Tool Hints based on the updated step tool filters.
  final VoidCallback? onToolSelectionChanged;

  const MultimediaInputWidget({
    super.key,
    required this.onSendMessage,
    required this.chatService,
    this.isEnabled = true,
    this.statusMessage,
    this.promptNotifier,
    this.initialText,
    this.controller,
    this.onToolSelectionChanged,
  });

  @override
  State<MultimediaInputWidget> createState() => _MultimediaInputWidgetState();
}

class _MultimediaInputWidgetState extends State<MultimediaInputWidget> {
  final TextEditingController _ownController = TextEditingController();
  final List<MessageAttachment> _attachments = [];
  final ImagePicker _imagePicker = ImagePicker();


  /// Returns the active controller: external if provided, otherwise internal.
  TextEditingController get _textController => widget.controller ?? _ownController;

  void _onTextChanged() => setState(() {});

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);
    widget.promptNotifier?.addListener(_onPromptUpdate);
    // Pre-fill without auto-sending
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _textController.text = widget.initialText!;
      _textController.selection = TextSelection.collapsed(offset: widget.initialText!.length);
    }
  }

  void _onPromptUpdate() {
    final prompt = widget.promptNotifier?.value;
    if (prompt != null && prompt.isNotEmpty) {
      setState(() {
        _textController.text = prompt;
      });
      widget.promptNotifier?.value = null;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _sendMessage();
        }
      });
    }
  }

  @override
  void dispose() {
    widget.promptNotifier?.removeListener(_onPromptUpdate);
    // Remove listener from whichever controller we used.
    _textController.removeListener(_onTextChanged);
    // Always dispose the internal controller (external is owned by the parent).
    _ownController.dispose();
    super.dispose();
  }



  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final viewInsets = MediaQuery.of(context).viewInsets;
    final availableHeight = MediaQuery.of(context).size.height - viewInsets.bottom;
    final maxInputHeight = availableHeight * 0.45;

    return SafeArea(
      top: false,
      bottom: viewInsets.bottom == 0,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxInputHeight),
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(top: BorderSide(color: Theme.of(context).dividerColor, width: 0.5)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_attachments.isNotEmpty) _buildAttachmentPreview(),
                Padding(padding: const EdgeInsets.all(8.0), child: isMobile ? _buildMobileLayout() : _buildDesktopLayout()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileLayout() {
    final enabled = widget.isEnabled && widget.statusMessage == null;
    return Column(
      children: [
        if (widget.statusMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              widget.statusMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w500, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
        IgnorePointer(
          ignoring: !enabled,
          child: Opacity(
            opacity: enabled ? 1.0 : 0.5,
            child: ListenableBuilder(
              listenable: widget.chatService.mcpClient,
              builder: (context, _) => StepListEditor(
                controller: _textController,
                chatMode: false,
                availableToolGroups: (widget.chatService.mcpClient is MultiMCPManager)
                    ? (widget.chatService.mcpClient as MultiMCPManager).clients
                          .map((c) => ToolGroup(name: c.label, toolNames: c.availableTools.map((t) => t.name).toList()))
                          .toList()
                    : widget.chatService.mcpClient.availableTools.isNotEmpty
                    ? [ToolGroup(name: 'Tools', toolNames: widget.chatService.mcpClient.availableTools.map((t) => t.name).toList())]
                    : [],
                onToolSelectionChanged: widget.onToolSelectionChanged,
                minLines: 1,
                maxLines: 6,
                hintText: _attachments.isNotEmpty ? 'Add a caption...' : 'Type a message...',
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildMobileToolbar(),
      ],
    );
  }

  Widget _buildDesktopLayout() {
    final enabled = widget.isEnabled && widget.statusMessage == null;
    final llm = widget.chatService.llmService;
    final isMultiModal = llm.isConfigured ? llm.isMultiModal : true;
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';

    if (isModern) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.statusMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                widget.statusMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w500, fontSize: 13),
              ),
            ),
          IgnorePointer(
            ignoring: !enabled,
            child: Opacity(
              opacity: enabled ? 1.0 : 0.5,
              child: ListenableBuilder(
                listenable: widget.chatService.mcpClient,
                builder: (context, _) => StepListEditor(
                  controller: _textController,
                  chatMode: false,
                  availableToolGroups: (widget.chatService.mcpClient is MultiMCPManager)
                      ? (widget.chatService.mcpClient as MultiMCPManager).clients
                            .map((c) => ToolGroup(name: c.label, toolNames: c.availableTools.map((t) => t.name).toList()))
                            .toList()
                      : widget.chatService.mcpClient.availableTools.isNotEmpty
                      ? [ToolGroup(name: 'Tools', toolNames: widget.chatService.mcpClient.availableTools.map((t) => t.name).toList())]
                      : [],
                  onToolSelectionChanged: widget.onToolSelectionChanged,
                  minLines: 1,
                  maxLines: 6,
                  hintText: _attachments.isNotEmpty ? 'Add a caption...' : 'Message AI Playground...',
                  leading: isMultiModal ? _buildAttachmentButton() : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.chatService.isProcessing)
                        IconButton(
                          icon: const Icon(Icons.stop_circle),
                          iconSize: 20,
                          tooltip: 'Stop processing',
                          onPressed: () => widget.chatService.stopProcessing(),
                          color: Colors.red,
                        ),
                      _buildSendButton(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.statusMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              widget.statusMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w500, fontSize: 13),
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (isMultiModal) _buildAttachmentButton(),
            const SizedBox(width: 4),
            Expanded(
              child: IgnorePointer(
                ignoring: !enabled,
                child: Opacity(
                  opacity: enabled ? 1.0 : 0.5,
                  child: ListenableBuilder(
                    listenable: widget.chatService.mcpClient,
                    builder: (context, _) => StepListEditor(
                      controller: _textController,
                      chatMode: false,
                      availableToolGroups: (widget.chatService.mcpClient is MultiMCPManager)
                          ? (widget.chatService.mcpClient as MultiMCPManager).clients
                                .map((c) => ToolGroup(name: c.label, toolNames: c.availableTools.map((t) => t.name).toList()))
                                .toList()
                          : widget.chatService.mcpClient.availableTools.isNotEmpty
                          ? [ToolGroup(name: 'Tools', toolNames: widget.chatService.mcpClient.availableTools.map((t) => t.name).toList())]
                          : [],
                      onToolSelectionChanged: widget.onToolSelectionChanged,
                      minLines: 1,
                      maxLines: 6,
                      hintText: _attachments.isNotEmpty ? 'Add a caption...' : 'Type a message...',
                    ),
                  ),
                ),
              ),
            ),
            if (widget.chatService.isProcessing)
              IconButton(
                icon: const Icon(Icons.stop_circle),
                iconSize: 20,
                tooltip: 'Stop processing',
                onPressed: () => widget.chatService.stopProcessing(),
                color: Colors.red,
              ),
            const SizedBox(width: 8),
            _buildSendButton(),
          ],
        ),
      ],
    );
  }

  Widget _buildMobileToolbar() {
    final llm = widget.chatService.llmService;
    final isMultiModal = llm.isConfigured ? llm.isMultiModal : true;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            if (isMultiModal) _buildAttachmentButton(),
            if (widget.chatService.isProcessing)
              IconButton(
                icon: const Icon(Icons.stop_circle),
                iconSize: 24,
                tooltip: 'Stop processing',
                onPressed: () => widget.chatService.stopProcessing(),
                color: Colors.red,
              ),
          ],
        ),
        _buildSendButton(),
      ],
    );
  }

  Widget _buildAttachmentPreview() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.attach_file, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                'Attachments',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  setState(() {
                    _attachments.clear();
                  });
                },
                iconSize: 16,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 80,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _attachments.length,
              itemBuilder: (context, index) {
                return _buildAttachmentPreviewItem(_attachments[index], index);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentPreviewItem(MessageAttachment attachment, int index) {
    return Container(
      width: 80,
      height: 80,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
      ),
      child: Stack(
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: _buildPreviewContent(attachment)),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _attachments.removeAt(index);
                });
              },
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.close, color: Colors.white, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewContent(MessageAttachment attachment) {
    switch (attachment.type) {
      case AttachmentType.image:
        if (attachment.bytes != null) {
          return Image.memory(
            attachment.bytes!,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => _buildFilePreview(attachment),
          );
        } else {
          return Image.file(
            File(attachment.path),
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => _buildFilePreview(attachment),
          );
        }
      default:
        return _buildFilePreview(attachment);
    }
  }

  Widget _buildFilePreview(MessageAttachment attachment) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(_getFileIcon(attachment.name), size: 24, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 4),
          Text(
            attachment.name.length > 10 ? '${attachment.name.substring(0, 7)}...' : attachment.name,
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentButton() {
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.attach_file,
        color: widget.isEnabled
            ? (isModern ? const Color(0xFF94A3B8) : Theme.of(context).colorScheme.primary)
            : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      ),
      enabled: widget.isEnabled,
      onSelected: _handleAttachmentAction,
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'camera',
          child: Row(children: [Icon(Icons.camera_alt), SizedBox(width: 12), Text('Take Photo')]),
        ),
        const PopupMenuItem(
          value: 'gallery',
          child: Row(children: [Icon(Icons.photo_library), SizedBox(width: 12), Text('Choose Photo')]),
        ),
        const PopupMenuItem(
          value: 'file',
          child: Row(children: [Icon(Icons.insert_drive_file), SizedBox(width: 12), Text('Choose File')]),
        ),
      ],
    );
  }

  Widget _buildSendButton() {
    final hasContent = _textController.text.isNotEmpty || _attachments.isNotEmpty;
    final canSend = hasContent && widget.isEnabled;
    final uiStyle = AppPreferencesService.instance.uiStyle;
    final isModern = uiStyle == 'modern';

    if (isModern) {
      return Container(
        height: 36,
        decoration: BoxDecoration(
          gradient: canSend
              ? const LinearGradient(
                  colors: [Color(0xFF06B6D4), Color(0xFF7C3AED)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                )
              : null,
          color: canSend ? null : Colors.white10,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: canSend ? _sendMessage : null,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  'Send',
                  style: TextStyle(
                    color: canSend ? Colors.white : Colors.white30,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: canSend ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: IconButton(
        icon: Icon(
          Icons.send,
          color: canSend ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        ),
        onPressed: canSend ? _sendMessage : null,
      ),
    );
  }

  void _handleAttachmentAction(String action) async {
    try {
      switch (action) {
        case 'camera':
          await _takePhoto();
          break;
        case 'gallery':
          await _pickImage();
          break;
        case 'file':
          await _pickFile();
          break;
      }
    } catch (e) {
      talker.error('Attachment action failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to attach file: $e')));
      }
    }
  }

  Future<void> _takePhoto() async {
    final XFile? photo = await _imagePicker.pickImage(source: ImageSource.camera, maxWidth: 1920, maxHeight: 1080, imageQuality: 85);
    if (photo != null) {
      await _addImageAttachmentFromXFile(photo);
    }
  }

  Future<void> _pickImage() async {
    final XFile? image = await _imagePicker.pickImage(source: ImageSource.gallery, maxWidth: 1920, maxHeight: 1080, imageQuality: 85);
    if (image != null) {
      await _addImageAttachmentFromXFile(image);
    }
  }

  Future<void> _addImageAttachmentFromXFile(XFile xFile) async {
    try {
      final Uint8List bytes = await xFile.readAsBytes();
      final String path = xFile.path;
      final String name = xFile.name;
      final int size = bytes.length;
      final String? mimeType = lookupMimeType(name) ?? xFile.mimeType;

      setState(() {
        _attachments.add(
          MessageAttachment(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            type: AttachmentType.image,
            path: path,
            name: name,
            size: size,
            mimeType: mimeType,
            bytes: bytes,
          ),
        );
      });
    } catch (e) {
      talker.error('Failed to read image bytes: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to attach image: $e')));
      }
    }
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.pickFiles(type: FileType.any, allowMultiple: false, withData: true);

    if (result != null && result.files.isNotEmpty) {
      final file = result.files.single;
      String? filePath = file.path;
      Uint8List? fileBytes = file.bytes;
      String? mimeType;

      if (filePath != null) {
        mimeType = lookupMimeType(filePath);
      } else if (fileBytes != null) {
        mimeType = lookupMimeType(file.name);
      } else {
        talker.error('File picker returned no path or bytes for: ${file.name}');
        return;
      }

      AttachmentType type = AttachmentType.file;
      if (mimeType?.startsWith('image/') == true) {
        type = AttachmentType.image;
      } else if (mimeType?.startsWith('audio/') == true) {
        type = AttachmentType.audio;
      } else if (mimeType?.startsWith('video/') == true) {
        type = AttachmentType.video;
      }

      if ((type == AttachmentType.audio || type == AttachmentType.video) &&
          widget.chatService.llmService.currentProvider != LLMProvider.gemini) {
        talker.warning('Audio/video attachment not supported for non-Gemini model: ${file.name}');
        if (mounted) {
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.warning, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('Unsupported File Type'),
                ],
              ),
              content: Text(
                'Audio and video attachments (${file.name}) are only supported by Gemini models.\n\n'
                'Please switch the active model to a Gemini model under settings, or upload text/PDF/image files instead.',
              ),
              actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
            ),
          );
        }
        return;
      }

      // Block Office documents (not supported by most LLMs)
      if (mimeType != null &&
          (mimeType.contains('officedocument') ||
              mimeType.contains('ms-excel') ||
              mimeType.contains('ms-word') ||
              mimeType.contains('ms-powerpoint') ||
              mimeType == 'application/vnd.ms-excel' ||
              mimeType == 'application/vnd.ms-powerpoint' ||
              mimeType == 'application/msword' ||
              file.name.toLowerCase().endsWith('.xlsx') ||
              file.name.toLowerCase().endsWith('.xls') ||
              file.name.toLowerCase().endsWith('.docx') ||
              file.name.toLowerCase().endsWith('.doc') ||
              file.name.toLowerCase().endsWith('.pptx') ||
              file.name.toLowerCase().endsWith('.ppt'))) {
        talker.warning('Office document not supported: ${file.name} ($mimeType)');
        if (mounted) {
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.warning, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('Unsupported File Type'),
                ],
              ),
              content: Text(
                'Office documents (${file.name}) are not supported by the AI.\n\n'
                'Supported formats:\n'
                '\u2022 Images (PNG, JPG, GIF, WebP)\n'
                '\u2022 PDF documents\n'
                '\u2022 Text files\n\n'
                'Please convert your Office document to PDF or copy the text content.',
              ),
              actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
            ),
          );
        }
        return;
      }

      setState(() {
        _attachments.add(
          MessageAttachment(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            type: type,
            path: filePath ?? file.name,
            name: file.name,
            size: file.size,
            mimeType: mimeType,
            bytes: fileBytes,
          ),
        );
        talker.info('File attached: ${file.name} (${file.size} bytes, $mimeType)');
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Attached: ${file.name}'), duration: const Duration(seconds: 2)));
      }
    }
  }

  void _sendMessage() {
    if (!widget.isEnabled) return;

    final text = _textController.text.trim();
    final hasAttachments = _attachments.isNotEmpty;

    if (text.isEmpty && !hasAttachments) return;

    final messageId = DateTime.now().millisecondsSinceEpoch.toString();
    ChatMessage message;

    if (hasAttachments) {
      final primaryAttachment = _attachments.first;
      MessageType messageType;

      switch (primaryAttachment.type) {
        case AttachmentType.image:
          messageType = MessageType.image;
          break;
        case AttachmentType.audio:
          messageType = MessageType.audio;
          break;
        case AttachmentType.video:
          messageType = MessageType.video;
          break;
        default:
          messageType = MessageType.file;
      }

      message = ChatMessage(
        id: messageId,
        content: text,
        role: ChatRole.user,
        timestamp: DateTime.now(),
        type: messageType,
        attachments: List.from(_attachments),
      );
    } else {
      message = ChatMessage.text(id: messageId, content: text, role: ChatRole.user);
    }

    widget.onSendMessage(message);

    _textController.clear();
    setState(() {
      _attachments.clear();
    });
  }

  IconData _getFileIcon(String fileName) {
    final extension = fileName.toLowerCase().split('.').last;
    switch (extension) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'txt':
        return Icons.text_snippet;
      case 'zip':
      case 'rar':
        return Icons.archive;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return Icons.image;
      case 'mp3':
      case 'wav':
      case 'aac':
        return Icons.audiotrack;
      case 'mp4':
      case 'avi':
      case 'mov':
        return Icons.videocam;
      default:
        return Icons.insert_drive_file;
    }
  }
}
