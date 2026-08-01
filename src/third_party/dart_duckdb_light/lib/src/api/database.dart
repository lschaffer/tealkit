import 'dart:typed_data';

import 'package:dart_duckdb/src/types/protocol.dart';

/// An opened duckdb database stub.
abstract class Database {
  dynamic get handle => throw UnimplementedError('stub');
  TransferableDatabase get transferable => throw UnimplementedError('stub');
  Future<void> registerFileBuffer(String name, Uint8List buffer) =>
      throw UnimplementedError('stub');
  Future<void> registerFileURL(
    String name,
    String url,
    DuckDBDataProtocol protocol,
    bool directIO,
  ) =>
      throw UnimplementedError('stub');
  Future<void> registerFileHandle(
    String name,
    dynamic handle,
    DuckDBDataProtocol protocol,
    bool directIO,
  ) =>
      throw UnimplementedError('stub');
  Future<void> dispose() => throw UnimplementedError('stub');
}

abstract class TransferableDatabase {}
