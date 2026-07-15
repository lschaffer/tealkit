import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/server_credential_cipher.dart';
import '../utils/server_logger.dart';

/// Stores settings in two files under [dataDir]:
///   - `config.json`   — non-sensitive key/value pairs
///   - `secrets.enc`   — AES-256-GCM encrypted JSON blob
class ServerConfigService {
  static final ServerConfigService _instance = ServerConfigService._internal();
  factory ServerConfigService() => _instance;
  ServerConfigService._internal();

  late String _dataDir;

  Map<String, dynamic> _plain = {};
  Map<String, dynamic> _secrets = {};

  String get _configPath => p.join(_dataDir, 'config.json');
  String get _secretsPath => p.join(_dataDir, 'secrets.enc');

  // ──────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────

  Future<void> init(String dataDir) async {
    _dataDir = dataDir;
    await Directory(dataDir).create(recursive: true);
    await _loadPlain();
    await _loadSecrets();
    log.info('[Config] Loaded config from: $dataDir');
  }

  Future<void> _loadPlain() async {
    final file = File(_configPath);
    if (!await file.exists()) {
      _plain = {};
      return;
    }
    try {
      _plain = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      log.warning('[Config] Could not read config.json: $e — using empty config');
      _plain = {};
    }
  }

  Future<void> _savePlain() async {
    await File(_configPath).writeAsString(const JsonEncoder.withIndent('  ').convert(_plain));
  }

  Future<void> _loadSecrets() async {
    final file = File(_secretsPath);
    if (!await file.exists()) {
      _secrets = {};
      return;
    }
    try {
      final encrypted = await file.readAsString();
      final decrypted = ServerCredentialCipher.instance.decrypt(encrypted);
      if (decrypted.isNotEmpty) {
        _secrets = jsonDecode(decrypted) as Map<String, dynamic>;
      } else {
        log.warning('[Config] Could not decrypt secrets.enc — using empty secrets');
        _secrets = {};
      }
    } catch (e) {
      log.warning('[Config] Could not read secrets.enc: $e — using empty secrets');
      _secrets = {};
    }
  }

  Future<void> _saveSecrets() async {
    final plaintext = jsonEncode(_secrets);
    final encrypted = ServerCredentialCipher.instance.encrypt(plaintext);
    await File(_secretsPath).writeAsString(encrypted);
  }

  // ──────────────────────────────────────────────
  // Plain (non-sensitive) accessors
  // ──────────────────────────────────────────────

  String? getString(String key) {
    final v = _plain[key];
    if (v == null) return null;
    if (v is String) return v;
    return v.toString();
  }

  int? getInt(String key) {
    final v = _plain[key];
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  double? getDouble(String key) {
    final v = _plain[key];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  bool? getBool(String key) {
    final v = _plain[key];
    if (v == null) return null;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (s == 'true' || s == '1' || s == 'yes' || s == 'on') return true;
      if (s == 'false' || s == '0' || s == 'no' || s == 'off') return false;
    }
    return null;
  }

  Future<void> setString(String key, String value) async {
    _plain[key] = value;
    await _savePlain();
  }

  Future<void> setInt(String key, int value) async {
    _plain[key] = value;
    await _savePlain();
  }

  Future<void> setDouble(String key, double value) async {
    _plain[key] = value;
    await _savePlain();
  }

  Future<void> setBool(String key, bool value) async {
    _plain[key] = value;
    await _savePlain();
  }

  Future<void> remove(String key) async {
    _plain.remove(key);
    await _savePlain();
  }

  // ──────────────────────────────────────────────
  // Secret accessors
  // ──────────────────────────────────────────────

  String? getSecret(String key) => _secrets[key] as String?;

  Future<void> setSecret(String key, String value) async {
    _secrets[key] = value;
    await _saveSecrets();
  }

  Future<void> removeSecret(String key) async {
    _secrets.remove(key);
    await _saveSecrets();
  }

  // ──────────────────────────────────────────────
  // Bulk access (for settings service loaders)
  // ──────────────────────────────────────────────

  Map<String, dynamic> get plainMap => Map.unmodifiable(_plain);
  Map<String, dynamic> get secretMap => Map.unmodifiable(_secrets);
}
