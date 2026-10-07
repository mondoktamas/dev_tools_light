import 'dart:async';
import 'dart:math' as math;

import 'package:dev_tools_light/src/core/clock.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/leaks/watched_kind.dart';

/// Lifecycle of a watched object.
enum WatchState {
  /// Disposed; waiting for the retained delay.
  watching,

  /// Still reachable after the retained delay; awaiting a GC check.
  retainedCandidate,

  /// Part of a running check.
  analyzing,
}

/// A weakly held, disposed object under observation.
class WatchedObject {
  /// Creates a record for [object].
  WatchedObject({
    required this.id,
    required Object object,
    required this.kind,
    required this.watchedAtMicros,
    required this.barrierAtWatch,
    this.description,
  }) : _ref = WeakReference(object),
       identityHash = identityHashCode(object),
       typeName = typeNameOf(object),
       type = object.runtimeType;

  /// Sequential id.
  final int id;

  /// The runtime type (the package policy is keyed by it).
  final Type type;

  /// `identityHashCode` of the object (for de-duplication without holding
  /// any reference).
  final int identityHash;

  WeakReference<Object>? _ref;

  /// Runtime type name (generics stripped).
  final String typeName;

  /// How the object came to be watched.
  final WatchedKind kind;

  /// Optional description from `DevToolsLight.watch`.
  final String? description;

  /// When watching started (timeline clock).
  final int watchedAtMicros;

  /// `reachabilityBarrier` when watching started.
  final int barrierAtWatch;

  /// Current state.
  WatchState state = WatchState.watching;

  /// Checks in which no GC could be confirmed.
  int gcAttempts = 0;

  /// Checks skipped because no frame had completed since disposal.
  int deferredChecks = 0;

  /// When the object became a candidate (timeline clock).
  int? candidateSinceMicros;

  /// `reachabilityBarrier` when the object became a candidate.
  int? barrierAtCandidate;

  /// The object, while it is alive and the reference is attached.
  Object? get target => _ref?.target;

  /// Whether the weak reference has been cleared by the GC.
  bool get isCollected => _ref != null && _ref!.target == null;

  /// Whether [detachReference] was called.
  bool get isDetached => _ref == null;

  /// Drops the weak reference. The VM's retaining-path search does not
  /// distinguish weak from strong references, so nothing of ours may point at
  /// the object while its retaining path is fetched.
  void detachReference() => _ref = null;
}

/// Analyzes a batch of retained candidates and returns the ids that are
/// resolved (reported, dropped, or found collected). Unresolved candidates
/// are checked again later.
typedef RetainedCandidatesHandler =
    Future<Set<int>> Function(
      List<WatchedObject> candidates, {
      bool forced,
    });

/// LeakCanary's `ObjectWatcher`: holds weak references to disposed objects
/// and decides when a batch of retained candidates should be analyzed.
class ObjectWatcher {
  /// Creates a watcher.
  ObjectWatcher({
    required LeakDetectionConfig config,
    required NowMicros now,
    required int Function() barrier,
    required RetainedCandidatesHandler onRetained,
    this.tickInterval = const Duration(seconds: 1),
    void Function(String message)? log,
  }) : _config = config,
       _now = now,
       _barrier = barrier,
       _onRetained = onRetained,
       _log = log;

  final LeakDetectionConfig _config;
  final NowMicros _now;
  final int Function() _barrier;
  final RetainedCandidatesHandler _onRetained;
  final void Function(String message)? _log;

  /// How often the registry is examined.
  final Duration tickInterval;

  final Map<int, WatchedObject> _byId = <int, WatchedObject>{};
  final Map<int, List<WatchedObject>> _byHash = <int, List<WatchedObject>>{};
  final List<int> _checkStarts = [];
  int _nextId = 1;
  Timer? _timer;
  bool _checkInProgress = false;
  int _lastCheckStartMicros = -1 << 60;

  /// Objects evicted or dropped without a verdict.
  int droppedCount = 0;

  /// Checks run so far.
  int checksRun = 0;

  /// Number of watched objects.
  int get watchedCount => _byId.length;

  /// Number of retained candidates.
  int get candidateCount =>
      _byId.values.where((r) => r.state != WatchState.watching).length;

  /// Whether a check is running.
  bool get isChecking => _checkInProgress;

  /// Starts watching [object] (idempotent per object).
  void watch(
    Object object, {
    required WatchedKind kind,
    String? description,
  }) {
    if (object is num ||
        object is String ||
        object is bool ||
        object is Record) {
      return; // Cannot be the target of a WeakReference.
    }
    final hash = identityHashCode(object);
    final bucket = _byHash[hash];
    if (bucket != null && bucket.any((r) => identical(r.target, object))) {
      return;
    }
    if (_byId.length >= _config.maxWatchedObjects) {
      final oldest = _byId.values.cast<WatchedObject?>().firstWhere(
        (r) => r!.state == WatchState.watching,
        orElse: () => null,
      );
      if (oldest == null) {
        droppedCount++;
        return;
      }
      _remove(oldest);
      droppedCount++;
    }
    final record = WatchedObject(
      id: _nextId++,
      object: object,
      kind: kind,
      description: description,
      watchedAtMicros: _now(),
      barrierAtWatch: _barrier(),
    );
    _byId[record.id] = record;
    (_byHash[hash] ??= <WatchedObject>[]).add(record);
  }

  /// Starts the periodic tick.
  void start() {
    _timer ??= Timer.periodic(tickInterval, (_) => unawaited(tick()));
  }

  /// Stops the periodic tick.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Forgets every watched object.
  void clear() {
    _byId.values.toList().forEach(_remove);
  }

  /// Examines the registry once. With [force], the retained delay, batch
  /// window, minimum interval and rate limit are skipped.
  Future<void> tick({bool force = false}) async {
    if (_checkInProgress) {
      return;
    }
    final now = _now();
    final delay = force ? 0 : _config.retainedDelay.inMicroseconds;
    for (final record in _byId.values.toList()) {
      if (record.state != WatchState.watching) {
        continue;
      }
      if (now - record.watchedAtMicros < delay) {
        continue;
      }
      if (record.isCollected) {
        _remove(record);
        continue;
      }
      record
        ..state = WatchState.retainedCandidate
        ..candidateSinceMicros = now
        ..barrierAtCandidate = _barrier();
    }
    final candidates = _byId.values
        .where((r) => r.state == WatchState.retainedCandidate)
        .toList();
    if (candidates.isEmpty) {
      return;
    }
    if (!force) {
      final oldest = candidates
          .map((c) => c.candidateSinceMicros!)
          .reduce(math.min);
      if (now - oldest < _config.batchWindow.inMicroseconds) {
        return;
      }
      if (now - _lastCheckStartMicros <
          _config.minIntervalBetweenChecks.inMicroseconds) {
        return;
      }
      _checkStarts.removeWhere(
        (t) => now - t > const Duration(minutes: 1).inMicroseconds,
      );
      if (_checkStarts.length >= _config.maxAnalysesPerMinute) {
        return;
      }
    }
    await _runCheck(candidates, now, forced: force);
  }

  /// Runs a check immediately, ignoring delays and limits.
  Future<void> checkNow() => tick(force: true);

  Future<void> _runCheck(
    List<WatchedObject> candidates,
    int now, {
    required bool forced,
  }) async {
    _checkInProgress = true;
    _lastCheckStartMicros = now;
    _checkStarts.add(now);
    checksRun++;
    for (final candidate in candidates) {
      candidate.state = WatchState.analyzing;
    }
    try {
      final resolved = await _onRetained(candidates, forced: forced);
      for (final candidate in candidates) {
        if (resolved.contains(candidate.id)) {
          _remove(candidate);
        } else if (candidate.state == WatchState.analyzing) {
          candidate.state = WatchState.retainedCandidate;
        }
      }
    } on Object catch (error) {
      for (final candidate in candidates) {
        if (candidate.state == WatchState.analyzing) {
          candidate.state = WatchState.retainedCandidate;
        }
      }
      _log?.call('leak check failed: $error');
    } finally {
      _checkInProgress = false;
    }
  }

  void _remove(WatchedObject record) {
    _byId.remove(record.id);
    final bucket = _byHash[record.identityHash];
    if (bucket != null) {
      bucket.remove(record);
      if (bucket.isEmpty) {
        _byHash.remove(record.identityHash);
      }
    }
  }
}
