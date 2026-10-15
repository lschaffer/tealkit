import 'dart:io';

import 'package:dart_mcp_core/dart_mcp_core.dart';
import 'package:test/test.dart';

void main() {
  group('BG95M3 LTE .h Header File Reading Tests', () {
    late Directory tempDir;
    late File fixtureFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('bg95m3_test_');
      fixtureFile = File('test/fixtures/BG95M3__LTE.h');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('FsReadFileTool successfully reads BG95M3__LTE.h fixture', () async {
      expect(fixtureFile.existsSync(), isTrue);

      final readTool = FsReadFileTool(workingDirectory: Directory.current.path);
      final result = await readTool.execute({
        'path': 'test/fixtures/BG95M3__LTE.h',
      });

      expect(
        result.isError,
        isFalse,
        reason: 'Reading BG95M3__LTE.h should not error',
      );
      expect(result.content, isNotEmpty);
      final text = result.content.first.text;

      // Verify core elements of the header are present
      expect(text, contains('_BG95M3__LTE_H_'));
      expect(text, contains('__LTE_ERROR__NO_ERROR__'));
      expect(text, contains('struct LTE_Info'));
      expect(text, contains('Init_BG95M3'));
    });

    test(
      'FsReadFileTool reads BG95M3__LTE.h with pagination (startLine and endLine)',
      () async {
        final readTool = FsReadFileTool(
          workingDirectory: Directory.current.path,
        );
        final result = await readTool.execute({
          'path': 'test/fixtures/BG95M3__LTE.h',
          'startLine': 150,
          'endLine': 240,
        });

        expect(result.isError, isFalse);
        final text = result.content.first.text;
        expect(text, contains('LTE_OpInfo_t'));
        expect(text, contains('sSCI__SINR'));
      },
    );

    test(
      'FsReadFileTool successfully reads raw Windows-1252 / ISO-8859-1 encoded C header with invalid UTF-8 bytes',
      () async {
        final targetFile = File('${tempDir.path}/BG95M3_legacy_encoding.h');

        // Create a header with Windows-1252 / ANSI bytes:
        // 0x96 (en-dash '–')
        // 0xB0 (degree '°')
        // 0xB7 (middle dot '·')
        // 0xE4 ('ä')
        // 0xFC ('ü')
        final headerContent = fixtureFile.readAsStringSync();
        // Replace with raw byte sequences that are invalid UTF-8
        final latin1Bytes = <int>[];
        for (final codeUnit in headerContent.codeUnits) {
          if (codeUnit > 255) {
            latin1Bytes.add(0x96); // en-dash
          } else {
            latin1Bytes.add(codeUnit);
          }
        }
        // Insert non-UTF8 German comment with umlauts
        final extraBytes = [
          0x0A, 0x2F, 0x2F, 0x20, 0x54, 0x65, 0x73, 0x74, 0x3A, 0x20,
          0xE4, 0xF6, 0xFC, 0xDF, 0x20, // äöüß in ISO-8859-1 (invalid UTF-8)
          0x96, 0x20, // en-dash
          0xB0, 0x43, 0x0A, // °C
        ];
        targetFile.writeAsBytesSync([...latin1Bytes, ...extraBytes]);

        final readTool = FsReadFileTool(workingDirectory: tempDir.path);
        final result = await readTool.execute({
          'path': 'BG95M3_legacy_encoding.h',
        });

        expect(
          result.isError,
          isFalse,
          reason: 'Must not throw FormatException on non-UTF-8 bytes',
        );
        expect(result.content.first.text, contains('_BG95M3__LTE_H_'));
        expect(result.content.first.text, contains('struct LTE_Info'));
      },
    );

    test(
      'FsReplaceTextTool can safely edit the BG95M3 header without corrupting file',
      () async {
        final targetFile = File('${tempDir.path}/BG95M3_edit_test.h');
        targetFile.writeAsStringSync(fixtureFile.readAsStringSync());

        final replaceTool = FsReplaceTextTool(workingDirectory: tempDir.path);
        final result = await replaceTool.execute({
          'path': 'BG95M3_edit_test.h',
          'search': '#define __LTE_OPERATOR_LEN__\t\t\t16',
          'replace': '#define __LTE_OPERATOR_LEN__\t\t\t32',
        });

        expect(result.isError, isFalse);

        final readTool = FsReadFileTool(workingDirectory: tempDir.path);
        final verifyResult = await readTool.execute({
          'path': 'BG95M3_edit_test.h',
        });
        expect(verifyResult.isError, isFalse);
        expect(
          verifyResult.content.first.text,
          contains('#define __LTE_OPERATOR_LEN__\t\t\t32'),
        );
      },
    );
  });
}
