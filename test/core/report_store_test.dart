import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/status.dart';
import 'package:dev_tools_light/src/jank/jank_candidate.dart';
import 'package:dev_tools_light/src/jank/slow_operation_report.dart';
import 'package:dev_tools_light/src/leaks/heap_trend_report.dart';
import 'package:dev_tools_light/src/leaks/leak_report.dart';
import 'package:dev_tools_light/src/leaks/watched_kind.dart';
import 'package:flutter_test/flutter_test.dart';

LeakReport leak(String id, String signature) {
  final now = DateTime(2026);
  return LeakReport(
    id: id,
    detectedAt: now,
    typeName: '_PageState',
    kind: WatchedKind.state,
    signature: signature,
    firstSeen: now,
    lastSeen: now,
  );
}

SlowOperationReport slowOp(String id, String signature) {
  final now = DateTime(2026);
  return SlowOperationReport(
    id: id,
    detectedAt: now,
    kinds: const {JankKind.slowBuild},
    windowStartMicros: 0,
    windowEndMicros: 50000,
    attributionState: AttributionState.attributed,
    signature: signature,
    firstSeen: now,
    lastSeen: now,
    buildDuration: const Duration(milliseconds: 50),
  );
}

void main() {
  group('ReportStore', () {
    test('adds leaks newest first and dedupes by signature', () {
      var notifications = 0;
      final store = ReportStore()
        ..addListener(() => notifications++)
        ..addLeak(leak('a', 'sig-1'))
        ..addLeak(leak('b', 'sig-2'))
        ..addLeak(leak('c', 'sig-1'));
      expect(store.leaks.map((r) => r.id), ['a', 'b']);
      expect(store.leaks.first.occurrences, 2);
      expect(store.unseenLeaks, 2);
      expect(store.pendingToasts, hasLength(2));
      expect(notifications, 3);
    });

    test('caps the number of reports', () {
      final store = ReportStore(maxReportsPerCategory: 2)
        ..addSlowOp(slowOp('a', '1'))
        ..addSlowOp(slowOp('b', '2'))
        ..addSlowOp(slowOp('c', '3'));
      expect(store.slowOps.map((r) => r.id), ['c', 'b']);
    });

    test('toasts are taken in order and seen counters reset', () {
      final store = ReportStore()
        ..addLeak(leak('a', '1'))
        ..addSlowOp(slowOp('b', '2'));
      expect(store.takeToast()?.reportId, 'a');
      expect(store.takeToast()?.reportId, 'b');
      expect(store.takeToast(), isNull);
      store.markLeaksSeen();
      expect(store.unseenLeaks, 0);
      expect(store.unseenSlowOps, 1);
      store.markSlowOpsSeen();
      expect(store.unseenSlowOps, 0);
    });

    test('updateSlowOp replaces a report in place', () {
      final store = ReportStore()
        ..addSlowOp(slowOp('a', '1'))
        ..updateSlowOp('a', (r) => r.merge(slowOp('x', '1')));
      expect(store.slowOps.single.occurrences, 2);
      expect(store.slowOpById('a'), isNotNull);
      expect(store.leakById('nope'), isNull);
    });

    test('heap trends refresh in place and toast once', () {
      final store = ReportStore();
      HeapTrendReport trend(int last) => HeapTrendReport(
        id: 'heap-$last',
        className: 'CacheEntry',
        libraryUri: 'package:my_app/cache.dart',
        origin: CodeOrigin.app,
        classId: 'classes/1',
        samples: [
          HeapTrendSample(at: DateTime(2026), instances: 10, bytes: 100),
          HeapTrendSample(
            at: DateTime(2026, 1, 2),
            instances: last,
            bytes: 500,
          ),
        ],
        firstSeen: DateTime(2026),
        lastSeen: DateTime(2026, 1, 2),
      );
      store
        ..addHeapTrend(trend(60))
        ..addHeapTrend(trend(90));
      expect(store.heapTrends, hasLength(1));
      expect(store.heapTrends.single.id, 'heap-60');
      expect(store.heapTrends.single.instanceGrowth, 80);
      expect(store.unseenHeapTrends, 1);
      expect(store.pendingToasts.single.kind, ReportKind.heapTrend);
      store.updateHeapTrend(
        'heap-60',
        (r) => r.copyWith(traceState: HeapTrendTraceState.failed),
      );
      expect(
        store.heapTrendById('heap-60')!.traceState,
        HeapTrendTraceState.failed,
      );
      store.markHeapTrendsSeen();
      expect(store.unseenHeapTrends, 0);
    });

    test('status changes notify the status listenable only', () {
      var reportNotifications = 0;
      var statusNotifications = 0;
      final store = ReportStore()..addListener(() => reportNotifications++);
      store.statusListenable.addListener(() => statusNotifications++);
      store
        ..status = const DevToolsLightStatus(watchedObjects: 1)
        ..updateStatus((s) => s.copyWith(watchedObjects: 2))
        ..updateStatus((s) => s); // unchanged: no notification
      expect(statusNotifications, 2);
      expect(reportNotifications, 0);
      expect(store.status.watchedObjects, 2);
    });

    test('clear empties everything', () {
      final store = ReportStore()
        ..addLeak(leak('a', '1'))
        ..addSlowOp(slowOp('b', '2'))
        ..clear();
      expect(store.leaks, isEmpty);
      expect(store.slowOps, isEmpty);
      expect(store.pendingToasts, isEmpty);
      expect(store.unseenLeaks, 0);
    });
  });
}
