import 'package:dart_duckdb/src/api/database.dart';
import 'package:dart_duckdb/src/api/connection.dart';

/// Stub implementation of the duckdb top-level object.
/// All methods throw UnimplementedError — server_light uses SQLite.
class DuckDbStub {
  Future<Database> open(String path) =>
      throw UnimplementedError('dart_duckdb_light stub: open() not available');

  Future<Connection> connect(Database db) => throw UnimplementedError(
    'dart_duckdb_light stub: connect() not available',
  );
}

/// The global duckdb instance — matches the API of the real dart_duckdb.
final duckdb = DuckDbStub();
