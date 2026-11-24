import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';
import 'package:tealkit_server/config/server_feature_flags.dart';
import 'package:tealkit_server/database/server_database_adapter.dart';
import 'package:tealkit_server/database/server_sqlite_adapter.dart';
import 'package:tealkit_server/runner/server_embedded_llm_adapter.dart';
import 'package:tealkit_server/server_runner.dart' as runner;
import 'package:tealkit_server/utils/server_logger.dart';

/// Compile-time Light server flag: pass `-DTEALKIT_LIGHT=true` (with
/// `llamadart` overridden to `third_party/llamadart_stub`) to build the
/// Light server edition without `llama.cpp` native libraries.
const bool _kIsLightServer = bool.fromEnvironment(
  'TEALKIT_LIGHT',
  defaultValue: false,
);

Future<void> main(List<String> args) async {
  final isLight = _kIsLightServer || args.contains('--light');
  final flags = isLight ? ServerFeatureFlags.light : const ServerFeatureFlags();

  bool vectorLoaded = false;
  try {
    sqlite3.loadSqliteVectorExtension();
    vectorLoaded = true;
    log.info('[Bootstrap] sqlite_vector extension loaded successfully');
  } catch (e) {
    log.warning(
      '[Bootstrap] sqlite_vector extension unavailable (falling back to pure-Dart cosine similarity): $e',
    );
  }

  // Unified SQLite + sqlite_vector + FTS5 database for both Full and Light builds.
  defaultDbFactory = () =>
      ServerSqliteAdapter.full(vectorExtensionLoaded: vectorLoaded);

  if (!isLight) {
    runner.embeddedLlmInstance = ServerEmbeddedLlmAdapter.instance;
  } else {
    log.info(
      '[Bootstrap] Running in LIGHT server mode (embedded llamadart models disabled)',
    );
  }

  await runner.serverBootstrap(flags: flags);
  await runner.startHttpServer(flags: flags);
}
