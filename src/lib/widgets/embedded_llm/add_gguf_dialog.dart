import 'package:flutter/material.dart';
import '../../config/app_theme.dart';
import '../../services/embedded_llm/embedded_model.dart';
import '../../services/embedded_llm/embedded_model_manager.dart';
import '../../services/server_api_client.dart';

/// Dialog for manually adding a GGUF model by entering its direct download URL.
///
/// The user provides a display name (optional) and a URL pointing to a .gguf
/// file. On confirm the model is added to the custom-model list via
/// [EmbeddedModelManager.addCustomModel] (or remote equivalent).
class AddGgufDialog extends StatefulWidget {
  final ServerApiClient? serverClient;
  const AddGgufDialog({super.key, this.serverClient});

  /// Show the dialog and return the newly added [EmbeddedGgufModel], or null if cancelled.
  static Future<EmbeddedGgufModel?> show(BuildContext context, {ServerApiClient? serverClient}) {
    return showDialog<EmbeddedGgufModel>(context: context, builder: (_) => AddGgufDialog(serverClient: serverClient));
  }

  @override
  State<AddGgufDialog> createState() => _AddGgufDialogState();
}

class _AddGgufDialogState extends State<AddGgufDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _mmprojUrlCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _mmprojUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _onAdd() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final url = _urlCtrl.text.trim();
      final filename = url.split('/').last.split('?').first;
      final mmprojUrl = _mmprojUrlCtrl.text.trim();
      final mmprojFilename = mmprojUrl.isNotEmpty ? mmprojUrl.split('/').last.split('?').first : null;
      final model = EmbeddedGgufModel(
        id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
        displayName: _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : filename,
        filename: filename,
        url: url,
        description: 'Custom model added by user.',
        mmprojUrl: mmprojUrl.isNotEmpty ? mmprojUrl : null,
        mmprojFilename: mmprojFilename,
      );
      if (widget.serverClient != null) {
        final current = (await widget.serverClient!.getServerCustomModels())
            .map((e) => EmbeddedGgufModel.fromJson(e))
            .toList();
        current.removeWhere((m) => m.id == model.id);
        current.add(model);
        await widget.serverClient!.saveServerCustomModels(current.map((m) => m.toJson()).toList());
      } else {
        await EmbeddedModelManager.instance.addCustomModel(model);
      }
      if (mounted) Navigator.of(context).pop(model);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add model: $e'), backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableHeight = media.size.height - media.viewInsets.bottom;
    final maxContentHeight = availableHeight * 0.52;

    return AlertDialog(
      title: const Row(children: [Icon(Icons.add_link, size: 22), SizedBox(width: 8), Text('Add GGUF Model')]),
      content: Form(
        key: _formKey,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxContentHeight),
          child: SingleChildScrollView(
            child: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Enter the direct download URL of a .gguf file. '
                    'You can find models on HuggingFace or other GGUF repositories.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Display name (optional)',
                      hintText: 'e.g. My Custom Model',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.label_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'GGUF download URL *',
                      hintText: 'https://huggingface.co/.../model.gguf',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.link),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'URL is required';
                      final uri = Uri.tryParse(v.trim());
                      if (uri == null || !uri.hasScheme) return 'Enter a valid URL';
                      if (!v.trim().toLowerCase().contains('.gguf') && !v.trim().contains('?')) {
                        return 'URL does not appear to point to a .gguf file';
                      }
                      return null;
                    },
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _mmprojUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Multimodal projection URL (optional)',
                      hintText: 'https://.../mmproj.gguf',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.image_outlined),
                      helperText: 'Only needed for vision models',
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: _saving ? null : _onAdd,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.add, size: 18),
          label: Text(_saving ? 'Adding...' : 'Add model'),
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primaryBlue),
        ),
      ],
    );
  }
}
