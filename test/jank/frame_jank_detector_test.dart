import 'dart:ui';

import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/jank/frame_clock_calibrator.dart';
import 'package:dev_tools_light/src/jank/frame_jank_detector.dart';
import 'package:dev_tools_light/src/jank/jank_candidate.dart';
import 'package:dev_tools_light/src/jank/slow_operation_report.dart';
import 'package:flutter_test/flutter_test.dart';

FrameTiming timing({
  required int vsyncStart,
  required int buildStart,
  required int buildFinish,
  required int rasterStart,
  required int rasterFinish,
  int frameNumber = 7,
}) {
  return FrameTiming(
    vsyncStart: vsyncStart,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: rasterStart,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: rasterFinish,
    frameNumber: frameNumber,
  );
}

void main() {
  late FrameClockCalibrator calibrator;
  late List<JankCandidate> candidates;
  late FrameJankDetector detector;

  setUp(() {
    var now = 0;
    // The timeline clock runs 1 ms ahead of the engine clock.
    calibrator = FrameClockCalibrator(now: () => now)..start();
    for (var i = 1; i <= 3; i++) {
      final buildStart = i * 16000;
      now = buildStart + 1000;
      calibrator
        ..onFrame(i)
        ..observe(
          timing(
            vsyncStart: buildStart - 1000,
            buildStart: buildStart,
            buildFinish: buildStart + 5000,
            rasterStart: buildStart + 5000,
            rasterFinish: buildStart + 9000,
            frameNumber: i,
          ),
        );
    }
    candidates = [];
    detector = FrameJankDetector(
      config: const JankDetectionConfig(
        frameBuildThreshold: Duration(milliseconds: 16),
        frameRasterThreshold: Duration(milliseconds: 16),
        vsyncOverheadThreshold: Duration(milliseconds: 32),
      ),
      calibrator: calibrator,
      onCandidate: candidates.add,
    );
  });

  test('a fast frame produces nothing', () {
    detector.handleTimings([
      timing(
        vsyncStart: 0,
        buildStart: 1000,
        buildFinish: 6000,
        rasterStart: 6000,
        rasterFinish: 12000,
      ),
    ]);
    expect(candidates, isEmpty);
    expect(detector.framesSeen, 1);
  });

  test('a slow build is attributable with a calibrated window', () {
    detector.handleTimings([
      timing(
        vsyncStart: 0,
        buildStart: 1000,
        buildFinish: 41000,
        rasterStart: 41000,
        rasterFinish: 45000,
      ),
    ]);
    final c = candidates.single;
    expect(c.kinds, {JankKind.slowBuild});
    expect(c.attributable, isTrue);
    expect(c.windowStartMicros, 2000);
    expect(c.windowEndMicros, 42000);
    expect(c.buildDuration, const Duration(milliseconds: 40));
    expect(c.frameNumber, 7);
  });

  test('a delayed frame covers vsync to build start', () {
    detector.handleTimings([
      timing(
        vsyncStart: 0,
        buildStart: 50000,
        buildFinish: 55000,
        rasterStart: 55000,
        rasterFinish: 60000,
      ),
    ]);
    final c = candidates.single;
    expect(c.kinds, {JankKind.delayedFrame});
    expect(c.windowStartMicros, 1000);
    expect(c.windowEndMicros, 51000);
  });

  test('a slow raster is not attributable', () {
    detector.handleTimings([
      timing(
        vsyncStart: 0,
        buildStart: 1000,
        buildFinish: 5000,
        rasterStart: 5000,
        rasterFinish: 45000,
      ),
    ]);
    final c = candidates.single;
    expect(c.kinds, {JankKind.slowRaster});
    expect(c.attributable, isFalse);
    expect(c.unattributableState, AttributionState.notAttributable);
  });

  test('an uncalibrated clock blocks attribution', () {
    final fresh = FrameClockCalibrator(now: () => 0);
    FrameJankDetector(
      config: const JankDetectionConfig(
        frameBuildThreshold: Duration(milliseconds: 16),
      ),
      calibrator: fresh,
      onCandidate: candidates.add,
    ).handleTimings([
      timing(
        vsyncStart: 0,
        buildStart: 1000,
        buildFinish: 41000,
        rasterStart: 41000,
        rasterFinish: 45000,
      ),
    ]);
    expect(candidates.single.attributable, isFalse);
    expect(
      candidates.single.unattributableState,
      AttributionState.uncalibrated,
    );
  });
}
