import 'package:tealkit_server/config/server_feature_flags.dart';
import 'package:tealkit_server/database/server_sqlite_adapter.dart';
import 'package:tealkit_server/server_runner.dart' as runner;

/// TealKit Server Light — lightweight ARM / low-RAM edition.
///
/// Reuses the full [tealkit_server] REST API with an SQLite backend
/// and reduced feature set (no embedded models, no indexing, no PDF/chart tools).
///
/// Target: ≤1 GB RAM.
Future<void> main(List<String> args) async {
  final db = ServerSqliteAdapter();
  await runner.serverBootstrap(db: db, flags: ServerFeatureFlags.light);
  await runner.startHttpServer(db: db, flags: ServerFeatureFlags.light);
}
