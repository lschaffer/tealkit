import 'package:tealkit_server/utils/cron_utils.dart';

void main() {
  int passed = 0;
  int failed = 0;

  void expect(String desc, dynamic actual, dynamic expected) {
    if (actual == expected) {
      print('  ✓ $desc');
      passed++;
    } else {
      print('  ✗ $desc\n    expected: $expected\n    actual:   $actual');
      failed++;
    }
  }

  // Reference: Wednesday 2026-04-08 08:30:00 local time
  // (nextCronFire uses local DateTime constructors internally)
  final ref = DateTime(2026, 4, 8, 8, 30, 0);

  print('nextCronFire tests\n');

  // ── Every N minutes (epoch-based) ────────────────────────────────────

  // Every 15 minutes: epoch 08:30 UTC → next multiple of 15 mins
  // The implementation uses epoch math so result is UTC-like; we verify
  // it is strictly after ref and the minute is correct.
  {
    final next = nextCronFire('*/15 * * * *', from: ref);
    final ok = next.isAfter(ref) && next.difference(ref).inSeconds <= 15 * 60 && next.minute % 15 == 0;
    if (ok) {
      print('  ✓ */15 * * * * → next quarter-hour (${next.minute})');
      passed++;
    } else {
      print('  ✗ */15 * * * * → unexpected result: $next');
      failed++;
    }
  }

  {
    final next = nextCronFire('*/5 * * * *', from: ref);
    final ok = next.isAfter(ref) && next.difference(ref).inSeconds <= 5 * 60 && next.minute % 5 == 0;
    if (ok) {
      print('  ✓ */5 * * * * → next 5-min slot (${next.minute})');
      passed++;
    } else {
      print('  ✗ */5 * * * * → unexpected result: $next');
      failed++;
    }
  }

  // ── Hourly ───────────────────────────────────────────────────────────

  // Hourly at :00 — 08:30 → 09:00
  {
    final next = nextCronFire('0 * * * *', from: ref);
    expect('0 * * * * → next :00', next, DateTime(2026, 4, 8, 9, 0));
  }

  // Hourly at :45 — 08:30 → 08:45
  {
    final next = nextCronFire('45 * * * *', from: ref);
    expect('45 * * * * → 08:45', next, DateTime(2026, 4, 8, 8, 45));
  }

  // ── Daily ────────────────────────────────────────────────────────────

  // Daily at 09:00 — 08:30 → same day
  {
    final next = nextCronFire('0 9 * * *', from: ref);
    expect('0 9 * * * → today 09:00', next, DateTime(2026, 4, 8, 9, 0));
  }

  // Daily at 07:00 — 08:30 → next day
  {
    final next = nextCronFire('0 7 * * *', from: ref);
    expect('0 7 * * * → tomorrow 07:00', next, DateTime(2026, 4, 9, 7, 0));
  }

  // ── Every N hours ────────────────────────────────────────────────────

  // Every 2 hours at :00 — from 08:30 → next even hour 10:00
  {
    final next = nextCronFire('0 */2 * * *', from: ref);
    expect('0 */2 * * * → 10:00', next, DateTime(2026, 4, 8, 10, 0));
  }

  // ── DOW specific ─────────────────────────────────────────────────────

  // ref is Wednesday (weekday=3 in Dart, DOW=3 in cron).
  // Next Sunday (cron DOW=0): ref.weekday=3, Sunday is 4 days away → 2026-04-12
  {
    final next = nextCronFire('0 6 * * 0', from: ref);
    expect('0 6 * * 0 → next Sunday', next, DateTime(2026, 4, 12, 6, 0));
  }

  // Next Wednesday at 06:00 — same weekday but 06:00 < 08:30, so next week
  {
    final next = nextCronFire('0 6 * * 3', from: ref);
    expect('0 6 * * 3 → next Wednesday', next, DateTime(2026, 4, 15, 6, 0));
  }

  // ── DOM specific ─────────────────────────────────────────────────────

  // 15th of every month at 10:00 — ref is 8th → April 15
  {
    final next = nextCronFire('0 10 15 * *', from: ref);
    expect('0 10 15 * * → April 15', next, DateTime(2026, 4, 15, 10, 0));
  }

  // 1st of month at 00:00 — ref is Apr 8 → May 1
  {
    final next = nextCronFire('0 0 1 * *', from: ref);
    expect('0 0 1 * * → May 1', next, DateTime(2026, 5, 1, 0, 0));
  }

  // ── Invalid input ────────────────────────────────────────────────────

  {
    final next = nextCronFire('bad', from: ref);
    expect('bad cron → +24h fallback', next, ref.add(const Duration(hours: 24)));
  }

  print('\n$passed passed, $failed failed');
  if (failed > 0) {
    throw Exception('$failed test(s) failed');
  }
}
