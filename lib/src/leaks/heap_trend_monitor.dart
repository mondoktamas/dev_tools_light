import 'dart:async';

import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/clock.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/stall_guard.dart';
import 'package:dev_tools_light/src/leaks/heap_trend_report.dart';
import 'package:dev_tools_light/src/leaks/leak_trace.dart';
import 'package:dev_tools_light/src/leaks/leak_trace_builder.dart';
import 'package:dev_tools_light/src/vm/gc_controller.dart';
import 'package:dev_tools_light/src/vm/object_inspector.dart';
import 'package:dev_tools_light/src/vm/script_line_resolver.dart';
import 'package:dev_tools_light/src/vm/strong_path_finder.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:dev_tools_light/src/vm/vm_session.dart';
import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// Takes heap snapshots (per-class live counts), reports classes that keep
/// growing, and fetches a retaining path for one live instance on demand.
///
/// With [HeapSnapshotTrigger.afterVmGc] the snapshots follow the VM's own
/// major collections, observed through `reachabilityBarrier`; the other
/// triggers run on a timer. See [HeapTrendConfig].
class HeapTrendMonitor {
  /// Creates a monitor.
  HeapTrendMonitor({
    required HeapTrendConfig config,
    required VmSession session,
    required SelfInflictedStallGuard guard,
    required ReportStore store,
    required AppCodeClassifier classifier,
    required NowMicros now,
    required String? Function() isolateId,
    required int Function() barrier,
    GcController? gc,
    LeakTraceBuilder? builder,
    StrongPathFinder strongPaths = const StrongPathFinder(),
    bool Function()? isBusy,
    DateTime Function()? wallClock,
    void Function(String message)? log,
  }) : _config = config,
       _session = session,
       _guard = guard,
       _store = store,
       _classifier = classifier,
       _now = now,
       _isolateId = isolateId,
       _barrier = barrier,
       _gc = gc ?? GcController(barrier: barrier, now: now),
       _builder =
           builder ??
           LeakTraceBuilder(
             classifier: classifier,
             lineResolver: ScriptLineResolver(),
           ),
       _strongPaths = strongPaths,
       _isBusy = isBusy,
       _wallClock = wallClock ?? DateTime.now,
       _log = log;

  final HeapTrendConfig _config;
  final VmSession _session;
  final SelfInflictedStallGuard _guard;
  final ReportStore _store;
  final AppCodeClassifier _classifier;
  final NowMicros _now;
  final String? Function() _isolateId;
  final int Function() _barrier;
  final GcController _gc;
  final LeakTraceBuilder _builder;
  final StrongPathFinder _strongPaths;
  final bool Function()? _isBusy;
  final DateTime Function() _wallClock;
  final void Function(String message)? _log;

  /// A VM collection seen while something else was in flight is used by a
  /// later poll, as long as it is not older than this.
  static const Duration maxPendingGcAge = Duration(seconds: 5);

  final Map<String, _ClassHistory> _history = {};
  Timer? _timer;
  bool _running = false;
  Future<bool>? _inFlight;
  int _sequence = 0;
  String? _lastLoggedProblem;
  int? _lastPolledBarrier;
  int? _pendingGcMicros;
  int _lastSnapshotMicros = -1 << 60;

  /// Snapshots taken so far.
  int snapshotsTaken = 0;

  /// How long the last snapshot took (timeline micros).
  int lastSnapshotCostMicros = 0;

  /// Snapshots skipped because something else was in flight.
  int skippedBusy = 0;

  /// VM collections observed while polling ([HeapSnapshotTrigger.afterVmGc]).
  int vmGcsObserved = 0;

  /// Snapshots taken after a VM collection (the rest were scheduled or
  /// manual).
  int vmGcSnapshots = 0;

  /// VM collections that came too soon after the previous snapshot, or while
  /// something else stayed in flight, and were not used.
  int vmGcsSkipped = 0;

  /// Classes currently tracked (those with at least one live instance).
  int get trackedClasses => _history.length;

  /// Starts taking snapshots.
  void start() {
    _running = true;
    switch (_config.trigger) {
      case HeapSnapshotTrigger.afterVmGc:
        _lastPolledBarrier = _barrier();
        _timer?.cancel();
        _timer = Timer.periodic(
          _config.vmGcPollInterval,
          (_) => unawaited(poll()),
        );
      case HeapSnapshotTrigger.forcedGc:
      case HeapSnapshotTrigger.periodic:
        _schedule(_config.interval);
    }
  }

  /// Stops taking snapshots.
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// One-line description of the trigger and its progress, for the status.
  String describe() => switch (_config.trigger) {
    HeapSnapshotTrigger.afterVmGc =>
      'after VM collections: $vmGcsObserved seen, $vmGcSnapshots used'
          '${vmGcsObserved == 0 ? ' (waiting for the first)' : ''}',
    HeapSnapshotTrigger.forcedGc =>
      'forced GC every ${_config.interval.inSeconds} s',
    HeapSnapshotTrigger.periodic =>
      'every ${_config.interval.inSeconds} s without GC',
  };

  Duration get _spacing {
    final byCost = Duration(
      microseconds: lastSnapshotCostMicros * _config.costFactor,
    );
    return byCost > _config.interval ? byCost : _config.interval;
  }

  /// Checks `reachabilityBarrier` once and takes a snapshot after a VM
  /// collection ([HeapSnapshotTrigger.afterVmGc]).
  @visibleForTesting
  Future<void> poll() async {
    if (!_running || _inFlight != null) {
      return;
    }
    final barrier = _barrier();
    final last = _lastPolledBarrier;
    _lastPolledBarrier = barrier;
    final now = _now();
    if (last != null && barrier > last) {
      vmGcsObserved++;
      if (now - _lastSnapshotMicros < _spacing.inMicroseconds) {
        vmGcsSkipped++;
        return;
      }
      _pendingGcMicros = now;
    }
    final pending = _pendingGcMicros;
    if (pending == null) {
      return;
    }
    if (now - pending > maxPendingGcAge.inMicroseconds) {
      _pendingGcMicros = null;
      vmGcsSkipped++;
      return;
    }
    if (_guard.isOpen || (_isBusy?.call() ?? false)) {
      skippedBusy++;
      return;
    }
    _pendingGcMicros = null;
    if (await _snapshot(forceGc: false, reason: 'after a VM collection')) {
      vmGcSnapshots++;
    }
  }

  void _schedule(Duration delay) {
    if (!_running) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(delay, () async {
      if (_guard.isOpen || (_isBusy?.call() ?? false)) {
        skippedBusy++;
        _schedule(const Duration(seconds: 2));
        return;
      }
      await snapshotNow(
        forceGc: _config.trigger == HeapSnapshotTrigger.forcedGc,
        reason: 'scheduled',
      );
      _schedule(_spacing);
    });
  }

  /// Takes a snapshot now and evaluates the trends; a snapshot already in
  /// progress is awaited first. [forceGc] defaults to true unless the
  /// trigger is [HeapSnapshotTrigger.periodic]. Returns false when the VM
  /// service was not available.
  Future<bool> snapshotNow({bool? forceGc, String reason = 'manual'}) async {
    while (_inFlight != null) {
      await _inFlight;
    }
    return _snapshot(
      forceGc: forceGc ?? _config.trigger != HeapSnapshotTrigger.periodic,
      reason: reason,
    );
  }

  Future<bool> _snapshot({
    required bool forceGc,
    required String reason,
  }) async {
    final isolateId = _isolateId();
    if (isolateId == null) {
      return false;
    }
    final completer = Completer<bool>();
    _inFlight = completer.future;
    var taken = false;
    try {
      var scavenged = false;
      var cost = 0;
      final profile = await _session.run(
        (api) => _guard.guard(() async {
          // Measured from here: the time spent discovering the VM service
          // (up to the grace period) is not a cost of the snapshot.
          final started = _now();
          try {
            if (!forceGc && _config.scavengeBeforeSnapshot) {
              scavenged = _gc.scavenge();
            }
            return await api.getAllocationProfile(isolateId, gc: forceGc);
          } finally {
            cost = _now() - started;
          }
        }, label: 'heap'),
      );
      lastSnapshotCostMicros = cost;
      _lastSnapshotMicros = _now();
      // A forced GC advances the barrier; it is not a VM collection.
      _lastPolledBarrier = _barrier();
      snapshotsTaken++;
      _record(profile);
      final reported = _evaluate();
      _log?.call(
        'heap snapshot #$snapshotsTaken ($reason, '
        '${forceGc
            ? 'forced GC'
            : scavenged
            ? 'scavenged'
            : 'no GC'}) in '
        '${lastSnapshotCostMicros ~/ 1000} ms: $trackedClasses classes '
        'tracked, $reported growing',
      );
      _lastLoggedProblem = null;
      taken = true;
    } on VmUnavailableException catch (error) {
      _problem('heap snapshot skipped: ${error.message}');
    } on Object catch (error) {
      _problem('heap snapshot failed: $error');
    } finally {
      _inFlight = null;
      completer.complete(taken);
    }
    return taken;
  }

  void _problem(String message) {
    if (message != _lastLoggedProblem) {
      _lastLoggedProblem = message;
      _log?.call(message);
    }
  }

  void _record(vms.AllocationProfile profile) {
    final at = _wallClock();
    for (final member in profile.members ?? const <vms.ClassHeapStats>[]) {
      final ref = member.classRef;
      if (ref == null) {
        continue;
      }
      final name = ref.name ?? '?';
      final uri = ref.library?.uri ?? '';
      final key = '$uri|$name';
      final instances = member.instancesCurrent ?? 0;
      final history = _history[key];
      if (history == null && instances <= 0) {
        continue;
      }
      final entry =
          history ??
          _ClassHistory(
            className: name,
            libraryUri: uri,
            classId: ref.id ?? '',
          );
      _history[key] = entry
        ..classId = ref.id ?? entry.classId
        ..add(
          HeapTrendSample(
            at: at,
            instances: instances,
            bytes: member.bytesCurrent ?? 0,
          ),
          _config.window,
        );
    }
  }

  int _evaluate() {
    final suspects = <HeapTrendReport>[];
    for (final history in _history.values) {
      final run = history.risingRun();
      if (run.length < 2 || _increases(run) < _config.minRisingSnapshots) {
        continue;
      }
      final growth = run.last.instances - run.first.instances;
      final bytesGrowth = run.last.bytes - run.first.bytes;
      if (growth < _config.minInstanceGrowth &&
          bytesGrowth < _config.minBytesGrowth) {
        continue;
      }
      if (growth < run.first.instances * _config.minRelativeGrowth) {
        continue;
      }
      if (_config.ignoredClassNames.contains(history.className)) {
        continue;
      }
      final origin = _classifier.classify(history.libraryUri);
      switch (origin) {
        case CodeOrigin.dart:
        case CodeOrigin.tooling:
        case CodeOrigin.unknown:
          continue;
        case CodeOrigin.flutter:
        case CodeOrigin.library:
          if (!_config.includeFrameworkClasses) {
            continue;
          }
        case CodeOrigin.app:
          break;
      }
      final now = _wallClock();
      suspects.add(
        HeapTrendReport(
          id: 'heap-${_sequence++}',
          className: history.className,
          libraryUri: history.libraryUri,
          origin: origin,
          classId: history.classId,
          samples: List.unmodifiable(run),
          firstSeen: now,
          lastSeen: now,
        ),
      );
    }
    suspects.sort((a, b) => b.instanceGrowth.compareTo(a.instanceGrowth));
    final reported = suspects.take(_config.maxSuspects).toList()
      ..forEach(_store.addHeapTrend);
    return reported.length;
  }

  static int _increases(List<HeapTrendSample> run) {
    var count = 0;
    for (var i = 1; i < run.length; i++) {
      if (run[i].instances > run[i - 1].instances) {
        count++;
      }
    }
    return count;
  }

  /// Fetches the retaining path of one live instance of the class reported
  /// in [reportId] and stores it on the report.
  Future<void> fetchTrace(String reportId) async {
    final report = _store.heapTrendById(reportId);
    if (report == null || report.traceState == HeapTrendTraceState.fetching) {
      return;
    }
    _store.updateHeapTrend(
      reportId,
      (r) => r.copyWith(traceState: HeapTrendTraceState.fetching),
    );
    try {
      final isolateId = _isolateId();
      if (isolateId == null) {
        throw VmUnavailableException('no isolate id (service protocol off)');
      }
      final result = await _session.run(
        (api) => _guard.guard(
          () => _traceOneInstance(api, isolateId, report),
          label: 'heap-path',
        ),
      );
      _store.updateHeapTrend(
        reportId,
        (r) => r.copyWith(
          trace: result.trace,
          traceState: result.trace == null
              ? HeapTrendTraceState.failed
              : HeapTrendTraceState.fetched,
          traceDetail: result.detail,
        ),
      );
    } on Object catch (error) {
      final message = error is VmUnavailableException
          ? error.message
          : '$error';
      _store.updateHeapTrend(
        reportId,
        (r) => r.copyWith(
          traceState: HeapTrendTraceState.failed,
          traceDetail: message,
        ),
      );
    }
  }

  Future<_TraceResult> _traceOneInstance(
    VmApi api,
    String isolateId,
    HeapTrendReport report,
  ) async {
    final set = await api.getInstances(
      isolateId,
      report.classId,
      _config.instancesToInspect,
    );
    final instances = set.instances ?? const <vms.ObjRef>[];
    var rootOnly = 0;
    for (final instance in instances) {
      final id = instance.id;
      if (id == null) {
        continue;
      }
      vms.RetainingPath path;
      try {
        path = await api.getRetainingPath(isolateId, id, 100);
      } on vms.SentinelException {
        // Collected between getInstances and now: try the next one.
        rootOnly++;
        continue;
      } on vms.RPCError catch (error) {
        _log?.call('getRetainingPath failed for $id: ${error.message}');
        continue;
      }
      if ((path.elements?.length ?? 0) <= 1) {
        rootOnly++;
        continue;
      }
      String? note;
      if (StrongPathFinder.firstWeakLink(path) > 0) {
        final strong = await _strongPaths.find(
          api,
          isolateId: isolateId,
          path: path,
          limit: 100,
        );
        final found = strong.path;
        if (found != null) {
          path = found;
          note =
              'The VM first reported a path through a weak reference '
              '(${strong.weakHolder}); this path of strong references was '
              'found with ${strong.lookups} inbound-reference lookups.';
        }
      }
      final trace = await _builder.build(
        path,
        leakedTypeName: report.className,
        leafStatusReason: 'live instance of a growing class',
        api: api,
        isolateId: isolateId,
        inspector: ObjectInspector(maxInspections: 12),
        note: note,
      );
      return _TraceResult(
        trace,
        'One of ${set.totalCount ?? instances.length} live instances.',
      );
    }
    return _TraceResult(
      null,
      instances.isEmpty
          ? 'The VM returned no live instances.'
          : '$rootOnly of ${instances.length} sampled instances were held '
                'only by a VM root (in flight); try again later.',
    );
  }
}

class _TraceResult {
  const _TraceResult(this.trace, this.detail);

  final LeakTrace? trace;
  final String detail;
}

class _ClassHistory {
  _ClassHistory({
    required this.className,
    required this.libraryUri,
    required this.classId,
  });

  final String className;
  final String libraryUri;
  String classId;
  final List<HeapTrendSample> samples = [];

  void add(HeapTrendSample sample, int window) {
    samples.add(sample);
    if (samples.length > window) {
      samples.removeAt(0);
    }
  }

  /// The longest suffix in which the count never decreased.
  List<HeapTrendSample> risingRun() {
    var start = samples.length - 1;
    while (start > 0 &&
        samples[start].instances >= samples[start - 1].instances) {
      start--;
    }
    return samples.sublist(start);
  }
}
