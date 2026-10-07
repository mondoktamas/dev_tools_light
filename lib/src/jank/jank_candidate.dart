import 'package:dev_tools_light/src/jank/slow_operation_report.dart';
import 'package:meta/meta.dart';

/// What kind of slowness was detected.
enum JankKind {
  /// The UI-thread build phase of a frame took too long.
  slowBuild,

  /// The frame started late because the UI thread was busy.
  delayedFrame,

  /// The raster thread took too long (not attributable to Dart code).
  slowRaster,

  /// The UI isolate did not run our heartbeat on time (no frame in flight).
  uiStall;

  /// Human-readable label.
  String get label => switch (this) {
    JankKind.slowBuild => 'Slow build',
    JankKind.delayedFrame => 'Delayed frame',
    JankKind.slowRaster => 'Slow raster',
    JankKind.uiStall => 'UI stall',
  };
}

/// A detected jank, before CPU samples are fetched.
@immutable
class JankCandidate {
  /// Creates a candidate; the window is in timeline microseconds.
  const JankCandidate({
    required this.kinds,
    required this.windowStartMicros,
    required this.windowEndMicros,
    required this.attributable,
    this.unattributableState,
    this.buildDuration,
    this.rasterDuration,
    this.vsyncOverhead,
    this.stallLateness,
    this.frameNumber,
  });

  /// The kinds of slowness observed.
  final Set<JankKind> kinds;

  /// Start of the slow window (timeline clock).
  final int windowStartMicros;

  /// End of the slow window (timeline clock).
  final int windowEndMicros;

  /// Whether CPU samples of the UI isolate can explain this candidate.
  final bool attributable;

  /// Why [attributable] is false.
  final AttributionState? unattributableState;

  /// UI-thread build duration of the frame, if a frame.
  final Duration? buildDuration;

  /// Raster duration of the frame, if a frame.
  final Duration? rasterDuration;

  /// Vsync-to-build-start delay, if a frame.
  final Duration? vsyncOverhead;

  /// Heartbeat lateness, if a UI stall.
  final Duration? stallLateness;

  /// Engine frame number, if a frame.
  final int? frameNumber;

  /// Length of the window.
  Duration get duration =>
      Duration(microseconds: windowEndMicros - windowStartMicros);
}
