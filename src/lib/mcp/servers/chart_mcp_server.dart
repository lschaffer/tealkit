import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../internal_mcp_server.dart';

class ChartMcpServer extends InternalMcpServer {
  @override
  String get type => 'chart';

  @override
  String get displayName => 'Chart generator';

  @override
  String get description => 'Generate PNG charts: line, bar, area, pie, scatter, histogram, and statistics_summary (4-in-1 dashboard).';

  @override
  String get iconName => 'insert_chart';

  @override
  Map<String, dynamic> get initParamSchema => {'type': 'object', 'properties': {}, 'required': []};

  @override
  Map<String, dynamic> get defaultInitParams => const {};

  @override
  String get defaultSystemPrompt =>
      'Use create_chart_png to build PNG charts. Supported chartTypes: line, bar, area, pie, scatter, histogram, statistics_summary. '
      'Provide xAxis labels, series data, optional title, xAxisTitle, yAxisTitle, xAxisRotate, yAxisRotate, and lineColors array. '
      'Use statistics_summary for a 4-panel dashboard (line+bar+pie+scatter) from one dataset.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {}

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'create_chart_png',
      description:
          'Generate a PNG chart from x-axis labels and numeric data series. '
          'Supported chart types: line, bar, area, pie, scatter, histogram, statistics_summary.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'chartType': {
            'type': 'string',
            'enum': ['line', 'bar', 'area', 'pie', 'scatter', 'histogram', 'statistics_summary'],
            'default': 'line',
            'description':
                'Chart style. "area" is a filled line chart. "pie" uses the first series. '
                '"scatter" plots points. "histogram" bins the first series values. '
                '"statistics_summary" renders a 4-panel dashboard (line, bar, pie, scatter).',
          },
          'xAxis': {
            'type': 'array',
            'description': 'X-axis labels (not required for pie/histogram/statistics_summary).',
            'items': {'type': 'string'},
          },
          'series': {
            'type': 'array',
            'description': 'Series definitions with name, numeric data array, and optional colorHex.',
            'items': {
              'type': 'object',
              'properties': {
                'name': {'type': 'string'},
                'data': {
                  'type': 'array',
                  'items': {'type': 'number'},
                },
                'colorHex': {'type': 'string', 'description': 'Optional color hex, e.g. #1E88E5.'},
              },
              'required': ['name', 'data'],
            },
          },
          'yAxisData': {'type': 'object', 'description': 'Alternative multi-series input: {"seriesName": [v1,v2,...]}.'},
          'yAxisSeries': {'type': 'object', 'description': 'Alias for yAxisData.'},
          'chartTitle': {'type': 'string', 'description': 'Chart title shown at top.'},
          'title': {'type': 'string', 'description': 'Alias for chartTitle.'},
          'xAxisTitle': {'type': 'string', 'description': 'X-axis label.'},
          'yAxisTitle': {'type': 'string', 'description': 'Y-axis label.'},
          'xAxisRotate': {
            'type': 'number',
            'default': 0,
            'description': 'Rotation angle in degrees for x-axis tick labels (e.g. 45 or -45).',
          },
          'yAxisRotate': {'type': 'number', 'default': -90, 'description': 'Rotation angle in degrees for the y-axis title (default -90).'},
          'lineColors': {
            'type': 'array',
            'description': 'Array of hex color strings to use for series in order, e.g. ["#1E88E5","#E53935"].',
            'items': {'type': 'string'},
          },
          'bins': {'type': 'integer', 'default': 10, 'description': 'Number of bins for histogram chart type.'},
          'fileName': {'type': 'string', 'description': 'Optional output file name (no extension needed).'},
          'width': {'type': 'integer', 'default': 1000, 'description': 'Image width in px (min 600, max 2400).'},
          'height': {'type': 'integer', 'default': 640, 'description': 'Image height in px (min 400, max 1600).'},
        },
        'required': [],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    switch (toolName) {
      case 'create_chart_png':
        return _createChartPng(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  Future<Map<String, dynamic>> _createChartPng(Map<String, dynamic> args) async {
    final chartType = (args['chartType'] as String? ?? 'line').trim().toLowerCase();
    final xAxisRaw = args['xAxis'] as List<dynamic>?;
    final seriesRaw = args['series'] as List<dynamic>?;

    const supportedTypes = {'line', 'bar', 'area', 'pie', 'scatter', 'histogram', 'statistics_summary'};
    if (!supportedTypes.contains(chartType)) {
      return {'error': 'Unsupported chartType "$chartType". Use one of: ${supportedTypes.join(", ")}.'};
    }

    final width = ((args['width'] as num?)?.toInt() ?? 1000).clamp(600, 2400);
    final height = ((args['height'] as num?)?.toInt() ?? 640).clamp(400, 1600);

    // Resolve title (support both "title" and "chartTitle")
    final chartTitle = ((args['title'] as String?) ?? (args['chartTitle'] as String?))?.trim();
    final xAxisTitle = (args['xAxisTitle'] as String?)?.trim() ?? '';
    final yAxisTitle = (args['yAxisTitle'] as String?)?.trim() ?? '';
    final xAxisRotate = (args['xAxisRotate'] as num?)?.toDouble() ?? 0.0;
    final yAxisRotate = (args['yAxisRotate'] as num?)?.toDouble() ?? -90.0;
    final bins = ((args['bins'] as num?)?.toInt() ?? 10).clamp(2, 100);
    final fileName = _normalizePngFileName((args['fileName'] as String?)?.trim());

    // lineColors overrides default palette per series
    final lineColorsRaw = args['lineColors'] as List<dynamic>?;
    final lineColors = lineColorsRaw?.map((c) => _parseColor(c.toString())).whereType<Color>().toList() ?? <Color>[];

    final xAxis = xAxisRaw?.map((e) => e.toString()).toList() ?? <String>[];
    final parsedSeries = _extractSeries(args, rawSeries: seriesRaw, lineColors: lineColors);

    // Pie and histogram only need one series; statistics_summary and others need at least one
    final needsXAxis = chartType == 'line' || chartType == 'bar' || chartType == 'area' || chartType == 'scatter';
    if (needsXAxis && xAxis.isEmpty) {
      return {'error': 'Parameter "xAxis" is required for "$chartType" chart type.'};
    }
    if (parsedSeries.isEmpty) {
      return {
        'error':
            'No valid series found. Provide "series" or "yAxisData"/"yAxisSeries". '
            'Example: series: [{"name":"A","data":[1,2,3]}]',
      };
    }

    Uint8List bytes;
    int pointCount = 0;
    if (chartType == 'statistics_summary') {
      final minLength = needsXAxis ? _minDataLength(xAxis.length, parsedSeries) : parsedSeries.first.data.length;
      pointCount = minLength;
      bytes = await _drawStatisticsSummary(
        xAxis: xAxis.isEmpty ? List.generate(parsedSeries.first.data.length, (i) => '${i + 1}') : xAxis,
        series: parsedSeries,
        chartTitle: chartTitle,
        xAxisTitle: xAxisTitle,
        yAxisTitle: yAxisTitle,
        width: width,
        height: height,
      );
    } else if (chartType == 'pie') {
      pointCount = parsedSeries.first.data.length;
      bytes = await _drawPieChart(series: parsedSeries, xLabels: xAxis, chartTitle: chartTitle, width: width, height: height);
    } else if (chartType == 'histogram') {
      pointCount = parsedSeries.first.data.length;
      bytes = await _drawHistogram(
        series: parsedSeries.first,
        bins: bins,
        chartTitle: chartTitle,
        xAxisTitle: xAxisTitle,
        yAxisTitle: yAxisTitle.isEmpty ? 'Count' : yAxisTitle,
        xAxisRotate: xAxisRotate,
        yAxisRotate: yAxisRotate,
        width: width,
        height: height,
      );
    } else {
      final minLength = _minDataLength(xAxis.length, parsedSeries);
      if (minLength < 2) {
        return {'error': 'At least 2 aligned data points are required across xAxis and series.'};
      }
      pointCount = minLength;
      final clippedXAxis = xAxis.take(minLength).toList();
      final clippedSeries = parsedSeries
          .map((s) => _ChartSeriesData(name: s.name, data: s.data.take(minLength).toList(), color: s.color))
          .toList();
      bytes = await _drawChart(
        chartType: chartType,
        xAxis: clippedXAxis,
        series: clippedSeries,
        chartTitle: chartTitle,
        xAxisTitle: xAxisTitle,
        yAxisTitle: yAxisTitle,
        xAxisRotate: xAxisRotate,
        yAxisRotate: yAxisRotate,
        width: width,
        height: height,
      );
    }

    return {
      'success': true,
      'message': 'Chart PNG generated successfully.',
      'fileName': fileName,
      'mimeType': 'image/png',
      'encoding': 'base64',
      'size': bytes.length,
      'content': base64Encode(bytes),
      'meta': {'chartType': chartType, 'pointCount': pointCount, 'seriesCount': parsedSeries.length},
    };
  }

  List<_ChartSeriesData> _extractSeries(Map<String, dynamic> args, {required List<dynamic>? rawSeries, List<Color> lineColors = const []}) {
    final series = <_ChartSeriesData>[];

    if (rawSeries != null && rawSeries.isNotEmpty) {
      series.addAll(_parseSeries(rawSeries, lineColors: lineColors));
    }

    final yAxisData = (args['yAxisData'] ?? args['yAxisSeries']);
    if (yAxisData is Map) {
      final normalized = <Map<String, dynamic>>[];
      for (final entry in yAxisData.entries) {
        normalized.add({'name': entry.key.toString(), 'data': entry.value});
      }
      series.addAll(_parseSeries(normalized, lineColors: lineColors, startIndex: series.length));
    }

    const knownMetricKeys = [
      'temperature',
      'feelsLike',
      'apparentTemperature',
      'humidity',
      'precipitation',
      'windSpeed',
      'windGust',
      'pressure',
    ];
    for (final key in knownMetricKeys) {
      final val = args[key];
      if (val is List && val.isNotEmpty) {
        series.addAll(
          _parseSeries(
            [
              {'name': key, 'data': val},
            ],
            lineColors: lineColors,
            startIndex: series.length,
          ),
        );
      }
    }

    final deduped = <String, _ChartSeriesData>{};
    for (final item in series) {
      deduped[item.name] = item;
    }
    return deduped.values.toList();
  }

  List<_ChartSeriesData> _parseSeries(List<dynamic> rawSeries, {List<Color> lineColors = const [], int startIndex = 0}) {
    final defaults = <Color>[
      const Color(0xFF1E88E5),
      const Color(0xFFE53935),
      const Color(0xFF43A047),
      const Color(0xFF8E24AA),
      const Color(0xFFFB8C00),
      const Color(0xFF00897B),
    ];

    Color paletteColor(int index) {
      final i = startIndex + index;
      if (lineColors.isNotEmpty) return lineColors[i % lineColors.length];
      return defaults[i % defaults.length];
    }

    final parsed = <_ChartSeriesData>[];
    for (var index = 0; index < rawSeries.length; index++) {
      final item = rawSeries[index];
      if (item is! Map) continue;

      final name = (item['name'] as String?)?.trim();
      final dataRaw = item['data'];
      if (name == null || name.isEmpty || dataRaw is! List || dataRaw.isEmpty) continue;

      final data = <double>[];
      for (final value in dataRaw) {
        final numeric = value is num ? value.toDouble() : double.tryParse(value.toString());
        if (numeric != null) data.add(numeric);
      }
      if (data.isEmpty) continue;

      final colorHex = (item['colorHex'] as String?)?.trim();
      final color = (colorHex == null || colorHex.isEmpty) ? paletteColor(index) : _parseColor(colorHex) ?? paletteColor(index);

      parsed.add(_ChartSeriesData(name: name, data: data, color: color));
    }

    return parsed;
  }

  int _minDataLength(int xAxisLength, List<_ChartSeriesData> series) {
    var minLen = xAxisLength;
    for (final s in series) {
      if (s.data.length < minLen) minLen = s.data.length;
    }
    return minLen;
  }

  Future<Uint8List> _drawChart({
    required String chartType,
    required List<String> xAxis,
    required List<_ChartSeriesData> series,
    required String? chartTitle,
    required String xAxisTitle,
    required String yAxisTitle,
    required double xAxisRotate,
    required double yAxisRotate,
    required int width,
    required int height,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));

    final background = Paint()..color = Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), background);

    // Extra bottom pad when x-labels are rotated
    final xLabelPad = xAxisRotate.abs() > 20 ? 120.0 : 100.0;
    const leftPad = 86.0;
    const rightPad = 26.0;
    const topPad = 64.0;
    final bottomPad = xLabelPad;

    final plotLeft = leftPad;
    final plotTop = topPad;
    final plotRight = width - rightPad;
    final plotBottom = height - bottomPad;
    final plotWidth = plotRight - plotLeft;
    final plotHeight = plotBottom - plotTop;

    final allValues = series.expand((s) => s.data).toList();
    var minY = allValues.reduce(math.min);
    var maxY = allValues.reduce(math.max);

    if (chartType == 'bar') minY = math.min(0, minY);
    if ((maxY - minY).abs() < 0.0001) {
      maxY += 1;
      minY -= 1;
    }

    double mapX(int i) {
      if (xAxis.length <= 1) return plotLeft;
      return plotLeft + (i / (xAxis.length - 1)) * plotWidth;
    }

    double mapY(double value) {
      final ratio = (value - minY) / (maxY - minY);
      return plotBottom - (ratio * plotHeight);
    }

    final axisPaint = Paint()
      ..color = const Color(0xFF6B7280)
      ..strokeWidth = 1.4;

    final gridPaint = Paint()
      ..color = const Color(0xFFE5E7EB)
      ..strokeWidth = 1;

    canvas.drawLine(Offset(plotLeft, plotBottom), Offset(plotRight, plotBottom), axisPaint);
    canvas.drawLine(Offset(plotLeft, plotTop), Offset(plotLeft, plotBottom), axisPaint);

    // Y grid lines + labels
    for (var i = 0; i <= 5; i++) {
      final yValue = minY + ((maxY - minY) * i / 5);
      final y = mapY(yValue);
      canvas.drawLine(Offset(plotLeft, y), Offset(plotRight, y), gridPaint);
      _drawText(canvas, yValue.toStringAsFixed(1), Offset(10, y - 8), const TextStyle(fontSize: 14, color: Color(0xFF374151)));
    }

    // X tick labels (with optional rotation)
    final step = xAxis.length <= 6 ? 1 : (xAxis.length / 6).ceil();
    final indicesDrawn = <int>{};
    for (var i = 0; i < xAxis.length; i += step) {
      indicesDrawn.add(i);
      final x = mapX(i);
      canvas.drawLine(Offset(x, plotBottom), Offset(x, plotBottom + 6), axisPaint);
      _drawXLabel(canvas, xAxis[i], x, plotBottom + 8, xAxisRotate);
    }
    // Always render last label
    if (!indicesDrawn.contains(xAxis.length - 1)) {
      final i = xAxis.length - 1;
      final x = mapX(i);
      canvas.drawLine(Offset(x, plotBottom), Offset(x, plotBottom + 6), axisPaint);
      _drawXLabel(canvas, xAxis[i], x, plotBottom + 8, xAxisRotate);
    }

    switch (chartType) {
      case 'line':
        _renderLine(canvas, series, mapX, mapY, dots: true);
      case 'area':
        _renderArea(canvas, series, mapX, mapY, plotBottom);
      case 'scatter':
        _renderScatter(canvas, series, mapX, mapY);
      case 'bar':
        _renderBar(canvas, series, xAxis, mapX, mapY, plotWidth);
    }

    // Chart title
    if (chartTitle != null && chartTitle.isNotEmpty) {
      _drawText(
        canvas,
        chartTitle,
        const Offset(16, 14),
        const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
        maxWidth: width - 32,
      );
    }

    // X-axis title
    if (xAxisTitle.isNotEmpty) {
      _drawText(
        canvas,
        xAxisTitle,
        Offset((plotLeft + plotRight) / 2 - 80, height - 28),
        const TextStyle(fontSize: 14, color: Color(0xFF374151)),
        maxWidth: 200,
        align: TextAlign.center,
      );
    }

    // Y-axis title (rotated)
    if (yAxisTitle.isNotEmpty) {
      final angleRad = yAxisRotate * math.pi / 180.0;
      canvas.save();
      canvas.translate(22, (plotTop + plotBottom) / 2 + 70);
      canvas.rotate(angleRad);
      _drawText(
        canvas,
        yAxisTitle,
        const Offset(0, 0),
        const TextStyle(fontSize: 14, color: Color(0xFF374151)),
        maxWidth: 160,
        align: TextAlign.center,
      );
      canvas.restore();
    }

    _drawLegend(canvas, series, width: width);

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  // ─── Pie chart ────────────────────────────────────────────────────────────

  Future<Uint8List> _drawPieChart({
    required List<_ChartSeriesData> series,
    required List<String> xLabels,
    required String? chartTitle,
    required int width,
    required int height,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
    canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.white);

    final data = series.first.data;
    final labels = xLabels.isNotEmpty ? xLabels : List.generate(data.length, (i) => '${i + 1}');
    final total = data.fold<double>(0, (a, b) => a + b.abs());
    if (total == 0) {
      _drawText(canvas, 'All values are zero', Offset(width / 2 - 80, height / 2), const TextStyle(fontSize: 16, color: Color(0xFF6B7280)));
    } else {
      // Assign colors per slice
      const palette = [
        Color(0xFF1E88E5),
        Color(0xFFE53935),
        Color(0xFF43A047),
        Color(0xFF8E24AA),
        Color(0xFFFB8C00),
        Color(0xFF00897B),
        Color(0xFFD81B60),
        Color(0xFF546E7A),
        Color(0xFF6D4C41),
        Color(0xFF039BE5),
      ];

      final cx = width * 0.42;
      final cy = height * 0.50;
      final radius = math.min(width * 0.32, height * 0.40);

      var startAngle = -math.pi / 2;
      for (var i = 0; i < data.length; i++) {
        final sweep = (data[i].abs() / total) * 2 * math.pi;
        final color = series.length == 1 ? palette[i % palette.length] : series[i % series.length].color;

        final paint = Paint()..color = color;
        canvas.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: radius), startAngle, sweep, true, paint);

        // Thin white separator
        final sep = Paint()
          ..color = Colors.white
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
        canvas.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: radius), startAngle, sweep, true, sep);

        // Percentage label inside slice
        final midAngle = startAngle + sweep / 2;
        final pct = (data[i].abs() / total * 100);
        if (pct > 4) {
          final lx = cx + math.cos(midAngle) * radius * 0.65;
          final ly = cy + math.sin(midAngle) * radius * 0.65;
          _drawText(
            canvas,
            '${pct.toStringAsFixed(1)}%',
            Offset(lx - 18, ly - 8),
            const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600),
            maxWidth: 52,
            align: TextAlign.center,
          );
        }
        startAngle += sweep;
      }

      // Legend on the right
      var ly = height * 0.18;
      final legendX = cx + radius + 24;
      for (var i = 0; i < data.length && i < labels.length; i++) {
        final color = series.length == 1 ? palette[i % palette.length] : series[i % series.length].color;
        canvas.drawRect(Rect.fromLTWH(legendX, ly, 14, 14), Paint()..color = color);
        _drawText(
          canvas,
          '${labels[i]} (${data[i].toStringAsFixed(1)})',
          Offset(legendX + 18, ly - 1),
          const TextStyle(fontSize: 12, color: Color(0xFF1F2937)),
          maxWidth: width - legendX - 18 - 8,
        );
        ly += 22;
      }
    }

    if (chartTitle != null && chartTitle.isNotEmpty) {
      _drawText(
        canvas,
        chartTitle,
        const Offset(16, 14),
        const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
        maxWidth: width - 32,
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  // ─── Histogram ────────────────────────────────────────────────────────────

  Future<Uint8List> _drawHistogram({
    required _ChartSeriesData series,
    required int bins,
    required String? chartTitle,
    required String xAxisTitle,
    required String yAxisTitle,
    required double xAxisRotate,
    required double yAxisRotate,
    required int width,
    required int height,
  }) async {
    final data = series.data;
    final minV = data.reduce(math.min);
    final maxV = data.reduce(math.max);
    final range = maxV - minV;
    final binWidth = range == 0 ? 1.0 : range / bins;

    final counts = List<int>.filled(bins, 0);
    for (final v in data) {
      var b = ((v - minV) / binWidth).floor();
      if (b >= bins) b = bins - 1;
      counts[b]++;
    }

    final binLabels = List.generate(bins, (i) => (minV + i * binWidth).toStringAsFixed(1));
    final binSeries = [_ChartSeriesData(name: series.name, data: counts.map((c) => c.toDouble()).toList(), color: series.color)];
    final xAxisList = binLabels;

    // Reuse bar chart renderer
    return _drawChart(
      chartType: 'bar',
      xAxis: xAxisList,
      series: binSeries,
      chartTitle: chartTitle,
      xAxisTitle: xAxisTitle.isNotEmpty ? xAxisTitle : series.name,
      yAxisTitle: yAxisTitle,
      xAxisRotate: xAxisRotate,
      yAxisRotate: yAxisRotate,
      width: width,
      height: height,
    );
  }

  // ─── Statistics summary (4-panel matplotlib-style) ────────────────────────

  Future<Uint8List> _drawStatisticsSummary({
    required List<String> xAxis,
    required List<_ChartSeriesData> series,
    required String? chartTitle,
    required String xAxisTitle,
    required String yAxisTitle,
    required int width,
    required int height,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
    canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.white);

    // Overall title
    if (chartTitle != null && chartTitle.isNotEmpty) {
      _drawText(
        canvas,
        chartTitle,
        const Offset(16, 10),
        const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
        maxWidth: width - 32,
      );
    }

    const titleH = 38.0;
    const gap = 14.0;
    final panelW = (width - gap * 3) / 2;
    final panelH = (height - titleH - gap * 3) / 2;

    // Panels: top-left=line, top-right=bar, bottom-left=pie, bottom-right=scatter
    final panels = [
      _PanelSpec(type: 'line', label: 'Line', left: gap, top: titleH + gap),
      _PanelSpec(type: 'bar', label: 'Bar', left: gap * 2 + panelW, top: titleH + gap),
      _PanelSpec(type: 'pie', label: 'Pie', left: gap, top: titleH + gap * 2 + panelH),
      _PanelSpec(type: 'scatter', label: 'Scatter', left: gap * 2 + panelW, top: titleH + gap * 2 + panelH),
    ];

    for (final panel in panels) {
      // Draw panel border
      final panelRect = Rect.fromLTWH(panel.left, panel.top, panelW, panelH);
      canvas.drawRect(
        panelRect,
        Paint()
          ..color = const Color(0xFFF3F4F6)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        panelRect,
        Paint()
          ..color = const Color(0xFFD1D5DB)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );

      // Sub-image for each panel
      final subBytes = await _drawPanelPng(
        type: panel.type,
        xAxis: xAxis,
        series: series,
        xAxisTitle: xAxisTitle,
        yAxisTitle: yAxisTitle,
        width: panelW.round(),
        height: panelH.round(),
        label: panel.label,
      );

      final codec = await ui.instantiateImageCodec(subBytes);
      final frame = await codec.getNextFrame();
      canvas.drawImageRect(frame.image, Rect.fromLTWH(0, 0, panelW, panelH), panelRect, Paint());
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  Future<Uint8List> _drawPanelPng({
    required String type,
    required List<String> xAxis,
    required List<_ChartSeriesData> series,
    required String xAxisTitle,
    required String yAxisTitle,
    required int width,
    required int height,
    required String label,
  }) async {
    if (type == 'pie') {
      return _drawPieChart(series: series, xLabels: xAxis, chartTitle: label, width: width, height: height);
    }
    return _drawChart(
      chartType: type,
      xAxis: xAxis,
      series: series,
      chartTitle: label,
      xAxisTitle: xAxisTitle,
      yAxisTitle: yAxisTitle,
      xAxisRotate: 0,
      yAxisRotate: -90,
      width: width,
      height: height,
    );
  }

  // ─── Low-level renderers ──────────────────────────────────────────────────

  void _renderLine(
    Canvas canvas,
    List<_ChartSeriesData> series,
    double Function(int) mapX,
    double Function(double) mapY, {
    bool dots = true,
  }) {
    for (final line in series) {
      final path = Path();
      for (var i = 0; i < line.data.length; i++) {
        final pt = Offset(mapX(i), mapY(line.data[i]));
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = line.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.8,
      );
      if (dots) {
        final dotPaint = Paint()..color = line.color;
        for (var i = 0; i < line.data.length; i++) {
          canvas.drawCircle(Offset(mapX(i), mapY(line.data[i])), 2.8, dotPaint);
        }
      }
    }
  }

  void _renderArea(
    Canvas canvas,
    List<_ChartSeriesData> series,
    double Function(int) mapX,
    double Function(double) mapY,
    double plotBottom,
  ) {
    for (final line in series) {
      final path = Path();
      for (var i = 0; i < line.data.length; i++) {
        final pt = Offset(mapX(i), mapY(line.data[i]));
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      // Close area to bottom
      path.lineTo(mapX(line.data.length - 1), plotBottom);
      path.lineTo(mapX(0), plotBottom);
      path.close();

      canvas.drawPath(
        path,
        Paint()
          ..color = line.color.withValues(alpha: 0.25)
          ..style = PaintingStyle.fill,
      );
      // Stroke on top
      final stroke = Path();
      for (var i = 0; i < line.data.length; i++) {
        final pt = Offset(mapX(i), mapY(line.data[i]));
        if (i == 0) {
          stroke.moveTo(pt.dx, pt.dy);
        } else {
          stroke.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.drawPath(
        stroke,
        Paint()
          ..color = line.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  void _renderScatter(Canvas canvas, List<_ChartSeriesData> series, double Function(int) mapX, double Function(double) mapY) {
    for (final s in series) {
      final paint = Paint()..color = s.color.withValues(alpha: 0.75);
      for (var i = 0; i < s.data.length; i++) {
        canvas.drawCircle(Offset(mapX(i), mapY(s.data[i])), 4.5, paint);
      }
    }
  }

  void _renderBar(
    Canvas canvas,
    List<_ChartSeriesData> series,
    List<String> xAxis,
    double Function(int) mapX,
    double Function(double) mapY,
    double plotWidth,
  ) {
    final groupCount = xAxis.length;
    final seriesCount = series.length;
    final groupWidth = plotWidth / math.max(groupCount, 1);
    final barGroupWidth = math.min(42.0, groupWidth * 0.78);
    final barWidth = math.max(3.0, barGroupWidth / math.max(seriesCount, 1));

    for (var i = 0; i < groupCount; i++) {
      final groupStart = mapX(i) - (barGroupWidth / 2);
      for (var j = 0; j < seriesCount; j++) {
        if (i >= series[j].data.length) continue;
        final value = series[j].data[i];
        final y = mapY(value);
        final zeroY = mapY(0);
        final top = math.min(y, zeroY);
        final bottom = math.max(y, zeroY);
        final left = groupStart + (j * barWidth);
        canvas.drawRect(Rect.fromLTWH(left, top, barWidth - 1, bottom - top), Paint()..color = series[j].color);
      }
    }
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  void _drawXLabel(Canvas canvas, String label, double x, double y, double rotateAngle) {
    if (rotateAngle.abs() < 1) {
      _drawText(canvas, label, Offset(x - 26, y), const TextStyle(fontSize: 12, color: Color(0xFF374151)), maxWidth: 72);
    } else {
      final rad = rotateAngle * math.pi / 180.0;
      canvas.save();
      canvas.translate(x, y + 10);
      canvas.rotate(rad);
      _drawText(canvas, label, const Offset(-30, -8), const TextStyle(fontSize: 11, color: Color(0xFF374151)), maxWidth: 80);
      canvas.restore();
    }
  }

  void _drawLegend(Canvas canvas, List<_ChartSeriesData> series, {required int width}) {
    var x = 18.0;
    const y = 46.0;

    for (final item in series) {
      final swatchPaint = Paint()..color = item.color;
      canvas.drawRect(Rect.fromLTWH(x, y, 14, 14), swatchPaint);
      _drawText(canvas, item.name, Offset(x + 18, y - 1), const TextStyle(fontSize: 13, color: Color(0xFF1F2937)), maxWidth: 160);
      x += 210;
      if (x > width - 210) x = 18;
    }
  }

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style, {double? maxWidth, TextAlign align = TextAlign.left}) {
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 2,
      ellipsis: '…',
    );
    textPainter.layout(maxWidth: maxWidth ?? double.infinity);
    textPainter.paint(canvas, offset);
  }

  Color? _parseColor(String hex) {
    final normalized = hex.replaceAll('#', '').trim();
    if (normalized.length == 6) {
      final parsed = int.tryParse('FF$normalized', radix: 16);
      if (parsed == null) return null;
      return Color(parsed);
    }
    if (normalized.length == 8) {
      final parsed = int.tryParse(normalized, radix: 16);
      if (parsed == null) return null;
      return Color(parsed);
    }
    return null;
  }

  String _normalizePngFileName(String? value) {
    final base = (value == null || value.isEmpty) ? 'generated_chart' : value;
    return base.toLowerCase().endsWith('.png') ? base : '$base.png';
  }
}

class _PanelSpec {
  final String type;
  final String label;
  final double left;
  final double top;
  const _PanelSpec({required this.type, required this.label, required this.left, required this.top});
}

class _ChartSeriesData {
  final String name;
  final List<double> data;
  final Color color;

  const _ChartSeriesData({required this.name, required this.data, required this.color});
}
