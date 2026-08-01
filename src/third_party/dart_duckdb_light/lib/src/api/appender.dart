/// Stub Appender for dart_duckdb_light.
abstract class Appender {
  Future<void> appendRow(List<dynamic> row) => throw UnimplementedError('stub');
  Future<void> flush() => throw UnimplementedError('stub');
  Future<void> close() => throw UnimplementedError('stub');
}
