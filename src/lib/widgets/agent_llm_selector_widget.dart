import 'package:material_ui/material_ui.dart';
import '../services/llm_settings_service.dart';

/// Unified LLM selector widget used across Assistant (Playground), Workflow Task Editor,
/// and Visual Agent Builder.
///
/// Displays:
/// 1. Configured LLM Profiles (shown in a distinct accent color with a * bullet)
/// 2. Raw Providers (shown in standard color)
///
/// When a Configured LLM Profile is selected:
/// - Provider and Model are displayed in a clean read-only card.
/// - None of the parameters can be modified inline (they are managed in Settings).
///
/// When a Raw Provider is selected:
/// - The editable parameter panel ([editablePanel]) is displayed.
class AgentLlmSelectorWidget extends StatelessWidget {
  final LlmSettingsService llmSettings;
  final String? selectedProfileId;
  final String selectedProviderKey;
  final ValueChanged<String?> onProfileSelected;
  final ValueChanged<String> onProviderSelected;
  final Widget? editablePanel;
  final bool showEmbeddedOption;

  const AgentLlmSelectorWidget({
    super.key,
    required this.llmSettings,
    required this.selectedProfileId,
    required this.selectedProviderKey,
    required this.onProfileSelected,
    required this.onProviderSelected,
    this.editablePanel,
    this.showEmbeddedOption = true,
  });

  static const List<LlmProvider> supportedProviders = [
    LlmProvider.gemini,
    LlmProvider.openai,
    LlmProvider.claude,
    LlmProvider.mistral,
    LlmProvider.ollama,
    LlmProvider.openaiCompatible,
    LlmProvider.embedded,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final profileColor = isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

    final profiles = llmSettings.profiles;
    final defaultProfile = llmSettings.selectedProfile ?? (profiles.isNotEmpty ? profiles.first : null);

    // Determine current dropdown value
    String dropdownValue;
    if (selectedProfileId != null && profiles.any((p) => p.id == selectedProfileId)) {
      dropdownValue = 'profile:$selectedProfileId';
    } else if (selectedProfileId == null && selectedProviderKey.isNotEmpty) {
      dropdownValue = 'provider:$selectedProviderKey';
    } else if (defaultProfile != null) {
      dropdownValue = 'profile:${defaultProfile.id}';
    } else {
      dropdownValue = 'provider:${selectedProviderKey.isNotEmpty ? selectedProviderKey : "gemini"}';
    }

    final isProfileSelected = dropdownValue.startsWith('profile:');
    final activeProfileId = isProfileSelected ? dropdownValue.substring(8) : null;
    final activeProfile = activeProfileId != null
        ? (llmSettings.getProfile(activeProfileId) ?? (profiles.isNotEmpty ? profiles.first : null))
        : null;

    final providersToDisplay = supportedProviders.where((p) {
      if (!showEmbeddedOption && p == LlmProvider.embedded) return false;
      return true;
    }).toList();

    // Ensure dropdownValue exists in the available items
    final validValues = <String>{
      ...profiles.map((p) => 'profile:${p.id}'),
      ...providersToDisplay.map((p) => 'provider:${p.configKey}'),
    };
    if (!validValues.contains(dropdownValue)) {
      if (profiles.isNotEmpty) {
        dropdownValue = 'profile:${profiles.first.id}';
      } else if (providersToDisplay.isNotEmpty) {
        dropdownValue = 'provider:${providersToDisplay.first.configKey}';
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'LLM',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey('agent_llm_selector_$dropdownValue'),
          initialValue: dropdownValue,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Select LLM or Provider',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.psychology_outlined),
            isDense: true,
          ),
          selectedItemBuilder: (context) {
            final items = <Widget>[];

            for (final p in profiles) {
              items.add(
                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      Icon(Icons.star_rounded, size: 16, color: profileColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '*  ${p.name}  (${p.provider.label} • ${p.model.isNotEmpty ? p.model : "no model"})',
                          style: TextStyle(
                            color: profileColor,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            if (profiles.isNotEmpty) {
              items.add(const SizedBox.shrink());
            }

            for (final prov in providersToDisplay) {
              items.add(
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${prov.label} (Custom inline)',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.normal,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              );
            }

            return items;
          },
          items: [
            // Section 1: Configured Profiles
            if (profiles.isNotEmpty) ...[
              ...profiles.map((p) => DropdownMenuItem<String>(
                    value: 'profile:${p.id}',
                    child: Row(
                      children: [
                        Icon(Icons.star_rounded, size: 16, color: profileColor),
                        const SizedBox(width: 6),
                        Expanded(
                          child: RichText(
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            text: TextSpan(
                              text: '*  ${p.name}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: profileColor,
                                fontSize: 13,
                              ),
                              children: [
                                TextSpan(
                                  text:
                                      '  (${p.provider.label} • ${p.model.isNotEmpty ? p.model : "no model"})',
                                  style: TextStyle(
                                    fontWeight: FontWeight.normal,
                                    fontSize: 11,
                                    color: profileColor.withValues(alpha: 0.8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  )),
              const DropdownMenuItem<String>(
                enabled: false,
                value: '__divider__',
                child: Divider(height: 1),
              ),
            ],

            // Section 2: Other Providers
            ...providersToDisplay.map((prov) => DropdownMenuItem<String>(
                  value: 'provider:${prov.configKey}',
                  child: Padding(
                    padding: const EdgeInsets.only(left: 22),
                    child: Text(
                      prov.label,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )),
          ],
          onChanged: (val) {
            if (val == null || val == '__divider__') return;
            if (val.startsWith('profile:')) {
              final id = val.substring(8);
              onProfileSelected(id);
            } else if (val.startsWith('provider:')) {
              final key = val.substring(9);
              onProfileSelected(null);
              onProviderSelected(key);
            }
          },
        ),

        // Read-only card when a Configured LLM profile is selected
        if (isProfileSelected && activeProfile != null) ...[
          const SizedBox(height: 10),
          Card(
            elevation: 0,
            color: profileColor.withValues(alpha: isDark ? 0.08 : 0.04),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: profileColor.withValues(alpha: 0.25),
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lock_outline, size: 15, color: profileColor),
                      const SizedBox(width: 6),
                      Text(
                        'Configured in Settings (Read-only)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: profileColor,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        activeProfile.name,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: profileColor.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          key: ValueKey('ro_provider_${activeProfile.id}'),
                          readOnly: true,
                          initialValue: activeProfile.provider.label,
                          decoration: InputDecoration(
                            labelText: 'Provider',
                            border: const OutlineInputBorder(),
                            isDense: true,
                            fillColor: isDark
                                ? Colors.white.withValues(alpha: 0.04)
                                : Colors.black.withValues(alpha: 0.02),
                            filled: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          key: ValueKey('ro_model_${activeProfile.id}'),
                          readOnly: true,
                          initialValue: activeProfile.model.isNotEmpty
                              ? activeProfile.model
                              : '(none)',
                          decoration: InputDecoration(
                            labelText: 'Model',
                            border: const OutlineInputBorder(),
                            isDense: true,
                            fillColor: isDark
                                ? Colors.white.withValues(alpha: 0.04)
                                : Colors.black.withValues(alpha: 0.02),
                            filled: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'To edit parameters (API key, temperature, max tokens, etc.), edit "${activeProfile.name}" in Settings > LLM.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        // Editable panel when a raw provider is selected
        if (!isProfileSelected && editablePanel != null) ...[
          const SizedBox(height: 8),
          editablePanel!,
        ],
      ],
    );
  }
}
