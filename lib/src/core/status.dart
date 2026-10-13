import 'package:flutter/foundation.dart';

/// The build mode / platform the package is running in.
enum RuntimeMode {
  /// Debug build on a VM platform.
  debug,

  /// Profile build on a VM platform.
  profile,

  /// Release build: a no-op unless `DevToolsLightConfig.allowInRelease`
  /// turns on jank detection without attribution.
  release,

  /// Web build (everything is a no-op).
  web;

  /// The mode of the current build.
  static RuntimeMode get current {
    if (kIsWeb) {
      return RuntimeMode.web;
    }
    if (kReleaseMode) {
      return RuntimeMode.release;
    }
    if (kProfileMode) {
      return RuntimeMode.profile;
    }
    return RuntimeMode.debug;
  }
}

/// State of the connection to the Dart VM service.
enum VmConnectionState {
  /// Not started.
  idle,

  /// Waiting for the tool's DDS to attach (or for the grace period).
  discovering,

  /// A VM-service URI is known and the last session succeeded.
  reachable,

  /// The last connection attempt failed; see the detail.
  failed,

  /// No VM service on this platform/build.
  unsupported,
}

/// State of the leak detector.
enum LeakDetectionState {
  /// Lifecycle objects are watched automatically (debug builds).
  automatic,

  /// Only objects passed to `DevToolsLight.watch` are watched.
  manualOnly,

  /// Off because this is not a debug build
  /// (`LeakDetectionConfig.allowInProfile` turns it on in profile builds).
  debugOnly,

  /// Disabled by configuration.
  disabled,

  /// Not available on this platform/build.
  unsupported,
}

/// State of the heap-growth monitor.
enum HeapTrendState {
  /// Snapshots are taken periodically.
  active,

  /// Disabled by configuration.
  disabled,

  /// Not available on this platform/build.
  unsupported,
}

/// State of the jank detector.
enum JankDetectionState {
  /// Jank is detected and attributed with CPU samples.
  attributing,

  /// Jank is detected but not attributed: the VM service is not (yet)
  /// reachable, or this is a release build.
  detectOnly,

  /// Disabled by configuration.
  disabled,

  /// Off because this is a debug build (`JankDetectionConfig.allowInDebug`
  /// turns it on).
  notInDebug,

  /// Not available on this platform/build.
  unsupported,
}

/// An immutable snapshot of what `dev_tools_light` is doing.
@immutable
class DevToolsLightStatus {
  /// Creates a status snapshot.
  const DevToolsLightStatus({
    this.mode = RuntimeMode.release,
    this.vm = VmConnectionState.idle,
    this.vmDetail,
    this.vmUri,
    this.leaks = LeakDetectionState.disabled,
    this.jank = JankDetectionState.disabled,
    this.heapTrends = HeapTrendState.disabled,
    this.profilerEnabled,
    this.samplePeriodMicros,
    this.appPackagePrefixes = const {},
    this.clockOffsetMicros,
    this.watchedObjects = 0,
    this.retainedCandidates = 0,
    this.droppedCandidates = 0,
    this.skippedByPackagePolicy = 0,
    this.leakChecksRun = 0,
    this.selfInflictedStallsSuppressed = 0,
    this.heapSnapshots = 0,
    this.lastHeapSnapshotMicros,
    this.heapTrendDetail,
    this.lastError,
  });

  /// Build mode / platform.
  final RuntimeMode mode;

  /// VM-service connection state.
  final VmConnectionState vm;

  /// Human-readable detail for [vm] (for example the failure reason).
  final String? vmDetail;

  /// The VM-service WebSocket URI in use, if any.
  final String? vmUri;

  /// Leak detector state.
  final LeakDetectionState leaks;

  /// Jank detector state.
  final JankDetectionState jank;

  /// Heap-growth monitor state.
  final HeapTrendState heapTrends;

  /// Whether the VM profiler is enabled (null while unknown).
  final bool? profilerEnabled;

  /// The VM's CPU sampling period in microseconds (null while unknown).
  final int? samplePeriodMicros;

  /// `package:` prefixes treated as app code.
  final Set<String> appPackagePrefixes;

  /// Measured offset between the engine frame clock and the timeline clock.
  final int? clockOffsetMicros;

  /// Objects currently watched for leaks.
  final int watchedObjects;

  /// Objects that survived their retained delay and await a GC check.
  final int retainedCandidates;

  /// Candidates dropped because a GC could not be confirmed in time.
  final int droppedCandidates;

  /// Objects not watched, or dropped before a report, because the package
  /// declaring their class is not watched (`WatchedPackages`).
  final int skippedByPackagePolicy;

  /// Number of leak checks (forced GC + analysis) run so far.
  final int leakChecksRun;

  /// Jank candidates dropped because we caused them ourselves.
  final int selfInflictedStallsSuppressed;

  /// Heap snapshots taken for growth trends.
  final int heapSnapshots;

  /// How long the last heap snapshot took (null before the first).
  final int? lastHeapSnapshotMicros;

  /// What triggers heap snapshots and how that is going (for example how
  /// many VM collections were seen).
  final String? heapTrendDetail;

  /// The last error message, if any.
  final String? lastError;

  @override
  bool operator ==(Object other) =>
      other is DevToolsLightStatus &&
      other.mode == mode &&
      other.vm == vm &&
      other.vmDetail == vmDetail &&
      other.vmUri == vmUri &&
      other.leaks == leaks &&
      other.jank == jank &&
      other.heapTrends == heapTrends &&
      other.profilerEnabled == profilerEnabled &&
      other.samplePeriodMicros == samplePeriodMicros &&
      setEquals(other.appPackagePrefixes, appPackagePrefixes) &&
      other.clockOffsetMicros == clockOffsetMicros &&
      other.watchedObjects == watchedObjects &&
      other.retainedCandidates == retainedCandidates &&
      other.droppedCandidates == droppedCandidates &&
      other.skippedByPackagePolicy == skippedByPackagePolicy &&
      other.leakChecksRun == leakChecksRun &&
      other.selfInflictedStallsSuppressed == selfInflictedStallsSuppressed &&
      other.heapSnapshots == heapSnapshots &&
      other.lastHeapSnapshotMicros == lastHeapSnapshotMicros &&
      other.heapTrendDetail == heapTrendDetail &&
      other.lastError == lastError;

  @override
  int get hashCode => Object.hashAll([
    mode,
    vm,
    vmDetail,
    vmUri,
    leaks,
    jank,
    heapTrends,
    profilerEnabled,
    samplePeriodMicros,
    Object.hashAllUnordered(appPackagePrefixes),
    clockOffsetMicros,
    watchedObjects,
    retainedCandidates,
    droppedCandidates,
    skippedByPackagePolicy,
    leakChecksRun,
    selfInflictedStallsSuppressed,
    heapSnapshots,
    lastHeapSnapshotMicros,
    heapTrendDetail,
    lastError,
  ]);

  /// Returns a copy with the given fields replaced.
  DevToolsLightStatus copyWith({
    RuntimeMode? mode,
    VmConnectionState? vm,
    String? vmDetail,
    String? vmUri,
    LeakDetectionState? leaks,
    JankDetectionState? jank,
    HeapTrendState? heapTrends,
    bool? profilerEnabled,
    int? samplePeriodMicros,
    Set<String>? appPackagePrefixes,
    int? clockOffsetMicros,
    int? watchedObjects,
    int? retainedCandidates,
    int? droppedCandidates,
    int? skippedByPackagePolicy,
    int? leakChecksRun,
    int? selfInflictedStallsSuppressed,
    int? heapSnapshots,
    int? lastHeapSnapshotMicros,
    String? heapTrendDetail,
    String? lastError,
  }) {
    return DevToolsLightStatus(
      mode: mode ?? this.mode,
      vm: vm ?? this.vm,
      vmDetail: vmDetail ?? this.vmDetail,
      vmUri: vmUri ?? this.vmUri,
      leaks: leaks ?? this.leaks,
      jank: jank ?? this.jank,
      heapTrends: heapTrends ?? this.heapTrends,
      profilerEnabled: profilerEnabled ?? this.profilerEnabled,
      samplePeriodMicros: samplePeriodMicros ?? this.samplePeriodMicros,
      appPackagePrefixes: appPackagePrefixes ?? this.appPackagePrefixes,
      clockOffsetMicros: clockOffsetMicros ?? this.clockOffsetMicros,
      watchedObjects: watchedObjects ?? this.watchedObjects,
      retainedCandidates: retainedCandidates ?? this.retainedCandidates,
      droppedCandidates: droppedCandidates ?? this.droppedCandidates,
      skippedByPackagePolicy:
          skippedByPackagePolicy ?? this.skippedByPackagePolicy,
      leakChecksRun: leakChecksRun ?? this.leakChecksRun,
      selfInflictedStallsSuppressed:
          selfInflictedStallsSuppressed ?? this.selfInflictedStallsSuppressed,
      heapSnapshots: heapSnapshots ?? this.heapSnapshots,
      lastHeapSnapshotMicros:
          lastHeapSnapshotMicros ?? this.lastHeapSnapshotMicros,
      heapTrendDetail: heapTrendDetail ?? this.heapTrendDetail,
      lastError: lastError ?? this.lastError,
    );
  }
}
