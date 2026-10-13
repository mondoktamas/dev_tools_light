import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/engine.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/status.dart';
import 'package:dev_tools_light/src/core/support.dart';
import 'package:dev_tools_light/src/ui/dev_tools_light_overlay.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// LeakCanary-style leak detection and app-code jank attribution for Flutter.
///
/// ```dart
/// Future<void> main() async {
///   await DevToolsLight.start();   // before runApp
///   runApp(MaterialApp(builder: DevToolsLight.builder, home: ...));
/// }
/// ```
abstract final class DevToolsLight {
  /// Whether this build can run anything: false on the web. In release
  /// builds only jank detection runs, and only with
  /// `DevToolsLightConfig.allowInRelease`; see [isVmSupported].
  static bool get isSupported => kDetectionSupported;

  /// Whether leak traces, heap snapshots and CPU-sample attribution are
  /// available: debug and profile builds on VM platforms.
  static bool get isVmSupported => kVmFeaturesSupported;

  /// Whether [start] has been called successfully.
  static bool get isRunning => Engine.instance.isRunning;

  /// Notifies when [isRunning] changes.
  static ValueListenable<bool> get runningListenable =>
      Engine.instance.runningNotifier;

  /// A snapshot of what the engine is doing.
  static DevToolsLightStatus get status => Engine.instance.store.status;

  /// Notifies when [status] changes (about once a second while running).
  static ValueListenable<DevToolsLightStatus> get statusListenable =>
      Engine.instance.store.statusListenable;

  /// All findings; listen to it to react to new reports.
  static ReportStore get reports => Engine.instance.store;

  /// Starts detection. Call it before `runApp` so the Android back button
  /// closes the report panel instead of popping your routes. Returns quickly;
  /// the VM service is discovered in the background.
  static Future<void> start({
    DevToolsLightConfig config = const DevToolsLightConfig(),
  }) => Engine.instance.start(config);

  /// Stops detection and restores the VM flags that were changed.
  static Future<void> stop() => Engine.instance.stop();

  /// Expects [object] to become unreachable soon (LeakCanary's
  /// `expectWeaklyReachable`). Debug builds only, unless
  /// `LeakDetectionConfig.allowInProfile`; a no-op otherwise.
  static void watch(Object object, {String? description}) =>
      Engine.instance.watch(object, description: description);

  /// Runs a leak check immediately (forces a GC), ignoring the usual delays.
  static Future<void> checkLeaksNow() => Engine.instance.checkLeaksNow();

  /// Takes a heap snapshot now (per-class live counts, after a forced GC
  /// unless `HeapTrendConfig.trigger` is `periodic`) and evaluates the
  /// growth trends. Returns false when the VM service is not available or
  /// the monitor is disabled.
  static Future<bool> snapshotHeapNow() => Engine.instance.snapshotHeapNow();

  /// Fetches the retaining path of one live instance of the growing class in
  /// [reportId] (see [ReportStore.heapTrends]); the report is updated in
  /// place.
  static Future<void> fetchHeapTrendTrace(String reportId) =>
      Engine.instance.fetchHeapTrendTrace(reportId);

  /// `MaterialApp(builder: DevToolsLight.builder)`.
  static Widget builder(BuildContext context, Widget? child) =>
      DevToolsLightOverlay(child: child);
}
