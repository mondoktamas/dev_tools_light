import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/stall_guard.dart';
import 'package:dev_tools_light/src/leaks/leak_analyzer.dart';
import 'package:dev_tools_light/src/leaks/object_watcher.dart';
import 'package:dev_tools_light/src/leaks/package_watch_policy.dart';
import 'package:dev_tools_light/src/leaks/watched_kind.dart';
import 'package:dev_tools_light/src/leaks/watched_packages.dart';
import 'package:dev_tools_light/src/vm/gc_controller.dart';
import 'package:dev_tools_light/src/vm/vm_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_runtime_bridge.dart';
import '../helpers/fake_vm_api.dart';
import '../helpers/fixtures.dart';

void main() {
  late int now;
  late FakeRuntimeBridge bridge;
  late LeakAnalyzer analyzer;
  int? lastPostFrame;
  final keepAlive = <Object>[];

  setUp(() {
    now = 0;
    lastPostFrame = null;
    bridge = FakeRuntimeBridge(
      serviceUris: [Uri.parse('http://127.0.0.1:1/x=/')],
      apiFactory: () =>
          FakeVmApi()..onCollectAllGarbage = () => bridge.barrier++,
    );
    final session = VmSession(
      bridge: bridge,
      now: () => now,
      discoveryGrace: Duration.zero,
      pollInterval: Duration.zero,
      connectedUri: () => 'http://127.0.0.1:1/x=/',
    );
    analyzer = LeakAnalyzer(
      config: const LeakDetectionConfig(maxDeferredChecks: 2),
      bridge: bridge,
      session: session,
      gc: GcController(barrier: () => bridge.barrier, now: () => now),
      store: ReportStore(),
      guard: SelfInflictedStallGuard(now: () => now),
      classifier: AppCodeClassifier(appPrefixes: {'package:my_app/'}),
      lastPostFrameMicros: () => lastPostFrame,
    );
  });

  WatchedObject watched(int id, {required int disposedAt}) {
    final object = Object();
    keepAlive.add(object);
    return WatchedObject(
      id: id,
      object: object,
      kind: WatchedKind.state,
      watchedAtMicros: disposedAt,
      barrierAtWatch: bridge.barrier,
    );
  }

  test('defers candidates until a frame completes after disposal', () async {
    final candidate = watched(1, disposedAt: 1000);
    expect(await analyzer.analyze([candidate]), isEmpty);
    expect(candidate.deferredChecks, 1);
    expect(bridge.connectedTo, isEmpty, reason: 'no VM work while deferred');

    lastPostFrame = 500; // a frame that completed before the disposal
    expect(await analyzer.analyze([candidate]), isEmpty);
    expect(candidate.deferredChecks, 2);
    expect(analyzer.deferredChecks, 2);

    lastPostFrame = 2000;
    expect(await analyzer.analyze([candidate]), {1});
    expect(bridge.connectedTo, isNotEmpty);
  });

  test('analyzes anyway after maxDeferredChecks', () async {
    final candidate = watched(1, disposedAt: 1000);
    await analyzer.analyze([candidate]);
    await analyzer.analyze([candidate]);
    expect(candidate.deferredChecks, 2);
    expect(await analyzer.analyze([candidate]), {1});
  });

  test('a forced check never defers', () async {
    final candidate = watched(1, disposedAt: 1000);
    expect(await analyzer.analyze([candidate], forced: true), {1});
    expect(candidate.deferredChecks, 0);
  });

  test('replaces a path through a weak reference by a strong one', () async {
    const core = 'dart:core';
    const app = 'package:my_app/cache.dart';
    final object = Object();
    keepAlive.add(object);
    final id = 'objects/${identityHashCode(object)}';
    final store = ReportStore();
    bridge = FakeRuntimeBridge(
      serviceUris: [Uri.parse('http://127.0.0.1:1/x=/')],
      apiFactory: () => FakeVmApi(
        retainingPaths: {
          id: retainingPath([
            retainingObject(instanceRef('Object', core, id: id)),
            retainingObject(
              instanceRef('_WeakProperty', core, id: 'objects/wp'),
            ),
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
                owner: classRef('Cache', app),
                uri: app,
                line: 3,
              ),
            ),
          ]),
        },
        inboundReferences: {
          id: inboundReferences([
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
              parentField: 2,
            ),
          ]),
        },
      )..onCollectAllGarbage = () => bridge.barrier++,
    );
    final weakAware = LeakAnalyzer(
      config: const LeakDetectionConfig(),
      bridge: bridge,
      session: VmSession(
        bridge: bridge,
        now: () => now,
        discoveryGrace: Duration.zero,
        pollInterval: Duration.zero,
        connectedUri: () => 'http://127.0.0.1:1/x=/',
      ),
      gc: GcController(barrier: () => bridge.barrier, now: () => now),
      store: store,
      guard: SelfInflictedStallGuard(now: () => now),
      classifier: AppCodeClassifier(appPrefixes: {'package:my_app/'}),
    );
    final candidate = WatchedObject(
      id: 1,
      object: object,
      kind: WatchedKind.manual,
      watchedAtMicros: 0,
      barrierAtWatch: 0,
    );
    expect(await weakAware.analyze([candidate], forced: true), {1});
    final trace = store.leaks.single.trace!;
    expect(trace.viaWeakReference, isFalse);
    expect(trace.note, contains('_WeakProperty'));
    expect(trace.summary, contains('Cache'));
    expect(trace.nodes[1].referenceDescription, '[2]');
    expect(weakAware.strongPathsFound, 1);
  });

  test('drops leaks of classes declared by unwatched packages', () async {
    const router = 'package:go_router/src/router.dart';
    const main = 'package:my_app/main.dart';
    final objects = [_Foreign(), _Foreign(), _Foreign()];
    keepAlive.addAll(objects);
    final ids = [for (final o in objects) 'objects/${identityHashCode(o)}'];
    final store = ReportStore();
    final policy = PackageWatchPolicy(
      config: WatchedPackages.defaults,
      classifier: AppCodeClassifier(appPrefixes: {'package:my_app/'}),
    );
    bridge = FakeRuntimeBridge(
      serviceUris: [Uri.parse('http://127.0.0.1:1/x=/')],
      apiFactory: () => FakeVmApi(
        retainingPaths: {
          for (final id in ids)
            id: retainingPath([
              retainingObject(instanceRef('GoRouter', router, id: id)),
              retainingObject(
                staticFieldRef(
                  'router',
                  owner: libraryRef(main),
                  uri: main,
                ),
              ),
            ]),
        },
      )..onCollectAllGarbage = () => bridge.barrier++,
    );
    final aware = LeakAnalyzer(
      config: const LeakDetectionConfig(),
      bridge: bridge,
      session: VmSession(
        bridge: bridge,
        now: () => now,
        discoveryGrace: Duration.zero,
        pollInterval: Duration.zero,
        connectedUri: () => 'http://127.0.0.1:1/x=/',
      ),
      gc: GcController(barrier: () => bridge.barrier, now: () => now),
      store: store,
      guard: SelfInflictedStallGuard(now: () => now),
      classifier: AppCodeClassifier(appPrefixes: {'package:my_app/'}),
      policy: policy,
    );
    WatchedObject watched(int index, WatchedKind kind) => WatchedObject(
      id: index,
      object: objects[index],
      kind: kind,
      watchedAtMicros: 0,
      barrierAtWatch: 0,
    );

    // The first instance costs a retaining path and teaches the policy.
    expect(await aware.analyze([watched(0, WatchedKind.changeNotifier)]), {
      0,
    });
    expect(store.leaks, isEmpty);
    expect(policy.skipped, 1);
    expect(policy.allowsType(_Foreign), isFalse);

    // The next one is dropped before any VM work beyond the GC.
    expect(await aware.analyze([watched(1, WatchedKind.changeNotifier)]), {
      1,
    });
    expect(bridge.apis.last.calls, isNot(contains('getRetainingPath')));
    expect(policy.skipped, 2);

    // A manual watch of the same class is still reported.
    expect(await aware.analyze([watched(2, WatchedKind.manual)]), {2});
    expect(store.leaks.single.typeName, '_Foreign');
    expect(policy.skipped, 2);
  });
}

class _Foreign {}
