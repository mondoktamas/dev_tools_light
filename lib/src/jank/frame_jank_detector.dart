import 'dart:ui' show FramePhase, FrameTiming;

import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/jank/frame_clock_calibrator.dart';
import 'package:dev_tools_light/src/jank/jank_candidate.dart';
import 'package:dev_tools_light/src/jank/slow_operation_report.dart';

/// Turns `FrameTiming`s into [JankCandidate]s.
class FrameJankDetector {
  /// Creates a detector.
  FrameJankDetector({
    required JankDetectionConfig config,
    required FrameClockCalibrator calibrator,
    required void Function(JankCandidate candidate) onCandidate,
  }) : _config = config,
       _calibrator = calibrator,
       _onCandidate = onCandidate;

  final JankDetectionConfig _config;
  final FrameClockCalibrator _calibrator;
  final void Function(JankCandidate candidate) _onCandidate;

  /// Frames examined so far.
  int framesSeen = 0;

  /// `SchedulerBinding.addTimingsCallback` entry point.
  void handleTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      framesSeen++;
      _calibrator.observe(timing);
      final candidate = evaluate(timing);
      if (candidate != null) {
        _onCandidate(candidate);
      }
    }
  }

  /// Evaluates one frame; returns null when it is fine.
  JankCandidate? evaluate(FrameTiming timing) {
    final kinds = <JankKind>{};
    if (timing.buildDuration >= _config.effectiveFrameBuildThreshold) {
      kinds.add(JankKind.slowBuild);
    }
    if (timing.vsyncOverhead >= _config.effectiveVsyncOverheadThreshold) {
      kinds.add(JankKind.delayedFrame);
    }
    if (timing.rasterDuration >= _config.effectiveFrameRasterThreshold) {
      kinds.add(JankKind.slowRaster);
    }
    if (kinds.isEmpty) {
      return null;
    }
    final uiJank =
        kinds.contains(JankKind.slowBuild) ||
        kinds.contains(JankKind.delayedFrame);
    final int engineStart;
    final int engineEnd;
    if (uiJank) {
      engineStart = timing.timestampInMicroseconds(
        kinds.contains(JankKind.delayedFrame)
            ? FramePhase.vsyncStart
            : FramePhase.buildStart,
      );
      engineEnd = timing.timestampInMicroseconds(
        kinds.contains(JankKind.slowBuild)
            ? FramePhase.buildFinish
            : FramePhase.buildStart,
      );
    } else {
      engineStart = timing.timestampInMicroseconds(FramePhase.rasterStart);
      engineEnd = timing.timestampInMicroseconds(FramePhase.rasterFinish);
    }
    final start = _calibrator.toTimelineMicros(engineStart);
    final end = _calibrator.toTimelineMicros(engineEnd);
    final calibrated = start != null && end != null;
    return JankCandidate(
      kinds: kinds,
      windowStartMicros: start ?? engineStart,
      windowEndMicros: end ?? engineEnd,
      attributable: uiJank && calibrated,
      unattributableState: !uiJank
          ? AttributionState.notAttributable
          : calibrated
          ? null
          : AttributionState.uncalibrated,
      buildDuration: timing.buildDuration,
      rasterDuration: timing.rasterDuration,
      vsyncOverhead: timing.vsyncOverhead,
      frameNumber: timing.frameNumber,
    );
  }
}
