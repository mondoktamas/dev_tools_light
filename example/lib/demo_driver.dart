import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dev_tools_light/dev_tools_light.dart';
import 'package:dev_tools_light_example/jank_pages.dart';
import 'package:dev_tools_light_example/leaky_pages.dart';
import 'package:flutter/material.dart';

/// `--dart-define=DTL_DEMO=true` makes the app drive itself: it opens and pops
/// the leaky pages, forces a leak check, blocks the UI isolate and prints every
/// report to the console.
const bool kDemo = bool.fromEnvironment('DTL_DEMO');

/// `--dart-define=DTL_EXIT=true` quits the app 15 s after the demo is done.
const bool kExit = bool.fromEnvironment('DTL_EXIT');

class DemoDriver {
  DemoDriver(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;

  static void _log(String message) => debugPrint('[demo] $message');

  Future<void> _wait(double seconds) =>
      Future<void>.delayed(Duration(milliseconds: (seconds * 1000).round()));

  Future<void> _visit(Widget page, {double stay = 1}) async {
    final navigator = navigatorKey.currentState!;
    unawaited(
      navigator.push(MaterialPageRoute<void>(builder: (_) => page)),
    );
    await _wait(stay);
    navigator.pop();
    await _wait(0.5);
  }

  /// Burns CPU on the UI isolate for [duration].
  double _burn(Duration duration) {
    final stopwatch = Stopwatch()..start();
    var acc = 0.0;
    while (stopwatch.elapsed < duration) {
      for (var i = 1; i < 2000; i++) {
        acc += math.sqrt(i.toDouble());
      }
    }
    return acc;
  }

  String _status() {
    final s = DevToolsLight.status;
    return 'mode=${s.mode.name} vm=${s.vm.name} (${s.vmDetail}) '
        'uri=${s.vmUri} '
        'leaks=${s.leaks.name} jank=${s.jank.name} '
        'profiler=${s.profilerEnabled} period=${s.samplePeriodMicros} '
        'app=${s.appPackagePrefixes} clockOffset=${s.clockOffsetMicros} '
        'watched=${s.watchedObjects} candidates=${s.retainedCandidates} '
        'checks=${s.leakChecksRun} '
        'suppressed=${s.selfInflictedStallsSuppressed} '
        'heap=${s.heapSnapshots} (${s.heapTrendDetail}) '
        'error=${s.lastError}';
  }

  Future<void> run() async {
    _log('waiting for VM service discovery');
    for (var i = 0; i < 30; i++) {
      await _wait(1);
      final vm = DevToolsLight.status.vm;
      if (vm == VmConnectionState.reachable || vm == VmConnectionState.failed) {
        break;
      }
    }
    _log('status: ${_status()}');

    _log('visiting leaky pages');
    await _visit(const LeakyStreamPage());
    await _visit(const LeakyStaticPage());
    await _visit(const LeakyNotifierPage());
    await _visit(const CleanPage());
    await _wait(1);
    _log('checkLeaksNow');
    final leakCheck = Stopwatch()..start();
    await DevToolsLight.checkLeaksNow();
    _log('leak check took ${leakCheck.elapsedMilliseconds} ms');
    await _wait(1);
    for (final leak in DevToolsLight.reports.leaks) {
      _log('LEAK REPORT\n${leak.toText()}');
    }
    _log('leaks: ${DevToolsLight.reports.leaks.length}');

    _log('filling the unbounded cache');
    await DevToolsLight.snapshotHeapNow(); // baseline
    for (var i = 0; i < 4; i++) {
      await _visit(const LeakyCachePage(), stay: 0.5);
      final taken = await DevToolsLight.snapshotHeapNow();
      _log('heap snapshot ${i + 2} taken: $taken');
    }
    for (final trend in DevToolsLight.reports.heapTrends) {
      await DevToolsLight.fetchHeapTrendTrace(trend.id);
      final updated = DevToolsLight.reports.heapTrendById(trend.id)!;
      _log('HEAP TREND REPORT\n${updated.toText()}');
    }
    _log('heap trends: ${DevToolsLight.reports.heapTrends.length}');

    _log('blocking the UI isolate for 300 ms');
    final result = _burn(const Duration(milliseconds: 300));
    _log('blocked (result $result)');
    await _wait(3);
    _log('opening the slow-build page');
    await _visit(const SlowBuildPage(), stay: 3);
    await _wait(8); // slow devices finish their queued fetches meanwhile
    for (final op in DevToolsLight.reports.slowOps) {
      _log('SLOW OP REPORT\n${op.toText()}');
    }
    _log('slow ops: ${DevToolsLight.reports.slowOps.length}');
    _log('status: ${_status()}');
    _log('done');
    if (kExit) {
      await _wait(15);
      _log('status: ${_status()}');
      _log('exiting');
      exit(0);
    }
  }
}
