/// Describes a GGUF model that can be run on-device via llama.cpp.
class EmbeddedGgufModel {
  final String id;
  final String displayName;
  final String filename;
  final String url;
  final String description;
  final String? mmprojUrl;
  final String? mmprojFilename;
  final int sizeBytes;
  final int minRamGb;
  final int contextSize;
  final int maxTokens;
  final int defaultTopK;
  final int defaultGpuLayers;
  final bool supportsToolCalling;
  final double defaultTemperature;
  final double defaultTopP;

  const EmbeddedGgufModel({
    required this.id,
    required this.displayName,
    required this.filename,
    required this.url,
    required this.description,
    this.mmprojUrl,
    this.mmprojFilename,
    this.sizeBytes = 0,
    this.minRamGb = 2,
    this.contextSize = 4096,
    this.maxTokens = 1024,
    this.defaultTopK = 40,
    this.defaultGpuLayers = 0,
    this.supportsToolCalling = false,
    this.defaultTemperature = 0.3,
    this.defaultTopP = 0.9,
  });

  /// Human-readable file size (e.g. "720 MB").
  String get sizeLabel {
    if (sizeBytes <= 0) return '';
    if (sizeBytes >= 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(sizeBytes / (1024 * 1024)).round()} MB';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'filename': filename,
    'url': url,
    'description': description,
    if (mmprojUrl != null) 'mmprojUrl': mmprojUrl,
    if (mmprojFilename != null) 'mmprojFilename': mmprojFilename,
    'sizeBytes': sizeBytes,
    'minRamGb': minRamGb,
    'contextSize': contextSize,
    'maxTokens': maxTokens,
    'defaultTopK': defaultTopK,
    'defaultGpuLayers': defaultGpuLayers,
    'supportsToolCalling': supportsToolCalling,
    'defaultTemperature': defaultTemperature,
    'defaultTopP': defaultTopP,
  };

  factory EmbeddedGgufModel.fromJson(Map<String, dynamic> json) => EmbeddedGgufModel(
    id: json['id'] as String,
    displayName: json['displayName'] as String,
    filename: json['filename'] as String,
    url: json['url'] as String,
    description: json['description'] as String? ?? '',
    mmprojUrl: json['mmprojUrl'] as String?,
    mmprojFilename: json['mmprojFilename'] as String?,
    sizeBytes: json['sizeBytes'] as int? ?? 0,
    minRamGb: json['minRamGb'] as int? ?? 2,
    contextSize: json['contextSize'] as int? ?? 4096,
    maxTokens: json['maxTokens'] as int? ?? 1024,
    defaultTopK: json['defaultTopK'] as int? ?? 40,
    defaultGpuLayers: json['defaultGpuLayers'] as int? ?? 0,
    supportsToolCalling: json['supportsToolCalling'] as bool? ?? false,
    defaultTemperature: (json['defaultTemperature'] as num? ?? 0.3).toDouble(),
    defaultTopP: (json['defaultTopP'] as num? ?? 0.9).toDouble(),
  );

  EmbeddedGgufModel copyWith({
    String? id,
    String? displayName,
    String? filename,
    String? url,
    String? description,
    String? mmprojUrl,
    String? mmprojFilename,
    int? sizeBytes,
    int? minRamGb,
    int? contextSize,
    int? maxTokens,
    int? defaultTopK,
    int? defaultGpuLayers,
    bool? supportsToolCalling,
    double? defaultTemperature,
    double? defaultTopP,
  }) => EmbeddedGgufModel(
    id: id ?? this.id,
    displayName: displayName ?? this.displayName,
    filename: filename ?? this.filename,
    url: url ?? this.url,
    description: description ?? this.description,
    mmprojUrl: mmprojUrl ?? this.mmprojUrl,
    mmprojFilename: mmprojFilename ?? this.mmprojFilename,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    minRamGb: minRamGb ?? this.minRamGb,
    contextSize: contextSize ?? this.contextSize,
    maxTokens: maxTokens ?? this.maxTokens,
    defaultTopK: defaultTopK ?? this.defaultTopK,
    defaultGpuLayers: defaultGpuLayers ?? this.defaultGpuLayers,
    supportsToolCalling: supportsToolCalling ?? this.supportsToolCalling,
    defaultTemperature: defaultTemperature ?? this.defaultTemperature,
    defaultTopP: defaultTopP ?? this.defaultTopP,
  );

  /// Built-in catalog of curated models.
  /// Intentionally empty — users discover and add models via the HuggingFace
  /// discovery dialog or by pasting a direct GGUF URL.
  static const List<EmbeddedGgufModel> defaultCatalog = [];
}
