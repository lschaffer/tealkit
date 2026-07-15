import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

/// HTML renderer widget using flutter_widget_from_html.
/// Replaces flutter_inappwebview-based rendering.
class HtmlRenderer extends StatelessWidget {
  final String html;

  const HtmlRenderer({super.key, required this.html});

  @override
  Widget build(BuildContext context) {
    return HtmlWidget(
      html,
      renderMode: RenderMode.column,
      textStyle: Theme.of(context).textTheme.bodyMedium,
      onTapUrl: (url) {
        // Could launch URL here if needed
        return true;
      },
    );
  }
}
