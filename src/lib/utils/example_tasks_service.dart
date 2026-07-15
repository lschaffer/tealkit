import 'dart:convert';
import 'package:flutter/services.dart';

/// A single example task loaded from assets/icons/example_tasks.json.
class ExampleTask {
  final String key;
  final String lang;
  final String title;
  final List<String> tools;
  final String prompt;
  final String? systemPrompt;
  final String? note;
  final List<String> requiresConfig;

  const ExampleTask({
    required this.key,
    required this.lang,
    required this.title,
    required this.tools,
    required this.prompt,
    this.systemPrompt,
    this.note,
    this.requiresConfig = const [],
  });

  factory ExampleTask.fromJson(Map<String, dynamic> json) {
    final rawTools = json['tools'];
    final List<String> tools;
    if (rawTools is List) {
      tools = rawTools.cast<String>();
    } else if (rawTools is String) {
      // Legacy: comma-separated string
      tools = rawTools.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    } else {
      tools = [];
    }

    final rawRequires = json['requiresConfig'];
    final List<String> requires;
    if (rawRequires is List) {
      requires = rawRequires.cast<String>();
    } else {
      requires = [];
    }

    return ExampleTask(
      key: json['key'] as String? ?? '',
      lang: json['lang'] as String? ?? 'en',
      title: json['title'] as String? ?? json['key'] as String? ?? '',
      tools: tools,
      prompt: json['prompt'] as String? ?? '',
      systemPrompt: json['system_prompt'] as String?,
      note: json['note'] as String?,
      requiresConfig: requires,
    );
  }
}

/// Loads example tasks from the bundled JSON asset.
class ExampleTasksService {
  static const _assetPath = 'assets/icons/example_tasks.json';

  /// Load and parse all example tasks from the asset bundle.
  static Future<List<ExampleTask>> load() async {
    final raw = await rootBundle.loadString(_assetPath);
    final data = jsonDecode(raw) as List<dynamic>;
    return data.map((e) => ExampleTask.fromJson(e as Map<String, dynamic>)).toList();
  }
}
