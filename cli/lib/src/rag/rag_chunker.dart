/// Represents a single text chunk produced by the chunker.
class DocumentChunk {
  final int index;
  final String text;
  final int tokenCount;
  final int startLine;
  final int endLine;

  DocumentChunk({
    required this.index,
    required this.text,
    required this.tokenCount,
    this.startLine = 1,
    this.endLine = 1,
  });
}

/// Sliding-window text chunker designed for document indexing.
class RagChunker {
  /// Splits [text] into chunks of approximately [chunkSize] characters with
  /// [chunkOverlap] overlap, respecting paragraph and line breaks where possible.
  static List<DocumentChunk> splitText({
    required String text,
    int chunkSize = 600,
    int chunkOverlap = 100,
  }) {
    if (text.trim().isEmpty) return [];

    if (text.length <= chunkSize) {
      return [
        DocumentChunk(
          index: 0,
          text: text.trim(),
          tokenCount: (text.length / 4).ceil(),
          startLine: 1,
          endLine: 1 + '\n'.allMatches(text).length,
        ),
      ];
    }

    final chunks = <DocumentChunk>[];
    int start = 0;
    int chunkIndex = 0;

    while (start < text.length) {
      int end = start + chunkSize;
      if (end >= text.length) {
        end = text.length;
      } else {
        // Try to break at a paragraph boundary, sentence, or whitespace
        final searchWindow = text.substring(
          (end - 100).clamp(start, text.length),
          end,
        );
        final paraBreak = searchWindow.lastIndexOf('\n\n');
        if (paraBreak != -1) {
          end = (end - 100) + paraBreak + 2;
        } else {
          final lineBreak = searchWindow.lastIndexOf('\n');
          if (lineBreak != -1) {
            end = (end - 100) + lineBreak + 1;
          } else {
            final space = searchWindow.lastIndexOf(' ');
            if (space != -1) {
              end = (end - 100) + space + 1;
            }
          }
        }
      }

      final chunkContent = text.substring(start, end);
      final trimmed = chunkContent.trim();
      if (trimmed.isNotEmpty) {
        final startLine = 1 + '\n'.allMatches(text.substring(0, start)).length;
        final endLine = startLine + '\n'.allMatches(chunkContent).length;
        chunks.add(
          DocumentChunk(
            index: chunkIndex++,
            text: trimmed,
            tokenCount: (trimmed.length / 4).ceil(),
            startLine: startLine,
            endLine: endLine,
          ),
        );
      }

      if (end >= text.length) break;

      // Advance start with overlap
      start = end - chunkOverlap;
      if (start <= (chunks.isNotEmpty ? end - chunkSize : 0)) {
        start = end;
      }
    }

    return chunks;
  }
}
