// Stub dart_duckdb for server_light.
// Exports the same public API as dart_duckdb but with no-op implementations.
// server_light uses SQLite, so these types are never instantiated at runtime.
library dart_duckdb;

export 'src/api/appender.dart';
export 'src/api/cancellation_token.dart';
export 'src/api/connection.dart';
export 'src/api/database.dart';
export 'src/api/database_type.dart';
export 'src/api/exception.dart';
export 'src/api/open.dart';
export 'src/api/prepared_statement.dart';
export 'src/api/result_set.dart';
export 'src/duckdb_stub.dart';
