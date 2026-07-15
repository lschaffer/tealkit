import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class WeatherForecastReportService {
  Future<Map<String, dynamic>> buildHourlyForecastPdf({
    required Map<String, dynamic> weatherData,
    required String locationName,
    required int requestedHours,
  }) async {
    final hourly = weatherData['hourly'] as Map<String, dynamic>?;
    if (hourly == null) {
      return {'error': 'Hourly weather data missing for PDF report.'};
    }

    final times = _asStringList(hourly['time']);
    if (times.isEmpty) {
      return {'error': 'Hourly time series is empty.'};
    }

    final temperature = _asDoubleList(hourly['temperature_2m']);
    final apparentTemperature = _asDoubleList(hourly['apparent_temperature']);
    final windSpeed = _asDoubleList(hourly['wind_speed_10m']);
    final windGust = _asDoubleList(hourly['wind_gusts_10m']);
    final humidity = _asDoubleList(hourly['relative_humidity_2m']);
    final precipitationProb = _asDoubleList(hourly['precipitation_probability']);
    final precipitation = _asDoubleList(hourly['precipitation']);

    final length = [
      times.length,
      temperature.length,
      apparentTemperature.length,
      windSpeed.length,
      windGust.length,
      humidity.length,
      precipitationProb.length,
      precipitation.length,
    ].reduce((a, b) => a < b ? a : b);

    final truncatedTimes = times.take(length).toList();
    final tempSeries = temperature.take(length).toList();
    final feelsSeries = apparentTemperature.take(length).toList();
    final windSeries = windSpeed.take(length).toList();
    final gustSeries = windGust.take(length).toList();
    final humiditySeries = humidity.take(length).toList();
    final precipProbSeries = precipitationProb.take(length).toList();
    final precipSeries = precipitation.take(length).toList();

    final now = DateTime.now();
    final fileName =
        'weather_forecast_${requestedHours}h_${_safeFileName(locationName)}_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.pdf';

    final tempSpots = _toSpots(tempSeries);
    final feelsSpots = _toSpots(feelsSeries);
    final windSpots = _toSpots(windSeries);
    final gustSpots = _toSpots(gustSeries);
    final humiditySpots = _toSpots(humiditySeries);
    final precipProbSpots = _toSpots(precipProbSeries);

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (context) => [
          pw.Text('Weather Forecast Report', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Text('Location: $locationName'),
          pw.Text('Generated: ${now.toIso8601String()}'),
          pw.Text('Horizon: $requestedHours hours'),
          pw.SizedBox(height: 14),
          _summaryTable(
            tempSeries: tempSeries,
            feelsSeries: feelsSeries,
            windSeries: windSeries,
            gustSeries: gustSeries,
            humiditySeries: humiditySeries,
            precipProbSeries: precipProbSeries,
            precipSeries: precipSeries,
          ),
          pw.SizedBox(height: 14),
          pw.SvgImage(
            svg: _buildLineChartSvg(
              sectionTitle: 'Temperature vs Feels Like',
              title: 'Temperature relation',
              xLabels: truncatedTimes,
              series: [
                _ChartSeries(label: 'Temperature °C', colorHex: '#E53935', points: tempSpots),
                _ChartSeries(label: 'Feels like °C', colorHex: '#FB8C00', points: feelsSpots),
              ],
            ),
          ),
          pw.SizedBox(height: 10),
          pw.SvgImage(
            svg: _buildLineChartSvg(
              sectionTitle: 'Wind Speed vs Wind Gust',
              title: 'Wind relation',
              xLabels: truncatedTimes,
              series: [
                _ChartSeries(label: 'Wind km/h', colorHex: '#1E88E5', points: windSpots),
                _ChartSeries(label: 'Gust km/h', colorHex: '#3949AB', points: gustSpots),
              ],
            ),
          ),
          pw.SizedBox(height: 10),
          pw.SvgImage(
            svg: _buildLineChartSvg(
              sectionTitle: 'Humidity vs Precipitation Probability',
              title: 'Humidity/precipitation probability relation',
              xLabels: truncatedTimes,
              series: [
                _ChartSeries(label: 'Humidity %', colorHex: '#00897B', points: humiditySpots),
                _ChartSeries(label: 'Precip prob %', colorHex: '#8E24AA', points: precipProbSpots),
              ],
            ),
          ),
          pw.SizedBox(height: 10),
          pw.Text('All forecast points', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          _previewTable(
            times: truncatedTimes,
            temp: tempSeries,
            feels: feelsSeries,
            wind: windSeries,
            gust: gustSeries,
            precipProb: precipProbSeries,
            precip: precipSeries,
          ),
        ],
      ),
    );

    final bytes = await doc.save();
    return {
      'success': true,
      'message': 'Weather PDF report generated. Tap to download/open.',
      'fileName': fileName,
      'mimeType': 'application/pdf',
      'size': bytes.length,
      'encoding': 'base64',
      'content': base64Encode(bytes),
    };
  }

  pw.Widget _summaryTable({
    required List<double> tempSeries,
    required List<double> feelsSeries,
    required List<double> windSeries,
    required List<double> gustSeries,
    required List<double> humiditySeries,
    required List<double> precipProbSeries,
    required List<double> precipSeries,
  }) {
    String minMaxAvg(List<double> values, {String suffix = ''}) {
      if (values.isEmpty) return '-';
      final min = values.reduce((a, b) => a < b ? a : b);
      final max = values.reduce((a, b) => a > b ? a : b);
      final avg = values.reduce((a, b) => a + b) / values.length;
      return '${min.toStringAsFixed(1)} / ${max.toStringAsFixed(1)} / ${avg.toStringAsFixed(1)}$suffix';
    }

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300),
      children: [
        _row('Metric (min / max / avg)', 'Value'),
        _row('Temperature °C', minMaxAvg(tempSeries)),
        _row('Feels like °C', minMaxAvg(feelsSeries)),
        _row('Wind km/h', minMaxAvg(windSeries)),
        _row('Wind gust km/h', minMaxAvg(gustSeries)),
        _row('Humidity %', minMaxAvg(humiditySeries)),
        _row('Precipitation probability %', minMaxAvg(precipProbSeries)),
        _row('Precipitation mm', minMaxAvg(precipSeries)),
      ],
    );
  }

  pw.TableRow _row(String a, String b) {
    return pw.TableRow(
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.all(6),
          child: pw.Text(a, style: const pw.TextStyle(fontSize: 10)),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(6),
          child: pw.Text(b, style: const pw.TextStyle(fontSize: 10)),
        ),
      ],
    );
  }

  pw.Widget _previewTable({
    required List<String> times,
    required List<double> temp,
    required List<double> feels,
    required List<double> wind,
    required List<double> gust,
    required List<double> precipProb,
    required List<double> precip,
  }) {
    final count = [
      times.length,
      temp.length,
      feels.length,
      wind.length,
      gust.length,
      precipProb.length,
      precip.length,
    ].reduce((a, b) => a < b ? a : b);
    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        children: ['Time', 'Temp', 'Feels', 'Wind', 'Gust', 'Precip %', 'Precip mm']
            .map(
              (e) => pw.Padding(
                padding: const pw.EdgeInsets.all(4),
                child: pw.Text(e, style: const pw.TextStyle(fontSize: 9)),
              ),
            )
            .toList(),
      ),
    ];

    for (var i = 0; i < count; i++) {
      rows.add(
        pw.TableRow(
          children: [
            _cell(times[i]),
            _cell(temp[i].toStringAsFixed(1)),
            _cell(feels[i].toStringAsFixed(1)),
            _cell(wind[i].toStringAsFixed(1)),
            _cell(gust[i].toStringAsFixed(1)),
            _cell(precipProb[i].toStringAsFixed(0)),
            _cell(precip[i].toStringAsFixed(1)),
          ],
        ),
      );
    }
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300),
      columnWidths: {
        0: const pw.FlexColumnWidth(2.3),
        1: const pw.FlexColumnWidth(1),
        2: const pw.FlexColumnWidth(1),
        3: const pw.FlexColumnWidth(1),
        4: const pw.FlexColumnWidth(1),
        5: const pw.FlexColumnWidth(1),
        6: const pw.FlexColumnWidth(1),
      },
      children: rows,
    );
  }

  pw.Widget _cell(String text) => pw.Padding(
    padding: const pw.EdgeInsets.all(4),
    child: pw.Text(text, style: const pw.TextStyle(fontSize: 8)),
  );

  List<String> _asStringList(dynamic value) {
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    return const [];
  }

  List<double> _asDoubleList(dynamic value) {
    if (value is List) {
      return value.map((e) => (e as num?)?.toDouble() ?? 0.0).toList();
    }
    return const [];
  }

  List<FlSpot> _toSpots(List<double> values) {
    final spots = <FlSpot>[];
    for (var i = 0; i < values.length; i++) {
      spots.add(FlSpot(i.toDouble(), values[i]));
    }
    return spots;
  }

  String _safeFileName(String input) {
    final cleaned = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'_+'), '_').trim();
    return cleaned.isEmpty ? 'location' : cleaned;
  }

  String _buildLineChartSvg({required String title, String? sectionTitle, required List<_ChartSeries> series, List<String>? xLabels}) {
    const width = 700.0;
    const baseHeight = 320.0;
    const sectionTitleOffset = 28.0;
    const leftPad = 44.0;
    const rightPad = 18.0;
    const legendItemWidth = 180.0;
    const legendRowHeight = 14.0;
    const bottomPad = 100.0;

    final extraTop = sectionTitle != null ? sectionTitleOffset : 0.0;
    final height = baseHeight + extraTop;
    final legendItemsPerRow = ((width - 24.0) / legendItemWidth).floor().clamp(1, 1000);
    final legendRows = (series.length / legendItemsPerRow).ceil();
    final topPad = extraTop + 28.0 + (legendRows * legendRowHeight) + 10.0;

    final allPoints = series.expand((s) => s.points).toList();
    if (allPoints.isEmpty) {
      return '<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height"><text x="20" y="30">No data</text></svg>';
    }

    final minX = allPoints.map((p) => p.x).reduce((a, b) => a < b ? a : b);
    final maxX = allPoints.map((p) => p.x).reduce((a, b) => a > b ? a : b);
    var minY = allPoints.map((p) => p.y).reduce((a, b) => a < b ? a : b);
    var maxY = allPoints.map((p) => p.y).reduce((a, b) => a > b ? a : b);
    if ((maxY - minY).abs() < 0.001) {
      minY -= 1;
      maxY += 1;
    }

    double mapX(double x) {
      final span = (maxX - minX) == 0 ? 1.0 : (maxX - minX);
      return leftPad + ((x - minX) / span) * (width - leftPad - rightPad);
    }

    double mapY(double y) {
      return topPad + (1 - ((y - minY) / (maxY - minY))) * (height - topPad - bottomPad);
    }

    final buffer = StringBuffer();
    buffer.writeln('<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height">');
    buffer.writeln('<rect x="0" y="0" width="$width" height="$height" fill="#ffffff"/>');
    if (sectionTitle != null) {
      buffer.writeln('<text x="10" y="20" font-size="14" font-weight="bold" fill="#1f2937">$sectionTitle</text>');
    }
    buffer.writeln('<text x="10" y="${16 + extraTop}" font-size="12" fill="#6b7280">$title</text>');

    for (var i = 0; i < series.length; i++) {
      final row = i ~/ legendItemsPerRow;
      final col = i % legendItemsPerRow;
      final y = extraTop + 28 + (row * legendRowHeight);
      final x = 12 + (col * legendItemWidth);
      buffer.writeln('<circle cx="$x" cy="$y" r="4" fill="${series[i].colorHex}"/>');
      buffer.writeln('<text x="${x + 8}" y="${y + 3}" font-size="10" fill="#1f2937">${series[i].label}</text>');
    }

    buffer.writeln(
      '<line x1="$leftPad" y1="${height - bottomPad}" x2="${width - rightPad}" y2="${height - bottomPad}" stroke="#9ca3af" stroke-width="1"/>',
    );
    buffer.writeln('<line x1="$leftPad" y1="$topPad" x2="$leftPad" y2="${height - bottomPad}" stroke="#9ca3af" stroke-width="1"/>');

    for (var i = 0; i <= 4; i++) {
      final yValue = minY + ((maxY - minY) * i / 4);
      final y = mapY(yValue);
      buffer.writeln(
        '<line x1="$leftPad" y1="$y" x2="${width - rightPad}" y2="$y" stroke="#e5e7eb" stroke-width="1" stroke-dasharray="3,3"/>',
      );
      buffer.writeln('<text x="4" y="${y + 3}" font-size="9" fill="#4b5563">${yValue.toStringAsFixed(1)}</text>');
    }

    if (xLabels != null && xLabels.isNotEmpty) {
      final maxDomainIndex = maxX.floor();
      final maxLabelIndex = xLabels.length - 1;
      final maxTickIndex = maxDomainIndex < maxLabelIndex ? maxDomainIndex : maxLabelIndex;

      if (maxTickIndex > 0) {
        final labelBaseY = height - bottomPad + 12;
        for (var idx = 0; idx <= maxTickIndex; idx++) {
          final x = mapX(idx.toDouble());
          final rawLabel = idx < xLabels.length ? xLabels[idx] : '';
          final label = _formatXAxisTimeLabel(rawLabel);
          buffer.writeln(
            '<line x1="$x" y1="${height - bottomPad}" x2="$x" y2="${height - bottomPad + 4}" stroke="#9ca3af" stroke-width="1"/>',
          );
          buffer.writeln(
            '<text x="$x" y="$labelBaseY" font-size="7" fill="#4b5563" text-anchor="start" transform="rotate(45 $x $labelBaseY)">$label</text>',
          );
        }
      }
    }

    for (final line in series) {
      if (line.points.isEmpty) continue;
      final points = line.points.map((p) => '${mapX(p.x).toStringAsFixed(2)},${mapY(p.y).toStringAsFixed(2)}').join(' ');
      buffer.writeln('<polyline fill="none" stroke="${line.colorHex}" stroke-width="2" points="$points"/>');
    }

    buffer.writeln('</svg>');
    return buffer.toString();
  }

  String _formatXAxisTimeLabel(String raw) {
    if (raw.trim().isEmpty) return '';
    final dt = DateTime.tryParse(raw);
    if (dt == null) {
      return raw.length > 10 ? raw.substring(0, 10) : raw;
    }
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')} $hh:$mm';
  }
}

class _ChartSeries {
  final String label;
  final String colorHex;
  final List<FlSpot> points;

  const _ChartSeries({required this.label, required this.colorHex, required this.points});
}
