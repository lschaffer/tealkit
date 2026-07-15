// Task database service — backed by DuckDB.
//
// This file re-exports the DuckDB-based implementation so that existing
// imports (`import '../database/task_database_service.dart'`) continue
// to work without changes.
export 'task_database_service_duckdb.dart';
