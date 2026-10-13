import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/leaks/reference_matchers.dart';
import 'package:dev_tools_light/src/leaks/watched_kind.dart';
import 'package:dev_tools_light/src/leaks/watched_packages.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Alignment;

/// Decides whether a disposed object should be watched in addition to the
/// built-in [WatchedKind]s.
typedef WatchFilter = bool Function(Object object);

/// Top-level configuration for `DevToolsLight.start`.
@immutable
class DevToolsLightConfig {
  /// Creates a configuration; every field has a sensible default.
  const DevToolsLightConfig({
    this.leaks = const LeakDetectionConfig(),
    this.jank = const JankDetectionConfig(),
    this.heapTrend = const HeapTrendConfig(),
    this.overlay = const OverlayConfig(),
    this.appCode = const AppCodeConfig(),
    this.log = false,
    this.allowInTests = false,
    this.allowInRelease = false,
    this.vmDiscoveryGrace = const Duration(seconds: 10),
  });

  /// Leak detection settings.
  final LeakDetectionConfig leaks;

  /// Jank detection settings.
  final JankDetectionConfig jank;

  /// Heap-growth trend settings.
  final HeapTrendConfig heapTrend;

  /// Overlay UI settings.
  final OverlayConfig overlay;

  /// How the app's own code is recognised.
  final AppCodeConfig appCode;

  /// Print engine events with `debugPrint`.
  final bool log;

  /// Run even when `FLUTTER_TEST` is set (our periodic timers would otherwise
  /// break `testWidgets`).
  final bool allowInTests;

  /// Run jank *detection* in release builds too: slow frames and UI stalls
  /// are reported with their durations, the badge, toasts and panel work,
  /// but there is no VM service, so no CPU samples, leak traces or heap
  /// snapshots (those features report themselves as unsupported). Meant for
  /// QA builds; off by default so a release build does nothing.
  final bool allowInRelease;

  /// How long to wait for the tool's DDS to attach before connecting to the
  /// raw VM service directly. Connecting too early would prevent DDS from
  /// taking control and silently degrade `flutter run`'s tooling.
  final Duration vmDiscoveryGrace;
}

/// How app code is told apart from framework/SDK/package code.
@immutable
class AppCodeConfig {
  /// Creates app-code settings.
  const AppCodeConfig({
    this.packagePrefixes,
    this.extraPackagePrefixes = const {},
    this.toolingPrefixes = const {
      'package:dev_tools_light/',
      'package:vm_service/',
    },
    this.isAppUri,
  });

  /// URI prefixes that are app code. When null the prefix is derived from the
  /// main isolate's root library (`package:<app>/`).
  final Set<String>? packagePrefixes;

  /// Additional app prefixes, for example internal monorepo packages.
  final Set<String> extraPackagePrefixes;

  /// Prefixes of tooling code that is never reported.
  final Set<String> toolingPrefixes;

  /// Full override; wins over every other rule when it returns true.
  final AppUriPredicate? isAppUri;
}

/// Leak detection settings.
@immutable
class LeakDetectionConfig {
  /// Creates leak detection settings.
  const LeakDetectionConfig({
    this.enabled = true,
    this.allowInProfile = false,
    this.retainedDelay = const Duration(seconds: 5),
    this.batchWindow = const Duration(seconds: 1),
    this.minIntervalBetweenChecks = const Duration(seconds: 10),
    this.maxTracesPerCheck = 5,
    this.maxAnalysesPerMinute = 10,
    this.requiredGcCycles = 1,
    this.gcTimeout = const Duration(seconds: 3),
    this.maxGcAttemptsPerObject = 3,
    this.maxDeferredChecks = 5,
    this.maxWatchedObjects = 2000,
    this.watchedKinds = const {
      WatchedKind.state,
      WatchedKind.changeNotifier,
      WatchedKind.animationController,
      WatchedKind.route,
      WatchedKind.overlayEntry,
    },
    this.watchFilter,
    this.watchedPackages = WatchedPackages.defaults,
    this.ignoredTypeNames = const {},
    this.retainingPathLimit = 100,
    this.inspectObjects = true,
    this.maxInspectedNodes = 12,
    this.referenceMatchers = defaultReferenceMatchers,
    this.reportWithoutTrace = true,
    this.strongPathLookups = 16,
  });

  /// Master switch.
  final bool enabled;

  /// Run in profile builds too. Off by default: Flutter reports disposals
  /// only inside `assert`s, so in profile mode nothing is watched
  /// automatically and only objects passed to `DevToolsLight.watch` would
  /// be checked. Release builds never run leak detection.
  final bool allowInProfile;

  /// Whether leak detection runs in this build: [enabled], in debug builds,
  /// or in profile builds with [allowInProfile].
  bool get isActive => enabled && (kDebugMode || allowInProfile);

  /// How long after disposal an object may legitimately stay reachable
  /// (route transitions, end-of-frame cleanup) before it becomes a candidate.
  final Duration retainedDelay;

  /// Candidates are batched for this long before a check runs.
  final Duration batchWindow;

  /// Minimum time between two checks (each check forces a GC).
  final Duration minIntervalBetweenChecks;

  /// Maximum retaining paths fetched per check.
  final int maxTracesPerCheck;

  /// Rate limit for checks.
  final int maxAnalysesPerMinute;

  /// `reachabilityBarrier` increments required after a candidate was observed
  /// before it is declared retained. One is rigorous per the SDK docs; raise
  /// it for extra margin at the cost of one more forced GC per cycle.
  final int requiredGcCycles;

  /// How long a forced GC may take before the check is postponed.
  final Duration gcTimeout;

  /// Candidates whose GC could not be confirmed this many times are dropped.
  final int maxGcAttemptsPerObject;

  /// How many automatic checks a retained object may sit out because no frame
  /// has completed since it was disposed. The framework releases routes,
  /// overlay entries and controllers from post-frame callbacks, so until a
  /// frame renders they are retained legitimately.
  final int maxDeferredChecks;

  /// Upper bound on watched objects; the oldest are evicted beyond it.
  final int maxWatchedObjects;

  /// Which framework object kinds are watched automatically.
  final Set<WatchedKind> watchedKinds;

  /// Widens the automatically watched set (for example `(o) => o is MyBloc`).
  final WatchFilter? watchFilter;

  /// Which packages' classes are watched automatically: the app's always,
  /// the Flutter SDK's by default, third-party packages on request (see
  /// [WatchedPackages] and [KnownPackages]).
  final WatchedPackages watchedPackages;

  /// Runtime type names (generics stripped) that are never watched.
  final Set<String> ignoredTypeNames;

  /// Maximum length of a retaining path.
  final int retainingPathLimit;

  /// Inspect path elements with `getObject` to label them LEAKING/NOT LEAKING.
  final bool inspectObjects;

  /// Maximum `getObject` calls per trace.
  final int maxInspectedNodes;

  /// Known library leaks and ignored references.
  final List<ReferenceMatcher> referenceMatchers;

  /// Report objects that survived a GC even when no retaining path can be
  /// obtained (no VM service).
  final bool reportWithoutTrace;

  /// When the VM reports a retaining path through a weak reference (an
  /// `Expando` key, a `WeakReference`), which does not explain why the
  /// object is alive, up to this many `getInboundReferences` and
  /// `getRetainingPath` calls are spent on finding a path made of strong
  /// references only. Zero disables the search; the weak path is then
  /// reported, flagged.
  final int strongPathLookups;
}

/// Which VM-service RPC provides CPU samples.
enum SampleFormat {
  /// `getPerfettoCpuSamples` (~20× smaller and several times faster than
  /// JSON); falls back to [json] when the VM does not support it.
  perfetto,

  /// `getCpuSamples` (JSON, carries line numbers; ~20 MB per fetch).
  json,
}

/// Jank detection settings.
@immutable
class JankDetectionConfig {
  /// Creates jank detection settings.
  const JankDetectionConfig({
    this.enabled = true,
    this.allowInDebug = false,
    this.frameBuildThreshold,
    this.frameRasterThreshold,
    this.vsyncOverheadThreshold,
    this.stallThreshold = const Duration(milliseconds: 100),
    this.maxStall = const Duration(seconds: 10),
    this.heartbeatInterval = const Duration(milliseconds: 50),
    this.samplePeriodMicros,
    this.minSamples = 5,
    this.windowPadding = const Duration(milliseconds: 1),
    this.maxSampleWindow = const Duration(seconds: 3),
    this.maxReportsPerMinute = 60,
    this.severeDuration = const Duration(milliseconds: 250),
    this.maxHotFunctions = 15,
    this.maxCallTreeDepth = 32,
    this.clearSamplesWhenFetchExceeds = const Duration(milliseconds: 250),
    this.idleSampleBufferClearInterval = const Duration(seconds: 3),
    this.fetchCooldownFactor = 9,
    this.maxQueuedCandidates = 8,
    this.warmUp = const Duration(seconds: 2),
    this.sampleFormat = SampleFormat.perfetto,
  });

  /// Master switch.
  final bool enabled;

  /// Run in debug builds too. Off by default: debug-mode frame times are
  /// dominated by the JIT and asserts, every navigation frame on a phone
  /// crosses the thresholds, and the sample fetches cost the most there.
  /// Profile mode is where jank numbers mean something; release builds use
  /// `DevToolsLightConfig.allowInRelease`.
  final bool allowInDebug;

  /// UI-thread build time above which a frame is janky
  /// (null → 32 ms in debug, 16 ms in profile).
  final Duration? frameBuildThreshold;

  /// Raster time above which a frame is janky
  /// (null → 32 ms in debug, 16 ms in profile).
  final Duration? frameRasterThreshold;

  /// Vsync-to-build-start delay above which the UI thread was busy
  /// (null → 64 ms in debug, 32 ms in profile).
  final Duration? vsyncOverheadThreshold;

  /// Heartbeat lateness above which the UI isolate counts as stalled.
  final Duration stallThreshold;

  /// Heartbeat lateness above which the gap is treated as a suspension or
  /// clock jump (app backgrounded, debugger pause) rather than a stall.
  final Duration maxStall;

  /// Heartbeat timer period.
  final Duration heartbeatInterval;

  /// Desired VM sampling period in microseconds (the VM default is 1000;
  /// DevTools' "high" resolution is 250). Only ever lowers the VM's current
  /// value and is restored on stop. Null leaves the VM untouched. Lower values
  /// cost more per `getCpuSamples` fetch.
  final int? samplePeriodMicros;

  /// Minimum CPU samples for an attribution to be meaningful.
  final int minSamples;

  /// Padding added to both ends of the sampled window.
  final Duration windowPadding;

  /// Longest window that is sampled.
  final Duration maxSampleWindow;

  /// Rate limit for jank candidates taken on per minute (fetch work is
  /// bounded separately by the cooldown and the queue). Candidates at least
  /// [severeDuration] long are exempt.
  final int maxReportsPerMinute;

  /// Candidates this long always get through the rate limit: a 300 ms stall
  /// matters even in a storm of slow debug-mode builds.
  final Duration severeDuration;

  /// Hot app functions kept per report.
  final int maxHotFunctions;

  /// Maximum depth of the app call tree.
  final int maxCallTreeDepth;

  /// The VM walks its whole sample buffer on every fetch, whatever the
  /// format, so fetches get slower as the buffer fills (on a desktop from
  /// ~70 ms to ~400 ms within a minute). The buffer is cleared after an RPC
  /// slower than this *and* than 1.5 times the fastest fetch seen so far
  /// (a phone whose every fetch takes 250 ms has not filled its buffer),
  /// and only while no other jank is waiting for its samples.
  final Duration clearSamplesWhenFetchExceeds;

  /// While no jank is being processed, the sample buffer is cleared this
  /// often so that the next fetch stays cheap. Null disables it. (A frame
  /// reported late, right after a clear, loses its samples; frame timings
  /// arrive within ~100 ms, so this is rare.)
  final Duration? idleSampleBufferClearInterval;

  /// After a CPU-sample fetch, the next fetch waits this many times the
  /// fetch's RPC time (the part that blocks the UI isolate), so the isolate
  /// spends at most about `1 / (factor + 1)` of its time serving fetches:
  /// a tenth with the default. Negligible on a desktop, where the RPCs
  /// take ~50 ms; keeps a phone usable in debug mode, where they take
  /// ~250 ms and every navigation frame is a jank candidate. While fetches
  /// keep finding no app code the spacing doubles, up to eight times,
  /// except for candidates at least [severeDuration] long. Janks that
  /// arrive meanwhile are merged or queued.
  final int fetchCooldownFactor;

  /// Janks waiting for CPU samples are processed longest first; when more
  /// than this many are waiting, the least significant one is reported
  /// without attribution.
  final int maxQueuedCandidates;

  /// Jank that starts within this long after the first rendered frame is
  /// ignored, as is everything before that frame (app start-up is always
  /// slow and rarely interesting).
  final Duration warmUp;

  /// How CPU samples are fetched.
  final SampleFormat sampleFormat;

  /// Whether jank detection runs in this build: [enabled], and not a debug
  /// build unless [allowInDebug].
  bool get isActive => enabled && (!kDebugMode || allowInDebug);

  /// [vsyncOverheadThreshold] with the mode-aware default applied.
  Duration get effectiveVsyncOverheadThreshold =>
      vsyncOverheadThreshold ??
      (kDebugMode
          ? const Duration(milliseconds: 64)
          : const Duration(milliseconds: 32));

  /// [frameBuildThreshold] with the mode-aware default applied.
  Duration get effectiveFrameBuildThreshold =>
      frameBuildThreshold ?? _defaultFrameThreshold;

  /// [frameRasterThreshold] with the mode-aware default applied.
  Duration get effectiveFrameRasterThreshold =>
      frameRasterThreshold ?? _defaultFrameThreshold;

  static Duration get _defaultFrameThreshold => kDebugMode
      ? const Duration(milliseconds: 32)
      : const Duration(milliseconds: 16);
}

/// Overlay UI settings.
@immutable
class OverlayConfig {
  /// Creates overlay settings.
  const OverlayConfig({
    this.showBadge = true,
    this.showToasts = true,
    this.initialAlignment = Alignment.bottomRight,
    this.margin = 16.0,
    this.toastDuration = const Duration(seconds: 4),
  });

  /// Show the floating badge.
  final bool showBadge;

  /// Show a transient banner for every new finding.
  final bool showToasts;

  /// Where the badge starts (it is draggable).
  final Alignment initialAlignment;

  /// Distance of the badge from the edges.
  final double margin;

  /// How long a toast stays visible.
  final Duration toastDuration;
}

/// When the heap-growth monitor takes its snapshots.
enum HeapSnapshotTrigger {
  /// After the VM's own major collections. `reachabilityBarrier` is polled
  /// every [HeapTrendConfig.vmGcPollInterval]; when it has advanced and at
  /// least [HeapTrendConfig.interval] has passed since the last snapshot, the
  /// allocation profile is read without forcing a GC. Old space is clean
  /// right after the collection and a cheap allocation-pressure scavenge
  /// ([HeapTrendConfig.scavengeBeforeSnapshot]) clears new space. Nothing
  /// blocks the UI isolate beyond the profile itself (~0.2 s on a desktop,
  /// ~0.5 s on a mid-range phone in debug mode), no collection is forced on
  /// the app, and detection follows the app's GC cadence: a quiet app that
  /// never collects takes no snapshots.
  afterVmGc,

  /// Every [HeapTrendConfig.interval], after a forced full GC: exact live
  /// counts at a fixed cadence. The pause is the heap walk plus the
  /// collection: ~0.2 s on a desktop and 0.5–0.7 s on a mid-range phone in
  /// debug mode, up to 2 s when the phone is throttled.
  forcedGc,

  /// Every [HeapTrendConfig.interval], with the scavenge but without a major
  /// GC: cheap, but old-space garbage inflates the counts.
  periodic,
}

/// Heap-growth trend detection: periodic per-class counts of live objects, so
/// that leaks of objects nobody watched (cache entries, listeners, plain data)
/// still show up as classes that keep growing.
///
/// A snapshot is one `getAllocationProfile` RPC, which walks the heap on the
/// UI isolate. With the default [trigger] it is taken right after the VM's
/// own major collections, so no GC is forced; see [HeapSnapshotTrigger] for
/// the alternatives. Snapshots run only while nothing else is in flight and
/// are spaced out by [costFactor] on slow devices. A manual
/// `DevToolsLight.snapshotHeapNow` forces a GC first (exact counts, right
/// now), except with [HeapSnapshotTrigger.periodic].
class HeapTrendConfig {
  /// Creates the configuration.
  const HeapTrendConfig({
    this.enabled = true,
    this.trigger = HeapSnapshotTrigger.afterVmGc,
    this.interval = const Duration(seconds: 60),
    this.vmGcPollInterval = const Duration(seconds: 1),
    this.scavengeBeforeSnapshot = true,
    this.window = 8,
    this.minRisingSnapshots = 4,
    this.minInstanceGrowth = 50,
    this.minBytesGrowth = 512 * 1024,
    this.minRelativeGrowth = 0.25,
    this.includeFrameworkClasses = true,
    this.ignoredClassNames = const {},
    this.maxSuspects = 10,
    this.instancesToInspect = 3,
    this.costFactor = 40,
  });

  /// Whether the monitor runs.
  final bool enabled;

  /// What starts a snapshot.
  final HeapSnapshotTrigger trigger;

  /// Minimum time between snapshots (the period with
  /// [HeapSnapshotTrigger.forcedGc] and [HeapSnapshotTrigger.periodic]),
  /// stretched to [costFactor] times the previous snapshot's cost on slow
  /// devices.
  final Duration interval;

  /// How often `reachabilityBarrier` is checked for a VM collection with
  /// [HeapSnapshotTrigger.afterVmGc].
  final Duration vmGcPollInterval;

  /// Before a snapshot that does not force a GC, trigger a new-space
  /// collection by allocating short-lived garbage (a few milliseconds) so
  /// that objects that died young are not counted.
  final bool scavengeBeforeSnapshot;

  /// Snapshots kept per class.
  final int window;

  /// How many consecutive snapshots a class must have grown in.
  final int minRisingSnapshots;

  /// The growth over the rising run must reach this many instances, or
  /// [minBytesGrowth] bytes.
  final int minInstanceGrowth;

  /// Alternative growth floor in bytes.
  final int minBytesGrowth;

  /// The growth must also be at least this share of the count at the start of
  /// the run (a class that went from 10,000 to 10,050 is not interesting).
  final double minRelativeGrowth;

  /// Report framework and third-party classes too. App classes are always
  /// reported; `dart:` core classes never are, they grow with everything.
  final bool includeFrameworkClasses;

  /// Class names never reported (caches that legitimately grow).
  final Set<String> ignoredClassNames;

  /// Suspects reported per snapshot at most, largest growth first.
  final int maxSuspects;

  /// Live instances tried when fetching a retaining path for a suspect.
  final int instancesToInspect;

  /// The next snapshot waits at least this many times the previous one's
  /// cost.
  final int costFactor;
}
