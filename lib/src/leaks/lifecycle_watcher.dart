import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/internal_marker.dart';
import 'package:dev_tools_light/src/leaks/object_watcher.dart';
import 'package:dev_tools_light/src/leaks/package_watch_policy.dart';
import 'package:dev_tools_light/src/leaks/watched_kind.dart';
import 'package:flutter/foundation.dart';

/// LeakCanary's `AppWatcher`: listens to Flutter's `FlutterMemoryAllocations`
/// and hands every disposed lifecycle object of a watched kind to the
/// [ObjectWatcher].
///
/// The framework only dispatches these events inside `assert`s, so this works
/// in debug builds only.
class LifecycleWatcher {
  /// Creates a lifecycle watcher.
  LifecycleWatcher({
    required LeakDetectionConfig config,
    required ObjectWatcher watcher,
    PackageWatchPolicy? policy,
  }) : _config = config,
       _watcher = watcher,
       _policy = policy;

  final LeakDetectionConfig _config;
  final ObjectWatcher _watcher;
  final PackageWatchPolicy? _policy;
  bool _active = false;

  /// Whether framework lifecycle events are available in this build.
  static bool get isSupported => kDebugMode && kFlutterMemoryAllocationsEnabled;

  /// Whether the listener is registered.
  bool get isActive => _active;

  /// Registers the listener (no-op when unsupported).
  void start() {
    if (!isSupported || _active) {
      return;
    }
    FlutterMemoryAllocations.instance.addListener(_onEvent);
    _active = true;
  }

  /// Unregisters the listener.
  void stop() {
    if (!_active) {
      return;
    }
    FlutterMemoryAllocations.instance.removeListener(_onEvent);
    _active = false;
  }

  void _onEvent(ObjectEvent event) {
    if (event is ObjectDisposed) {
      handleDisposed(event.object);
    }
  }

  /// Decides whether the disposed [object] is watched.
  @visibleForTesting
  void handleDisposed(Object object) {
    if (object is DevToolsLightInternal) {
      return;
    }
    var kind = watchedKindOf(object);
    if (kind != null && !_config.watchedKinds.contains(kind)) {
      kind = null;
    }
    if (kind == null) {
      final filter = _config.watchFilter;
      if (filter == null || !filter(object)) {
        return;
      }
      kind = WatchedKind.custom;
    }
    if (_config.ignoredTypeNames.isNotEmpty &&
        _config.ignoredTypeNames.contains(typeNameOf(object))) {
      return;
    }
    final policy = _policy;
    if (policy != null &&
        kind.isAutomatic &&
        policy.allowsType(object.runtimeType) == false) {
      policy.skipped++;
      return;
    }
    _watcher.watch(object, kind: kind);
  }
}
