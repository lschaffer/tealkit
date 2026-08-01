import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'server_logger.dart';

/// Field-level AES-256-GCM encryption for sensitive values stored in DuckDB.
///
/// The 256-bit key is stored in `$TEALKIT_DATA_DIR/master.key` (chmod 600).
/// On first startup the key is generated from [Random.secure].
///
/// This is the server-side equivalent of the Flutter app's `CredentialCipher`.
/// The on-disk format is identical so that data exported from the GUI app
/// and imported into the server is decrypted correctly — as long as the same
/// master key is used (or the data is migrated with the export API).
///
/// Format:  `enc_v1:<base64url(iv[12] + ciphertext + gcm-tag[16])>`
class ServerCredentialCipher {
  ServerCredentialCipher._();
  static final ServerCredentialCipher instance = ServerCredentialCipher._();

  static const _prefix = 'enc_v1:';
  static const _ivLen = 12; // 96-bit IV recommended for GCM
  static const _tagLen = 128; // 128-bit authentication tag

  Uint8List? _key;

  /// Names of initParam fields that hold sensitive credentials.
  static const sensitiveFields = <String>{
    'password',
    'privateKey',
    'apiKey',
    'accessToken',
    'secret',
    'token',
  };

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Initialise the cipher. Reads the key from `$dataDir/master.key`.
  /// When the file does not exist, a new key is generated and saved there
  /// (with `chmod 600`).
  Future<void> init(String dataDir) async {
    final keyFile = File('$dataDir/master.key');
    try {
      if (await keyFile.exists()) {
        final b64 = (await keyFile.readAsString()).trim();
        _key = Uint8List.fromList(base64.decode(b64));
        log.info('[Cipher] Loaded master key from ${keyFile.path}');
      } else {
        final rng = Random.secure();
        final key = Uint8List.fromList(
          List.generate(32, (_) => rng.nextInt(256)),
        );
        await keyFile.parent.create(recursive: true);
        await keyFile.writeAsString(base64.encode(key));
        // chmod 600 — only works on POSIX (Linux), ignored on Windows.
        if (!Platform.isWindows) {
          await Process.run('chmod', ['600', keyFile.path]);
        }
        _key = key;
        log.info('[Cipher] Generated new master key at ${keyFile.path}');
      }
    } catch (e, st) {
      log.error('[Cipher] Failed to load/generate master key', e, st);
      _key = null;
    }
  }

  // ── Primitive encrypt / decrypt ───────────────────────────────────────────

  /// Encrypts [plaintext] and returns an `enc_v1:…` encoded string.
  String encrypt(String plaintext) {
    if (_key == null || plaintext.isEmpty) return plaintext;

    final rng = Random.secure();
    final iv = Uint8List.fromList(
      List.generate(_ivLen, (_) => rng.nextInt(256)),
    );

    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      true,
      AEADParameters(KeyParameter(_key!), _tagLen, iv, Uint8List(0)),
    );

    final input = Uint8List.fromList(utf8.encode(plaintext));
    final cipherAndTag = cipher.process(input);

    final combined = Uint8List(iv.length + cipherAndTag.length)
      ..setRange(0, iv.length, iv)
      ..setRange(iv.length, iv.length + cipherAndTag.length, cipherAndTag);

    return '$_prefix${base64.encode(combined)}';
  }

  /// Decrypts a value produced by [encrypt]. Returns [value] unchanged when
  /// the key is absent, the value is plain-text, or decryption fails.
  String decrypt(String value) {
    if (_key == null || !value.startsWith(_prefix)) return value;

    try {
      final combined = base64.decode(value.substring(_prefix.length));
      if (combined.length < _ivLen + 16) return value;

      final iv = combined.sublist(0, _ivLen);
      final cipherAndTag = combined.sublist(_ivLen);

      final cipher = GCMBlockCipher(AESEngine());
      cipher.init(
        false,
        AEADParameters(KeyParameter(_key!), _tagLen, iv, Uint8List(0)),
      );

      final plainBytes = cipher.process(cipherAndTag);
      return utf8.decode(plainBytes);
    } catch (_) {
      return value;
    }
  }

  // ── Map-level helpers ─────────────────────────────────────────────────────

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
