import 'dart:async';
import 'dart:math' as math;

import 'package:dev_tools_light/src/core/clock.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/fnv_hash.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/stall_guard.dart';
import 'package:dev_tools_light/src/jank/cpu_attribution.dart';
import 'package:dev_tools_light/src/jank/jank_attribution_backend.dart';
import 'package:dev_tools_light/src/jank/jank_candidate.dart';
import 'package:dev_tools_light/src/jank/slow_operation_report.dart';
import 'package:meta/meta.dart';

/// Merges, rate-limits and attributes [JankCandidate]s, then publishes
/// [SlowOperationReport]s.
///
/// Attribution is delegated to a [JankAttributionBackend]; without one
/// (release builds) candidates are reported with their durations only.
class JankCoordinator {
  /// Creates a coordinator.
  JankCoordinator({
    required JankDetectionConfig config,
    required ReportStore store,
    required SelfInflictedStallGuard guard,
    required NowMicros now,
    JankAttributionBackend? backend,
    bool Function()? isAppActive,
    bool Function(int startMicros, int endMicros)? isOverlayWindow,
    DateTime Function()? wallClock,
    void Function(String message)? log,
  }) : _config = config,
       _store = store,
       _guard = guard,
       _now = now,
       _backend = backend,
       _isAppActive = isAppActive,
       _isOverlayWindow = isOverlayWindow,
       _wallClock = wallClock ?? DateTime.now,
       _log = log;

  final JankDetectionConfig _config;
  final ReportStore _store;
  final SelfInflictedStallGuard _guard;
  final NowMicros _now;
  final JankAttributionBackend? _backend;
  final bool Function()? _isAppActive;
  final bool Function(int startMicros, int endMicros)? _isOverlayWindow;
  final DateTime Function() _wallClock;
  final void Function(String message)? _log;

  /// Sample-less candidates ignored because the app was not in the
  /// foreground (a throttled background process, not the app's code).
  int inactiveIgnored = 0;

  /// Candidates ignored because the report panel was open: its own frames.
  int overlayIgnored = 0;

  final List<_RecentReport> _recent = [];
  final List<int> _reportTimes = [];
  final List<_Pending> _queue = [];
  _Pending? _inFlight;
  int _sequence = 0;
  bool _busy = false;
  int? _firstFrameMicros;
  int _lastFetchMicros = 0;
  int _lastFetchDurationMicros = 0;
  int _lastClearMicros = 0;
  int? _fastestRpcMicros;
  Timer? _idleClearTimer;

  /// Candidates ignored because they fell into the warm-up period.
  int warmUpIgnored = 0;

  /// Candidates not fetched because the sample buffer had been cleared
  /// after their window.
  int clearedBeforeFetch = 0;

  /// Post-fetch buffer clears (the buffer had grown).
  int bufferClears = 0;

  /// Consecutive fetches that found no app code (or no samples); each one
  /// doubles the cooldown, up to [maxBackoffDoublings].
  int uselessFetches = 0;

  /// Cap on the cooldown doublings while fetches keep finding nothing:
  /// 8 × the base cooldown.
  static const int maxBackoffDoublings = 3;

  /// Records the first rendered frame. Warm-up is measured from it, and
  /// candidates before it (app start-up) are ignored.
  void markFirstFrame() => _firstFrameMicros ??= _now();

  /// Starts the idle sample-buffer maintenance (needs a backend).
  void start() {
    final interval = _config.idleSampleBufferClearInterval;
    if (interval == null || _backend == null) {
      return;
    }
    _idleClearTimer ??= Timer.periodic(interval, (_) => _clearIfIdle());
  }

  /// Stops the idle sample-buffer maintenance.
  void stop() {
    _idleClearTimer?.cancel();
    _idleClearTimer = null;
  }

  Future<void> _clearIfIdle() async {
    final interval = _config.idleSampleBufferClearInterval;
    final backend = _backend;
    if (interval == null || backend == null || _busy) {
      return;
    }
    if (_now() - _lastFetchMicros < interval.inMicroseconds) {
      return;
    }
    await backend.clearSampleBuffer();
    _lastFetchMicros = _now();
    _lastClearMicros = _lastFetchMicros;
  }

  /// Candidates dropped by the rate limit.
  int rateLimited = 0;

  /// Whether a candidate is being attributed right now.
  bool get isBusy => _busy;

  /// Candidates merged into a recent report.
  int merged = 0;

  /// Entry point for detectors.
  void handleCandidate(JankCandidate candidate) {
    // A candidate that overlaps a jank we are already handling describes the
    // same event (a slow build also delays the next frame): merge it before
    // anything else, or the guard would drop it as self-inflicted.
    final now = _now();
    final recent = _findRecent(candidate, now);
    if (recent != null) {
      merged++;
      _log?.call(
        'candidate ${_describe(candidate)} merged into recent report '
        '${recent.reportId}',
      );
      recent
        ..windowStart = candidate.windowStartMicros < recent.windowStart
            ? candidate.windowStartMicros
            : recent.windowStart
        ..windowEnd = candidate.windowEndMicros > recent.windowEnd
            ? candidate.windowEndMicros
            : recent.windowEnd;
      _store.updateSlowOp(
        recent.reportId,
        (report) => _mergeCandidate(report, candidate),
      );
      return;
    }
    final pending = _findPending(candidate);
    if (pending != null) {
      merged++;
      _log?.call(
        'candidate ${_describe(candidate)} merged into the pending one',
      );
      pending.candidate = mergeCandidates(pending.candidate, candidate);
      return;
    }
    final overlaps = _guard.overlaps(
      candidate.windowStartMicros,
      candidate.windowEndMicros,
    );
    _log?.call(
      'candidate ${candidate.kinds.map((k) => k.name).join('+')} '
      '[${candidate.windowStartMicros}..${candidate.windowEndMicros}] '
      '${candidate.duration.inMilliseconds} ms '
      'frame=${candidate.frameNumber} suppressed=$overlaps '
      'guard=${_guard.describe()}',
    );
    if (overlaps) {
      _guard.suppressedCount++;
      return;
    }
    if (_isOverlayWindow?.call(
          candidate.windowStartMicros,
          candidate.windowEndMicros,
        ) ??
        false) {
      overlayIgnored++;
      _log?.call(
        'candidate ${_describe(candidate)} ignored: the report panel was '
        'open',
      );
      return;
    }
    final firstFrame = _firstFrameMicros;
    if (firstFrame == null ||
        candidate.unattributableState == AttributionState.uncalibrated ||
        candidate.windowStartMicros <
            firstFrame + _config.warmUp.inMicroseconds) {
      // Frames before the clock is calibrated are the first few frames.
      warmUpIgnored++;
      return;
    }
    _reportTimes.removeWhere(
      (t) => now - t > const Duration(minutes: 1).inMicroseconds,
    );
    if (_reportTimes.length >= _config.maxReportsPerMinute &&
        candidate.duration < _config.severeDuration) {
      rateLimited++;
      _log?.call('candidate ${_describe(candidate)} rate limited');
      return;
    }
    _reportTimes.add(now);
    final holder = _Pending(candidate, detectedAt: _wallClock());
    if (_busy) {
      _queue.add(holder);
      if (_queue.length > _config.maxQueuedCandidates) {
        // Too much jank for this device to attribute: report the least
        // significant waiting one without samples.
        final victim = _queue.reduce(
          (a, b) => a.candidate.duration <= b.candidate.duration ? a : b,
        );
        _queue.remove(victim);
        _log?.call(
          'candidate ${_describe(victim.candidate)} skipped: '
          '${_config.maxQueuedCandidates} janks already waiting',
        );
        _publish(
          victim,
          state: AttributionState.skipped,
          hint:
              'CPU samples were not fetched: too many janks were waiting for '
              'attribution on this device.',
          announce: false,
        );
      }
      return;
    }
    unawaited(_drain(holder));
  }

  static String _describe(JankCandidate c) =>
      '${c.kinds.map((k) => k.name).join('+')} '
      '[${c.windowStartMicros}..${c.windowEndMicros}] '
      '${c.duration.inMilliseconds} ms';

  Future<void> _drain(_Pending first) async {
    _busy = true;
    try {
      await _process(first);
      while (_queue.isNotEmpty) {
        // Longest first: a 300 ms stall matters more than a 40 ms build.
        final next = _queue.reduce(
          (a, b) => a.candidate.duration >= b.candidate.duration ? a : b,
        );
        _queue.remove(next);
        await _process(next);
      }
    } finally {
      _busy = false;
    }
  }

  _Pending? _findPending(JankCandidate candidate) {
    final inFlight = _inFlight;
    if (inFlight != null && _overlapsEnough(candidate, inFlight.candidate)) {
      return inFlight;
    }
    for (final pending in _queue) {
      if (_overlapsEnough(candidate, pending.candidate)) {
        return pending;
      }
    }
    return null;
  }

  static bool _overlapsEnough(JankCandidate a, JankCandidate b) {
    final overlapStart = a.windowStartMicros > b.windowStartMicros
        ? a.windowStartMicros
        : b.windowStartMicros;
    final overlapEnd = a.windowEndMicros < b.windowEndMicros
        ? a.windowEndMicros
        : b.windowEndMicros;
    final overlap = overlapEnd - overlapStart;
    if (overlap <= 0) {
      return false;
    }
    final aLength = a.windowEndMicros - a.windowStartMicros;
    final bLength = b.windowEndMicros - b.windowStartMicros;
    final smaller = aLength < bLength ? aLength : bLength;
    return smaller <= 0 || overlap >= smaller * 0.3;
  }

  /// Unions two overlapping candidates.
  @visibleForTesting
  static JankCandidate mergeCandidates(JankCandidate a, JankCandidate b) {
    final attributable = a.attributable || b.attributable;
    return JankCandidate(
      kinds: {...a.kinds, ...b.kinds},
      windowStartMicros: a.windowStartMicros < b.windowStartMicros
          ? a.windowStartMicros
          : b.windowStartMicros,
      windowEndMicros: a.windowEndMicros > b.windowEndMicros
          ? a.windowEndMicros
          : b.windowEndMicros,
      attributable: attributable,
      unattributableState: attributable
          ? null
          : a.unattributableState ?? b.unattributableState,
      buildDuration: _max(a.buildDuration, b.buildDuration),
      rasterDuration: _max(a.rasterDuration, b.rasterDuration),
      vsyncOverhead: _max(a.vsyncOverhead, b.vsyncOverhead),
      stallLateness: _max(a.stallLateness, b.stallLateness),
      frameNumber: a.frameNumber ?? b.frameNumber,
    );
  }

  _RecentReport? _findRecent(JankCandidate candidate, int now) {
    _recent.removeWhere(
      (r) => now - r.createdAt > const Duration(seconds: 2).inMicroseconds,
    );
    for (final recent in _recent) {
      final overlapStart = candidate.windowStartMicros > recent.windowStart
          ? candidate.windowStartMicros
          : recent.windowStart;
      final overlapEnd = candidate.windowEndMicros < recent.windowEnd
          ? candidate.windowEndMicros
          : recent.windowEnd;
      final overlap = overlapEnd - overlapStart;
      if (overlap <= 0) {
        continue;
      }
      final candidateLength =
          candidate.windowEndMicros - candidate.windowStartMicros;
      final recentLength = recent.windowEnd - recent.windowStart;
      final smaller = candidateLength < recentLength
          ? candidateLength
          : recentLength;
      if (smaller <= 0 || overlap >= smaller * 0.3) {
        return recent;
      }
    }
    return null;
  }

  SlowOperationReport _mergeCandidate(
    SlowOperationReport report,
    JankCandidate candidate,
  ) {
    return SlowOperationReport(
      id: report.id,
      detectedAt: report.detectedAt,
      kinds: {...report.kinds, ...candidate.kinds},
      windowStartMicros: candidate.windowStartMicros < report.windowStartMicros
          ? candidate.windowStartMicros
          : report.windowStartMicros,
      windowEndMicros: candidate.windowEndMicros > report.windowEndMicros
          ? candidate.windowEndMicros
          : report.windowEndMicros,
      buildDuration: _max(report.buildDuration, candidate.buildDuration),
      rasterDuration: _max(report.rasterDuration, candidate.rasterDuration),
      vsyncOverhead: _max(report.vsyncOverhead, candidate.vsyncOverhead),
      stallLateness: _max(report.stallLateness, candidate.stallLateness),
      frameNumber: report.frameNumber ?? candidate.frameNumber,
      attribution: report.attribution,
      attributionState: report.attributionState,
      attributionHint: report.attributionHint,
      signature: report.signature,
      occurrences: report.occurrences,
      firstSeen: report.firstSeen,
      lastSeen: report.lastSeen,
    );
  }

  static Duration? _max(Duration? a, Duration? b) {
    if (a == null) {
      return b;
    }
    if (b == null) {
      return a;
    }
    return a > b ? a : b;
  }

  Future<void> _process(_Pending pending) async {
    _inFlight = pending;
    try {
      if (pending.candidate.attributable && _backend != null) {
        await _cooldown(pending.candidate);
      }
      await _processCandidate(pending);
    } finally {
      _inFlight = null;
    }
  }

  /// On a slow device a fetch takes a good part of a second, so fetches are
  /// spaced out by a multiple of the last one's RPC time; candidates
  /// arriving meanwhile are merged into the pending one or queued. While
  /// fetches keep finding no app code (a UI thread waiting in native code,
  /// a throttled process) the spacing doubles, up to [maxBackoffDoublings]
  /// times; severe candidates keep the base spacing.
  Future<void> _cooldown(JankCandidate candidate) async {
    final severe = candidate.duration >= _config.severeDuration;
    final backoff = severe
        ? 1
        : 1 << math.min(uselessFetches, maxBackoffDoublings);
    final wait =
        _lastFetchMicros +
        _lastFetchDurationMicros * _config.fetchCooldownFactor * backoff -
        _now();
    if (wait > 0) {
      if (backoff > 1) {
        _log?.call(
          'backing off: $uselessFetches fetches without app code; next '
          'fetch in ${wait ~/ 1000} ms',
        );
      }
      await Future<void>.delayed(Duration(microseconds: wait));
    }
  }

  Future<void> _processCandidate(_Pending pending) async {
    final candidate = pending.candidate;
    if (!candidate.attributable) {
      final state =
          candidate.unattributableState ?? AttributionState.notAttributable;
      _publish(
        pending,
        state: state,
        hint: switch (state) {
          AttributionState.uncalibrated =>
            'The frame clock was not calibrated yet; wait for a few frames.',
          _ => 'Raster-thread work cannot be attributed to Dart code.',
        },
      );
      return;
    }
    final backend = _backend;
    if (backend == null) {
      // Without samples a late frame start on its own is weak evidence (an
      // OS that throttles a background window produces one every frame), so
      // it is listed but not announced; stalls and slow builds are.
      _publish(
        pending,
        state: AttributionState.unsupported,
        hint:
            'Detected but not attributed: CPU samples are not available in '
            'this build (release mode has no VM service).',
        announce: candidate.kinds.any((k) => k != JankKind.delayedFrame),
      );
      return;
    }
    if (candidate.windowEndMicros <= _lastClearMicros) {
      // The samples of this window are gone (cleared after a slower fetch
      // or while idle); fetching would block the UI isolate for nothing.
      clearedBeforeFetch++;
      _publish(
        pending,
        state: AttributionState.skipped,
        hint:
            'CPU samples were not fetched: the sample buffer had been '
            'cleared after this window, before the jank could be attributed.',
        announce: false,
      );
      return;
    }
    final outcome = await backend.attribute(candidate);
    _lastFetchMicros = _now();
    _lastFetchDurationMicros = outcome.rpcMicros;
    await _clearIfGrown(backend, outcome.rpcMicros);
    final attribution = outcome.attribution;
    if (attribution != null && attribution.hasAppCode) {
      uselessFetches = 0;
    } else if (!outcome.selfInflicted) {
      uselessFetches++;
    }
    if (!outcome.selfInflicted &&
        attribution != null &&
        attribution.sampleCount == 0 &&
        !(_isAppActive?.call() ?? true)) {
      // Nothing ran on the UI isolate and the app is not in the foreground:
      // the process was throttled (a backgrounded window, App Nap), which
      // delays frames and heartbeats without any code of the app running.
      // Reporting it would schedule a badge frame, delayed again...
      inactiveIgnored++;
      _log?.call(
        'candidate ${_describe(candidate)} ignored: no CPU samples while '
        'the app is inactive',
      );
      return;
    }
    final engineOnly =
        attribution != null &&
        !attribution.hasAppCode &&
        attribution.isMostlyEngineWork &&
        _guard.overlapsInflated(
          candidate.windowStartMicros,
          candidate.windowEndMicros,
        );
    if (outcome.selfInflicted || engineOnly) {
      // Either the samples name the VM service, or the window sits inside
      // one of our own RPCs that merely took longer than usual and shows
      // nothing but engine frames (unsymbolized on Android): ours.
      _guard
        ..suppressedCount += 1
        ..confirmSelfInflicted(
          candidate.windowStartMicros,
          candidate.windowEndMicros,
        );
      final reason = outcome.selfInflicted
          ? outcome.hint
          : 'engine frames only, inside our own slow RPC';
      _log?.call('candidate ${_describe(candidate)} dropped: $reason');
      return;
    }
    // A window without a single sample means the UI isolate ran nothing:
    // native code blocked the thread, or the OS throttled the process. The
    // report is kept for the list, but a toast would animate a frame, which
    // a throttled app delivers late, which would be the next candidate.
    _publish(
      pending,
      attribution: attribution,
      state: outcome.state,
      hint: outcome.hint,
      announce: attribution == null || attribution.sampleCount > 0,
    );
  }

  /// The VM walks its whole sample buffer on every fetch, whatever the
  /// format, so a fetch that is slow *for this device* means the buffer has
  /// grown: clear it, unless other janks are still waiting for their samples.
  Future<void> _clearIfGrown(
    JankAttributionBackend backend,
    int rpcMicros,
  ) async {
    if (rpcMicros <= 0) {
      return;
    }
    final fastest = _fastestRpcMicros = math.min(
      _fastestRpcMicros ?? rpcMicros,
      rpcMicros,
    );
    final threshold = math.max(
      _config.clearSamplesWhenFetchExceeds.inMicroseconds,
      (fastest * 1.5).round(),
    );
    if (rpcMicros <= threshold || _queue.isNotEmpty) {
      return;
    }
    bufferClears++;
    _log?.call(
      'sample RPCs took ${rpcMicros ~/ 1000} ms (fastest ${fastest ~/ 1000} '
      'ms); clearing the sample buffer',
    );
    await backend.clearSampleBuffer(guarded: true);
    _lastClearMicros = _now();
  }

  void _publish(
    _Pending pending, {
    required AttributionState state,
    CpuAttribution? attribution,
    String? hint,
    bool announce = true,
  }) {
    final merged = pending.candidate; // may have absorbed later candidates
    final id = 'jank-${_sequence++}';
    final detectedAt = pending.detectedAt;
    final report = SlowOperationReport(
      id: id,
      detectedAt: detectedAt,
      kinds: merged.kinds,
      windowStartMicros: merged.windowStartMicros,
      windowEndMicros: merged.windowEndMicros,
      buildDuration: merged.buildDuration,
      rasterDuration: merged.rasterDuration,
      vsyncOverhead: merged.vsyncOverhead,
      stallLateness: merged.stallLateness,
      frameNumber: merged.frameNumber,
      attribution: attribution,
      attributionState: state,
      attributionHint: hint,
      signature: _signature(merged, attribution, state),
      firstSeen: detectedAt,
      lastSeen: detectedAt,
    );
    _store.addSlowOp(report, announce: announce);
    _recent.add(
      _RecentReport(
        reportId: id,
        windowStart: merged.windowStartMicros,
        windowEnd: merged.windowEndMicros,
        createdAt: _now(),
      ),
    );
    _log?.call('slow op: ${report.title} ${report.subtitle}');
  }

  String _signature(
    JankCandidate candidate,
    CpuAttribution? attribution,
    AttributionState state,
  ) {
    final kinds = (candidate.kinds.map((k) => k.name).toList()..sort()).join(
      ',',
    );
    if (attribution == null) {
      // Without samples, group by kind and severity so that a storm of
      // small janks does not hide a big one.
      return stableSignature([
        kinds,
        state.name,
        durationBucket(candidate.duration),
      ]);
    }
    if (attribution.hasAppCode) {
      return stableSignature([
        kinds,
        for (final f in attribution.hotAppFunctions.take(3))
          '${f.uri}:${f.name}',
      ]);
    }
    return stableSignature([kinds, 'noapp']);
  }

  /// A coarse severity class of [duration] for grouping unattributed janks.
  @visibleForTesting
  static String durationBucket(Duration duration) {
    final ms = duration.inMilliseconds;
    for (final limit in const [32, 64, 128, 250, 500, 1000]) {
      if (ms < limit) {
        return '<$limit ms';
      }
    }
    return '>=1000 ms';
  }
}

class _Pending {
  _Pending(this.candidate, {required this.detectedAt});

  JankCandidate candidate;
  final DateTime detectedAt;
}

class _RecentReport {
  _RecentReport({
    required this.reportId,
    required this.windowStart,
    required this.windowEnd,
    required this.createdAt,
  });

  final String reportId;
  int windowStart;
  int windowEnd;
  final int createdAt;
}
