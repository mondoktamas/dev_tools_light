@Tags(['vm'])
library;

import 'dart:math' as math;

import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/clock.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/jank/cpu_sample_attributor.dart';
import 'package:dev_tools_light/src/leaks/leak_trace.dart';
import 'package:dev_tools_light/src/leaks/leak_trace_builder.dart';
import 'package:dev_tools_light/src/vm/cpu_samples_client.dart';
import 'package:dev_tools_light/src/vm/gc_controller.dart';
import 'package:dev_tools_light/src/vm/object_inspector.dart';
import 'package:dev_tools_light/src/vm/retaining_path_client.dart';
import 'package:dev_tools_light/src/vm/runtime_bridge.dart';
import 'package:dev_tools_light/src/vm/script_line_resolver.dart';
import 'package:dev_tools_light/src/vm/strong_path_finder.dart';
import 'package:dev_tools_light/src/vm/vm_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' as vms;

import '../helpers/fixtures.dart';

/// These tests talk to the real VM service of the test process. Run them
/// with `--enable-vmservice` (see dart_test.yaml); they are skipped otherwise.
class Holder {
  Holder(this.label);

  final String label;
}

final List<Object> retainedByStatic = <Object>[];
void Function()? retainedByClosure;

// The strong holder is declared before the Expando on purpose: a plain Dart
// VM explores the roots it visited last first and then reports the Expando's
// weak property although the list holds the object. The Flutter tester's VM
// reported the list instead, so the test covers both orders.
final List<Object> retainedStrongly = <Object>[];
final Expando<int> retainedWeakly = Expando<int>('real_vm_test');

/// Retains a fresh object both ways without leaving it in a local variable
/// of a suspended frame.
@pragma('vm:never-inline')
void retainBothWays() {
  final holder = Holder('both');
  retainedStrongly.add(holder);
  retainedWeakly[holder] = 1;
}

/// Class names along [path], target first.
String describePath(vms.RetainingPath path) =>
    '${path.gcRootType}: ${path.elements!.map((e) {
      final value = e.value;
      return value is vms.InstanceRef ? value.classRef?.name : value?.type;
    }).join(' <- ')}';

void main() {
  final bridge = createRuntimeBridge();
  late VmSession session;
  late bool available;

  setUpAll(() async {
    session = VmSession(
      bridge: bridge,
      now: timelineNowMicros,
      discoveryGrace: const Duration(seconds: 1),
      pollInterval: const Duration(milliseconds: 100),
    );
    available = await session.discover() != null;
    if (!available) {
      debugPrint('VM service not available; run with --enable-vmservice');
    }
  });

  final classifier = AppCodeClassifier(
    isAppUri: (uri) => uri.contains('real_vm_test.dart'),
  );

  test('discovers the VM service and reads the root library', () async {
    if (!available) {
      return;
    }
    final isolateId = bridge.currentIsolateId;
    expect(isolateId, isNotNull);
    final isolate = await session.run((api) => api.getIsolate(isolateId!));
    debugPrint(
      'rootLib: ${isolate.rootLib?.uri}, uri: ${session.webSocketUri}',
    );
    expect(isolate.rootLib?.uri, isNotNull);
  });

  test('a forced GC advances reachabilityBarrier', () async {
    if (!available) {
      return;
    }
    final isolateId = bridge.currentIsolateId!;
    final before = bridge.reachabilityBarrier;
    final gc = GcController(
      barrier: () => bridge.reachabilityBarrier,
      now: timelineNowMicros,
    );
    final stopwatch = Stopwatch()..start();
    final ok = await session.run(
      (api) => gc.collectUntilBarrier(
        before + 1,
        timeout: const Duration(seconds: 5),
        vmGc: () => api.getAllocationProfile(isolateId, gc: true),
      ),
    );
    debugPrint(
      'barrier $before → ${bridge.reachabilityBarrier} in '
      '${stopwatch.elapsedMilliseconds} ms '
      '(vm requests: ${gc.vmGcRequests}, allocation rounds: '
      '${gc.allocationRounds})',
    );
    expect(ok, isTrue);
  });

  test('retaining path of a statically held object', () async {
    if (!available) {
      return;
    }
    // Only the static list holds it: a local would also be reachable from
    // this test's suspended frame while the RPC is in flight.
    retainedByStatic.add(Holder('static'));
    final isolateId = bridge.currentIsolateId!;
    final objectId = bridge.objectIdOf(retainedByStatic.last)!;
    final result = await session.run(
      (api) => const RetainingPathClient().fetch(
        api,
        isolateId: isolateId,
        objectId: objectId,
        limit: 100,
      ),
    );
    expect(
      result.path,
      isNotNull,
      reason: '${result.failure} ${result.message}',
    );
    debugPrint('raw path: ${result.path!.toJson()}');
    final trace = await session.run(
      (api) =>
          LeakTraceBuilder(
            classifier: classifier,
            lineResolver: ScriptLineResolver(),
          ).build(
            result.path!,
            leakedTypeName: 'Holder',
            api: api,
            isolateId: isolateId,
            inspector: ObjectInspector(maxInspections: 10),
          ),
    );
    debugPrint(trace.toText());
    expect(trace.leakedObject.className, 'Holder');
    expect(
      trace.nodes.any(
        (n) =>
            n.referenceKind == ReferenceKind.staticField &&
            n.referenceName == 'retainedByStatic',
      ),
      isTrue,
    );
    retainedByStatic.clear();
  });

  test('retaining path through a closure shows the closure', () async {
    if (!available) {
      return;
    }
    final holder = Holder('closure');
    retainedByClosure = () => debugPrint(holder.label);
    final isolateId = bridge.currentIsolateId!;
    final objectId = bridge.objectIdOf(holder)!;
    final result = await session.run(
      (api) => const RetainingPathClient().fetch(
        api,
        isolateId: isolateId,
        objectId: objectId,
        limit: 100,
      ),
    );
    expect(
      result.path,
      isNotNull,
      reason: '${result.failure} ${result.message}',
    );
    debugPrint('raw path: ${result.path!.toJson()}');
    final trace = await session.run(
      (api) =>
          LeakTraceBuilder(
            classifier: classifier,
            lineResolver: ScriptLineResolver(),
          ).build(
            result.path!,
            leakedTypeName: 'Holder',
            api: api,
            isolateId: isolateId,
          ),
    );
    debugPrint(trace.toText());
    expect(
      trace.nodes.any((n) => n.referenceKind == ReferenceKind.closureCapture),
      isTrue,
    );
    retainedByClosure = null;
  });

  test('finds a strong path with inbound references', () async {
    if (!available) {
      return;
    }
    retainBothWays();
    final isolateId = bridge.currentIsolateId!;
    final objectId = bridge.objectIdOf(retainedStrongly.last)!;
    final (vmPath, searched, strong) = await session.run((api) async {
      final result = await const RetainingPathClient().fetch(
        api,
        isolateId: isolateId,
        objectId: objectId,
        limit: 100,
      );
      final vmPath = result.path;
      expect(vmPath, isNotNull, reason: '${result.failure}');
      var searched = vmPath!;
      if (StrongPathFinder.firstWeakLink(searched) < 0) {
        // This VM explored the list before the Expando: start the search
        // from the path it reports when the Expando comes first.
        searched = vms.RetainingPath(
          length: 2,
          gcRootType: vmPath.gcRootType,
          elements: [
            vmPath.elements!.first,
            vms.RetainingObject(
              value: vms.InstanceRef.parse(
                instanceRef('_WeakProperty', 'dart:core', id: 'objects/weak'),
              ),
            ),
          ],
        );
      }
      final strong = await const StrongPathFinder().find(
        api,
        isolateId: isolateId,
        path: searched,
        limit: 100,
      );
      return (vmPath, searched, strong);
    });
    debugPrint('VM path: ${describePath(vmPath)}');
    debugPrint('searched from: ${describePath(searched)}');
    expect(StrongPathFinder.firstWeakLink(searched), 1);
    expect(strong.path, isNotNull, reason: strong.detail);
    debugPrint(
      'strong path after ${strong.lookups} lookups: '
      '${describePath(strong.path!)}',
    );
    expect(StrongPathFinder.firstWeakLink(strong.path!), -1);
    expect(strong.lookups, greaterThanOrEqualTo(2));
    expect(
      strong.path!.elements!.any(
        (e) =>
            e.value is vms.FieldRef &&
            (e.value! as vms.FieldRef).name == 'retainedStrongly',
      ),
      isTrue,
    );
    retainedStrongly.clear();
  });

  test('a collected object yields the Collected sentinel', () async {
    if (!available) {
      return;
    }
    final isolateId = bridge.currentIsolateId!;
    String makeId() => bridge.objectIdOf(Holder('gone'))!;
    final objectId = makeId();
    final gc = GcController(
      barrier: () => bridge.reachabilityBarrier,
      now: timelineNowMicros,
    );
    final result = await session.run((api) async {
      await gc.collectUntilBarrier(
        bridge.reachabilityBarrier + 1,
        timeout: const Duration(seconds: 5),
        vmGc: () => api.getAllocationProfile(isolateId, gc: true),
      );
      return const RetainingPathClient().fetch(
        api,
        isolateId: isolateId,
        objectId: objectId,
        limit: 100,
      );
    });
    debugPrint('collected object → ${result.failure} ${result.message}');
    expect(result.path, isNull);
  });

  test('CPU samples of a busy loop attribute to this test', () async {
    if (!available) {
      return;
    }
    final isolateId = bridge.currentIsolateId!;
    final setup = await session.run(
      (api) => const CpuSamplesClient().ensureProfiler(
        api,
        desiredSamplePeriodMicros: 500,
      ),
    );
    debugPrint(
      'profiler=${setup.profilerEnabled} period=${setup.samplePeriodMicros} '
      '(was ${setup.originalSamplePeriodMicros})',
    );
    final start = timelineNowMicros();
    final burned = burn(const Duration(milliseconds: 300));
    final end = timelineNowMicros();
    expect(burned, greaterThan(0));
    final attribution = await session.run((api) async {
      final samples = await const CpuSamplesClient().fetch(
        api,
        isolateId: isolateId,
        startMicros: start - 1000,
        endMicros: end + 1000,
      );
      debugPrint(
        'samples=${samples.sampleCount} period=${samples.samplePeriod} '
        'maxStackDepth=${samples.maxStackDepth}',
      );
      final functions = samples.functions ?? [];
      for (final f in functions.take(15)) {
        debugPrint('  fn ${f.toJson()}');
      }
      final tags = <String, int>{};
      for (final s in samples.samples ?? const <vms.CpuSample>[]) {
        tags[s.vmTag ?? '?'] = (tags[s.vmTag ?? '?'] ?? 0) + 1;
      }
      debugPrint('  vmTags: $tags');
      final attributor = CpuSampleAttributor(
        classifier: classifier,
        config: const JankDetectionConfig(),
      );
      final draft = attributor.attribute(samples);
      await attributor.resolveLines(
        draft,
        api: api,
        isolateId: isolateId,
        resolver: ScriptLineResolver(),
      );
      return attributor.finish(draft);
    });
    for (final f in attribution.hotAppFunctions) {
      debugPrint(
        '  hot ${f.name} ${f.location} responsible=${f.responsibleTicks} '
        'self=${f.selfTicks} inclusive=${f.inclusiveTicks}',
      );
    }
    debugPrint('  origins: ${attribution.selfTicksByOrigin}');
    expect(attribution.usedSamples, greaterThan(10));
    expect(attribution.hasAppCode, isTrue);
    expect(attribution.hotAppFunctions.first.name, contains('burn'));
    await session.run((api) => const CpuSamplesClient().restore(api, setup));
  });
}

/// Burns CPU for [duration].
double burn(Duration duration) {
  final stopwatch = Stopwatch()..start();
  var acc = 0.0;
  while (stopwatch.elapsed < duration) {
    for (var i = 1; i < 2000; i++) {
      acc += math.sqrt(i.toDouble());
    }
  }
  return acc;
}
