import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/leaks/watched_packages.dart';

/// Applies a [WatchedPackages] policy to runtime types, learning the
/// declaring library of each type from the VM as retained objects are
/// analyzed.
class PackageWatchPolicy {
  /// Creates a policy.
  PackageWatchPolicy({
    required this.config,
    required AppCodeClassifier classifier,
  }) : _classifier = classifier;

  /// The configured policy.
  final WatchedPackages config;

  final AppCodeClassifier _classifier;
  final Map<Type, String> _libraryByType = {};

  /// Objects not watched, or dropped before a report, because their package
  /// is not watched.
  int skipped = 0;

  /// Types whose declaring library is known.
  int get knownTypes => _libraryByType.length;

  /// Whether objects of [type] are watched, or null while its declaring
  /// library is unknown.
  bool? allowsType(Type type) {
    final uri = _libraryByType[type];
    return uri == null ? null : allowsLibrary(uri);
  }

  /// Whether objects of a class declared in [libraryUri] are watched.
  ///
  /// Until the app's own package is known every library is allowed, so an
  /// app class is never mistaken for a third-party one.
  bool allowsLibrary(String libraryUri) {
    if (_classifier.appPrefixes.isEmpty) {
      return true;
    }
    return config.allows(
      _classifier.classify(libraryUri),
      AppCodeClassifier.packageNameOf(libraryUri),
    );
  }

  /// Remembers that [type] is declared in [libraryUri].
  void learn(Type type, String libraryUri) => _libraryByType[type] = libraryUri;

  /// `package go_router`, `the Flutter SDK` or `dart:core` for messages.
  String describeLibrary(String libraryUri) {
    final package = AppCodeClassifier.packageNameOf(libraryUri);
    return switch (_classifier.classify(libraryUri)) {
      CodeOrigin.flutter => 'the Flutter SDK',
      CodeOrigin.app => 'the app',
      CodeOrigin.library when package != null => 'package $package',
      CodeOrigin.tooling => 'dev_tools_light',
      _ => libraryUri,
    };
  }
}
