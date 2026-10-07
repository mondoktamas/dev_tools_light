import 'dart:math' as math;

import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/stall_guard.dart';
import 'package:dev_tools_light/src/jank/cpu_attribution.dart';
import 'package:dev_tools_light/src/jank/cpu_sample_attributor.dart';
import 'package:dev_tools_light/src/jank/jank_attribution_backend.dart';
import 'package:dev_tools_light/src/jank/jank_candidate.dart';
import 'package:dev_tools_light/src/jank/jank_coordinator.dart';
import 'package:dev_tools_light/src/jank/sampled_profile.dart';
import 'package:dev_tools_light/src/jank/slow_operation_report.dart';
import 'package:dev_tools_light/src/jank/vm_jank_attribution.dart';
import 'package:dev_tools_light/src/ui/overlay_controller.dart';
import 'package:dev_tools_light/src/vm/vm_session.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show Alignment;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_runtime_bridge.dart';
import '../helpers/fake_vm_api.dart';
import '../helpers/fixtures.dart';

/// A backend answering with scripted outcomes (the last one repeats).
class _ScriptedBackend implements JankAttributionBackend {
  _ScriptedBackend(this.outcomes);

  final List<JankAttributionOutcome> outcomes;
  int attributions = 0;
  int clears = 0;
  int guardedClears = 0;

  @override
  Future<JankAttributionOutcome> attribute(JankCandidate candidate) async {
    final outcome = outcomes[math.min(attributions, outcomes.length - 1)];
    attributions++;
    return outcome;
  }

  @override
  Future<void> clearSampleBuffer({bool guarded = false}) async {
    clears++;
    if (guarded) {
      guardedClears++;
    }
  }
}

void main() {
  const page = 'package:my_app/page.dart';
  late int now;
  late ReportStore store;
  late SelfInflictedStallGuard guard;
  late FakeRuntimeBridge bridge;
  late VmSession session;
  late AppCodeClassifier classifier;
  late JankCoordinator coordinator;

  JankCandidate candidate({
    required int start,
    required int end,
    Set<JankKind> kinds = const {JankKind.slowBuild},
    bool attributable = true,
    AttributionState? unattributableState,
  }) => JankCandidate(
    kinds: kinds,
    windowStartMicros: start,
    windowEndMicros: end,
    attributable: attributable,
    unattributableState:
        unattributableState ??
        (attributable ? null : AttributionState.notAttributable),
    buildDuration: Duration(microseconds: end - start),
  );

  VmSession sessionFor(FakeRuntimeBridge bridge) => VmSession(
    bridge: bridge,
    now: () => now,
    discoveryGrace: Duration.zero,
    pollInterval: Duration.zero,
    connectedUri: () => 'http://127.0.0.1:1/x=/',
  );

  /// A coordinator with a VM backend on [session] (the shared one by
  /// default); without [withBackend] it has none, like a release build.
  JankCoordinator coordinatorFor({
    JankDetectionConfig config = const JankDetectionConfig(
      warmUp: Duration.zero,
    ),
    VmSession? session,
    bool Function()? profilerEnabled,
    bool withBackend = true,
  }) => JankCoordinator(
    config: config,
    store: store,
    guard: guard,
    now: () => now,
    wallClock: () => DateTime(2026),
    backend: withBackend
        ? VmJankAttribution(
            config: config,
            session: session ?? sessionFor(bridge),
            attributor: CpuSampleAttributor(
              classifier: classifier,
              config: const JankDetectionConfig(),
            ),
            guard: guard,
            now: () => now,
            isolateId: () => 'isolates/1',
            profilerEnabled: profilerEnabled,
          )
        : null,
  );

  setUp(() {
    now = 0;
    store = ReportStore();
    guard = SelfInflictedStallGuard(now: () => now);
    final samples = cpuSamples(
      functions: [
        profileFunction(
          funcRef(
            'slow',
            owner: classRef('Thing', page),
            location: sourceLocation(page, line: 7),
          ),
        ),
      ],
      samples: [
        for (var i = 0; i < 10; i++) cpuSample([0]),
      ],
    );
    bridge = FakeRuntimeBridge(
      serviceUris: [Uri.parse('http://127.0.0.1:1/x=/')],
      apiFactory: () => FakeVmApi(samples: samples),
    );
    session = sessionFor(bridge);
    classifier = AppCodeClassifier(appPrefixes: {'package:my_app/'});
    coordinator = coordinatorFor(session: session)..markFirstFrame();
  });

  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('attributes a candidate and publishes a report', () async {
    coordinator.handleCandidate(candidate(start: 1000, end: 51000));
    await settle();
    final report = store.slowOps.single;
    expect(report.attributionState, AttributionState.attributed);
    expect(report.topAppFunction?.name, 'Thing.slow');
    expect(report.topAppFunction?.location, 'lib/page.dart:7');
    expect(report.title, 'Slow build 50 ms');
    expect(bridge.apis.single.calls, contains('getCpuSamples'));
  });

  test('reports candidates unattributed without a backend', () async {
    coordinatorFor(withBackend: false)
      ..markFirstFrame()
      ..handleCandidate(candidate(start: 1000, end: 51000))
      ..handleCandidate(
        candidate(start: 2000000, end: 2300000, kinds: {JankKind.uiStall}),
      );
    await settle();
    expect(store.slowOps, hasLength(2));
    for (final report in store.slowOps) {
      expect(report.attributionState, AttributionState.unsupported);
      expect(report.attributionHint, contains('release'));
      expect(report.attribution, isNull);
    }
    expect(bridge.apis, isEmpty, reason: 'no VM work at all');
    expect(
      store.slowOps.map((r) => r.title),
      ['UI stall 300 ms', 'Slow build 50 ms'],
    );
    expect(store.pendingToasts, hasLength(2));

    // A late frame start on its own is listed silently.
    coordinatorFor(withBackend: false)
      ..markFirstFrame()
      ..handleCandidate(
        candidate(
          start: 4000000,
          end: 4190000,
          kinds: {JankKind.delayedFrame},
        ),
      );
    await settle();
    expect(store.slowOps, hasLength(3));
    expect(store.pendingToasts, hasLength(2));
    expect(store.unseenSlowOps, 2);
  });

  test('groups unattributed janks by kind and severity', () async {
    final release = coordinatorFor(withBackend: false)..markFirstFrame();
    for (var i = 0; i < 3; i++) {
      release.handleCandidate(
        candidate(start: i * 1000000, end: i * 1000000 + 40000),
      );
      await settle();
    }
    release.handleCandidate(candidate(start: 5000000, end: 5400000));
    await settle();
    expect(store.slowOps, hasLength(2));
    expect(store.slowOps.last.occurrences, 3);
    expect(store.slowOps.first.title, 'Slow build 400 ms');
    expect(
      JankCoordinator.durationBucket(const Duration(milliseconds: 40)),
      '<64 ms',
    );
    expect(
      JankCoordinator.durationBucket(const Duration(seconds: 2)),
      '>=1000 ms',
    );
  });

  test('drops candidates overlapping our own stalls', () async {
    guard.begin();
    now += 100000;
    guard.end();
    coordinator.handleCandidate(candidate(start: 20000, end: 90000));
    await settle();
    expect(store.slowOps, isEmpty);
    expect(guard.suppressedCount, 1);
  });

  test('merges an overlapping candidate into the one in flight', () async {
    coordinator
      ..handleCandidate(candidate(start: 1000, end: 51000))
      ..handleCandidate(
        candidate(
          start: 30000,
          end: 60000,
          kinds: {JankKind.delayedFrame},
        ),
      );
    await settle();
    final report = store.slowOps.single;
    expect(report.kinds, {JankKind.slowBuild, JankKind.delayedFrame});
    expect(report.windowEndMicros, 60000);
    expect(coordinator.merged, 1);
  });

  test('merges an overlapping candidate into a recent report', () async {
    coordinator.handleCandidate(candidate(start: 1000, end: 51000));
    await settle();
    coordinator.handleCandidate(
      candidate(start: 40000, end: 70000, kinds: {JankKind.uiStall}),
    );
    await settle();
    final report = store.slowOps.single;
    expect(report.kinds, {JankKind.slowBuild, JankKind.uiStall});
    expect(report.occurrences, 1);
    expect(coordinator.merged, 1);
  });

  test('a non-attributable candidate is reported without samples', () async {
    coordinator.handleCandidate(
      candidate(
        start: 1000,
        end: 51000,
        kinds: {JankKind.slowRaster},
        attributable: false,
      ),
    );
    await settle();
    final report = store.slowOps.single;
    expect(report.attributionState, AttributionState.notAttributable);
    expect(report.attribution, isNull);
    expect(bridge.apis, isEmpty);
  });

  test('rate limits reports but lets severe candidates through', () async {
    final limited = coordinatorFor(
      config: const JankDetectionConfig(
        warmUp: Duration.zero,
        maxReportsPerMinute: 5,
      ),
    )..markFirstFrame();
    for (var i = 0; i < 10; i++) {
      limited.handleCandidate(
        candidate(start: i * 1000000, end: i * 1000000 + 50000),
      );
      await settle();
    }
    expect(limited.rateLimited, 5);
    limited.handleCandidate(
      candidate(
        start: 20000000,
        end: 20300000,
        kinds: {JankKind.uiStall},
      ),
    );
    await settle();
    expect(limited.rateLimited, 5, reason: 'a 300 ms stall is never dropped');
    expect(
      store.slowOps.map((r) => r.kinds.single),
      contains(JankKind.uiStall),
    );
  });

  test(
    'ignores candidates before the first frame and during warm-up',
    () async {
      final warm = coordinatorFor(
        config: const JankDetectionConfig(warmUp: Duration(seconds: 1)),
      );
      now = 3000000;
      warm.handleCandidate(candidate(start: 2000000, end: 2900000));
      await settle();
      expect(store.slowOps, isEmpty, reason: 'no frame has been rendered yet');
      warm.markFirstFrame();
      now = 4500000;
      warm.handleCandidate(candidate(start: 3500000, end: 3600000));
      await settle();
      expect(store.slowOps, isEmpty, reason: 'started during warm-up');
      warm.handleCandidate(candidate(start: 4100000, end: 4200000));
      await settle();
      expect(store.slowOps, hasLength(1));
      expect(warm.warmUpIgnored, 2);
    },
  );

  test(
    'explains missing samples by an idle UI thread when profiling',
    () async {
      final idleBridge = FakeRuntimeBridge(
        serviceUris: [Uri.parse('http://127.0.0.1:1/x=/')],
      );
      coordinatorFor(
          session: sessionFor(idleBridge),
          profilerEnabled: () => true,
        )
        ..markFirstFrame()
        ..handleCandidate(
          candidate(start: 1000, end: 101000, kinds: {JankKind.uiStall}),
        );
      await settle();
      final report = store.slowOps.single;
      expect(report.attributionState, AttributionState.insufficientSamples);
      expect(report.attributionHint, contains('idle'));
    },
  );

  test('ignores sample-less candidates while the app is inactive', () async {
    final idleBridge = FakeRuntimeBridge(
      serviceUris: [Uri.parse('http://127.0.0.1:1/x=/')],
    );
    var active = false;
    final idle =
        JankCoordinator(
            config: const JankDetectionConfig(warmUp: Duration.zero),
            store: store,
            guard: guard,
            now: () => now,
            wallClock: () => DateTime(2026),
            isAppActive: () => active,
            backend: VmJankAttribution(
              config: const JankDetectionConfig(),
              session: sessionFor(idleBridge),
              attributor: CpuSampleAttributor(
                classifier: classifier,
                config: const JankDetectionConfig(),
              ),
              guard: guard,
              now: () => now,
              isolateId: () => 'isolates/1',
            ),
          )
          ..markFirstFrame()
          ..handleCandidate(
            candidate(start: 1000, end: 301000, kinds: {JankKind.uiStall}),
          );
    await settle();
    expect(store.slowOps, isEmpty);
    expect(idle.inactiveIgnored, 1);

    active = true;
    idle.handleCandidate(
      candidate(start: 5000000, end: 5300000, kinds: {JankKind.uiStall}),
    );
    await settle();
    expect(store.slowOps, hasLength(1));
    expect(
      store.slowOps.single.attributionState,
      AttributionState.insufficientSamples,
    );
    // Listed, but silent: no toast and no unseen highlight.
    expect(store.pendingToasts, isEmpty);
    expect(store.unseenSlowOps, 0);
  });

  test('processes the longest waiting candidate first', () async {
    // Distinct kinds, so the reports are not merged by signature.
    coordinator
      ..handleCandidate(candidate(start: 0, end: 50000))
      ..handleCandidate(
        candidate(start: 1000000, end: 1020000, kinds: {JankKind.uiStall}),
      )
      ..handleCandidate(
        candidate(
          start: 2000000,
          end: 2080000,
          kinds: {JankKind.delayedFrame},
        ),
      );
    await settle();
    // Newest first: the 80 ms one was processed before the 20 ms one.
    expect(store.slowOps.map((r) => r.kinds.single), [
      JankKind.uiStall,
      JankKind.delayedFrame,
      JankKind.slowBuild,
    ]);
  });

  test('reports the least significant candidate unattributed when the queue '
      'is full', () async {
    coordinatorFor(
        config: const JankDetectionConfig(
          warmUp: Duration.zero,
          maxQueuedCandidates: 1,
        ),
      )
      ..markFirstFrame()
      ..handleCandidate(candidate(start: 0, end: 50000))
      ..handleCandidate(
        candidate(start: 1000000, end: 1060000, kinds: {JankKind.uiStall}),
      )
      ..handleCandidate(candidate(start: 2000000, end: 2030000));
    await settle();
    final skipped = store.slowOps.where(
      (r) => r.attributionState == AttributionState.skipped,
    );
    expect(skipped.single.title, 'Slow build 30 ms');
    expect(store.slowOps, hasLength(3));
  });

  test('ignores candidates from before the clock was calibrated', () async {
    coordinator.handleCandidate(
      candidate(
        start: 1000,
        end: 51000,
        attributable: false,
        unattributableState: AttributionState.uncalibrated,
      ),
    );
    await settle();
    expect(store.slowOps, isEmpty);
    expect(coordinator.warmUpIgnored, 1);
  });

  test('drops a window in which this isolate served our own RPC', () async {
    final serviceBridge = FakeRuntimeBridge(
      serviceUris: [Uri.parse('http://127.0.0.1:1/x=/')],
      apiFactory: () => FakeVmApi(
        samples: cpuSamples(
          functions: [
            nativeFunction('dart::ProfilerService::PrintJSON'),
            profileFunction(funcRef('slow', owner: classRef('Thing', page))),
          ],
          samples: [
            for (var i = 0; i < 8; i++) cpuSample([0, 1]),
            cpuSample([1]),
          ],
        ),
      ),
    );
    coordinatorFor(session: sessionFor(serviceBridge))
      ..markFirstFrame()
      ..handleCandidate(
        candidate(start: 1000, end: 201000, kinds: {JankKind.uiStall}),
      );
    await settle();
    expect(store.slowOps, isEmpty);
    expect(guard.suppressedCount, 1);
  });

  test('clears the buffer only after a fetch that is slow for the device, '
      'and skips janks whose samples were cleared', () async {
    JankAttributionOutcome fetch(int rpcMillis) => JankAttributionOutcome(
      state: AttributionState.noVmService,
      rpcMicros: rpcMillis * 1000,
    );
    final backend = _ScriptedBackend([
      fetch(270),
      fetch(270),
      fetch(500),
      fetch(270),
    ]);
    final scheduler = JankCoordinator(
      config: const JankDetectionConfig(
        warmUp: Duration.zero,
        fetchCooldownFactor: 0,
      ),
      store: store,
      guard: guard,
      now: () => now,
      wallClock: () => DateTime(2026),
      backend: backend,
    )..markFirstFrame();

    // Two fetches of 270 ms: slower than the 250 ms floor, but that is this
    // device's baseline, so the buffer is not cleared.
    for (var i = 1; i <= 2; i++) {
      scheduler.handleCandidate(
        candidate(start: i * 1000000, end: i * 1000000 + 50000),
      );
      await settle();
    }
    expect(backend.clears, 0);

    // A fetch 1.5× slower than the fastest clears it, guarded.
    now = 3100000;
    scheduler.handleCandidate(candidate(start: 3000000, end: 3050000));
    await settle();
    expect(backend.clears, 1);
    expect(backend.guardedClears, 1);
    expect(scheduler.bufferClears, 1);

    // A jank from before the clear has lost its samples: no fetch, listed
    // silently. One from after it is fetched.
    scheduler.handleCandidate(
      candidate(start: 2500000, end: 2550000, kinds: {JankKind.uiStall}),
    );
    await settle();
    expect(backend.attributions, 3);
    expect(scheduler.clearedBeforeFetch, 1);
    final skipped = store.slowOps.first;
    expect(skipped.attributionState, AttributionState.skipped);
    expect(skipped.attributionHint, contains('cleared'));
    // The three slow builds share one signature (kind, state, severity);
    // the skipped stall was listed silently.
    expect(store.unseenSlowOps, 1);

    scheduler.handleCandidate(candidate(start: 3500000, end: 3550000));
    await settle();
    expect(backend.attributions, 4);
  });

  test('does not clear the buffer while other janks are waiting', () async {
    JankAttributionOutcome fetch(int rpcMillis) => JankAttributionOutcome(
      state: AttributionState.noVmService,
      rpcMicros: rpcMillis * 1000,
    );
    final backend = _ScriptedBackend([fetch(200), fetch(900), fetch(900)]);
    final scheduler =
        JankCoordinator(
            config: const JankDetectionConfig(
              warmUp: Duration.zero,
              fetchCooldownFactor: 0,
            ),
            store: store,
            guard: guard,
            now: () => now,
            wallClock: () => DateTime(2026),
            backend: backend,
          )
          ..markFirstFrame()
          ..handleCandidate(candidate(start: 1000000, end: 1050000));
    await settle();
    expect(backend.clears, 0, reason: 'the baseline fetch');

    // The third jank queues up during the second fetch: that slow fetch
    // does not clear; the next one, with nothing waiting, does.
    scheduler
      ..handleCandidate(
        candidate(start: 2000000, end: 2050000, kinds: {JankKind.uiStall}),
      )
      ..handleCandidate(
        candidate(
          start: 3000000,
          end: 3050000,
          kinds: {JankKind.delayedFrame},
        ),
      );
    await settle();
    expect(backend.attributions, 3);
    expect(backend.clears, 1);
  });

  test('spaces fetches out by the cooldown factor', () {
    fakeAsync((async) {
      final backend = _ScriptedBackend([
        const JankAttributionOutcome(
          state: AttributionState.noVmService,
          rpcMicros: 270000,
        ),
      ]);
      final paced =
          JankCoordinator(
              config: const JankDetectionConfig(warmUp: Duration.zero),
              store: store,
              guard: guard,
              now: () => now,
              wallClock: () => DateTime(2026),
              backend: backend,
            )
            ..markFirstFrame()
            ..handleCandidate(candidate(start: 1000, end: 51000));
      async.flushMicrotasks();
      expect(backend.attributions, 1);
      // Severe, so the backoff for fetches without app code does not apply.
      paced.handleCandidate(
        candidate(start: 1000000, end: 1300000, kinds: {JankKind.uiStall}),
      );
      async.flushMicrotasks();
      expect(backend.attributions, 1, reason: 'cooling down: 9 × 270 ms');
      async.elapse(const Duration(milliseconds: 2400));
      expect(backend.attributions, 1);
      async.elapse(const Duration(milliseconds: 100));
      expect(backend.attributions, 2);
    });
  });

  test('backs off while fetches find no app code', () {
    fakeAsync((async) {
      final backend = _ScriptedBackend([
        const JankAttributionOutcome(
          state: AttributionState.noVmService,
          rpcMicros: 270000,
        ),
      ]);
      final paced =
          JankCoordinator(
              config: const JankDetectionConfig(warmUp: Duration.zero),
              store: store,
              guard: guard,
              now: () => now,
              wallClock: () => DateTime(2026),
              backend: backend,
            )
            ..markFirstFrame()
            ..handleCandidate(candidate(start: 1000, end: 51000));
      async.flushMicrotasks();
      expect(backend.attributions, 1);
      expect(paced.uselessFetches, 1);

      // Second fetch: the cooldown doubled to 2 × 9 × 270 ms.
      paced.handleCandidate(
        candidate(start: 1000000, end: 1050000, kinds: {JankKind.uiStall}),
      );
      async.elapse(const Duration(milliseconds: 4800));
      expect(backend.attributions, 1);
      async.elapse(const Duration(milliseconds: 100));
      expect(backend.attributions, 2);
      expect(paced.uselessFetches, 2);

      // A severe candidate keeps the base spacing (9 × 270 ms).
      paced.handleCandidate(
        candidate(
          start: 2000000,
          end: 2300000,
          kinds: {JankKind.delayedFrame},
        ),
      );
      async.elapse(const Duration(milliseconds: 2500));
      expect(backend.attributions, 3);
    });
  });

  test('ignores janks rendered while the report panel was open', () async {
    final controller = OverlayController(
      initialAlignment: Alignment.bottomRight,
      now: () => now,
    );
    final backend = _ScriptedBackend([
      const JankAttributionOutcome(state: AttributionState.noVmService),
    ]);
    final panelAware = JankCoordinator(
      config: const JankDetectionConfig(warmUp: Duration.zero),
      store: store,
      guard: guard,
      now: () => now,
      wallClock: () => DateTime(2026),
      backend: backend,
      isOverlayWindow: controller.coversWindow,
    )..markFirstFrame();
    expect(controller.coversWindow(0, 1), isFalse, reason: 'never opened');

    now = 1000000;
    controller.open();
    panelAware.handleCandidate(candidate(start: 500000, end: 900000));
    await settle();
    expect(backend.attributions, 1, reason: 'ended before the panel opened');

    panelAware.handleCandidate(
      candidate(start: 2000000, end: 2300000, kinds: {JankKind.uiStall}),
    );
    await settle();
    expect(backend.attributions, 1);
    expect(panelAware.overlayIgnored, 1);

    now = 3000000;
    controller.close();
    // The closing transition still counts; a second later it does not.
    panelAware.handleCandidate(candidate(start: 3500000, end: 3550000));
    await settle();
    expect(panelAware.overlayIgnored, 2);
    panelAware.handleCandidate(
      candidate(start: 4100000, end: 4400000, kinds: {JankKind.uiStall}),
    );
    await settle();
    expect(backend.attributions, 2);
  });

  test(
    'drops an engine-only window inside an inflated section of ours',
    () async {
      // Baseline: two 50 ms sample fetches. Then one of 300 ms: inflated,
      // so the guard alone does not suppress candidates inside it.
      for (final start in [1000000, 1500000]) {
        now = start;
        guard.begin(label: 'samples');
        now = start + 50000;
        guard.end();
      }
      now = 2000000;
      guard.begin(label: 'samples');
      now = 2300000;
      guard.end();
      expect(guard.overlaps(2050000, 2250000), isFalse);
      expect(guard.overlapsInflated(2050000, 2250000), isTrue);
      expect(guard.overlapsInflated(1010000, 1040000), isFalse);

      const engineOnly = CpuAttribution(
        source: ProfileSource.perfetto,
        sampleCount: 10,
        usedSamples: 10,
        samplePeriodMicros: 1000,
        truncatedSamples: 0,
        idleTicks: 0,
        gcTicks: 0,
        compileTicks: 0,
        toolingTicks: 0,
        selfTicksByOrigin: {},
        ticksWithAppCode: 0,
        ticksWithoutAppCode: 10,
        hotAppFunctions: [],
        hotOtherFunctions: [],
        appCallTree: [],
        engineTicks: 8,
        systemTicks: 1,
      );
      final backend = _ScriptedBackend([
        const JankAttributionOutcome(
          state: AttributionState.attributed,
          attribution: engineOnly,
          rpcMicros: 300000,
        ),
      ]);
      final scheduler = JankCoordinator(
        config: const JankDetectionConfig(
          warmUp: Duration.zero,
          fetchCooldownFactor: 0,
        ),
        store: store,
        guard: guard,
        now: () => now,
        wallClock: () => DateTime(2026),
        backend: backend,
      );
      now = 0;
      scheduler.markFirstFrame();
      now = 2300000;
      scheduler.handleCandidate(
        candidate(start: 2050000, end: 2250000, kinds: {JankKind.uiStall}),
      );
      await settle();
      expect(backend.attributions, 1);
      expect(store.slowOps, isEmpty, reason: 'ours: dropped');
      expect(guard.suppressedCount, 1);

      // The same samples outside any section of ours are the app's problem.
      now = 3300000;
      scheduler.handleCandidate(
        candidate(start: 3000000, end: 3200000, kinds: {JankKind.uiStall}),
      );
      await settle();
      expect(store.slowOps, hasLength(1));
      expect(store.slowOps.single.subtitle, contains('Flutter engine'));
    },
  );

  test('mergeCandidates unions kinds and windows', () {
    final merged = JankCoordinator.mergeCandidates(
      candidate(start: 0, end: 10, kinds: {JankKind.slowBuild}),
      candidate(start: 5, end: 20, kinds: {JankKind.delayedFrame}),
    );
    expect(merged.kinds, {JankKind.slowBuild, JankKind.delayedFrame});
    expect(merged.windowStartMicros, 0);
    expect(merged.windowEndMicros, 20);
    expect(merged.attributable, isTrue);
  });
}
