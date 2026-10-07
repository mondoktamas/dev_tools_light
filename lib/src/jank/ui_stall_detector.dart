import 'dart:async';

import 'package:dev_tools_light/src/core/clock.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/jank/jank_candidate.dart';

/// Detects UI-isolate stalls with a heartbeat timer: if a tick arrives much
/// later than scheduled, the isolate was busy — even when no frame was in
/// flight (heavy work in a tap handler before any `setState`).
class UiStallDetector {
  /// Creates a detector.
  UiStallDetector({
    required JankDetectionConfig config,
    required NowMicros now,
    required void Function(JankCandidate candidate) onCandidate,
  }) : _config = config,
       _now = now,
       _onCandidate = onCandidate;

  final JankDetectionConfig _config;
  final NowMicros _now;
  final void Function(JankCandidate candidate) _onCandidate;

  Timer? _timer;
  int? _lastTickMicros;

  /// Gaps ignored because they exceeded `maxStall`.
  int suspensionsIgnored = 0;

  /// Whether the heartbeat runs.
  bool get isActive => _timer != null;

  /// Starts the heartbeat.
  void start() {
    _lastTickMicros = null;
    _timer ??= Timer.periodic(_config.heartbeatInterval, (_) => tick());
  }

  /// Stops the heartbeat.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastTickMicros = null;
  }

  /// Forgets the last tick (call after the app was paused/resumed).
  void reset() => _lastTickMicros = null;

  /// One heartbeat.
  void tick() {
    final now = _now();
    final last = _lastTickMicros;
    _lastTickMicros = now;
    if (last == null) {
      return;
    }
    final lateness = now - (last + _config.heartbeatInterval.inMicroseconds);
    if (lateness < _config.stallThreshold.inMicroseconds) {
      return;
    }
    if (lateness > _config.maxStall.inMicroseconds) {
      // The process was suspended or the clock jumped; not a stall.
      suspensionsIgnored++;
      return;
    }
    _onCandidate(
      JankCandidate(
        kinds: const {JankKind.uiStall},
        windowStartMicros: last,
        windowEndMicros: now,
        attributable: true,
        stallLateness: Duration(microseconds: lateness),
      ),
    );
  }
}
