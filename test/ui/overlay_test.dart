import 'package:dev_tools_light/dev_tools_light.dart';
import 'package:dev_tools_light/src/ui/badge.dart';
import 'package:dev_tools_light/src/ui/reports_page.dart';
import 'package:dev_tools_light/src/ui/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

LeakReport sampleLeak() {
  final now = DateTime(2026);
  const trace = LeakTrace(
    gcRootType: 'user global',
    signature: 'sig',
    nodes: [
      LeakTraceNode(
        className: 'AppEvents',
        libraryUri: 'package:my_app/globals.dart',
        origin: CodeOrigin.app,
        status: LeakStatus.notLeaking,
        statusReason: 'static field',
        referenceKind: ReferenceKind.staticField,
        referenceName: 'retained',
        location: 'lib/globals.dart:12',
        isSuspect: true,
      ),
      LeakTraceNode(
        className: '_HomePageState',
        libraryUri: 'package:my_app/home.dart',
        origin: CodeOrigin.app,
        status: LeakStatus.leaking,
        statusReason: 'disposed and still reachable after GC',
      ),
    ],
  );
  return LeakReport(
    id: 'leak-1',
    detectedAt: now,
    typeName: '_HomePageState',
    kind: WatchedKind.state,
    signature: 'sig',
    firstSeen: now,
    lastSeen: now,
    trace: trace,
  );
}

/// The status the engine publishes when every feature is enabled.
const runningStatus = DevToolsLightStatus(
  mode: RuntimeMode.debug,
  vm: VmConnectionState.reachable,
  leaks: LeakDetectionState.automatic,
  jank: JankDetectionState.attributing,
  heapTrends: HeapTrendState.active,
);

Widget host({
  required ReportStore store,
  required OverlayController controller,
  OverlayConfig config = const OverlayConfig(),
  DevToolsLightStatus status = runningStatus,
}) {
  store.status = status;
  return MaterialApp(
    builder: (context, child) => DevToolsLightOverlay(
      store: store,
      controller: controller,
      config: config,
      child: child,
    ),
    home: const Scaffold(body: Center(child: Text('host app'))),
  );
}

void main() {
  testWidgets('returns the child untouched when not running', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        builder: DevToolsLight.builder,
        home: Scaffold(body: Text('host app')),
      ),
    );
    expect(find.text('host app'), findsOneWidget);
    expect(find.byType(FindingsBadge), findsNothing);
  });

  testWidgets('badge shows counts and opens the panel', (tester) async {
    final store = ReportStore();
    final controller = OverlayController(
      initialAlignment: Alignment.bottomRight,
    );
    await tester.pumpWidget(host(store: store, controller: controller));
    expect(find.byType(FindingsBadge), findsOneWidget);
    expect(find.text('0'), findsNWidgets(2));

    store.addLeak(sampleLeak());
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    // Toast for the new finding.
    expect(find.byType(ToastLayer), findsOneWidget);
    expect(find.text('Leak: _HomePageState'), findsOneWidget);

    await tester.tap(find.byKey(FindingsBadge.pillKey));
    await tester.pumpAndSettle();
    expect(find.byType(ReportsPage), findsOneWidget);
    expect(find.text('Leaks (1)'), findsOneWidget);
    expect(store.unseenLeaks, 0, reason: 'opening the Leaks tab marks seen');

    // Open the detail page and check the trace rendering.
    await tester.tap(find.text('_HomePageState').first);
    await tester.pumpAndSettle();
    expect(find.text('GC root: user global'), findsOneWidget);
    expect(find.textContaining('static AppEvents.retained'), findsWidgets);
    expect(find.textContaining('LEAKING'), findsWidgets);

    // Back closes the detail page, then the panel.
    expect(controller.handleBack(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(ReportsPage), findsOneWidget);
    expect(controller.handleBack(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(ReportsPage), findsNothing);
    expect(controller.handleBack(), isFalse);

    // Let the toast timers expire.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('the Growth tab lists a growing class and fetches its path', (
    tester,
  ) async {
    final store = ReportStore();
    final controller =
        OverlayController(initialAlignment: Alignment.bottomRight)
          ..onFetchHeapTrendTrace = (id) async {
            store.updateHeapTrend(
              id,
              (r) => r.copyWith(
                trace: sampleLeak().trace,
                traceState: HeapTrendTraceState.fetched,
                traceDetail: 'One of 800 live instances.',
              ),
            );
          };
    await tester.pumpWidget(host(store: store, controller: controller));
    final now = DateTime(2026);
    store.addHeapTrend(
      HeapTrendReport(
        id: 'heap-1',
        className: 'CacheEntry',
        libraryUri: 'package:my_app/cache.dart',
        origin: CodeOrigin.app,
        classId: 'classes/1',
        samples: [
          HeapTrendSample(at: now, instances: 200, bytes: 6400),
          HeapTrendSample(
            at: now.add(const Duration(seconds: 30)),
            instances: 800,
            bytes: 25600,
          ),
        ],
        firstSeen: now,
        lastSeen: now,
      ),
    );
    await tester.pump();
    expect(find.text('Growing: CacheEntry'), findsOneWidget, reason: 'toast');

    await tester.tap(find.byKey(FindingsBadge.pillKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Growth (1)'));
    await tester.pumpAndSettle();
    expect(store.unseenHeapTrends, 0);
    expect(find.text('CacheEntry'), findsOneWidget);
    expect(find.textContaining('+600 instances'), findsWidgets);

    await tester.tap(find.text('CacheEntry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find retaining path'));
    await tester.pumpAndSettle();
    expect(find.text('GC root: user global'), findsOneWidget);
    expect(find.textContaining('One of 800 live instances'), findsOneWidget);

    // Let the toast timers expire.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('disabled features have no tab and no action', (tester) async {
    final store = ReportStore();
    final controller = OverlayController(
      initialAlignment: Alignment.bottomRight,
    );
    await tester.pumpWidget(
      host(
        store: store,
        controller: controller,
        // Leaks and heap trends keep their default, disabled.
        status: const DevToolsLightStatus(
          mode: RuntimeMode.debug,
          vm: VmConnectionState.reachable,
          jank: JankDetectionState.attributing,
        ),
      ),
    );
    await tester.tap(find.byKey(FindingsBadge.pillKey));
    await tester.pumpAndSettle();
    expect(find.text('Slow ops (0)'), findsOneWidget);
    expect(find.text('Status'), findsOneWidget);
    expect(find.textContaining('Leaks ('), findsNothing);
    expect(find.textContaining('Growth ('), findsNothing);
    expect(find.byTooltip('Check leaks now'), findsNothing);
    expect(find.byTooltip('Snapshot heap now (forces a GC)'), findsNothing);
    expect(find.byTooltip('Clear all reports'), findsOneWidget);
  });

  testWidgets('leaks off in a profile build has no Leaks tab', (tester) async {
    final store = ReportStore();
    final controller = OverlayController(
      initialAlignment: Alignment.bottomRight,
    );
    await tester.pumpWidget(
      host(
        store: store,
        controller: controller,
        status: const DevToolsLightStatus(
          mode: RuntimeMode.profile,
          vm: VmConnectionState.reachable,
          leaks: LeakDetectionState.debugOnly,
          jank: JankDetectionState.attributing,
          heapTrends: HeapTrendState.active,
        ),
      ),
    );
    await tester.tap(find.byKey(FindingsBadge.pillKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('Leaks ('), findsNothing);
    expect(find.byTooltip('Check leaks now'), findsNothing);
    expect(find.text('Slow ops (0)'), findsOneWidget);
    expect(find.text('Growth (0)'), findsOneWidget);
  });

  testWidgets('jank off in a debug build has no Slow ops tab', (tester) async {
    final store = ReportStore();
    final controller = OverlayController(
      initialAlignment: Alignment.bottomRight,
    );
    await tester.pumpWidget(
      host(
        store: store,
        controller: controller,
        status: const DevToolsLightStatus(
          mode: RuntimeMode.debug,
          vm: VmConnectionState.reachable,
          leaks: LeakDetectionState.automatic,
          jank: JankDetectionState.notInDebug,
          heapTrends: HeapTrendState.active,
        ),
      ),
    );
    await tester.tap(find.byKey(FindingsBadge.pillKey));
    await tester.pumpAndSettle();
    expect(find.text('Leaks (0)'), findsOneWidget);
    expect(find.text('Growth (0)'), findsOneWidget);
    expect(find.textContaining('Slow ops ('), findsNothing);
  });

  testWidgets('a toast opens the report it announces', (tester) async {
    final store = ReportStore();
    final controller = OverlayController(
      initialAlignment: Alignment.bottomRight,
    );
    await tester.pumpWidget(host(store: store, controller: controller));
    store.addLeak(sampleLeak());
    await tester.pump();
    await tester.tap(find.text('Leak: _HomePageState'));
    await tester.pumpAndSettle();
    expect(controller.isPanelOpen.value, isTrue);
    expect(find.text('GC root: user global'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a merged report schedules no frame', (tester) async {
    final store = ReportStore();
    final controller = OverlayController(
      initialAlignment: Alignment.bottomRight,
    );
    await tester.pumpWidget(host(store: store, controller: controller));
    store.addLeak(sampleLeak());
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);

    // The same signature again: counts do not change, so neither the badge
    // nor the toast layer marks anything dirty.
    store.addLeak(sampleLeak());
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(store.leaks.single.occurrences, 2);
  });

  testWidgets('badge and toasts can be disabled', (tester) async {
    final store = ReportStore();
    final controller = OverlayController(
      initialAlignment: Alignment.bottomRight,
    );
    await tester.pumpWidget(
      host(
        store: store,
        controller: controller,
        config: const OverlayConfig(showBadge: false, showToasts: false),
      ),
    );
    expect(find.byType(FindingsBadge), findsNothing);
    expect(find.byType(ToastLayer), findsNothing);
  });
}
