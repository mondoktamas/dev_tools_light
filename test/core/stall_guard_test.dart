import 'package:dev_tools_light/src/core/stall_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SelfInflictedStallGuard', () {
    late int now;
    late SelfInflictedStallGuard guard;

    setUp(() {
      now = 1000000;
      guard = SelfInflictedStallGuard(now: () => now);
    });

    test('closed intervals overlap with padding', () {
      guard.begin();
      now += 100000; // 100 ms of work
      guard.end();
      // Inside.
      expect(guard.overlaps(1020000, 1050000), isTrue);
      // Just before, within the lead padding.
      expect(guard.overlaps(996000, 999000), isTrue);
      // Before the lead padding.
      expect(guard.overlaps(900000, 990000), isFalse);
      // After, within the trail padding.
      expect(guard.overlaps(1120000, 1140000), isTrue);
      // After the trail padding.
      expect(guard.overlaps(1200000, 1300000), isFalse);
      // Mostly covered.
      expect(guard.overlaps(980000, 1120000), isTrue);
      // A long stall that merely touches our work is genuine.
      expect(guard.overlaps(700000, 1010000), isFalse);
    });

    test('an open section covers everything since its start', () {
      guard.begin();
      expect(guard.isOpen, isTrue);
      now = 3000000;
      expect(guard.overlaps(2000000, 3000000), isTrue);
      expect(guard.overlaps(0, 900000), isFalse);
      // A stall that ended as our section started is not ours.
      expect(guard.overlaps(600000, 1001000), isFalse);
      guard.end();
      expect(guard.isOpen, isFalse);
    });

    test('inflated sections do not suppress', () {
      // Two normal sections establish the typical duration.
      for (var i = 0; i < 2; i++) {
        guard.begin(label: 'samples');
        now += 100000;
        guard.end();
        now += 100000;
      }
      // A section four times longer: something else stalled the isolate.
      guard.begin(label: 'samples');
      final start = now;
      now += 400000;
      guard.end();
      expect(guard.describe(), contains('!'));
      expect(guard.overlaps(start + 50000, start + 350000), isFalse);
      // A normal section afterwards still suppresses.
      guard.begin(label: 'samples');
      final normal = now;
      now += 100000;
      guard.end();
      expect(guard.overlaps(normal, normal + 100000), isTrue);
      // An open section that is already running too long does not either.
      guard.begin(label: 'samples');
      final open = now;
      now += 1000000;
      expect(guard.overlaps(open + 100000, open + 900000), isFalse);
      guard.end();
    });

    test('a drifted cost becomes the new baseline after two long sections', () {
      for (var i = 0; i < 2; i++) {
        guard.begin(label: 'samples');
        now += 70000;
        guard.end();
        now += 100000;
      }
      // The sample buffer grew: every fetch now takes 400 ms.
      guard.begin(label: 'samples');
      final first = now;
      now += 400000;
      guard.end();
      expect(
        guard.overlaps(first, first + 400000),
        isFalse,
        reason: 'inflated',
      );
      guard.begin(label: 'samples');
      final second = now;
      now += 400000;
      guard.end();
      expect(
        guard.overlaps(second, second + 400000),
        isTrue,
        reason: 'two in a row: the cost moved, suppression resumes',
      );
      expect(guard.describe(), isNot(endsWith('!')));
    });

    test('confirmSelfInflicted un-inflates the sections of a window', () {
      for (var i = 0; i < 2; i++) {
        guard.begin(label: 'samples');
        now += 70000;
        guard.end();
        now += 100000;
      }
      guard.begin(label: 'samples');
      final start = now;
      now += 400000;
      guard.end();
      expect(guard.overlaps(start, start + 400000), isFalse);
      guard.confirmSelfInflicted(start + 50000, start + 350000);
      expect(guard.overlaps(start, start + 400000), isTrue);
      // The next long section is normal now.
      guard.begin(label: 'samples');
      final next = now;
      now += 400000;
      guard.end();
      expect(guard.overlaps(next, next + 400000), isTrue);
    });

    test('is re-entrant and closes only on the outermost end', () {
      guard
        ..begin()
        ..begin()
        ..end();
      expect(guard.isOpen, isTrue);
      guard.end();
      expect(guard.isOpen, isFalse);
      // Extra end() calls are ignored.
      guard.end();
      expect(guard.isOpen, isFalse);
    });

    test('guard() wraps a future and pruning forgets old intervals', () async {
      await guard.guard(() async {
        now += 1000;
      });
      expect(guard.overlaps(1000000, 1001000), isTrue);
      now += const Duration(seconds: 10).inMicroseconds;
      guard
        ..begin()
        ..end(); // triggers pruning
      expect(guard.overlaps(1000000, 1001000), isFalse);
    });
  });
}
