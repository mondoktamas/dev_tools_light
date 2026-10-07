import 'package:meta/meta.dart';

/// What we know about the main isolate.
@immutable
class IsolateInfo {
  /// Creates isolate info.
  const IsolateInfo({required this.isolateId, this.rootLibraryUri});

  /// The VM-service isolate id.
  final String isolateId;

  /// The URI of the isolate's root library (`package:my_app/main.dart`).
  final String? rootLibraryUri;

  /// `package:my_app/`, derived from [rootLibraryUri], or null.
  String? get appPackagePrefix {
    final uri = rootLibraryUri;
    if (uri == null || !uri.startsWith('package:')) {
      return null;
    }
    final slash = uri.indexOf('/');
    return slash < 0 ? null : uri.substring(0, slash + 1);
  }
}
