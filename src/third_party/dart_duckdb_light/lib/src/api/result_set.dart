/// Stub ResultSet for dart_duckdb_light.
abstract class ResultSet {
  Iterable<Row> get rows => throw UnimplementedError('stub');
  Iterable<Column> get columns => throw UnimplementedError('stub');
  int get rowCount => throw UnimplementedError('stub');
  List<Row> fetchAll() => throw UnimplementedError('stub');
}

abstract class Row extends Iterable<dynamic> {
  dynamic operator [](dynamic index);
}

abstract class Column {
  String get name => throw UnimplementedError('stub');
  String get type => throw UnimplementedError('stub');
}
