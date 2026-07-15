import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

/// Field-level AES-256-GCM encryption for sensitive values stored in SQLite.
///
/// The 256-bit key is generated once per device and stored in the platform
/// keychain (Android Keystore / iOS Keychain / Windows Credential Manager /
/// macOS Keychain / Linux Secret Service) via flutter_secure_storage.
///
/// Encrypted values are prefixed with [_prefix] so that:
/// - Existing plain-text values are never broken (backward-compat).
/// - If decryption fails for any reason, the raw value is returned unchanged
///   so the app does not crash on corrupt/migrated data.
///
/// Format:  `enc_v1:<base64url(iv[12] + ciphertext + gcm-tag[16])>`
class CredentialCipher {
  CredentialCipher._();
  static final CredentialCipher instance = CredentialCipher._();

  static const _prefix = 'enc_v1:';
  static const _keyStorageKey = 'mcp_credential_cipher_key_v1';
  static const _ivLen = 12; // 96-bit IV recommended for GCM
  static const _tagLen = 128; // 128-bit authentication tag

  Uint8List? _key;

  /// Names of initParam fields that hold sensitive credentials.
  /// Any field whose key is in this set will be encrypted on [encryptParams]
  /// and decrypted on [decryptParams].
  static const sensitiveFields = <String>{'password', 'privateKey', 'apiKey', 'accessToken', 'secret', 'token'};

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Initialise the cipher. Must be called once during app startup (and in
  /// background isolate bootstrap) before any task is read from or written
  /// to the database.
  Future<void> init() async {
    const storage = FlutterSecureStorage();
    try {
      final stored = await storage.read(key: _keyStorageKey);
      if (stored != null) {
        _key = base64.decode(stored);
      } else {
        final rng = Random.secure();
        final key = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
        await storage.write(key: _keyStorageKey, value: base64.encode(key));
        _key = key;
      }
    } catch (e) {
      // Secure storage unavailable (e.g. running in unit tests without a
      // keystore). Fall back to no-op mode: values are stored as plain text.
      _key = null;
    }
  }

  // ── Primitive encrypt / decrypt ───────────────────────────────────────────

  /// Encrypts [plaintext] and returns an `enc_v1:…` encoded string.
  /// Returns [plaintext] unchanged when:
  /// - [init] has not been called (no key available), or
  /// - [plaintext] is empty (nothing to encrypt).
  String encrypt(String plaintext) {
    if (_key == null || plaintext.isEmpty) return plaintext;

    final rng = Random.secure();
    final iv = Uint8List.fromList(List.generate(_ivLen, (_) => rng.nextInt(256)));

    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(true, AEADParameters(KeyParameter(_key!), _tagLen, iv, Uint8List(0)));

    final input = Uint8List.fromList(utf8.encode(plaintext));
    final cipherAndTag = cipher.process(input); // ciphertext bytes + 16-byte GCM tag

    // Concatenate: IV ‖ ciphertext+tag
    final combined = Uint8List(iv.length + cipherAndTag.length)
      ..setRange(0, iv.length, iv)
      ..setRange(iv.length, iv.length + cipherAndTag.length, cipherAndTag);

    return '$_prefix${base64.encode(combined)}';
  }

  /// Decrypts a value produced by [encrypt].
  /// Returns [value] unchanged when:
  /// - [init] has not been called,
  /// - [value] does not start with [_prefix] (plain-text pass-through), or
  /// - decryption fails (wrong key, corrupted data — forward-compat safety).
  String decrypt(String value) {
    if (_key == null || !value.startsWith(_prefix)) return value;

    try {
      final combined = base64.decode(value.substring(_prefix.length));
      if (combined.length < _ivLen + 16) return value; // sanity check

      final iv = combined.sublist(0, _ivLen);
      final cipherAndTag = combined.sublist(_ivLen);

      final cipher = GCMBlockCipher(AESEngine());
      cipher.init(false, AEADParameters(KeyParameter(_key!), _tagLen, iv, Uint8List(0)));

      final plainBytes = cipher.process(cipherAndTag);
      return utf8.decode(plainBytes);
    } catch (_) {
      // Authentication failure (tampered data) or any other error:
      // return raw value so the app doesn't crash.
      return value;
    }
  }

  // ── Map-level helpers ─────────────────────────────────────────────────────

  /// Returns a copy of [params] where every key in [sensitiveFields] whose
  /// value is a non-empty [String] is replaced with its encrypted form.
  Map<String, dynamic> encryptParams(Map<String, dynamic> params) {
    if (_key == null) return params;
    final result = Map<String, dynamic>.from(params);
    for (final fieldKey in sensitiveFields) {
      final val = result[fieldKey];
      if (val is String && val.isNotEmpty && !val.startsWith(_prefix)) {
        result[fieldKey] = encrypt(val);
      }
    }
    return result;
  }

  /// Returns a copy of [params] where every key in [sensitiveFields] is
  /// decrypted (plain-text values are passed through unchanged).
  Map<String, dynamic> decryptParams(Map<String, dynamic> params) {
    if (_key == null) return params;
    final result = Map<String, dynamic>.from(params);
    for (final fieldKey in sensitiveFields) {
      final val = result[fieldKey];
      if (val is String && val.isNotEmpty) {
        result[fieldKey] = decrypt(val);
      }
    }
    return result;
  }
}
