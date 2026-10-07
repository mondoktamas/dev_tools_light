import 'package:dev_tools_light/src/core/clock.dart';
import 'package:dev_tools_light/src/vm/gc_controller.dart';
import 'package:dev_tools_light/src/vm/runtime_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('allocation pressure scavenges new space without a major GC', () {
    final bridge = createRuntimeBridge();
    final gc = GcController(
      barrier: () => bridge.reachabilityBarrier,
      now: timelineNowMicros,
    );
    final before = bridge.reachabilityBarrier;
    final stopwatch = Stopwatch()..start();
    final collected = gc.scavenge();
    debugPrint(
      'scavenge in ${stopwatch.elapsedMicroseconds} µs; barrier '
      '$before → ${bridge.reachabilityBarrier}',
    );
    expect(collected, isTrue);
    expect(gc.scavenges, 1);
    expect(
      bridge.reachabilityBarrier,
      before,
      reason: 'a scavenge is not a major collection',
    );
  });
}
