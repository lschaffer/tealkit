import 'package:tealkit_server/database/server_database_adapter.dart';
import 'package:tealkit_server/database/server_duckdb_adapter.dart';
import 'package:tealkit_server/runner/server_embedded_llm_adapter.dart';
import 'package:tealkit_server/server_runner.dart' as runner;

Future<void> main(List<String> args) async {
  // Wire up default adapters — these imports pull in dart_duckdb and
  // llamadart, which is correct for the full server but NOT for server_light.
  defaultDbFactory = () => ServerDuckDbAdapter();
  runner.embeddedLlmInstance = ServerEmbeddedLlmAdapter.instance;

  await runner.serverBootstrap();
  await runner.startHttpServer();
}
