import 'dart:math' as math;

import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/fnv_hash.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/stall_guard.dart';
import 'package:dev_tools_light/src/leaks/leak_report.dart';
import 'package:dev_tools_light/src/leaks/leak_trace_builder.dart';
import 'package:dev_tools_light/src/leaks/object_watcher.dart';
import 'package:dev_tools_light/src/leaks/package_watch_policy.dart';
import 'package:dev_tools_light/src/leaks/reference_matchers.dart';
import 'package:dev_tools_light/src/vm/gc_controller.dart';
import 'package:dev_tools_light/src/vm/object_inspector.dart';
import 'package:dev_tools_light/src/vm/retaining_path_client.dart';
import 'package:dev_tools_light/src/vm/runtime_bridge.dart';
import 'package:dev_tools_light/src/vm/script_line_resolver.dart';
import 'package:dev_tools_light/src/vm/strong_path_finder.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:dev_tools_light/src/vm/vm_session.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// LeakCanary's heap-dump trigger + Shark analysis, adapted to the VM service:
/// force a GC, re-check the candidates, fetch retaining paths and publish
/// [LeakReport]s.
class LeakAnalyzer {
  /// Creates an analyzer.
  LeakAnalyzer({
    required LeakDetectionConfig config,
    required RuntimeBridge bridge,
    required VmSession session,
    required GcController gc,
    required ReportStore store,
    required SelfInflictedStallGuard guard,
    required AppCodeClassifier classifier,
    RetainingPathClient pathClient = const RetainingPathClient(),
    PackageWatchPolicy? policy,
    ScriptLineResolver? lineResolver,
    int? Function()? lastPostFrameMicros,
    DateTime Function()? wallClock,
    void Function(String message)? log,
  }) : _config = config,
       _bridge = bridge,
       _session = session,
       _gc = gc,
       _store = store,
       _guard = guard,
       _paths = pathClient,
       _policy = policy,
       _lastPostFrameMicros = lastPostFrameMicros,
       _wallClock = wallClock ?? DateTime.now,
       _log = log,
       _builder = LeakTraceBuilder(
         classifier: classifier,
         lineResolver: lineResolver ?? ScriptLineResolver(),
       ),
       _strongPaths = StrongPathFinder(maxLookups: config.strongPathLookups);

  final LeakDetectionConfig _config;
  final RuntimeBridge _bridge;
  final VmSession _session;
  final GcController _gc;
  final ReportStore _store;
  final SelfInflictedStallGuard _guard;
  final RetainingPathClient _paths;
  final PackageWatchPolicy? _policy;
  final int? Function()? _lastPostFrameMicros;
  final DateTime Function() _wallClock;
  final void Function(String message)? _log;
  final LeakTraceBuilder _builder;
  final StrongPathFinder _strongPaths;
  int _sequence = 0;

  /// Candidates dropped because a GC could not be confirmed.
  int droppedCandidates = 0;

  /// Traces whose weak path was replaced by a strong one.
  int strongPathsFound = 0;

  /// Candidates deferred because no frame had completed since disposal.
  int deferredChecks = 0;

  /// Analyzes [candidates]; returns the resolved ids (see
  /// [RetainedCandidatesHandler]). Unless [forced], objects disposed after
  /// the last completed frame are deferred: the framework releases routes,
  /// overlay entries and controllers from post-frame callbacks.
  Future<Set<int>> analyze(
    List<WatchedObject> candidates, {
    bool forced = false,
  }) {
    return _guard.guard(() async {
      final resolved = <int>{};
      final ready = forced ? candidates : _withoutDeferred(candidates);
      if (ready.isEmpty) {
        return resolved;
      }
      try {
        await _session.run((api) => _analyzeWithVm(api, ready, resolved));
      } on VmUnavailableException catch (error) {
        await _analyzeWithoutVm(ready, resolved, error.message);
      }
      return resolved;
    }, label: 'leaks');
  }

  List<WatchedObject> _withoutDeferred(List<WatchedObject> candidates) {
    final lastPostFrame = _lastPostFrameMicros;
    if (lastPostFrame == null) {
      return candidates;
    }
    final frameMicros = lastPostFrame();
    final ready = <WatchedObject>[];
    final deferred = <String>[];
    for (final candidate in candidates) {
      if ((frameMicros != null && frameMicros > candidate.watchedAtMicros) ||
          candidate.deferredChecks >= _config.maxDeferredChecks) {
        ready.add(candidate);
        continue;
      }
      candidate.deferredChecks++;
      deferredChecks++;
      deferred.add(candidate.typeName);
    }
    if (deferred.isNotEmpty) {
      _log?.call(
        'deferring ${deferred.length} retained object(s) until a frame '
        'completes: ${deferred.join(', ')}',
      );
    }
    return ready;
  }

  int _gcTarget(List<WatchedObject> candidates) {
    final barrier = candidates
        .map((c) => c.barrierAtCandidate ?? c.barrierAtWatch)
        .reduce(math.max);
    return barrier + _config.requiredGcCycles;
  }

  void _handleGcTimeout(List<WatchedObject> candidates, Set<int> resolved) {
    _log?.call('GC could not be confirmed within ${_config.gcTimeout}');
    for (final candidate in candidates) {
      candidate.gcAttempts++;
      if (candidate.gcAttempts >= _config.maxGcAttemptsPerObject) {
        resolved.add(candidate.id);
        droppedCandidates++;
      }
    }
  }

  Future<void> _analyzeWithVm(
    VmApi api,
    List<WatchedObject> candidates,
    Set<int> resolved,
  ) async {
    final isolateId = _bridge.currentIsolateId;
    final collected = await _gc.collectUntilBarrier(
      _gcTarget(candidates),
      timeout: _config.gcTimeout,
      vmGc: isolateId == null ? null : () => api.collectAllGarbage(isolateId),
    );
    if (!collected) {
      _handleGcTimeout(candidates, resolved);
      return;
    }
    final retained = <WatchedObject>[];
    for (final candidate in candidates) {
      if (candidate.isCollected || _skippedByPolicy(candidate)) {
        resolved.add(candidate.id);
      } else {
        retained.add(candidate);
      }
    }
    retained.sort((a, b) => a.watchedAtMicros.compareTo(b.watchedAtMicros));
    for (final candidate in retained.take(_config.maxTracesPerCheck)) {
      await _analyzeRetained(api, isolateId, candidate);
      resolved.add(candidate.id);
    }
  }

  Future<void> _analyzeWithoutVm(
    List<WatchedObject> candidates,
    Set<int> resolved,
    String reason,
  ) async {
    final collected = await _gc.collectUntilBarrier(
      _gcTarget(candidates),
      timeout: _config.gcTimeout,
    );
    if (!collected) {
      _handleGcTimeout(candidates, resolved);
      return;
    }
    for (final candidate in candidates) {
      if (!candidate.isCollected && _config.reportWithoutTrace) {
        _reportWithoutTrace(
          candidate,
          LeakTraceUnavailableReason.noVmService,
          reason,
        );
      }
      resolved.add(candidate.id);
    }
  }

  Future<void> _analyzeRetained(
    VmApi api,
    String? isolateId,
    WatchedObject candidate,
  ) async {
    if (isolateId == null) {
      _reportWithoutTrace(candidate, LeakTraceUnavailableReason.noObjectId);
      return;
    }
    final objectId = _objectIdOf(candidate);
    if (objectId == null) {
      if (!candidate.isCollected) {
        _reportWithoutTrace(candidate, LeakTraceUnavailableReason.noObjectId);
      }
      return;
    }
    // From here on nothing of ours may reference the object, not even weakly:
    // the VM's retaining-path search would happily report our WeakReference.
    candidate.detachReference();
    final result = await _paths.fetch(
      api,
      isolateId: isolateId,
      objectId: objectId,
      limit: _config.retainingPathLimit,
    );
    final path = result.path;
    if (path == null) {
      if (result.failure != RetainingPathFailure.collected) {
        _reportWithoutTrace(
          candidate,
          LeakTraceUnavailableReason.rpcError,
          result.message,
        );
      }
      return;
    }
    if ((path.elements?.length ?? 0) <= 1) {
      // Nothing but a VM root (a handle, the stack, the object-id ring) holds
      // the object: it is in flight and will be collected shortly.
      _log?.call(
        'skipping ${candidate.typeName}: only a VM root '
        '(${path.gcRootType}) holds it',
      );
      return;
    }
    final policy = _policy;
    final leaf = path.elements!.first.value;
    final leafLibrary = leaf is vms.InstanceRef
        ? leaf.classRef?.library?.uri
        : null;
    if (policy != null && leafLibrary != null) {
      policy.learn(candidate.type, leafLibrary);
      if (candidate.kind.isAutomatic && !policy.allowsLibrary(leafLibrary)) {
        policy.skipped++;
        _log?.call(
          'ignored leak of ${candidate.typeName}: declared by '
          '${policy.describeLibrary(leafLibrary)}, which is not watched '
          '(see WatchedPackages)',
        );
        return;
      }
    }
    final (strongPath, note) = await _strongPathFor(
      api,
      isolateId,
      candidate.typeName,
      path,
    );
    final trace = await _builder.build(
      strongPath,
      leakedTypeName: candidate.typeName,
      api: api,
      isolateId: isolateId,
      inspector: _config.inspectObjects
          ? ObjectInspector(maxInspections: _config.maxInspectedNodes)
          : null,
      note: note,
    );
    if (trace.leakedObject.origin == CodeOrigin.tooling) {
      return;
    }
    String? libraryLeak;
    for (final matcher in _config.referenceMatchers) {
      if (!matcher.matches(trace)) {
        continue;
      }
      switch (matcher) {
        case IgnoredReferenceMatcher():
          _log?.call(
            'ignored leak of ${candidate.typeName}: ${matcher.description}',
          );
          return;
        case LibraryLeakReferenceMatcher():
          libraryLeak ??= matcher.description;
      }
    }
    final finalTrace = libraryLeak == null
        ? trace
        : trace.copyWith(libraryLeakDescription: libraryLeak);
    final now = _wallClock();
    _store.addLeak(
      LeakReport(
        id: 'leak-${_sequence++}',
        detectedAt: now,
        typeName: candidate.typeName,
        kind: candidate.kind,
        description: candidate.description,
        trace: finalTrace,
        signature: finalTrace.signature,
        firstSeen: now,
        lastSeen: now,
        isLibraryLeak: libraryLeak != null,
      ),
    );
    _log?.call('leak: ${candidate.typeName} ← ${finalTrace.summary}');
  }

  /// Whether [candidate]'s class is already known to belong to a package
  /// that is not watched.
  bool _skippedByPolicy(WatchedObject candidate) {
    final policy = _policy;
    if (policy == null ||
        !candidate.kind.isAutomatic ||
        policy.allowsType(candidate.type) != false) {
      return false;
    }
    policy.skipped++;
    _log?.call('skipping ${candidate.typeName}: its package is not watched');
    return true;
  }

  /// Replaces a path that runs through a weak reference by a path of strong
  /// references when the search succeeds; the note explains the swap.
  Future<(vms.RetainingPath, String?)> _strongPathFor(
    VmApi api,
    String isolateId,
    String typeName,
    vms.RetainingPath path,
  ) async {
    if (_config.strongPathLookups <= 0 ||
        StrongPathFinder.firstWeakLink(path) <= 0) {
      return (path, null);
    }
    final strong = await _strongPaths.find(
      api,
      isolateId: isolateId,
      path: path,
      limit: _config.retainingPathLimit,
    );
    final found = strong.path;
    if (found == null) {
      _log?.call(
        '$typeName: the VM reported a path through ${strong.weakHolder} and '
        'no strong path was found (${strong.detail})',
      );
      return (path, null);
    }
    strongPathsFound++;
    _log?.call(
      '$typeName: strong path found behind ${strong.weakHolder} with '
      '${strong.lookups} lookups',
    );
    return (
      found,
      'The VM first reported a path through a weak reference '
          '(${strong.weakHolder}); this path of strong references was found '
          'with ${strong.lookups} inbound-reference lookups.',
    );
  }

  /// Obtains the VM object id without holding a strong reference across an
  /// `await` (the strong reference lives only in this synchronous frame).
  String? _objectIdOf(WatchedObject candidate) {
    final target = candidate.target;
    if (target == null) {
      return null;
    }
    return _bridge.objectIdOf(target);
  }

  void _reportWithoutTrace(
    WatchedObject candidate,
    LeakTraceUnavailableReason reason, [
    String? detail,
  ]) {
    if (!_config.reportWithoutTrace) {
      return;
    }
    final now = _wallClock();
    _store.addLeak(
      LeakReport(
        id: 'leak-${_sequence++}',
        detectedAt: now,
        typeName: candidate.typeName,
        kind: candidate.kind,
        description: candidate.description,
        traceUnavailableReason: reason,
        traceUnavailableDetail: detail,
        signature: stableSignature([
          'notrace',
          candidate.typeName,
          candidate.kind.name,
        ]),
        firstSeen: now,
        lastSeen: now,
      ),
    );
    _log?.call(
      'leak (no trace, ${reason.description}): ${candidate.typeName}',
    );
  }
}
