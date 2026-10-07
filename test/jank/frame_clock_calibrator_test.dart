import 'dart:ui';

import 'package:dev_tools_light/src/jank/frame_clock_calibrator.dart';
import 'package:flutter_test/flutter_test.dart';

FrameTiming timing({required int frameNumber, required int buildStart}) {
  return FrameTiming(
    vsyncStart: buildStart - 1000,
    buildStart: buildStart,
    buildFinish: buildStart + 5000,
    rasterStart: buildStart + 5000,
    rasterFinish: buildStart + 9000,
    rasterFinishWallTime: buildStart + 9000,
    frameNumber: frameNumber,
  );
}

void main() {
  test('matches frames by number and keeps the minimum offset', () {
    var now = 5000;
    final calibrator = FrameClockCalibrator(now: () => now)
      ..onFrame(1)
      ..observe(timing(frameNumber: 1, buildStart: 1000));
    expect(calibrator.sampleCount, 0, reason: 'inactive until started');

    calibrator
      ..start()
      ..onFrame(2); // now 5000
    now = 22000;
    calibrator.onFrame(3);
    now = 39000;
    calibrator
      ..onFrame(4)
      // Frame 2: offset 4000.
      ..observe(timing(frameNumber: 2, buildStart: 1000));
    expect(calibrator.isCalibrated, isFalse);
    expect(calibrator.toTimelineMicros(0), isNull);
    calibrator
      ..observe(timing(frameNumber: 3, buildStart: 17500)) // offset 4500
      ..observe(timing(frameNumber: 4, buildStart: 34900)); // offset 4100
    expect(calibrator.isCalibrated, isTrue);
    expect(calibrator.offsetMicros, 4000);
    expect(calibrator.toTimelineMicros(10000), 14000);

    calibrator.observe(timing(frameNumber: 99, buildStart: 0));
    expect(calibrator.sampleCount, 3, reason: 'unknown frames are ignored');

    calibrator.stop();
    now = 100;
    calibrator
      ..onFrame(5)
      ..observe(timing(frameNumber: 5, buildStart: 100));
    expect(calibrator.offsetMicros, 4000, reason: 'ignored after stop');
  });

  test('forgets frames beyond the history', () {
    final calibrator = FrameClockCalibrator(now: () => 1000, history: 2)
      ..start()
      ..onFrame(1)
      ..onFrame(2)
      ..onFrame(3)
      ..observe(timing(frameNumber: 1, buildStart: 0));
    expect(calibrator.sampleCount, 0);
    calibrator.observe(timing(frameNumber: 3, buildStart: 0));
    expect(calibrator.sampleCount, 1);
    expect(calibrator.offsetMicros, 1000);
  });
}
