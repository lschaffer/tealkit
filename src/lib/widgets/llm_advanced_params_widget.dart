import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Reusable widget that renders the four "extra" LLM inference parameters
/// (Top K, Top P, Repeat Penalty, Seed) as two rows of two fields each.
///
/// Each field shows an info tooltip icon (tapped to reveal) explaining its
/// purpose. All fields are optional — leave the controller text empty to
/// omit the parameter from the final request.
///
/// Used in both the global LLM Settings dialog (LLM 1 & LLM 2 tabs) and
/// the per-task LLM override section in the Task Editor.
class LlmAdvancedParamsWidget extends StatelessWidget {
  final TextEditingController topKController;
  final TextEditingController topPController;
  final TextEditingController repeatPenaltyController;
  final TextEditingController seedController;

  const LlmAdvancedParamsWidget({
    super.key,
    required this.topKController,
    required this.topPController,
    required this.repeatPenaltyController,
    required this.seedController,
  });

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _field(label: l.topK, tooltip: l.topKTooltip, hint: '40', controller: topKController, isInt: true),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _field(label: l.topP, tooltip: l.topPTooltip, hint: '0.9', controller: topPController, isDecimal: true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _field(
                label: l.repeatPenalty,
                tooltip: l.repeatPenaltyTooltip,
                hint: '1.1',
                controller: repeatPenaltyController,
                isDecimal: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _field(label: l.seed, tooltip: l.seedTooltip, hint: '42', controller: seedController, isInt: true),
            ),
          ],
        ),
      ],
    );
  }

  static Widget _field({
    required String label,
    required String tooltip,
    required TextEditingController controller,
    String? hint,
    bool isInt = false,
    bool isDecimal = false,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        suffixIcon: Tooltip(message: tooltip, triggerMode: TooltipTriggerMode.tap, child: const Icon(Icons.info_outline, size: 16)),
      ),
      keyboardType: isInt ? TextInputType.number : (isDecimal ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text),
    );
  }
}
