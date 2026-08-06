import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class SkillGalleryDialog extends StatefulWidget {
  final void Function(List<Map<String, dynamic>> selectedSkills) onImport;
  const SkillGalleryDialog({super.key, required this.onImport});

  @override
  State<SkillGalleryDialog> createState() => _SkillGalleryDialogState();
}

class _SkillGalleryDialogState extends State<SkillGalleryDialog> {
  List<_SkillEntry> _entries = [];
  bool _loading = false;
  String? _error;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  final _selected = <String>{};
  bool _importing = false;
  final _apiCtrl = TextEditingController(
    text: 'https://openskills.space/api/skills',
  );

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(
      () =>
          setState(() => _searchQuery = _searchCtrl.text.trim().toLowerCase()),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _apiCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchSkills() async {
    final url = _apiCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Enter an API endpoint URL.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _entries = [];
    });
    try {
      debugPrint('[SkillGallery] Fetching: $url');
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception(
          'HTTP ${response.statusCode}\nURL: $url\n${response.body}',
        );
      }
      final decoded = jsonDecode(response.body);
      final List<dynamic> list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map<String, dynamic>) {
        final possibleList =
            decoded['skills'] ??
            decoded['data'] ??
            decoded['items'] ??
            decoded['results'];
        if (possibleList is List) {
          list = possibleList;
        } else {
          list = [decoded];
        }
      } else {
        list = [];
      }
      final entries = <_SkillEntry>[];
      // Log first item structure for debugging
      if (list.isNotEmpty) {
        debugPrint(
          '[SkillGallery] First item keys: ${(list.first as Map).keys.toList()}',
        );
        debugPrint('[SkillGallery] First item: ${jsonEncode(list.first)}');
      }

      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final name = (item['name'] ?? item['title'] ?? '').toString();
        final desc = (item['description'] ?? item['desc'] ?? '').toString();
        final skillId = (item['id'] ?? item['skillId'] ?? '').toString();
        final downloadUrl =
            (item['download_url'] ??
                    item['downloadUrl'] ??
                    item['url'] ??
                    item['file_url'] ??
                    item['raw_url'] ??
                    '')
                .toString();
        final content =
            (item['content'] ??
                    item['skill_content'] ??
                    item['file_content'] ??
                    item['body'])
                ?.toString();
        entries.add(
          _SkillEntry(
            id: name.isNotEmpty ? name : 'skill_${entries.length}',
            name: name.isNotEmpty ? name : 'Skill ${entries.length + 1}',
            description: desc,
            url: downloadUrl,
            rawContent: content,
            skillId: skillId.isNotEmpty ? skillId : null,
          ),
        );
      }
      entries.sort((a, b) => a.name.compareTo(b.name));
      if (mounted) {
        setState(() {
          _entries = entries;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[SkillGallery] Error: $e');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  List<_SkillEntry> get _filtered {
    if (_searchQuery.isEmpty) return _entries;
    return _entries
        .where(
          (e) =>
              e.name.toLowerCase().contains(_searchQuery) ||
              e.description.toLowerCase().contains(_searchQuery),
        )
        .toList();
  }

  Future<void> _importSelected() async {
    final selected = _entries.where((e) => _selected.contains(e.id)).toList();
    if (selected.isEmpty) return;
    setState(() => _importing = true);
    final apiBaseUrl = _apiCtrl.text.trim().replaceAll(
      RegExp(r'/api/skills$'),
      '',
    );

    final results = <Map<String, dynamic>>[];
    for (final e in selected) {
      try {
        debugPrint(
          '[SkillGallery] Importing skill "${e.name}", url="${e.url}", hasContent=${e.rawContent != null}, skillId=${e.skillId}',
        );
        if (e.rawContent != null && e.rawContent!.isNotEmpty) {
          results.add({
            'bytes': utf8.encode(e.rawContent!),
            'filename': '${e.name}.md',
          });
        } else if (e.url.isNotEmpty) {
          final resp = await http.get(Uri.parse(e.url));
          if (resp.statusCode == 200) {
            results.add({
              'bytes': resp.bodyBytes,
              'filename': e.url.split('/').last,
            });
          } else {
            debugPrint(
              '[SkillGallery] Failed to download skill from ${e.url}, HTTP status ${resp.statusCode}',
            );
          }
        } else if (e.skillId != null && e.skillId!.isNotEmpty) {
          // Fetch skill files via /api/skills/{id}/files
          final filesUrl = '$apiBaseUrl/api/skills/${e.skillId}/files';
          debugPrint('[SkillGallery] Fetching files from: $filesUrl');
          final filesResp = await http.get(Uri.parse(filesUrl));
          if (filesResp.statusCode == 200) {
            final filesData = jsonDecode(filesResp.body);
            final List<dynamic> files = filesData['files'] ?? [];

            // Collect .md files, preferring SKILL.md / skills.md as the
            // primary skill definition.  Non-markdown files (scripts, etc.)
            // are skipped — use the file-picker ZIP import for those.
            String? bestMdName;
            String? bestMdContent;
            String? fallbackMdName;
            String? fallbackMdContent;

            for (final file in files) {
              if (file is! Map<String, dynamic>) continue;
              final fileName = (file['name'] ?? file['path'] ?? '').toString();
              if (!fileName.toLowerCase().endsWith('.md')) continue;
              final fileContent = (file['content'] ?? '').toString();
              if (fileContent.isEmpty) continue;
              final lower = fileName.toLowerCase();
              if (lower == 'skill.md' || lower == 'skills.md') {
                bestMdName = fileName;
                bestMdContent = fileContent;
                break; // prefer the canonical skill definition
              }
              fallbackMdName ??= fileName;
              fallbackMdContent ??= fileContent;
            }

            final mdName = bestMdName ?? fallbackMdName;
            final mdContent = bestMdContent ?? fallbackMdContent;

            if (mdName != null && mdContent != null) {
              results.add({
                'bytes': utf8.encode(mdContent),
                'filename': mdName,
              });
            } else {
              debugPrint(
                '[SkillGallery] No .md file found for skill "${e.name}"',
              );
            }
          } else {
            debugPrint(
              '[SkillGallery] Failed to fetch files for "${e.name}" from $filesUrl, HTTP status ${filesResp.statusCode}',
            );
          }
        } else {
          debugPrint(
            '[SkillGallery] Skill "${e.name}" has neither rawContent, url, nor skillId',
          );
        }
      } catch (err) {
        debugPrint('[SkillGallery] Error importing "${e.name}": $err');
      }
    }
    if (results.isEmpty) {
      debugPrint(
        '[SkillGallery] Warning: No skills were successfully downloaded/prepared for import.',
      );
    }
    if (mounted) setState(() => _importing = false);
    widget.onImport(results);
  }

  void _toggleAll(bool? val) {
    setState(() {
      if (val == true) {
        _selected.addAll(_filtered.map((e) => e.id));
      } else {
        _selected.removeAll(_filtered.map((e) => e.id));
      }
    });
  }

  Widget _buildContent() {
    final filtered = _filtered;
    final allSelected =
        filtered.isNotEmpty && filtered.every((e) => _selected.contains(e.id));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _apiCtrl,
                readOnly: true,
                decoration: const InputDecoration(
                  hintText: 'https://openskills.space/api/skills',
                  labelText: 'API Endpoint',
                  border: OutlineInputBorder(),
                  isDense: true,
                  prefixIcon: Icon(Icons.cloud),
                ),
                onSubmitted: (_) => _fetchSkills(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _fetchSkills,
              icon: const Icon(Icons.search, size: 16),
              label: const Text('Fetch'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                minimumSize: Size.zero,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_entries.isNotEmpty || _loading || _error != null) ...[
          TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search skills...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => _searchCtrl.clear(),
                    )
                  : null,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            dense: true,
            value: allSelected,
            onChanged: _toggleAll,
            title: Text(
              'Select all (${filtered.length} skills)',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const Divider(height: 1),
        ],
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 40,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          _error!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed: _fetchSkills,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : _entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome,
                        size: 40,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap Fetch to load skills',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                )
              : ListView(
                  children: filtered.map((e) {
                    final isSelected = _selected.contains(e.id);
                    return CheckboxListTile(
                      dense: true,
                      value: isSelected,
                      onChanged: (v) => setState(
                        () => v == true
                            ? _selected.add(e.id)
                            : _selected.remove(e.id),
                      ),
                      title: Text(
                        e.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: e.description.isNotEmpty
                          ? Text(
                              e.description,
                              style: const TextStyle(fontSize: 11),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                      secondary: Icon(
                        isSelected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: isSelected ? Colors.green : Colors.grey,
                        size: 20,
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    if (isMobile) {
      return Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Skill Gallery'),
            actions: [
              FilledButton.icon(
                onPressed: (_selected.isEmpty || _importing)
                    ? null
                    : _importSelected,
                icon: _importing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download, size: 16),
                label: Text(
                  _importing ? 'Importing...' : 'Import ${_selected.length}',
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  minimumSize: Size.zero,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: _buildContent(),
          ),
        ),
      );
    }

    return AlertDialog(
      title: const Text('Skill Gallery'),
      content: SizedBox(
        width: 550,
        height: MediaQuery.of(context).size.height * 0.7,
        child: _buildContent(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: (_selected.isEmpty || _importing) ? null : _importSelected,
          icon: _importing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download, size: 16),
          label: Text(
            _importing ? 'Importing...' : 'Import ${_selected.length} selected',
          ),
        ),
      ],
    );
  }
}

class _SkillEntry {
  final String id;
  final String name;
  final String description;
  final String url;
  final String? rawContent;
  final String?
  skillId; // API skill ID for fetching files via /api/skills/{id}/files
  const _SkillEntry({
    required this.id,
    required this.name,
    this.description = '',
    this.url = '',
    this.rawContent,
    this.skillId,
  });
}
