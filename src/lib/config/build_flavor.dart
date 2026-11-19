/// Compile-time edition flags for TealKit.
///
/// Pass `--dart-define=TEALKIT_LIGHT=true` during desktop Store or Light
/// sideload/direct builds to disable on-device embedded LLM (`llamadart`) UI
/// and initialization while overriding `llamadart` with `third_party/llamadart_stub`.
class BuildFlavor {
  const BuildFlavor._();

  /// True when compiled with `--dart-define=TEALKIT_LIGHT=true`.
  static const bool isLight =
      bool.fromEnvironment('TEALKIT_LIGHT', defaultValue: false);

  /// Whether on-device embedded GGUF / LiteRT-LM models (`llamadart`) are enabled.
  static const bool supportsEmbeddedLlm = !isLight;
}
