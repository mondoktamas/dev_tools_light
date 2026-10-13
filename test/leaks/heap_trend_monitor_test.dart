import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/stall_guard.dart';
import 'package:dev_tools_light/src/leaks/heap_trend_monitor.dart';
import 'package:dev_tools_light/src/leaks/heap_trend_report.dart';
import 'package:dev_tools_light/src/vm/gc_controller.dart';
import 'package:dev_tools_light/src/vm/vm_session.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' as vms;

import '../helpers/fake_runtime_bridge.dart';
import '../helpers/fake_vm_api.dart';
import '../helpers/fixtures.dart';

/// A GC controller whose scavenge is counted instead of run.
class _FakeGc extends GcController {
  _FakeGc({required super.barrier, required super.now});

  int scavengeCalls = 0;

  @override
  bool scavenge() {
    scavengeCalls++;
    return true;
  }
}

void main() {
  const cache = 'package:my_app/cache.dart';
  late int now;
  late int barrier;
  late bool busy;
  late ReportStore store;
  late SelfInflictedStallGuard guard;
  late FakeVmApi api;
  late _FakeGc gc;
  var clock = DateTime(2026);

  vms.AllocationProfile snapshot({
    required int entries,
    int lists = 1000,
    int controllers = 5,
  }) => allocationProfile([
    classHeapStats(
      'CacheEntry',
      cache,
      instances: entries,
      bytes: entries * 64,
      classId: 'classes/1',
    ),
    classHeapStats(
      '_GrowableList',
      'dart:core',
      instances: lists,
      bytes: lists * 32,
    ),
    classHeapStats(
      'TextEditingController',
      'package:flutter/src/widgets/editable_text.dart',
      instances: controllers,
      bytes: controllers * 128,
    ),
  ]);

  HeapTrendMonitor monitor(
    List<vms.AllocationProfile> profiles, {
    HeapTrendConfig config = const HeapTrendConfig(minRisingSnapshots: 3),
    Map<String, vms.InstanceSet> instanceSets = const {},
    Map<String, vms.RetainingPath> retainingPaths = const {},
    Map<String, vms.InboundReferences> inboundReferences = const {},
    bool reachable = true,
  }) {
    // One API instance across the ephemeral connections, so that the
    // scripted profiles advance from snapshot to snapshot.
    api = FakeVmApi(
      allocationProfiles: profiles,
      instanceSets: instanceSets,
      retainingPaths: retainingPaths,
      inboundReferences: inboundReferences,
    );
    final bridge = FakeRuntimeBridge(
      serviceUris: [Uri.parse('http://127.0.0.1:1/x=/')],
      apiFactory: () => api,
    )..connectError = reachable ? null : Exception('refused');
    final session = VmSession(
      bridge: bridge,
      now: () => now,
      discoveryGrace: Duration.zero,
      pollInterval: Duration.zero,
      connectedUri: () => 'http://127.0.0.1:1/x=/',
    );
    gc = _FakeGc(barrier: () => barrier, now: () => now);
    return HeapTrendMonitor(
      config: config,
      session: session,
      guard: guard,
      store: store,
      classifier: AppCodeClassifier(appPrefixes: {'package:my_app/'}),
      now: () => now,
      isolateId: () => 'isolates/1',
      barrier: () => barrier,
      gc: gc,
      isBusy: () => busy,
      wallClock: () => clock = clock.add(const Duration(seconds: 30)),
    );
  }

  setUp(() {
    now = 0;
    barrier = 0;
    busy = false;
    store = ReportStore();
    guard = SelfInflictedStallGuard(now: () => now);
    clock = DateTime(2026);
  });

  test('reports a class after enough consecutive growth', () async {
    final m = monitor([
      snapshot(entries: 100),
      snapshot(entries: 150),
      snapshot(entries: 200),
      snapshot(entries: 260),
    ]);
    for (var i = 0; i < 3; i++) {
      expect(await m.snapshotNow(), isTrue);
      expect(store.heapTrends, isEmpty, reason: 'snapshot ${i + 1}');
    }
    expect(await m.snapshotNow(), isTrue);
    final report = store.heapTrends.single;
    expect(report.className, 'CacheEntry');
    expect(report.instanceGrowth, 160);
    expect(report.samples, hasLength(4));
    expect(report.subtitle, contains('+160 instances'));
    expect(report.subtitle, contains('now 260 live'));
    expect(store.pendingToasts.single.title, 'Growing: CacheEntry');
    expect(m.snapshotsTaken, 4);
    expect(api.gcRequests, 4, reason: 'manual snapshots force a GC');
    expect(gc.scavengeCalls, 0);
  });

  test('afterVmGc snapshots follow VM collections and the interval', () async {
    final m = monitor([for (var i = 0; i < 6; i++) snapshot(entries: 100)])
      ..start();
    addTearDown(m.stop);
    await m.poll();
    expect(m.snapshotsTaken, 0, reason: 'no collection yet');
    expect(m.describe(), contains('waiting for the first'));

    barrier++;
    await m.poll();
    expect(m.snapshotsTaken, 1);
    expect(m.vmGcsObserved, 1);
    expect(gc.scavengeCalls, 1, reason: 'new space is scavenged first');
    expect(api.gcRequests, 0, reason: 'no forced GC');

    barrier++;
    now += const Duration(seconds: 10).inMicroseconds;
    await m.poll();
    expect(m.snapshotsTaken, 1, reason: 'too soon after the last snapshot');
    expect(m.vmGcsSkipped, 1);

    now += const Duration(seconds: 60).inMicroseconds;
    await m.poll();
    expect(m.snapshotsTaken, 1, reason: 'no collection since');

    barrier++;
    await m.poll();
    expect(m.snapshotsTaken, 2);

    // A collection seen while busy is used by a later poll.
    busy = true;
    barrier++;
    now += const Duration(seconds: 70).inMicroseconds;
    await m.poll();
    expect(m.snapshotsTaken, 2);
    expect(m.skippedBusy, 1);
    busy = false;
    now += const Duration(seconds: 1).inMicroseconds;
    await m.poll();
    expect(m.snapshotsTaken, 3);

    // ... unless it is too old by then.
    busy = true;
    barrier++;
    now += const Duration(seconds: 70).inMicroseconds;
    await m.poll();
    busy = false;
    now += const Duration(seconds: 10).inMicroseconds;
    await m.poll();
    expect(m.snapshotsTaken, 3);
    expect(m.vmGcsSkipped, 2);
    expect(m.describe(), contains('5 seen, 3 used'));
  });

  test('a manual snapshot forces a GC and is not a VM collection', () async {
    final m = monitor([snapshot(entries: 100), snapshot(entries: 100)])
      ..start();
    addTearDown(m.stop);
    api.onGcRequest = () => barrier += 4;
    expect(await m.snapshotNow(), isTrue);
    expect(api.gcRequests, 1);
    await m.poll();
    expect(m.vmGcsObserved, 0);
    expect(m.snapshotsTaken, 1);
    expect(m.vmGcSnapshots, 0);
    expect(m.describe(), contains('0 seen, 0 used'));
  });

  test('the other triggers run on a timer', () {
    for (final trigger in [
      HeapSnapshotTrigger.forcedGc,
      HeapSnapshotTrigger.periodic,
    ]) {
      fakeAsync((async) {
        final m = monitor(
          [snapshot(entries: 100), snapshot(entries: 100)],
          config: HeapTrendConfig(
            trigger: trigger,
            interval: const Duration(seconds: 30),
          ),
        )..start();
        async
          ..elapse(const Duration(seconds: 29))
          ..flushMicrotasks();
        expect(m.snapshotsTaken, 0, reason: '$trigger');
        async
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        expect(m.snapshotsTaken, 1, reason: '$trigger');
        final forced = trigger == HeapSnapshotTrigger.forcedGc;
        expect(api.gcRequests, forced ? 1 : 0, reason: '$trigger');
        expect(gc.scavengeCalls, forced ? 0 : 1, reason: '$trigger');
        m.stop();
      });
    }
  });

  test('ignores dart: classes, small growth and a broken run', () async {
    final m = monitor([
      snapshot(entries: 100),
      snapshot(entries: 120, lists: 5000),
      snapshot(entries: 140, lists: 9000),
      snapshot(entries: 130, lists: 13000), // CacheEntry shrank
      snapshot(entries: 160, lists: 17000),
    ]);
    for (var i = 0; i < 5; i++) {
      await m.snapshotNow();
    }
    expect(store.heapTrends, isEmpty);
  });

  test('framework classes can be excluded and ignore lists apply', () async {
    final profiles = [
      for (var i = 0; i < 5; i++)
        snapshot(entries: 100 + i * 100, controllers: 10 + i * 100),
    ];
    final m = monitor(
      profiles,
      config: const HeapTrendConfig(
        minRisingSnapshots: 3,
        includeFrameworkClasses: false,
        ignoredClassNames: {'CacheEntry'},
      ),
    );
    for (var i = 0; i < 5; i++) {
      await m.snapshotNow();
    }
    expect(store.heapTrends, isEmpty);

    final all = monitor(profiles);
    for (var i = 0; i < 5; i++) {
      await all.snapshotNow();
    }
    expect(
      store.heapTrends.map((r) => r.className),
      containsAll(['CacheEntry', 'TextEditingController']),
    );
  });

  test('fetchTrace attaches the retaining path of a live instance', () async {
    final m = monitor(
      [for (var i = 0; i < 5; i++) snapshot(entries: 100 + i * 100)],
      instanceSets: {
        'classes/1': instanceSet(['objects/7', 'objects/8']),
      },
      retainingPaths: {
        'objects/8': retainingPath([
          retainingObject(instanceRef('CacheEntry', cache, id: 'objects/8')),
          retainingObject(
            instanceRef('_GrowableList', 'dart:core', id: 'objects/9'),
            parentListIndex: 3,
          ),
          retainingObject(
            staticFieldRef(
              'entries',
              owner: classRef('ImageCacheLike', cache),
              uri: cache,
            ),
          ),
        ]),
      },
    );
    for (var i = 0; i < 5; i++) {
      await m.snapshotNow();
    }
    final report = store.heapTrends.single;
    expect(report.traceState, HeapTrendTraceState.notFetched);
    await m.fetchTrace(report.id);
    final fetched = store.heapTrendById(report.id)!;
    expect(fetched.traceState, HeapTrendTraceState.fetched);
    expect(fetched.trace, isNotNull);
    expect(fetched.trace!.summary, contains('ImageCacheLike'));
    expect(fetched.traceDetail, contains('live instances'));
  });

  test('fetchTrace looks for a strong path behind a weak one', () async {
    const core = 'dart:core';
    final m = monitor(
      [for (var i = 0; i < 5; i++) snapshot(entries: 100 + i * 100)],
      instanceSets: {
        'classes/1': instanceSet(['objects/8']),
      },
      retainingPaths: {
        'objects/8': retainingPath([
          retainingObject(instanceRef('CacheEntry', cache, id: 'objects/8')),
          retainingObject(instanceRef('_WeakProperty', core, id: 'objects/wp')),
          retainingObject(
            instanceRef('Expando', core, id: 'objects/e'),
            parentField: '_data',
          ),
        ]),
        'objects/list': retainingPath([
          retainingObject(
            instanceRef(
              '_GrowableList',
              core,
              kind: 'List',
              id: 'objects/list',
            ),
          ),
          retainingObject(
            staticFieldRef(
              'entries',
              owner: classRef('ImageCacheLike', cache),
              uri: cache,
            ),
          ),
        ]),
      },
      inboundReferences: {
        'objects/8': inboundReferences([
          inboundReference(
            instanceRef('_WeakProperty', core, id: 'objects/wp'),
          ),
          inboundReference(
            instanceRef(
              '_GrowableList',
              core,
              kind: 'List',
              id: 'objects/list',
            ),
            parentField: 1,
          ),
        ]),
      },
    );
    for (var i = 0; i < 5; i++) {
      await m.snapshotNow();
    }
    final report = store.heapTrends.single;
    await m.fetchTrace(report.id);
    final trace = store.heapTrendById(report.id)!.trace!;
    expect(trace.viaWeakReference, isFalse);
    expect(trace.note, contains('_WeakProperty'));
    expect(trace.summary, contains('ImageCacheLike'));
  });

  test('is quiet when the VM service is unavailable', () async {
    final m = monitor([snapshot(entries: 100)], reachable: false);
    expect(await m.snapshotNow(), isFalse);
    expect(store.heapTrends, isEmpty);
    expect(m.snapshotsTaken, 0);
  });
}
