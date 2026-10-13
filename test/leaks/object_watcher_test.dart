import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/leaks/object_watcher.dart';
import 'package:dev_tools_light/src/leaks/watched_kind.dart';
import 'package:flutter_test/flutter_test.dart';

class Holder {
  Holder(this.name);

  final String name;
}

void main() {
  group('ObjectWatcher', () {
    late int now;
    late int barrier;
    late List<List<WatchedObject>> batches;
    late Set<int> Function(List<WatchedObject>) resolver;

    ObjectWatcher watcher([LeakDetectionConfig? config]) {
      return ObjectWatcher(
        config: config ?? const LeakDetectionConfig(),
        now: () => now,
        barrier: () => barrier,
        onRetained: (candidates, {forced = false}) async {
          batches.add(candidates);
          return resolver(candidates);
        },
      );
    }

    setUp(() {
      now = 0;
      barrier = 10;
      batches = [];
      resolver = (candidates) => {for (final c in candidates) c.id};
    });

    test(
      'promotes a still-reachable object after the retained delay',
      () async {
        final w = watcher();
        final holder = Holder('a');
        w.watch(holder, kind: WatchedKind.manual, description: 'test');
        expect(w.watchedCount, 1);

        await w.tick();
        expect(w.candidateCount, 0, reason: 'before the retained delay');

        now += const Duration(seconds: 6).inMicroseconds;
        barrier = 12;
        await w.tick();
        expect(w.candidateCount, 1);
        expect(batches, isEmpty, reason: 'batch window not elapsed');

        now += const Duration(seconds: 2).inMicroseconds;
        await w.tick();
        expect(batches, hasLength(1));
        final candidate = batches.single.single;
        expect(candidate.typeName, 'Holder');
        expect(candidate.kind, WatchedKind.manual);
        expect(candidate.description, 'test');
        expect(candidate.barrierAtWatch, 10);
        expect(candidate.barrierAtCandidate, 12);
        expect(candidate.target, same(holder));
        expect(w.watchedCount, 0, reason: 'resolved candidates are removed');
        expect(w.checksRun, 1);
      },
    );

    test('watching the same object twice is a no-op', () {
      final w = watcher();
      final holder = Holder('a');
      w
        ..watch(holder, kind: WatchedKind.manual)
        ..watch(holder, kind: WatchedKind.state);
      expect(w.watchedCount, 1);
    });

    test('rejects objects that cannot be Expando keys', () {
      final w = watcher()
        ..watch(42, kind: WatchedKind.manual)
        ..watch('s', kind: WatchedKind.manual)
        ..watch(true, kind: WatchedKind.manual);
      expect(w.watchedCount, 0);
    });

    test('evicts the oldest watched object beyond the capacity', () {
      final w = watcher(const LeakDetectionConfig(maxWatchedObjects: 2));
      final a = Holder('a');
      final b = Holder('b');
      final c = Holder('c');
      w
        ..watch(a, kind: WatchedKind.manual)
        ..watch(b, kind: WatchedKind.manual)
        ..watch(c, kind: WatchedKind.manual);
      expect(w.watchedCount, 2);
      expect(w.droppedCount, 1);
    });

    test('respects the minimum interval and the per-minute limit', () async {
      final w = watcher(
        const LeakDetectionConfig(
          retainedDelay: Duration.zero,
          batchWindow: Duration.zero,
          maxAnalysesPerMinute: 2,
        ),
      );
      final holders = List.generate(4, (i) => Holder('$i'));
      w.watch(holders[0], kind: WatchedKind.manual);
      await w.tick();
      expect(batches, hasLength(1));

      w.watch(holders[1], kind: WatchedKind.manual);
      await w.tick();
      expect(batches, hasLength(1), reason: 'min interval not elapsed');

      now += const Duration(seconds: 11).inMicroseconds;
      await w.tick();
      expect(batches, hasLength(2));

      w.watch(holders[2], kind: WatchedKind.manual);
      now += const Duration(seconds: 11).inMicroseconds;
      await w.tick();
      expect(batches, hasLength(2), reason: 'per-minute limit reached');

      now += const Duration(seconds: 60).inMicroseconds;
      await w.tick();
      expect(batches, hasLength(3));
    });

    test('checkNow ignores delays and limits', () async {
      final w = watcher();
      final holder = Holder('a');
      w.watch(holder, kind: WatchedKind.manual);
      await w.checkNow();
      expect(batches, hasLength(1));
      expect(w.watchedCount, 0);
    });

    test('unresolved candidates stay for the next check', () async {
      resolver = (_) => {};
      final w = watcher(
        const LeakDetectionConfig(
          retainedDelay: Duration.zero,
          batchWindow: Duration.zero,
          minIntervalBetweenChecks: Duration.zero,
        ),
      );
      final holder = Holder('a');
      w.watch(holder, kind: WatchedKind.manual);
      await w.tick();
      expect(w.watchedCount, 1);
      expect(w.candidateCount, 1);
      await w.tick();
      expect(batches, hasLength(2));
    });

    test('a failing handler does not lose candidates', () async {
      final w = ObjectWatcher(
        config: const LeakDetectionConfig(
          retainedDelay: Duration.zero,
          batchWindow: Duration.zero,
          minIntervalBetweenChecks: Duration.zero,
        ),
        now: () => now,
        barrier: () => barrier,
        onRetained: (_, {forced = false}) async => throw StateError('boom'),
      );
      final holder = Holder('a');
      w.watch(holder, kind: WatchedKind.manual);
      await w.tick();
      expect(w.candidateCount, 1);
      expect(w.isChecking, isFalse);
    });
  });
}
