import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/internal_marker.dart';
import 'package:dev_tools_light/src/leaks/lifecycle_watcher.dart';
import 'package:dev_tools_light/src/leaks/object_watcher.dart';
import 'package:dev_tools_light/src/leaks/package_watch_policy.dart';
import 'package:dev_tools_light/src/leaks/watched_kind.dart';
import 'package:dev_tools_light/src/leaks/watched_packages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

class _Internal extends ValueNotifier<int> with DevToolsLightInternal {
  _Internal() : super(0);
}

class _Bloc {}

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  test('watchedKindOf classifies framework objects', () {
    expect(watchedKindOf(ValueNotifier<int>(0)), WatchedKind.changeNotifier);
    expect(watchedKindOf(TextEditingController()), WatchedKind.changeNotifier);
    expect(
      watchedKindOf(AnimationController(vsync: const TestVSync())),
      WatchedKind.animationController,
    );
    expect(
      watchedKindOf(OverlayEntry(builder: (_) => const SizedBox())),
      WatchedKind.overlayEntry,
    );
    expect(
      watchedKindOf(MaterialPageRoute<void>(builder: (_) => const SizedBox())),
      WatchedKind.route,
    );
    expect(watchedKindOf(Ticker((_) {})), WatchedKind.ticker);
    expect(watchedKindOf(Object()), isNull);
    expect(typeNameOf(ValueNotifier<int>(0)), 'ValueNotifier');
  });

  group('LifecycleWatcher.handleDisposed', () {
    late ObjectWatcher watcher;
    late List<WatchedObject> seen;

    ObjectWatcher makeWatcher(LeakDetectionConfig config) => ObjectWatcher(
      config: config,
      now: () => 0,
      barrier: () => 0,
      onRetained: (candidates, {forced = false}) async {
        seen.addAll(candidates);
        return {for (final c in candidates) c.id};
      },
    );

    setUp(() {
      seen = [];
      watcher = makeWatcher(const LeakDetectionConfig());
    });

    test('watches enabled kinds and skips the rest', () {
      LifecycleWatcher(config: const LeakDetectionConfig(), watcher: watcher)
        ..handleDisposed(ValueNotifier<int>(0))
        ..handleDisposed(Ticker((_) {})) // ticker is opt-in
        ..handleDisposed(_Internal())
        ..handleDisposed(Object());
      expect(watcher.watchedCount, 1);
    });

    test('skips objects whose package is known not to be watched', () {
      final policy =
          PackageWatchPolicy(
            config: WatchedPackages.appOnly,
            classifier: AppCodeClassifier(appPrefixes: {'package:my_app/'}),
          )..learn(
            ValueNotifier<int>,
            'package:flutter/src/foundation/change_notifier.dart',
          );
      LifecycleWatcher(
          config: const LeakDetectionConfig(),
          watcher: watcher,
          policy: policy,
        )
        ..handleDisposed(ValueNotifier<int>(0)) // known: not watched
        ..handleDisposed(TextEditingController()); // unknown yet: watched
      expect(watcher.watchedCount, 1);
      expect(policy.skipped, 1);
    });

    test('honours ignoredTypeNames and watchFilter', () {
      final config = LeakDetectionConfig(
        ignoredTypeNames: const {'ValueNotifier'},
        watchFilter: (o) => o is _Bloc,
      );
      watcher = makeWatcher(config);
      LifecycleWatcher(config: config, watcher: watcher)
        ..handleDisposed(ValueNotifier<int>(0))
        ..handleDisposed(_Bloc());
      expect(watcher.watchedCount, 1);
    });

    testWidgets('receives real FlutterMemoryAllocations events', (
      tester,
    ) async {
      final lifecycle = LifecycleWatcher(
        config: const LeakDetectionConfig(),
        watcher: watcher,
      )..start();
      addTearDown(lifecycle.stop);
      expect(lifecycle.isActive, LifecycleWatcher.isSupported);

      await tester.pumpWidget(const _Probe());
      final state = tester.state<_ProbeState>(find.byType(_Probe));
      expect(state, isNotNull);
      await tester.pumpWidget(const SizedBox()); // unmounts → State.dispose()

      // A controller created and disposed by hand.
      TextEditingController().dispose();

      expect(watcher.watchedCount, LifecycleWatcher.isSupported ? 2 : 0);
    });
  });
}
