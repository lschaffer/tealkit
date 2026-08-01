/// Stub exception types for dart_duckdb_light.
class DuckDBException implements Exception {
  final String message;
  const DuckDBException(this.message);
  @override
  String toString() => 'DuckDBException: $message';
}
