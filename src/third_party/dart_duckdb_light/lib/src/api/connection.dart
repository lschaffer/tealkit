import 'package:dart_duckdb/src/api/appender.dart';
import 'package:dart_duckdb/src/api/cancellation_token.dart';
import 'package:dart_duckdb/src/api/prepared_statement.dart';
import 'package:dart_duckdb/src/api/result_set.dart';

/// A DuckDB connection stub.
abstract class Connection {
  dynamic get handle => throw UnimplementedError('stub');
  String? get id => throw UnimplementedError('stub');
  Future<ResultSet> query(String query, {DuckDBCancellationToken? token}) =>
      throw UnimplementedError('stub');
  Future<void> execute(String query, {DuckDBCancellationToken? token}) =>
      throw UnimplementedError('stub');
  Future<PreparedStatement> prepare(
    String query, {
    DuckDBCancellationToken? token,
  }) =>
      throw UnimplementedError('stub');
  Future<Appender> append(String table, String? schema) =>
      throw UnimplementedError('stub');
  Future<Iterable<String>> getColumnOrder(String table) =>
      throw UnimplementedError('stub');
  Future<void> interrupt() => throw UnimplementedError('stub');
  Future<void> dispose() => throw UnimplementedError('stub');
}
