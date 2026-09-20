// Copyright (c) TealKit. All rights reserved.
//
// Compatibility shim for `flutter_markdown_plus` after the Flutter 3.47
// `material_ui` / `cupertino_ui` decoupling.
//
// Background
// ----------
// `flutter_markdown_plus` still imports `package:flutter/material.dart` (the
// legacy, SDK-bundled Material library). Its style factory
//
//     MarkdownStyleSheet.fromTheme(ThemeData theme)   // legacy ThemeData
//
// therefore expects the *legacy* `ThemeData`, while this app now imports
// `package:material_ui/material_ui.dart`, whose `ThemeData` is a different class
// (defined in `material_ui/lib/src/theme_data.dart`). Passing one into the other
// fails to compile:
//
//     argument_type_not_assignable:
//     'ThemeData (material_ui)' can't be assigned to 'ThemeData (flutter/material)'
//
// Because the stylesheet is built by the *app*, not by the package, no newer
// version of the package can fix this: the mismatch is at the call site.
//
// Solution
// --------
// [markdownStyleSheetFromTheme] is a 1:1 port of `MarkdownStyleSheet.fromTheme()`
// that reads the values from `material_ui`'s `ThemeData` and only uses
// widget-layer types (`TextStyle`, `Color`, `BoxDecoration`, `Border`, ...).
// Those types are shared between both libraries (`material_ui` re-exports
// `package:flutter/widgets.dart`), so they are accepted by
// `flutter_markdown_plus` without any legacy import coming back into the app.
//
// The visual result is identical to the pre-migration output, because every
// value (`textTheme.*`, `cardTheme.color`, `dividerColor`, `colorScheme.*`) is
// read from the same `ThemeData` object that was previously passed to
// `fromTheme`.
//
// When `flutter_markdown_plus` ships a release that targets
// `package:material_ui`, this file can be deleted and the call sites can go back
// to `MarkdownStyleSheet.fromTheme(Theme.of(context))`.

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_ui/material_ui.dart';

/// Returns the markdown style sheet matching the active `material_ui` theme.
///
/// [bodyColor] defaults to `ColorScheme.onSurfaceVariant`, which is the body
/// colour the markdown views in this app use (previously applied via
/// `Theme.of(context).copyWith(textTheme: ...apply(bodyColor: ...))` before
/// calling `MarkdownStyleSheet.fromTheme`).
MarkdownStyleSheet appMarkdownStyleSheet(
  BuildContext context, {
  Color? bodyColor,
}) {
  return markdownStyleSheetFromTheme(Theme.of(context), bodyColor: bodyColor);
}

/// Port of `MarkdownStyleSheet.fromTheme()` for `package:material_ui`'s
/// [ThemeData].
///
/// Only widget-layer types are used here, so the result can be handed to
/// `flutter_markdown_plus` (which still consumes the legacy Material library)
/// without mixing the two `ThemeData` classes.
MarkdownStyleSheet markdownStyleSheetFromTheme(
  ThemeData theme, {
  Color? bodyColor,
}) {
  final ColorScheme colorScheme = theme.colorScheme;
  final TextTheme textTheme = theme.textTheme.apply(
    bodyColor: bodyColor ?? colorScheme.onSurfaceVariant,
  );

  // `MarkdownStyleSheet.fromTheme` uses `theme.cardTheme.color ?? theme.cardColor`
  // for block decorations and `theme.cardTheme.color` (nullable) for inline code.
  // `ThemeData.cardColor` is deprecated, its Material 3 equivalent is
  // `ColorScheme.surface`.
  final Color? cardThemeColor = theme.cardTheme.color;
  final Color cardColor = cardThemeColor ?? colorScheme.surface;

  final TextStyle body = textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
  final double bodyFontSize = body.fontSize ?? 14;

  return MarkdownStyleSheet(
    a: const TextStyle(color: Colors.blue),
    p: body,
    pPadding: EdgeInsets.zero,
    code: body.copyWith(
      backgroundColor: cardThemeColor,
      fontFamily: 'monospace',
      fontSize: bodyFontSize * 0.85,
    ),
    h1: textTheme.headlineSmall,
    h1Padding: EdgeInsets.zero,
    h2: textTheme.titleLarge,
    h2Padding: EdgeInsets.zero,
    h3: textTheme.titleMedium,
    h3Padding: EdgeInsets.zero,
    h4: textTheme.bodyLarge,
    h4Padding: EdgeInsets.zero,
    h5: textTheme.bodyLarge,
    h5Padding: EdgeInsets.zero,
    h6: textTheme.bodyLarge,
    h6Padding: EdgeInsets.zero,
    em: const TextStyle(fontStyle: FontStyle.italic),
    strong: const TextStyle(fontWeight: FontWeight.bold),
    del: const TextStyle(decoration: TextDecoration.lineThrough),
    blockquote: body,
    img: body,
    checkbox: body.copyWith(color: colorScheme.primary),
    blockSpacing: 8.0,
    listIndent: 24.0,
    listBullet: body,
    listBulletPadding: const EdgeInsets.only(right: 4),
    tableHead: const TextStyle(fontWeight: FontWeight.w600),
    tableBody: body,
    tableHeadAlign: TextAlign.center,
    tablePadding: const EdgeInsets.only(bottom: 4.0),
    tableBorder: TableBorder.all(color: theme.dividerColor),
    tableColumnWidth: const FlexColumnWidth(),
    tableCellsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    tableCellsDecoration: const BoxDecoration(),
    blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    blockquoteDecoration: BoxDecoration(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(3),
      border: Border(left: BorderSide(color: colorScheme.primary, width: 3)),
    ),
    codeblockPadding: const EdgeInsets.all(8.0),
    codeblockDecoration: BoxDecoration(
      color: cardColor,
      borderRadius: BorderRadius.circular(2.0),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(width: 5.0, color: theme.dividerColor)),
    ),
  );
}
