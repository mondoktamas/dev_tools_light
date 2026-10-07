import 'dart:async';

import 'package:dev_tools_light/src/core/clock.dart';

/// Asks the VM for a full garbage collection.
typedef VmGcRequest = Future<void> Function();

/// Drives garbage collection until `reachabilityBarrier` reaches a target.
class GcController {
  /// Creates a controller reading the barrier through [barrier].
  GcController({
    required int Function() barrier,
    required NowMicros now,
    this.allocationChunks = 20,
    this.chunkSize = 30000,
  }) : _barrier = barrier,
       _now = now;

  final int Function() _barrier;
  final NowMicros _now;

  /// Chunks allocated per allocation-pressure round.
  final int allocationChunks;

  /// Objects per chunk.
  final int chunkSize;

  /// Number of allocation-pressure rounds run so far (diagnostics).
  int allocationRounds = 0;

  /// Number of VM GC requests made so far (diagnostics).
  int vmGcRequests = 0;

  /// Number of [scavenge] calls that observed a collection (diagnostics).
  int scavenges = 0;

  /// Chunks allocated by the last [scavenge] call (diagnostics).
  int lastScavengeChunks = 0;

  /// Elements per chunk allocated by [scavenge]: 128 KB, below the size at
  /// which the VM allocates straight into old space.
  static const int scavengeChunkLength = 16 * 1024;

  /// Upper bound of chunks allocated by one [scavenge] call (128 MB).
  static const int maxScavengeChunks = 1024;

  /// Holds the chunk being allocated so the allocation is observable.
  static List<Object?>? _sink;

  /// Triggers a new-space collection by allocating short-lived garbage until
  /// a probe object held only weakly has been collected.
  ///
  /// Synchronous and cheap: a 32 MB semi-space fills in a few milliseconds
  /// and the scavenge copies nothing of ours. The probe makes the outcome
  /// exact. Returns false when [maxScavengeChunks] were allocated without a
  /// collection (new space disabled or huge).
  bool scavenge() {
    final probe = _probe();
    var chunks = 0;
    while (chunks < maxScavengeChunks && probe.target != null) {
      _sink = List<Object?>.filled(scavengeChunkLength, null);
      chunks += (_sink?.length ?? 0) ~/ scavengeChunkLength;
    }
    _sink = null;
    lastScavengeChunks = chunks;
    if (probe.target == null) {
      scavenges++;
      return true;
    }
    return false;
  }

  /// In its own frame, so no slot of the caller keeps the probe target alive.
  @pragma('vm:never-inline')
  static WeakReference<Object> _probe() => WeakReference(Object());

  /// Collects garbage until the barrier is at least [target] or [timeout]
  /// elapses. Prefers [vmGc] (a full GC via the VM service) and falls back to
  /// allocation pressure, like `leak_tracker`'s `forceGC`.
  Future<bool> collectUntilBarrier(
    int target, {
    required Duration timeout,
    VmGcRequest? vmGc,
  }) async {
    final deadline = _now() + timeout.inMicroseconds;
    var vmAttempts = 0;
    while (_barrier() < target) {
      if (_now() > deadline) {
        return false;
      }
      if (vmGc != null && vmAttempts < 2) {
        vmAttempts++;
        vmGcRequests++;
        try {
          await vmGc();
        } on Object catch (_) {
          vmAttempts = 2;
        }
        continue;
      }
      await _allocationPressureRound();
    }
    return true;
  }

  Future<void> _allocationPressureRound() async {
    allocationRounds++;
    final storage = <List<Object>>[];
    for (var i = 0; i < allocationChunks; i++) {
      storage.add(List<Object>.generate(chunkSize, (_) => Object()));
      if (storage.length > 100) {
        storage.removeAt(0);
      }
      await Future<void>.delayed(Duration.zero);
    }
  }
}
