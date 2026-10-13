import 'dart:ui' show FramePhase, FrameTiming;

import 'package:dev_tools_light/src/core/clock.dart';

/// Maps the engine's `FrameTiming` clock onto the VM timeline clock.
///
/// A persistent frame callback records `Timeline.now` for the frame number
/// being built; when that frame's `FrameTiming` arrives, the difference to its
/// `buildStart` is `trueOffset + delay` with `delay ≥ 0`, so the running
/// minimum converges on the true offset between the two clocks.
class FrameClockCalibrator {
  /// Creates a calibrator.
  FrameClockCalibrator({
    required NowMicros now,
    this.minSamples = 3,
    this.history = 128,
  }) : _now = now;

  final NowMicros _now;

  /// Frames needed before [isCalibrated] is true.
  final int minSamples;

  /// How many recent frames are remembered while their timings are pending.
  final int history;

  final Map<int, int> _nowByFrame = <int, int>{};
  final List<int> _order = <int>[];
  int? _minOffset;
  int _samples = 0;
  bool _active = false;

  /// Whether frames are being observed.
  bool get isActive => _active;

  /// Whether enough frames were observed.
  bool get isCalibrated => _samples >= minSamples;

  /// The current offset estimate (timeline − engine), if any.
  int? get offsetMicros => _minOffset;

  /// Number of frame timings matched so far.
  int get sampleCount => _samples;

  /// Starts observing.
  void start() => _active = true;

  /// Stops observing (the persistent frame callback cannot be removed).
  void stop() => _active = false;

  /// Call once per frame from a persistent frame callback with the frame
  /// number the engine is building (`PlatformDispatcher.frameData`).
  void onFrame(int frameNumber) {
    if (!_active || frameNumber < 0) {
      return;
    }
    if (!_nowByFrame.containsKey(frameNumber)) {
      _order.add(frameNumber);
    }
    _nowByFrame[frameNumber] = _now();
    while (_order.length > history) {
      _nowByFrame.remove(_order.removeAt(0));
    }
  }

  /// Matches [timing] with the frame observed by [onFrame].
  void observe(FrameTiming timing) {
    final now = _nowByFrame.remove(timing.frameNumber);
    if (now == null) {
      return;
    }
    _order.remove(timing.frameNumber);
    final offset = now - timing.timestampInMicroseconds(FramePhase.buildStart);
    final min = _minOffset;
    if (min == null || offset < min) {
      _minOffset = offset;
    }
    _samples++;
  }

  /// Converts an engine timestamp to the timeline clock, or null while
  /// uncalibrated.
  int? toTimelineMicros(int engineMicros) {
    final offset = _minOffset;
    if (offset == null || !isCalibrated) {
      return null;
    }
    return engineMicros + offset;
  }
}
