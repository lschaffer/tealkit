import 'result_set.dart';

/// Stub PreparedStatement for dart_duckdb_light.
abstract class PreparedStatement {
  Future<void> execute([List<dynamic>? params]) =>
      throw UnimplementedError('stub');
  Future<ResultSet> query([List<dynamic>? params]) =>
      throw UnimplementedError('stub');
  Future<void> dispose() => throw UnimplementedError('stub');
}
