import 'dart:io';
import 'package:yaml/yaml.dart';
import 'env_loader.dart';
import 'global_config.dart';

/// Single server connection profile.
class ServerProfile {
  final String name;
  final String url;
  final String apiKey;
  final bool isActive;

  ServerProfile({
    required this.name,
    required this.url,
    this.apiKey = '',
    this.isActive = false,
  });

  ServerProfile copyWith({
    String? name,
    String? url,
    String? apiKey,
    bool? isActive,
  }) {
    return ServerProfile(
      name: name ?? this.name,
      url: url ?? this.url,
      apiKey: apiKey ?? this.apiKey,
      isActive: isActive ?? this.isActive,
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'url': url,
    'api_key': apiKey,
    'is_active': isActive,
  };
}

/// Manages loading, saving, and switching `server.yaml` profiles.
class ServerConfigManager {
  final String configPath;

  ServerConfigManager([this.configPath = 'server.yaml']);

  /// Resolves the actual File to read/write using local workspace first, then ~/.tealkit/
  File get file => GlobalConfigLocator.resolveConfigFile('server.yaml', configPath);

  /// Default configuration template if server.yaml doesn't exist.
  static const String defaultTemplate = '''# TealKit CLI Server Connection Profiles
servers:
  - name: "Local Dev"
    url: "http://localhost:7771"
    api_key: ""
    is_active: true
  - name: "Production"
    url: "https://agent.yourdomain.com"
    api_key: "\${TEALKIT_API_KEY}"
    is_active: false
''';

  /// Ensures server.yaml exists, creating default if absent.
  void ensureConfigFile() {
    final targetFile = file;
    if (!targetFile.existsSync()) {
      targetFile.parent.createSync(recursive: true);
      targetFile.writeAsStringSync(defaultTemplate);
    }
  }

  /// Loads all profiles from `server.yaml`.
  List<ServerProfile> loadProfiles() {
    ensureConfigFile();
    final raw = file.readAsStringSync();
    final resolved = EnvLoader.substitute(raw);

    try {
      final yaml = loadYaml(resolved) as YamlMap?;
      final list = yaml?['servers'] as YamlList?;
      if (list == null) return [];

      return list.whereType<YamlMap>().map((m) {
        return ServerProfile(
          name: (m['name'] as String?) ?? 'Unnamed',
          url: (m['url'] as String?) ?? 'http://localhost:7771',
          apiKey: (m['api_key'] as String?) ?? '',
          isActive: m['is_active'] as bool? ?? false,
        );
      }).toList();
    } catch (e) {
      stderr.writeln('Warning: Failed to parse $configPath: $e');
      return [];
    }
  }

  /// Returns the currently active server profile, or the first profile if none active.
  ServerProfile? getActiveProfile() {
    final profiles = loadProfiles();
    if (profiles.isEmpty) return null;
    return profiles.firstWhere(
      (p) => p.isActive,
      orElse: () => profiles.first,
    );
  }

  /// Activates profile by index (1-based) or by name.
  bool activateProfile(String identifier) {
    final profiles = loadProfiles();
    if (profiles.isEmpty) return false;

    int targetIndex = -1;
    final parsedIndex = int.tryParse(identifier);
    if (parsedIndex != null) {
      targetIndex = parsedIndex - 1; // 1-based to 0-based
    } else {
      targetIndex = profiles.indexWhere(
        (p) => p.name.toLowerCase() == identifier.toLowerCase(),
      );
    }

    if (targetIndex < 0 || targetIndex >= profiles.length) {
      return false;
    }

    final updated = <ServerProfile>[];
    for (int i = 0; i < profiles.length; i++) {
      updated.add(profiles[i].copyWith(isActive: i == targetIndex));
    }

    saveProfiles(updated);
    return true;
  }

  /// Saves updated profile list back to `server.yaml`.
  void saveProfiles(List<ServerProfile> profiles) {
    final buffer = StringBuffer();
    buffer.writeln('# TealKit CLI Server Connection Profiles');
    buffer.writeln('servers:');
    for (final p in profiles) {
      buffer.writeln('  - name: "${p.name}"');
      buffer.writeln('    url: "${p.url}"');
      buffer.writeln('    api_key: "${p.apiKey}"');
      buffer.writeln('    is_active: ${p.isActive}');
    }

    file.writeAsStringSync(buffer.toString());
  }
}
