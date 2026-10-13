/// Where a library URI comes from, as the developer would think about it.
enum CodeOrigin {
  /// The application's own package(s).
  app,

  /// The Flutter framework and its sibling SDK packages.
  flutter,

  /// The Dart SDK (`dart:` libraries).
  dart,

  /// A third-party pub package.
  library,

  /// `dev_tools_light` itself and `package:vm_service` (never reported).
  tooling,

  /// Native frames or URIs that could not be resolved.
  unknown;

  /// Short upper-case label used in reports and the overlay.
  String get label => switch (this) {
    CodeOrigin.app => 'APP',
    CodeOrigin.flutter => 'FLUTTER',
    CodeOrigin.dart => 'DART',
    CodeOrigin.library => 'LIB',
    CodeOrigin.tooling => 'TOOL',
    CodeOrigin.unknown => '?',
  };
}
