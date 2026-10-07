import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/jank/jank_candidate.dart';
import 'package:dev_tools_light/src/jank/ui_stall_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reports a candidate when a tick is late', () {
    var now = 0;
    final candidates = <JankCandidate>[];
    final detector = UiStallDetector(
      config: const JankDetectionConfig(),
      now: () => now,
      onCandidate: candidates.add,
    )..tick(); // first tick only records
    now = 50000;
    detector.tick(); // on time
    now = 100000 + 20000; // 20 ms late: below the threshold
    detector.tick();
    expect(candidates, isEmpty);
    now += 50000 + 300000; // 300 ms late
    detector.tick();
    expect(candidates, hasLength(1));
    final c = candidates.single;
    expect(c.kinds, {JankKind.uiStall});
    expect(c.stallLateness, const Duration(milliseconds: 300));
    expect(c.windowStartMicros, 120000);
    expect(c.windowEndMicros, now);
    expect(c.attributable, isTrue);

    detector.reset();
    now += 1000000;
    detector.tick(); // after reset the gap is not reported
    expect(candidates, hasLength(1));

    now += 50000 + const Duration(minutes: 12).inMicroseconds;
    detector.tick(); // a suspension / clock jump is not a stall
    expect(candidates, hasLength(1));
    expect(detector.suspensionsIgnored, 1);
  });
}
