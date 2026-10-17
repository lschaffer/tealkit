import 'package:path/path.dart' as p;
import '../config/global_config.dart';

/// Configuration for Local CLI RAG subsystem.
class RagConfig {
  bool enabled;
  String databasePath;
  List<String> folderSources;
  List<String> webSources;
  List<String> fileExtensions;
  int chunkSize;
  int chunkOverlap;
  String embeddingProvider;
  String embeddingModel;
  String embeddingRepo;
  String embeddingBaseUrl;
  String embeddingApiKey;
  String searchMode; // 'hybrid', 'fts', 'semantic'
  int maxChunks;
  double minScore;
  int maxPages; // Maximum pages to crawl per website (default 50)

  RagConfig({
    this.enabled = true,
    String? databasePath,
    List<String>? folderSources,
    List<String>? webSources,
    List<String>? fileExtensions,
    this.chunkSize = 600,
    this.chunkOverlap = 100,
    this.embeddingProvider = 'embedded',
    this.embeddingModel = 'nomic-embed-text-v1.5.Q4_K_M.gguf',
    this.embeddingRepo = 'nomic-ai/nomic-embed-text-v1.5-GGUF',
    this.embeddingBaseUrl = 'http://localhost:11434',
    this.embeddingApiKey = '',
    this.searchMode = 'hybrid',
    this.maxChunks = 5,
    this.minScore = 0.25,
    this.maxPages = 50,
  })  : databasePath = databasePath ?? defaultDatabasePath,
        folderSources = folderSources ?? ['./docs'],
        webSources = webSources ?? [],
        fileExtensions = fileExtensions ??
            ['.txt', '.md', '.docx', '.pdf', '.csv', '.json'];

  /// Default SQLite database path in user's ~/.tealkit/index/tealkit_rag.db
  static String get defaultDatabasePath {
    return p.normalize(
      p.join(GlobalConfigLocator.globalDir, 'index', 'tealkit_rag.db'),
    );
  }

  /// Parses RAG configuration from a loaded YAML map.
  factory RagConfig.fromYaml(Map<dynamic, dynamic>? yaml) {
    if (yaml == null) return RagConfig();

    final enabled = yaml['enabled'] != false;
    final dbPath = (yaml['database_path'] as String?)?.trim();

    final sourcesMap = yaml['sources'] is Map ? yaml['sources'] as Map : null;
    final folders = <String>[];
    if (yaml['folder_sources'] is List) {
      for (final item in yaml['folder_sources'] as List) {
        if (item is String && item.trim().isNotEmpty) {
          folders.add(item.trim());
        } else if (item is Map && item['path'] is String) {
          folders.add((item['path'] as String).trim());
        }
      }
    } else if (sourcesMap != null && sourcesMap['folders'] is List) {
      for (final item in sourcesMap['folders'] as List) {
        if (item is String) {
          folders.add(item.trim());
        } else if (item is Map && item['path'] is String) {
          folders.add((item['path'] as String).trim());
        }
      }
    } else if (yaml['sources'] is List) {
      for (final item in yaml['sources'] as List) {
        if (item is String && item.trim().isNotEmpty) folders.add(item.trim());
      }
    }

    final web = <String>[];
    void addWebItem(dynamic item) {
      if (item is String && item.trim().isNotEmpty) {
        web.add(item.trim());
      } else if (item is Map) {
        for (final entry in item.entries) {
          final k = entry.key?.toString().trim() ?? '';
          final v = entry.value?.toString().trim() ?? '';
          if (v.isEmpty) {
            if (k.isNotEmpty) web.add(k);
          } else {
            web.add('$k:$v');
          }
        }
      }
    }

    if (yaml['web_sources'] is List) {
      for (final item in yaml['web_sources'] as List) {
        addWebItem(item);
      }
    } else if (sourcesMap != null && sourcesMap['web'] is List) {
      for (final item in sourcesMap['web'] as List) {
        addWebItem(item);
      }
    }

    final extList = <String>[];
    final rawExts = yaml['file_extensions'] is List
        ? yaml['file_extensions'] as List
        : (yaml['extensions'] is List ? yaml['extensions'] as List : null);
    if (rawExts != null) {
      for (final ext in rawExts) {
        if (ext is String && ext.trim().isNotEmpty) {
          final clean = ext.trim().toLowerCase();
          extList.add(clean.startsWith('.') ? clean : '.$clean');
        }
      }
    }

    final chunkingMap = yaml['chunking'] is Map ? yaml['chunking'] as Map : null;
    final chunkSize = chunkingMap != null && chunkingMap['chunk_size'] != null
        ? int.tryParse(chunkingMap['chunk_size'].toString()) ?? 600
        : int.tryParse(yaml['chunk_size']?.toString() ?? '600') ?? 600;
    final chunkOverlap = chunkingMap != null && chunkingMap['chunk_overlap'] != null
        ? int.tryParse(chunkingMap['chunk_overlap'].toString()) ?? 100
        : int.tryParse(yaml['chunk_overlap']?.toString() ?? '100') ?? 100;

    final embedMap = yaml['embedding'] is Map ? yaml['embedding'] as Map : null;
    final embProvider = embedMap != null
        ? (embedMap['provider'] as String? ?? 'embedded').trim().toLowerCase()
        : (yaml['embedding_provider'] as String? ?? 'embedded').trim().toLowerCase();
    final embModel = embedMap != null
        ? (embedMap['model'] as String? ?? 'nomic-embed-text-v1.5.Q4_K_M.gguf').trim()
        : (yaml['embedding_model'] as String? ?? 'nomic-embed-text-v1.5.Q4_K_M.gguf').trim();
    final embRepo = embedMap != null
        ? (embedMap['repo'] as String? ?? 'nomic-ai/nomic-embed-text-v1.5-GGUF').trim()
        : (yaml['embedding_repo'] as String? ?? 'nomic-ai/nomic-embed-text-v1.5-GGUF').trim();
    final embBaseUrl = embedMap != null
        ? (embedMap['base_url'] as String? ?? 'http://localhost:11434').trim()
        : (yaml['embedding_base_url'] as String? ?? 'http://localhost:11434').trim();
    final embKey = embedMap != null
        ? (embedMap['api_key'] as String? ?? '').trim()
        : (yaml['embedding_api_key'] as String? ?? '').trim();

    final searchMap = yaml['search'] is Map ? yaml['search'] as Map : null;
    final sMode = searchMap != null
        ? (searchMap['mode'] as String? ?? 'hybrid').trim().toLowerCase()
        : (yaml['search_mode'] as String? ?? 'hybrid').trim().toLowerCase();
    final maxC = searchMap != null && searchMap['max_chunks'] != null
        ? int.tryParse(searchMap['max_chunks'].toString()) ?? 5
        : int.tryParse(yaml['max_chunks']?.toString() ?? '5') ?? 5;
    final minS = searchMap != null && searchMap['min_score'] != null
        ? double.tryParse(searchMap['min_score'].toString()) ?? 0.25
        : double.tryParse(yaml['min_score']?.toString() ?? '0.25') ?? 0.25;

    final rawMaxPages = yaml['max_pages'] ??
        (sourcesMap != null ? sourcesMap['max_pages'] : null) ??
        yaml['web_max_pages'];
    final maxP = switch (rawMaxPages) {
      int val => val,
      num val => val.toInt(),
      String val => int.tryParse(val.trim()) ?? 50,
      _ => 50,
    }.clamp(1, 1000);

    return RagConfig(
      enabled: enabled,
      databasePath: dbPath,
      folderSources: folders.isNotEmpty ? folders : ['./docs'],
      webSources: web,
      fileExtensions: extList.isNotEmpty ? extList : null,
      chunkSize: chunkSize,
      chunkOverlap: chunkOverlap,
      embeddingProvider: embProvider,
      embeddingModel: embModel,
      embeddingRepo: embRepo,
      embeddingBaseUrl: embBaseUrl,
      embeddingApiKey: embKey,
      searchMode: sMode,
      maxChunks: maxC,
      minScore: minS,
      maxPages: maxP,
    );
  }

  /// Exports this configuration into a YAML string map.
  Map<String, dynamic> toYamlMap() {
    return {
      'enabled': enabled,
      'database_path': databasePath,
      'sources': {
        'folders': folderSources,
        'web': webSources,
        'max_pages': maxPages,
      },
      'file_extensions': fileExtensions,
      'chunking': {
        'chunk_size': chunkSize,
        'chunk_overlap': chunkOverlap,
      },
      'embedding': {
        'provider': embeddingProvider,
        'model': embeddingModel,
        'repo': embeddingRepo,
        'base_url': embeddingBaseUrl,
        'api_key': embeddingApiKey,
      },
      'search': {
        'mode': searchMode,
        'max_chunks': maxChunks,
        'min_score': minScore,
      },
    };
  }
}
