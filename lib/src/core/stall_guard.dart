import 'dart:math' as math;

import 'package:dev_tools_light/src/core/clock.dart';

/// Records the intervals in which `dev_tools_light` itself blocks the UI
/// isolate.
///
/// Isolate-scoped VM-service RPCs (retaining paths, forced GCs, `getObject`,
/// CPU-sample serialisation) are executed *by the UI isolate*, so every leak
/// check and sample fetch is a stall we caused. The jank detector drops
/// candidates whose window is mostly covered by these intervals; a genuine
/// stall that merely touches one (typically because the stall itself delayed
/// the start of our work) is kept.
///
/// A section is an `await` of an RPC, and the UI isolate is free for part of
/// it. When app code stalls the isolate during that await, the section runs
/// much longer than usual (the response can only be processed afterwards):
/// such *inflated* sections, longer than `typical × inflationFactor +
/// inflationSlack` for their label, do not suppress anything.
class SelfInflictedStallGuard {
  /// Creates a guard that keeps closed intervals for [retention].
  SelfInflictedStallGuard({
    required NowMicros now,
    this.retention = const Duration(seconds: 5),
    this.leadPadding = const Duration(milliseconds: 5),
    this.trailPadding = const Duration(milliseconds: 50),
    this.minOverlapFraction = 0.5,
    this.inflationFactor = 1.5,
    this.inflationSlack = const Duration(milliseconds: 50),
  }) : _now = now;

  final NowMicros _now;

  /// How long closed intervals are remembered.
  final Duration retention;

  /// Slack applied before an interval when testing for overlap.
  final Duration leadPadding;

  /// Slack applied after an interval when testing for overlap.
  final Duration trailPadding;

  /// The share of a candidate window that guarded intervals (with padding)
  /// must cover for the candidate to count as self-inflicted.
  final double minOverlapFraction;

  /// A section longer than this multiple of its label's typical duration
  /// (plus [inflationSlack]) was delayed by something else and is ignored.
  final double inflationFactor;

  /// Absolute slack added to the inflation threshold.
  final Duration inflationSlack;

  final List<_Section> _closed = [];
  final Map<String, ({int micros, int count})> _typical = {};
  final Map<String, int> _consecutiveInflated = {};
  int _openDepth = 0;
  int? _openStart;
  String _openLabel = 'work';

  /// Inflated sections in a row after which the label's typical duration is
  /// reset to the current one: the cost drifted (for example a fuller sample
  /// buffer), nothing else is stalling the isolate.
  static const int inflatedRunResetsBaseline = 2;

  /// Number of jank candidates dropped because of this guard.
  int suppressedCount = 0;

  /// Whether a guarded section is currently running.
  bool get isOpen => _openDepth > 0;

  /// Marks the start of a guarded section (re-entrant). [label] groups
  /// sections whose typical duration is comparable (`'samples'`, `'leaks'`).
  void begin({String label = 'work'}) {
    if (_openDepth == 0) {
      _openStart = _now();
      _openLabel = label;
    }
    _openDepth++;
  }

  /// Marks the end of the innermost guarded section.
  void end() {
    if (_openDepth == 0) {
      return;
    }
    _openDepth--;
    if (_openDepth == 0) {
      final start = _openStart!;
      final now = _now();
      final duration = now - start;
      var inflated = _isInflated(_openLabel, duration);
      if (inflated) {
        final run = (_consecutiveInflated[_openLabel] ?? 0) + 1;
        if (run >= inflatedRunResetsBaseline) {
          // Not a one-off: the cost itself has moved.
          _typical[_openLabel] = (micros: duration, count: 2);
          _consecutiveInflated[_openLabel] = 0;
          inflated = false;
        } else {
          _consecutiveInflated[_openLabel] = run;
        }
      } else {
        _consecutiveInflated[_openLabel] = 0;
        _learn(_openLabel, duration);
      }
      _closed.add(
        _Section(start: start, end: now, inflated: inflated, label: _openLabel),
      );
      _openStart = null;
      _prune();
    }
  }

  void _learn(String label, int duration) {
    final typical = _typical[label];
    _typical[label] = typical == null
        ? (micros: duration, count: 1)
        : (
            micros: (typical.micros * 0.7 + duration * 0.3).round(),
            count: typical.count + 1,
          );
  }

  /// Tells the guard that the window `[windowStart, windowEnd]` turned out to
  /// be our own work after all (its CPU samples were the VM service serving
  /// one of our RPCs): sections overlapping it stop counting as inflated and
  /// their durations become the new normal.
  void confirmSelfInflicted(int windowStart, int windowEnd) {
    for (var i = 0; i < _closed.length; i++) {
      final section = _closed[i];
      if (!section.inflated ||
          section.end < windowStart ||
          section.start > windowEnd) {
        continue;
      }
      _closed[i] = _Section(
        start: section.start,
        end: section.end,
        inflated: false,
        label: section.label,
      );
      // Strong evidence: this is what the work costs now.
      _typical[section.label] = (
        micros: section.end - section.start,
        count: 2,
      );
      _consecutiveInflated[section.label] = 0;
    }
  }

  bool _isInflated(String label, int duration) {
    final typical = _typical[label];
    if (typical == null || typical.count < 2) {
      return false;
    }
    return duration >
        typical.micros * inflationFactor + inflationSlack.inMicroseconds;
  }

  /// Runs [body] inside a guarded section.
  Future<T> guard<T>(
    Future<T> Function() body, {
    String label = 'work',
  }) async {
    begin(label: label);
    try {
      return await body();
    } finally {
      end();
    }
  }

  /// Whether at least [minOverlapFraction] of the window
  /// `[windowStart, windowEnd]` (timeline micros) is covered by guarded
  /// intervals, padded by [leadPadding] and [trailPadding].
  bool overlaps(int windowStart, int windowEnd) =>
      _covered(windowStart, windowEnd, inflated: false);

  /// Whether at least [minOverlapFraction] of the window is covered by
  /// *inflated* sections: our own work that took unusually long. Such a
  /// window is reported by [overlaps] as not ours, because an app stall may
  /// have inflated the section; when the window's samples then show nothing
  /// but engine and system frames, it was ours after all (an RPC that was
  /// simply slow), and the caller can drop it.
  bool overlapsInflated(int windowStart, int windowEnd) =>
      _covered(windowStart, windowEnd, inflated: true);

  bool _covered(int windowStart, int windowEnd, {required bool inflated}) {
    final length = windowEnd - windowStart;
    if (length <= 0) {
      return false;
    }
    final lead = leadPadding.inMicroseconds;
    final trail = trailPadding.inMicroseconds;
    var covered = 0;
    void cover(int start, int end) {
      final from = math.max(windowStart, start);
      final to = math.min(windowEnd, end);
      if (to > from) {
        covered += to - from;
      }
    }

    final openStart = _openStart;
    if (openStart != null &&
        _isInflated(_openLabel, _now() - openStart) == inflated) {
      cover(openStart - lead, _now());
    }
    for (final section in _closed) {
      if (section.inflated == inflated) {
        cover(section.start - lead, section.end + trail);
      }
    }
    return covered >= length * minOverlapFraction;
  }

  /// Human-readable description of the open and closed intervals (inflated
  /// ones are marked with `!`).
  String describe() {
    final open = _openStart == null ? '' : 'open since $_openStart; ';
    final closed = _closed
        .map((s) => '[${s.start}..${s.end}]${s.inflated ? '!' : ''}')
        .join(', ');
    return '$open${_closed.length} closed: $closed';
  }

  void _prune() {
    final cutoff = _now() - retention.inMicroseconds;
    _closed.removeWhere((interval) => interval.end < cutoff);
  }
}

class _Section {
  const _Section({
    required this.start,
    required this.end,
    required this.inflated,
    required this.label,
  });

  final int start;
  final int end;
  final bool inflated;
  final String label;
}
