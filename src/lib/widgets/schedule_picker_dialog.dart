import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../config/app_theme.dart';

// Schedule Picker Dialog — accordion-style (Minutes/Hourly/Daily/Weekly/Monthly)
// ═══════════════════════════════════════════════════════════════════
/// Shared cron schedule picker dialog.
///
/// Set [allowSubHourly] to `false` to hide the "Minutes" category (useful for
/// contexts that require at least a 1-hour recurrence, e.g. website indexing).
class SchedulePickerDialog extends StatefulWidget {
  final String initialCron;
  final String? initialCategory;
  final bool allowSubHourly;

  const SchedulePickerDialog({super.key, required this.initialCron, this.initialCategory, this.allowSubHourly = true});

  @override
  State<SchedulePickerDialog> createState() => _SchedulePickerDialogState();
}

class _SchedulePickerDialogState extends State<SchedulePickerDialog> {
  late String _selectedCategory;

  // Minutes
  int _minuteInterval = 15;

  // Hourly
  int _hourInterval = 1;
  int _hourlyAtMinute = 0;

  // Daily
  int _dailyHour = 8;
  int _dailyMinute = 0;

  // Weekly
  int _weeklyHour = 8;
  int _weeklyMinute = 0;
  final Set<int> _weeklyDays = {1}; // 1=Mon

  // Monthly
  int _monthlyDay = 1;
  int _monthlyHour = 8;
  int _monthlyMinute = 0;

  String _determineCategory(String cron) {
    final parts = cron.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return 'daily';
    final minute = parts[0];
    final hour = parts[1];
    final dom = parts[2];
    final month = parts[3];
    final dow = parts[4];

    if ((minute == '*' || minute.contains('/')) &&
        hour == '*' &&
        dom == '*' &&
        month == '*' &&
        dow == '*') {
      return 'minutes';
    }
    if (dow != '*') {
      return 'weekly';
    }
    if (dow == '*' && month == '*' && dom != '*' && !dom.contains('/')) {
      return 'monthly';
    }
    if (hour == '*' || hour.contains('/')) {
      return 'hourly';
    }
    return 'daily';
  }

  @override
  void initState() {
    super.initState();
    // If sub-hourly is not allowed and the initial category is 'minutes', fall back to 'hourly'
    String cat = widget.initialCategory ?? _determineCategory(widget.initialCron);
    if (!widget.allowSubHourly && cat == 'minutes') cat = 'hourly';
    _selectedCategory = cat;
    _parseCron(widget.initialCron);
  }

  void _parseCron(String cron) {
    final parts = cron.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return;
    final minute = parts[0];
    final hour = parts[1];
    final day = parts[2];
    final weekday = parts[4];

    try {
      if (_selectedCategory == 'minutes') {
        if (minute.contains('/')) {
          _minuteInterval = (int.tryParse(minute.split('/').last) ?? 15).clamp(5, 60);
        } else {
          _minuteInterval = 15;
        }
      } else if (_selectedCategory == 'hourly') {
        _hourlyAtMinute = int.tryParse(minute) ?? 0;
        if (hour.contains('/')) {
          _hourInterval = int.tryParse(hour.split('/').last) ?? 1;
        }
      } else if (_selectedCategory == 'daily') {
        _dailyMinute = int.tryParse(minute) ?? 0;
        _dailyHour = int.tryParse(hour) ?? 8;
      } else if (_selectedCategory == 'weekly') {
        _weeklyMinute = int.tryParse(minute) ?? 0;
        _weeklyHour = int.tryParse(hour) ?? 8;
        _weeklyDays.clear();
        if (weekday != '*') {
          for (final d in weekday.split(',')) {
            if (d.contains('-')) {
              final range = d.split('-');
              final start = int.tryParse(range[0]) ?? 1;
              final end = int.tryParse(range[1]) ?? 5;
              for (int i = start; i <= end; i++) {
                _weeklyDays.add(i);
              }
            } else {
              final v = int.tryParse(d);
              if (v != null) _weeklyDays.add(v);
            }
          }
        }
        if (_weeklyDays.isEmpty) _weeklyDays.add(1);
      } else if (_selectedCategory == 'monthly') {
        _monthlyMinute = int.tryParse(minute) ?? 0;
        _monthlyHour = int.tryParse(hour) ?? 8;
        _monthlyDay = int.tryParse(day) ?? 1;
      }
    } catch (_) {}
  }

  String _buildCron() {
    switch (_selectedCategory) {
      case 'minutes':
        return '*/$_minuteInterval * * * *';
      case 'hourly':
        if (_hourInterval <= 1) return '$_hourlyAtMinute * * * *';
        return '$_hourlyAtMinute */$_hourInterval * * *';
      case 'daily':
        return '$_dailyMinute $_dailyHour * * *';
      case 'weekly':
        final days = _weeklyDays.toList()..sort();
        return '$_weeklyMinute $_weeklyHour * * ${days.join(',')}';
      case 'monthly':
        return '$_monthlyMinute $_monthlyHour $_monthlyDay * *';
      default:
        return '0 8 * * *';
    }
  }

  String _buildHint() {
    final l = L.of(context);
    switch (_selectedCategory) {
      case 'minutes':
        return l.scheduleEveryNMinutes(_minuteInterval);
      case 'hourly':
        if (_hourInterval <= 1) return l.cronHourly;
        return l.scheduleEveryNHours(_hourInterval);
      case 'daily':
        return '${l.scheduleDaily} ${_dailyHour.toString().padLeft(2, '0')}:${_dailyMinute.toString().padLeft(2, '0')}';
      case 'weekly':
        final dayNames = {
          1: l.scheduleMon,
          2: l.scheduleTue,
          3: l.scheduleWed,
          4: l.scheduleThu,
          5: l.scheduleFri,
          6: l.scheduleSat,
          0: l.scheduleSun,
          7: l.scheduleSun,
        };
        final days = _weeklyDays.toList()..sort();
        final names = days.map((d) => dayNames[d] ?? '?').join(', ');
        return '${l.scheduleWeekly} $names ${_weeklyHour.toString().padLeft(2, '0')}:${_weeklyMinute.toString().padLeft(2, '0')}';
      case 'monthly':
        return '${l.scheduleMonthly} $_monthlyDay. ${_monthlyHour.toString().padLeft(2, '0')}:${_monthlyMinute.toString().padLeft(2, '0')}';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final allCategories = [
      ('minutes', l.scheduleMinutes, Icons.timer),
      ('hourly', l.scheduleHourly, Icons.hourglass_bottom),
      ('daily', l.scheduleDaily, Icons.today),
      ('weekly', l.scheduleWeekly, Icons.view_week),
      ('monthly', l.scheduleMonthly, Icons.calendar_month),
    ];
    final categories = widget.allowSubHourly ? allCategories : allCategories.where((c) => c.$1 != 'minutes').toList();

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () =>
                        Navigator.of(context, rootNavigator: true).pop(),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l.schedulePickerTitle,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context, rootNavigator: true).pop({
                        'cron': _buildCron(),
                        'hint': _buildHint(),
                      });
                    },
                    child: Text(l.save),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // ── Accordion list ──
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: categories.map((cat) {
                  final isSelected = _selectedCategory == cat.$1;
                  return Column(
                    children: [
                      ListTile(
                        leading: Icon(cat.$3, color: isSelected ? AppTheme.primaryBlue : null),
                        title: Text(
                          cat.$2,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? AppTheme.primaryBlue : null,
                          ),
                        ),
                        trailing: isSelected ? Icon(Icons.check, color: AppTheme.primaryBlue) : const Icon(Icons.chevron_right),
                        onTap: () => setState(() => _selectedCategory = cat.$1),
                      ),
                      if (isSelected) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 16), child: _buildCategoryContent(cat.$1)),
                      const Divider(height: 1),
                    ],
                  );
                }).toList(),
              ),
            ),

            // ── Preview ──
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.cronExpression, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    _buildCron(),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(_buildHint(), style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryContent(String category) {
    final l = L.of(context);
    switch (category) {
      case 'minutes':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.scheduleEveryNMinutes(_minuteInterval), style: const TextStyle(fontSize: 13)),
            Slider(
              value: _minuteInterval.toDouble(),
              min: 5,
              max: 60,
              divisions: 11,
              label: '$_minuteInterval',
              onChanged: (v) => setState(() => _minuteInterval = v.round()),
            ),
          ],
        );
      case 'hourly':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.scheduleEveryNHours(_hourInterval), style: const TextStyle(fontSize: 13)),
            Slider(
              value: _hourInterval.toDouble(),
              min: 1,
              max: 12,
              divisions: 11,
              label: '$_hourInterval',
              onChanged: (v) => setState(() => _hourInterval = v.round()),
            ),
            const SizedBox(height: 8),
            _buildTimePicker(
              label: l.scheduleAtMinute,
              hourValue: null,
              minuteValue: _hourlyAtMinute,
              onMinuteChanged: (v) => setState(() => _hourlyAtMinute = v),
            ),
          ],
        );
      case 'daily':
        return _buildTimePicker(
          label: l.scheduleAtHour,
          hourValue: _dailyHour,
          minuteValue: _dailyMinute,
          onHourChanged: (v) => setState(() => _dailyHour = v),
          onMinuteChanged: (v) => setState(() => _dailyMinute = v),
        );
      case 'weekly':
        final dayLabels = {
          0: l.scheduleSun,
          1: l.scheduleMon,
          2: l.scheduleTue,
          3: l.scheduleWed,
          4: l.scheduleThu,
          5: l.scheduleFri,
          6: l.scheduleSat,
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.scheduleOnDays, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [1, 2, 3, 4, 5, 6, 0].map((day) {
                final isSelected = _weeklyDays.contains(day);
                return FilterChip(
                  label: Text(dayLabels[day]!, style: const TextStyle(fontSize: 12)),
                  selected: isSelected,
                  onSelected: (val) {
                    setState(() {
                      if (val) {
                        _weeklyDays.add(day);
                      } else if (_weeklyDays.length > 1) {
                        _weeklyDays.remove(day);
                      }
                    });
                  },
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            _buildTimePicker(
              label: l.scheduleAtHour,
              hourValue: _weeklyHour,
              minuteValue: _weeklyMinute,
              onHourChanged: (v) => setState(() => _weeklyHour = v),
              onMinuteChanged: (v) => setState(() => _weeklyMinute = v),
            ),
          ],
        );
      case 'monthly':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${l.scheduleOnDayOfMonth}: ', style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade600),
                  ),
                  child: DropdownButton<int>(
                    value: _monthlyDay.clamp(1, 28),
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    items: List.generate(28, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
                    onChanged: (v) => setState(() => _monthlyDay = v ?? 1),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildTimePicker(
              label: l.scheduleAtHour,
              hourValue: _monthlyHour,
              minuteValue: _monthlyMinute,
              onHourChanged: (v) => setState(() => _monthlyHour = v),
              onMinuteChanged: (v) => setState(() => _monthlyMinute = v),
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// Reusable time picker row (hour : minute dropdowns)
  Widget _buildTimePicker({
    required String label,
    int? hourValue,
    required int minuteValue,
    ValueChanged<int>? onHourChanged,
    required ValueChanged<int> onMinuteChanged,
  }) {
    final hourItems = List.generate(24, (i) => DropdownMenuItem(value: i, child: Text(i.toString().padLeft(2, '0'))));
    final minuteItems = [
      0,
      5,
      10,
      15,
      20,
      25,
      30,
      35,
      40,
      45,
      50,
      55,
    ].map((m) => DropdownMenuItem(value: m, child: Text(m.toString().padLeft(2, '0')))).toList();

    final allowedMinutes = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55];
    int coercedMinute = minuteValue;
    if (!allowedMinutes.contains(minuteValue)) {
      coercedMinute = ((minuteValue / 5).round() * 5).clamp(0, 55);
    }

    return Row(
      children: [
        Text('$label: ', style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 8),
        if (hourValue != null && onHourChanged != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade600),
            ),
            child: DropdownButton<int>(
              value: hourValue,
              underline: const SizedBox.shrink(),
              isDense: true,
              items: hourItems,
              onChanged: (v) => onHourChanged(v ?? 0),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Text(':', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
        ],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade600),
          ),
          child: DropdownButton<int>(
            value: coercedMinute,
            underline: const SizedBox.shrink(),
            isDense: true,
            items: minuteItems,
            onChanged: (v) => onMinuteChanged(v ?? 0),
          ),
        ),
      ],
    );
  }
}
