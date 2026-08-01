/// Supported platforms for duckdb.dart.
enum OperatingSystem { android, iOS, macOS, windows, linux, wasm }

abstract class OpenLibrary {
  void overrideFor(OperatingSystem os, String path) {}
  void reset() {}
}
