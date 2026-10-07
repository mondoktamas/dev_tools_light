import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// Derives the app's `package:` prefix when the isolate's root library is a
/// `file:` URI, which is what test runners (`flutter test`,
/// `integration_test`) give the main isolate: the package name cannot be read
/// off the root library then, but the test file lives inside the package,
/// and one of the loaded `package:` libraries resolves to `<package>/lib/`.
/// `flutter test` starts the isolate on a generated listener in a temporary
/// directory that imports the test file, so the root library's imports are
/// tried as well.
class AppPackageDetector {
  /// Creates a detector.
  const AppPackageDetector();

  /// Directories that sit directly under a package root.
  static const Set<String> sourceDirectories = {
    'lib',
    'test',
    'integration_test',
    'test_driver',
    'bin',
  };

  /// The package directory of a `file:` root library, e.g.
  /// `/path/to/app` for `file:///path/to/app/integration_test/x_test.dart`;
  /// null for other schemes or unrecognised layouts.
  static String? packageDirectoryOf(String rootLibraryUri) {
    final uri = Uri.tryParse(rootLibraryUri);
    if (uri == null || uri.scheme != 'file') {
      return null;
    }
    final segments = uri.pathSegments;
    // The innermost source directory above the file wins, so that
    // `pkg/example/lib/main.dart` yields `pkg/example`.
    for (var i = segments.length - 2; i > 0; i--) {
      if (sourceDirectories.contains(segments[i])) {
        return '/${segments.sublist(0, i).join('/')}';
      }
    }
    return null;
  }

  /// Returns the `package:name/` prefix of the package that contains the
  /// isolate's root library, or null. [learn] receives the package URI and
  /// resolved file URI of the library that identified it, so the caller can
  /// map `file:` paths of that package to app code.
  Future<String?> detect(
    VmApi api, {
    required String isolateId,
    required vms.Isolate isolate,
    void Function(String packageUri, String fileUri)? learn,
  }) async {
    final directories = await _candidateDirectories(api, isolateId, isolate);
    if (directories.isEmpty) {
      return null;
    }
    // One representative library per package.
    final representatives = <String, String>{};
    for (final library in isolate.libraries ?? const <vms.LibraryRef>[]) {
      final uri = library.uri;
      if (uri == null || !uri.startsWith('package:')) {
        continue;
      }
      final slash = uri.indexOf('/');
      if (slash < 0) {
        continue;
      }
      representatives.putIfAbsent(uri.substring(0, slash + 1), () => uri);
    }
    if (representatives.isEmpty) {
      return null;
    }
    final prefixes = representatives.keys.toList();
    final uris = representatives.values.toList();
    final resolved =
        (await api.lookupResolvedPackageUris(isolateId, uris)).uris ??
        const <String?>[];
    for (var i = 0; i < uris.length && i < resolved.length; i++) {
      final file = resolved[i];
      if (file == null) {
        continue;
      }
      final path = Uri.tryParse(file)?.path ?? file;
      for (final directory in directories) {
        if (path.startsWith('$directory/lib/')) {
          learn?.call(uris[i], file);
          return prefixes[i];
        }
      }
    }
    return null;
  }

  /// The package directories suggested by the root library itself or, for a
  /// generated listener, by the files it imports.
  Future<List<String>> _candidateDirectories(
    VmApi api,
    String isolateId,
    vms.Isolate isolate,
  ) async {
    final root = isolate.rootLib;
    final direct = packageDirectoryOf(root?.uri ?? '');
    if (direct != null) {
      return [direct];
    }
    final id = root?.id;
    if (id == null) {
      return const [];
    }
    try {
      final library = await api.getObject(isolateId, id);
      if (library is! vms.Library) {
        return const [];
      }
      final found = <String>{};
      for (final dependency
          in library.dependencies ?? const <vms.LibraryDependency>[]) {
        final directory = packageDirectoryOf(dependency.target?.uri ?? '');
        if (directory != null) {
          found.add(directory);
        }
      }
      return found.toList();
    } on Object {
      return const [];
    }
  }
}
