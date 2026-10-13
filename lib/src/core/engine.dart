import 'dart:async';
import 'dart:math' as math;

import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/clock.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/stall_guard.dart';
import 'package:dev_tools_light/src/core/status.dart';
import 'package:dev_tools_light/src/core/support.dart';
import 'package:dev_tools_light/src/jank/cpu_sample_attributor.dart';
import 'package:dev_tools_light/src/jank/frame_clock_calibrator.dart';
import 'package:dev_tools_light/src/jank/frame_jank_detector.dart';
import 'package:dev_tools_light/src/jank/jank_attribution_backend.dart';
import 'package:dev_tools_light/src/jank/jank_coordinator.dart';
import 'package:dev_tools_light/src/jank/ui_stall_detector.dart';
import 'package:dev_tools_light/src/jank/vm_jank_attribution.dart';
import 'package:dev_tools_light/src/leaks/heap_trend_monitor.dart';
import 'package:dev_tools_light/src/leaks/leak_analyzer.dart';
import 'package:dev_tools_light/src/leaks/lifecycle_watcher.dart';
import 'package:dev_tools_light/src/leaks/object_watcher.dart';
import 'package:dev_tools_light/src/leaks/package_watch_policy.dart';
import 'package:dev_tools_light/src/leaks/watched_kind.dart';
import 'package:dev_tools_light/src/ui/overlay_controller.dart';
import 'package:dev_tools_light/src/vm/app_package_detector.dart';
import 'package:dev_tools_light/src/vm/cpu_samples_client.dart';
import 'package:dev_tools_light/src/vm/gc_controller.dart';
import 'package:dev_tools_light/src/vm/isolate_info.dart';
import 'package:dev_tools_light/src/vm/runtime_bridge.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:dev_tools_light/src/vm/vm_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Owns every subsystem; a process-wide singleton behind `DevToolsLight`.
///
/// Everything that needs the VM service is created inside
/// `if (kVmFeaturesSupported)` blocks, so release builds compile only the
/// detectors, the store and the overlay.
class Engine {
  Engine._();

  /// The singleton.
  static final Engine instance = Engine._();

  /// True while started.
  final ValueNotifier<bool> runningNotifier = InternalValueNotifier<bool>(
    false,
  );

  /// The active configuration.
  DevToolsLightConfig config = const DevToolsLightConfig();

  ReportStore? _store;
  OverlayController? _overlayController;

  RuntimeBridge? _bridge;
  VmSession? _session;
  SelfInflictedStallGuard? _guard;
  AppCodeClassifier? _classifier;
  ObjectWatcher? _objectWatcher;
  LifecycleWatcher? _lifecycleWatcher;
  LeakAnalyzer? _leakAnalyzer;
  PackageWatchPolicy? _watchPolicy;
  HeapTrendMonitor? _heapTrendMonitor;
  FrameClockCalibrator? _calibrator;
  UiStallDetector? _stallDetector;
  JankCoordinator? _jankCoordinator;
  TimingsCallback? _timingsCallback;
  _EngineObserver? _observer;
  Timer? _statusTimer;
  ProfilerSetup? _profilerSetup;
  IsolateInfo? _isolateInfo;
  bool _frameCallbackRegistered = false;
  int _generation = 0;
  int? _lastPostFrameMicros;

  /// Findings and status (survives restarts).
  ReportStore get store => _store ??= ReportStore();

  /// UI state shared with the overlay.
  OverlayController get overlayController =>
      _overlayController ??= OverlayController(
        initialAlignment: config.overlay.initialAlignment,
      );

  /// Whether the engine is started.
  bool get isRunning => runningNotifier.value;

  /// The main isolate, once known.
  IsolateInfo? get isolateInfo => _isolateInfo;

  void _log(String message) {
    if (config.log) {
      debugPrint('[dev_tools_light] $message');
    }
  }

  /// Starts every enabled subsystem. Returns quickly; the VM service is
  /// discovered in the background.
  Future<void> start(DevToolsLightConfig config) async {
    if (!kDetectionSupported) {
      return;
    }
    if (kReleaseMode && !config.allowInRelease) {
      return;
    }
    if (isRunning) {
      await stop();
    }
    this.config = config;
    final bridge = createRuntimeBridge();
    if (bridge.isFlutterTestEnvironment && !config.allowInTests) {
      _log('not starting under flutter test (set allowInTests to override)');
      return;
    }
    _bridge = bridge;
    final generation = ++_generation;
    final binding = WidgetsFlutterBinding.ensureInitialized();
    final guard = _guard = SelfInflictedStallGuard(now: timelineNowMicros);
    final classifier = _classifier = AppCodeClassifier(
      appPrefixes: {
        ...?config.appCode.packagePrefixes,
        ...config.appCode.extraPackagePrefixes,
      },
      toolingPrefixes: config.appCode.toolingPrefixes,
      isAppUri: config.appCode.isAppUri,
    );
    overlayController
      ..badgeAlignment.value = config.overlay.initialAlignment
      ..onCheckLeaksNow = checkLeaksNow
      ..onSnapshotHeapNow = snapshotHeapNow
      ..onFetchHeapTrendTrace = fetchHeapTrendTrace;
    if (!_frameCallbackRegistered) {
      // Persistent frame callbacks can never be removed; delegate to the
      // current subsystems (null once stopped).
      binding.addPersistentFrameCallback((_) {
        _calibrator?.onFrame(binding.platformDispatcher.frameData.frameNumber);
        _jankCoordinator?.markFirstFrame();
        binding.addPostFrameCallback(
          (_) => _lastPostFrameMicros = timelineNowMicros(),
        );
      });
      _frameCallbackRegistered = true;
    }

    // The VM layer: leak analysis, heap trends and the backend for jank
    // attribution. Absent in release builds.
    JankAttributionBackend? jankBackend;
    if (kVmFeaturesSupported) {
      VmServiceApi.diagnostics = config.log ? _log : null;
      final session = _session = VmSession(
        bridge: bridge,
        now: timelineNowMicros,
        discoveryGrace: config.vmDiscoveryGrace,
        log: _log,
      );
      if (config.leaks.isActive) {
        final policy = _watchPolicy = PackageWatchPolicy(
          config: config.leaks.watchedPackages,
          classifier: classifier,
        );
        final analyzer = _leakAnalyzer = LeakAnalyzer(
          config: config.leaks,
          bridge: bridge,
          session: session,
          gc: GcController(
            barrier: () => bridge.reachabilityBarrier,
            now: timelineNowMicros,
          ),
          store: store,
          guard: guard,
          classifier: classifier,
          policy: policy,
          lastPostFrameMicros: () => _lastPostFrameMicros,
          log: _log,
        );
        final watcher = _objectWatcher = ObjectWatcher(
          config: config.leaks,
          now: timelineNowMicros,
          barrier: () => bridge.reachabilityBarrier,
          onRetained: analyzer.analyze,
          log: _log,
        )..start();
        _lifecycleWatcher = LifecycleWatcher(
          config: config.leaks,
          watcher: watcher,
          policy: policy,
        )..start();
      }
      if (config.jank.isActive) {
        jankBackend = VmJankAttribution(
          config: config.jank,
          session: session,
          attributor: CpuSampleAttributor(
            classifier: classifier,
            config: config.jank,
          ),
          guard: guard,
          now: timelineNowMicros,
          isolateId: () => _isolateInfo?.isolateId ?? bridge.currentIsolateId,
          samplesClient: CpuSamplesClient(compute: bridge.compute),
          profilerEnabled: () => _profilerSetup?.profilerEnabled ?? false,
          log: _log,
        );
      }
      if (config.heapTrend.enabled) {
        _heapTrendMonitor = HeapTrendMonitor(
          config: config.heapTrend,
          session: session,
          guard: guard,
          store: store,
          classifier: classifier,
          now: timelineNowMicros,
          isolateId: () => _isolateInfo?.isolateId ?? bridge.currentIsolateId,
          barrier: () => bridge.reachabilityBarrier,
          isBusy: () =>
              (_objectWatcher?.isChecking ?? false) ||
              (_jankCoordinator?.isBusy ?? false),
          log: _log,
        )..start();
      }
    }

    if (config.jank.isActive) {
      final calibrator = _calibrator = FrameClockCalibrator(
        now: timelineNowMicros,
      )..start();
      final coordinator = _jankCoordinator = JankCoordinator(
        config: config.jank,
        store: store,
        guard: guard,
        now: timelineNowMicros,
        backend: jankBackend,
        isAppActive: () {
          final state = binding.lifecycleState;
          return state == null || state == AppLifecycleState.resumed;
        },
        isOverlayWindow: overlayController.coversWindow,
        log: _log,
      )..start();
      final frameDetector = FrameJankDetector(
        config: config.jank,
        calibrator: calibrator,
        onCandidate: coordinator.handleCandidate,
      );
      final timingsCallback = _timingsCallback = frameDetector.handleTimings;
      binding.addTimingsCallback(timingsCallback);
      _stallDetector = UiStallDetector(
        config: config.jank,
        now: timelineNowMicros,
        onCandidate: coordinator.handleCandidate,
      )..start();
    }

    final observer = _observer = _EngineObserver(this);
    binding.addObserver(observer);
    runningNotifier.value = true;
    store.status = DevToolsLightStatus(
      mode: RuntimeMode.current,
      vm: kVmFeaturesSupported
          ? VmConnectionState.discovering
          : VmConnectionState.unsupported,
      vmDetail: kVmFeaturesSupported
          ? null
          : 'no VM service in ${RuntimeMode.current.name} builds: jank is '
                'detected but not attributed; leak traces and heap '
                'snapshots are unavailable',
      leaks: !config.leaks.enabled
          ? LeakDetectionState.disabled
          : kVmFeaturesSupported && !config.leaks.isActive
          ? LeakDetectionState.debugOnly
          : !kVmFeaturesSupported
          ? LeakDetectionState.unsupported
          : LifecycleWatcher.isSupported
          ? LeakDetectionState.automatic
          : LeakDetectionState.manualOnly,
      jank: !config.jank.enabled
          ? JankDetectionState.disabled
          : !config.jank.isActive
          ? JankDetectionState.notInDebug
          : JankDetectionState.detectOnly,
      heapTrends: !config.heapTrend.enabled
          ? HeapTrendState.disabled
          : kVmFeaturesSupported
          ? HeapTrendState.active
          : HeapTrendState.unsupported,
      appPackagePrefixes: classifier.appPrefixes,
    );
    _statusTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshStatus(),
    );
    _log('started in ${RuntimeMode.current.name} mode');
    if (kVmFeaturesSupported) {
      if (config.leaks.isActive ||
          config.jank.isActive ||
          config.heapTrend.enabled) {
        unawaited(_initVm(generation));
      } else {
        _log('no feature needs the VM service; not connecting');
        store.updateStatus(
          (s) => s.copyWith(
            vm: VmConnectionState.idle,
            vmDetail: 'not needed: every feature is disabled',
          ),
        );
      }
    }
  }

  Future<void> _initVm(int generation) async {
    final session = _session;
    final bridge = _bridge;
    final classifier = _classifier;
    if (session == null || bridge == null || classifier == null) {
      return;
    }
    const delays = [1, 2, 5, 10];
    var attempt = 0;
    while (generation == _generation) {
      try {
        await session.run((api) async {
          final isolateId = bridge.currentIsolateId;
          if (isolateId == null) {
            throw VmUnavailableException(
              'no isolate id (service protocol off)',
            );
          }
          final isolate = await api.getIsolate(isolateId);
          final info = _isolateInfo = IsolateInfo(
            isolateId: isolateId,
            rootLibraryUri: isolate.rootLib?.uri,
          );
          if (config.appCode.packagePrefixes == null) {
            var prefix = info.appPackagePrefix;
            if (prefix == null) {
              // Test runners start the isolate on the test file itself.
              prefix = await const AppPackageDetector().detect(
                api,
                isolateId: isolateId,
                isolate: isolate,
                learn: (packageUri, fileUri) => classifier.learnAppFileRoot(
                  packageUri: packageUri,
                  fileUri: fileUri,
                ),
              );
              if (prefix != null) {
                _log('app package $prefix derived from the root file');
              }
            }
            if (prefix != null) {
              classifier.addAppPrefixes({prefix});
            }
          }
          final before = timelineNowMicros();
          final vmMicros = (await api.getVMTimelineMicros()).timestamp;
          final roundTrip = timelineNowMicros() - before;
          final skew = vmMicros == null ? null : vmMicros - before;
          ProfilerSetup? setup;
          if (config.jank.isActive) {
            setup = _profilerSetup = await const CpuSamplesClient()
                .ensureProfiler(
                  api,
                  desiredSamplePeriodMicros: config.jank.samplePeriodMicros,
                );
            try {
              await api.clearCpuSamples(isolateId);
            } on Object catch (_) {
              // Older VMs may not support it; fetches just start slower.
            }
          }
          store.updateStatus(
            (s) => s.copyWith(
              vm: VmConnectionState.reachable,
              vmDetail: skew == null
                  ? null
                  : 'timeline skew $skew µs '
                        '(RPC round trip ${roundTrip ~/ 1000} ms)',
              vmUri: session.webSocketUri?.toString(),
              appPackagePrefixes: classifier.appPrefixes,
              profilerEnabled: setup?.profilerEnabled,
              samplePeriodMicros: setup?.samplePeriodMicros,
              jank: !config.jank.enabled
                  ? JankDetectionState.disabled
                  : !config.jank.isActive
                  ? JankDetectionState.notInDebug
                  : (setup?.profilerEnabled ?? false)
                  ? JankDetectionState.attributing
                  : JankDetectionState.detectOnly,
            ),
          );
        });
        _log(
          'VM service ready; app packages: '
          '${classifier.appPrefixes.join(', ')}',
        );
        return;
      } on VmUnavailableException catch (error) {
        store.updateStatus(
          (s) => s.copyWith(
            vm: VmConnectionState.failed,
            vmDetail: error.message,
            lastError: error.message,
          ),
        );
        if (!error.retryable) {
          _log('giving up on the VM service: ${error.message}');
          return;
        }
      } on Object catch (error) {
        store.updateStatus(
          (s) => s.copyWith(
            vm: VmConnectionState.failed,
            vmDetail: '$error',
            lastError: '$error',
          ),
        );
      }
      await Future<void>.delayed(
        Duration(seconds: delays[math.min(attempt++, delays.length - 1)]),
      );
    }
  }

  void _refreshStatus() {
    final watcher = _objectWatcher;
    final session = _session;
    store.updateStatus(
      (s) => s.copyWith(
        vm:
            session?.state == VmConnectionState.discovering ||
                session?.state == VmConnectionState.idle
            ? s.vm
            : session?.state,
        clockOffsetMicros: _calibrator?.offsetMicros,
        watchedObjects: watcher?.watchedCount ?? 0,
        retainedCandidates: watcher?.candidateCount ?? 0,
        droppedCandidates:
            (watcher?.droppedCount ?? 0) +
            (_leakAnalyzer?.droppedCandidates ?? 0),
        skippedByPackagePolicy: _watchPolicy?.skipped ?? 0,
        leakChecksRun: watcher?.checksRun ?? 0,
        selfInflictedStallsSuppressed: _guard?.suppressedCount ?? 0,
        heapSnapshots: _heapTrendMonitor?.snapshotsTaken ?? 0,
        lastHeapSnapshotMicros: (_heapTrendMonitor?.snapshotsTaken ?? 0) == 0
            ? null
            : _heapTrendMonitor?.lastSnapshotCostMicros,
        heapTrendDetail: _heapTrendMonitor?.describe(),
      ),
    );
  }

  /// Stops everything and restores VM flags we changed.
  Future<void> stop() async {
    if (!isRunning) {
      return;
    }
    _generation++;
    _statusTimer?.cancel();
    _statusTimer = null;
    _lifecycleWatcher?.stop();
    _objectWatcher
      ?..stop()
      ..clear();
    _stallDetector?.stop();
    _jankCoordinator?.stop();
    _heapTrendMonitor?.stop();
    _heapTrendMonitor = null;
    _calibrator?.stop();
    _calibrator = null;
    final binding = WidgetsBinding.instance;
    final timingsCallback = _timingsCallback;
    if (timingsCallback != null) {
      binding.removeTimingsCallback(timingsCallback);
      _timingsCallback = null;
    }
    final observer = _observer;
    if (observer != null) {
      binding.removeObserver(observer);
      _observer = null;
    }
    if (kVmFeaturesSupported) {
      final setup = _profilerSetup;
      final session = _session;
      if (setup != null && setup.changedPeriod && session != null) {
        try {
          await session.run(
            (api) => const CpuSamplesClient().restore(api, setup),
          );
        } on Object catch (_) {
          // Best effort.
        }
      }
    }
    _profilerSetup = null;
    _lifecycleWatcher = null;
    _objectWatcher = null;
    _leakAnalyzer = null;
    _watchPolicy = null;
    _stallDetector = null;
    _jankCoordinator = null;
    _session = null;
    _guard = null;
    _classifier = null;
    _bridge = null;
    _isolateInfo = null;
    overlayController.close();
    runningNotifier.value = false;
    store.updateStatus(
      (s) => s.copyWith(
        vm: VmConnectionState.idle,
        leaks: LeakDetectionState.disabled,
        jank: JankDetectionState.disabled,
        heapTrends: HeapTrendState.disabled,
      ),
    );
    _log('stopped');
  }

  /// Watches [object] manually.
  void watch(Object object, {String? description}) {
    _objectWatcher?.watch(
      object,
      kind: WatchedKind.manual,
      description: description,
    );
  }

  /// Runs a leak check now.
  Future<void> checkLeaksNow() async {
    final watcher = _objectWatcher;
    if (watcher == null) {
      return;
    }
    await watcher.checkNow();
    _refreshStatus();
  }

  /// Takes a heap snapshot now and evaluates growth trends.
  Future<bool> snapshotHeapNow() async {
    if (!kVmFeaturesSupported) {
      return false;
    }
    final monitor = _heapTrendMonitor;
    if (monitor == null) {
      return false;
    }
    final taken = await monitor.snapshotNow();
    _refreshStatus();
    return taken;
  }

  /// Fetches a retaining path for one live instance of the growing class in
  /// [reportId].
  Future<void> fetchHeapTrendTrace(String reportId) {
    if (!kVmFeaturesSupported) {
      return Future<void>.value();
    }
    return _heapTrendMonitor?.fetchTrace(reportId) ?? Future<void>.value();
  }

  /// Exposes the jank coordinator's counters for the status page.
  JankCoordinator? get jankCoordinator => _jankCoordinator;
}

class _EngineObserver with WidgetsBindingObserver {
  _EngineObserver(this.engine);

  final Engine engine;

  @override
  Future<bool> didPopRoute() async =>
      engine._overlayController?.handleBack() ?? false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Forget the last heartbeat around background time so the first tick
    // after resuming is not reported as a stall.
    engine._stallDetector?.reset();
    engine._log('app lifecycle: ${state.name}');
  }
}
