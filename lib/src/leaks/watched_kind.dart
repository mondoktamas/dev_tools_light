import 'package:flutter/animation.dart' show AnimationController;
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart' show OverlayEntry, Route, State;

/// The kinds of objects the leak detector watches after they are disposed.
enum WatchedKind {
  /// A `State` after `dispose()` (the Flutter equivalent of a destroyed
  /// Activity/Fragment).
  state,

  /// A `ChangeNotifier` (controllers, `ValueNotifier`s, view models) after
  /// `dispose()`.
  changeNotifier,

  /// An `AnimationController` after `dispose()`.
  animationController,

  /// A `Route` after it was disposed by the navigator.
  route,

  /// An `OverlayEntry` after `dispose()`.
  overlayEntry,

  /// A `Ticker` after `dispose()` (opt-in).
  ticker,

  /// An object admitted by `LeakDetectionConfig.watchFilter`.
  custom,

  /// An object passed to `DevToolsLight.watch`.
  manual;

  /// Whether the object was watched because of a framework lifecycle event,
  /// as opposed to `DevToolsLight.watch` or `watchFilter`.
  bool get isAutomatic =>
      this != WatchedKind.custom && this != WatchedKind.manual;

  /// Human-readable label.
  String get label => switch (this) {
    WatchedKind.state => 'State',
    WatchedKind.changeNotifier => 'ChangeNotifier',
    WatchedKind.animationController => 'AnimationController',
    WatchedKind.route => 'Route',
    WatchedKind.overlayEntry => 'OverlayEntry',
    WatchedKind.ticker => 'Ticker',
    WatchedKind.custom => 'custom',
    WatchedKind.manual => 'manual',
  };
}

/// The [WatchedKind] of a disposed [object], or null if it is not a kind the
/// detector knows about.
WatchedKind? watchedKindOf(Object object) {
  if (object is State) {
    return WatchedKind.state;
  }
  if (object is Route) {
    return WatchedKind.route;
  }
  if (object is OverlayEntry) {
    return WatchedKind.overlayEntry;
  }
  if (object is AnimationController) {
    return WatchedKind.animationController;
  }
  if (object is Ticker) {
    return WatchedKind.ticker;
  }
  if (object is ChangeNotifier) {
    return WatchedKind.changeNotifier;
  }
  return null;
}

/// The runtime type name of [object] with generic arguments stripped.
String typeNameOf(Object object) {
  final name = object.runtimeType.toString();
  final generic = name.indexOf('<');
  return generic < 0 ? name : name.substring(0, generic);
}
