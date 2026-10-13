import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:meta/meta.dart';

/// Which automatically disposed objects are watched, decided by the package
/// that declares their class.
///
/// The app's own classes are always watched, and objects handed to
/// `DevToolsLight.watch` or admitted by `LeakDetectionConfig.watchFilter`
/// bypass this policy. Everything else is decided per package: the Flutter
/// SDK with [flutter], every other pub package with [thirdParty] plus the
/// per-package [include] and [exclude] sets. Third-party packages are off by
/// default: their internal `State`s and controllers usually stay reachable
/// only as a consequence of an app leak, which is reported on its own.
///
/// The declaring package of a class is learned from the VM when its first
/// retained instance is analyzed (the retaining path names the class's
/// library); from then on instances of a class that is not watched are
/// skipped before any VM work.
@immutable
class WatchedPackages {
  /// Creates a policy.
  const WatchedPackages({
    this.flutter = true,
    this.thirdParty = false,
    this.include = const {},
    this.exclude = const {},
  });

  /// App and Flutter SDK objects (the default).
  static const WatchedPackages defaults = WatchedPackages();

  /// App objects only.
  static const WatchedPackages appOnly = WatchedPackages(flutter: false);

  /// Objects of every package.
  static const WatchedPackages all = WatchedPackages(thirdParty: true);

  /// Whether classes declared by the Flutter SDK are watched (for example the
  /// `State` of a framework widget).
  final bool flutter;

  /// Whether classes declared by pub packages are watched unless listed in
  /// [exclude].
  final bool thirdParty;

  /// Package names (as in `package:name/`) watched even when [thirdParty] is
  /// false, for example `KnownPackages.bloc`.
  final Set<String> include;

  /// Package names never watched; wins over everything else.
  final Set<String> exclude;

  /// Whether objects of a class declared in a library of [origin] in the
  /// package [packageName] are watched.
  bool allows(CodeOrigin origin, String? packageName) {
    if (packageName != null && exclude.contains(packageName)) {
      return false;
    }
    return switch (origin) {
      CodeOrigin.app || CodeOrigin.dart || CodeOrigin.unknown => true,
      CodeOrigin.flutter => flutter,
      CodeOrigin.library =>
        thirdParty || (packageName != null && include.contains(packageName)),
      CodeOrigin.tooling => false,
    };
  }

  /// Returns a copy with the given fields replaced.
  WatchedPackages copyWith({
    bool? flutter,
    bool? thirdParty,
    Set<String>? include,
    Set<String>? exclude,
  }) {
    return WatchedPackages(
      flutter: flutter ?? this.flutter,
      thirdParty: thirdParty ?? this.thirdParty,
      include: include ?? this.include,
      exclude: exclude ?? this.exclude,
    );
  }
}

/// Package names of popular state-management, routing and hooks packages,
/// for [WatchedPackages.include] and [WatchedPackages.exclude].
///
/// Objects of these packages reach the detector only when Flutter disposes
/// them (`State`s, `ChangeNotifier`s, controllers). A `Bloc`, a Riverpod
/// notifier or a `GetxController` is closed by its own package and has to be
/// handed to `DevToolsLight.watch` from that package's observer hook; the
/// README shows how.
abstract final class KnownPackages {
  /// `package:bloc` and its Flutter bindings.
  static const Set<String> bloc = {
    'bloc',
    'flutter_bloc',
    'hydrated_bloc',
    'replay_bloc',
  };

  /// Riverpod.
  static const Set<String> riverpod = {
    'riverpod',
    'flutter_riverpod',
    'hooks_riverpod',
  };

  /// `package:provider`.
  static const Set<String> provider = {'provider'};

  /// GetX.
  static const Set<String> getx = {'get'};

  /// `package:go_router`.
  static const Set<String> goRouter = {'go_router'};

  /// `package:auto_route`.
  static const Set<String> autoRoute = {'auto_route'};

  /// `package:flutter_hooks`.
  static const Set<String> flutterHooks = {'flutter_hooks'};
}
