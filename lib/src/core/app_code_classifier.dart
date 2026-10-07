import 'package:dev_tools_light/src/core/code_origin.dart';

/// Decides whether a script URI is app code, framework code, SDK code, a
/// third-party package or tooling.
typedef AppUriPredicate = bool Function(String uri);

/// Classifies library/script URIs into a [CodeOrigin].
class AppCodeClassifier {
  /// Creates a classifier for the given app package prefixes
  /// (for example `{'package:my_app/'}`).
  AppCodeClassifier({
    Set<String> appPrefixes = const {},
    this.toolingPrefixes = const {
      'package:dev_tools_light/',
      'package:vm_service/',
    },
    this.isAppUri,
  }) : _appPrefixes = {...appPrefixes};

  /// Packages that count as "the Flutter framework".
  static const Set<String> flutterPackages = {
    'flutter',
    'flutter_test',
    'flutter_localizations',
    'flutter_driver',
    'flutter_web_plugins',
    'flutter_goldens',
    'integration_test',
    'sky_engine',
  };

  /// URI prefixes of the tooling itself; samples containing these frames are
  /// excluded from attribution.
  final Set<String> toolingPrefixes;

  /// Path fragments that identify the tooling's own sources when only a
  /// resolved `file:` URI is available.
  static const List<String> toolingPathMarkers = [
    '/dev_tools_light/lib/',
    '/dev_tools_light-',
    '/vm_service-',
    '/vm_service_protos-',
  ];

  /// Optional override that decides app code first.
  final AppUriPredicate? isAppUri;

  final Set<String> _appPrefixes;
  final Set<String> _appFileRoots = {};

  /// The `package:` prefixes currently treated as app code.
  Set<String> get appPrefixes => Set.unmodifiable(_appPrefixes);

  /// Adds app package prefixes (for example when auto-detected from the
  /// isolate's root library).
  void addAppPrefixes(Iterable<String> prefixes) =>
      _appPrefixes.addAll(prefixes);

  /// Classifies [uri].
  CodeOrigin classify(String? uri) {
    if (uri == null || uri.isEmpty) {
      return CodeOrigin.unknown;
    }
    if (uri.startsWith('dart:')) {
      return CodeOrigin.dart;
    }
    final override = isAppUri;
    if (override != null && override(uri)) {
      return CodeOrigin.app;
    }
    for (final prefix in toolingPrefixes) {
      if (uri.startsWith(prefix)) {
        return CodeOrigin.tooling;
      }
    }
    for (final prefix in _appPrefixes) {
      if (uri.startsWith(prefix)) {
        return CodeOrigin.app;
      }
    }
    if (uri.startsWith('package:')) {
      final name = packageNameOf(uri);
      if (name != null && flutterPackages.contains(name)) {
        return CodeOrigin.flutter;
      }
      return CodeOrigin.library;
    }
    if (uri.startsWith('file:')) {
      for (final marker in toolingPathMarkers) {
        if (uri.contains(marker)) {
          return CodeOrigin.tooling;
        }
      }
      for (final root in _appFileRoots) {
        if (uri.startsWith(root)) {
          return CodeOrigin.app;
        }
      }
      if (uri.contains('/.pub-cache/') || uri.contains('/pub-cache/')) {
        return CodeOrigin.library;
      }
      if (uri.contains('/flutter/packages/') || uri.contains('/bin/cache/')) {
        return CodeOrigin.flutter;
      }
      return CodeOrigin.app;
    }
    return CodeOrigin.unknown;
  }

  /// Learns the `file:` root of an app package from a function that is known
  /// under both URI forms, so later `file:` URIs can be classified as app code.
  void learnAppFileRoot({
    required String packageUri,
    required String fileUri,
  }) {
    if (!packageUri.startsWith('package:') || !fileUri.startsWith('file:')) {
      return;
    }
    if (classify(packageUri) != CodeOrigin.app) {
      return;
    }
    final slash = packageUri.indexOf('/');
    if (slash < 0) {
      return;
    }
    final relative = '/lib/${packageUri.substring(slash + 1)}';
    if (fileUri.endsWith(relative)) {
      _appFileRoots.add(
        fileUri.substring(0, fileUri.length - relative.length + '/lib/'.length),
      );
    }
  }

  /// The package name of a `package:` URI, or null.
  static String? packageNameOf(String uri) {
    if (!uri.startsWith('package:')) {
      return null;
    }
    final end = uri.indexOf('/');
    if (end < 0) {
      return null;
    }
    return uri.substring('package:'.length, end);
  }

  /// A short, developer-friendly path for [uri]
  /// (`package:my_app/a/b.dart` → `lib/a/b.dart`).
  static String displayPath(String uri) {
    if (uri.startsWith('package:')) {
      final slash = uri.indexOf('/');
      return slash < 0 ? uri : 'lib/${uri.substring(slash + 1)}';
    }
    if (uri.startsWith('file:')) {
      final libIndex = uri.lastIndexOf('/lib/');
      if (libIndex >= 0) {
        return uri.substring(libIndex + 1);
      }
      final testIndex = uri.lastIndexOf('/test/');
      if (testIndex >= 0) {
        return uri.substring(testIndex + 1);
      }
      return uri.split('/').last;
    }
    return uri;
  }
}
