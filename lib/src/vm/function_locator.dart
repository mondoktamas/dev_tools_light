import 'package:dev_tools_light/src/vm/script_line_resolver.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// Finds the source line of a function given its script URI and qualified
/// name, by walking `Isolate.libraries → Library.classes → Class.functions`
/// with small cached `getObject` calls (Perfetto profiles carry no lines).
class FunctionLocator {
  /// Creates a locator.
  FunctionLocator({
    ScriptLineResolver? lineResolver,
    this.maxCachedClasses = 200,
  }) : _lines = lineResolver ?? ScriptLineResolver();

  final ScriptLineResolver _lines;

  /// Bound on cached classes.
  final int maxCachedClasses;

  Map<String, vms.LibraryRef>? _librariesByUri;
  final Map<String, Future<vms.Library?>> _libraries = {};
  final Map<String, Future<vms.Class?>> _classes = {};

  /// Number of `getObject` calls made (diagnostics).
  int rpcCalls = 0;

  /// Why the last [lineFor] call returned null (diagnostics).
  String? lastFailure;

  /// The 1-based line of [qualifiedName] declared in [uri], or null.
  Future<int?> lineFor(
    VmApi api,
    String isolateId, {
    required String uri,
    required String qualifiedName,
  }) async {
    lastFailure = null;
    final library = await _library(api, isolateId, uri);
    if (library == null) {
      lastFailure =
          'library $uri not found among ${_librariesByUri?.length} libraries';
      return null;
    }
    final parts = qualifiedName.split('.');
    if (parts.length >= 2) {
      final classRef = _firstWhere(library.classes, (c) => c.name == parts[0]);
      if (classRef != null) {
        final klass = await _class(api, isolateId, classRef);
        final function = _firstWhere(
          klass?.functions,
          (f) => f.name == parts[1],
        );
        if (function != null) {
          final line = await _line(api, isolateId, function);
          if (line == null) {
            lastFailure = 'no location for $qualifiedName';
          }
          return line;
        }
        lastFailure =
            'function ${parts[1]} not in class ${parts[0]} '
            '(${klass?.functions?.map((f) => f.name).take(20).toList()})';
        return null;
      }
    }
    final function = _firstWhere(library.functions, (f) => f.name == parts[0]);
    if (function != null) {
      return _line(api, isolateId, function);
    }
    lastFailure =
        'neither class nor top-level function ${parts[0]} in $uri '
        '(classes: ${library.classes?.map((c) => c.name).take(20).toList()})';
    return null;
  }

  static T? _firstWhere<T>(List<T>? items, bool Function(T) test) {
    if (items == null) {
      return null;
    }
    for (final item in items) {
      if (test(item)) {
        return item;
      }
    }
    return null;
  }

  Future<int?> _line(VmApi api, String isolateId, vms.FuncRef function) {
    final location = function.location;
    final script = location?.script;
    final tokenPos = location?.tokenPos;
    if (location == null) {
      return Future.value();
    }
    if (location.line != null) {
      return Future.value(location.line);
    }
    if (script == null || tokenPos == null) {
      return Future.value();
    }
    rpcCalls++;
    return _lines.lineFor(api, isolateId, script, tokenPos);
  }

  Future<vms.Library?> _library(VmApi api, String isolateId, String uri) async {
    var libraries = _librariesByUri;
    if (libraries == null) {
      rpcCalls++;
      final isolate = await api.getIsolate(isolateId);
      libraries = _librariesByUri = {
        for (final ref in isolate.libraries ?? const <vms.LibraryRef>[])
          if (ref.uri != null) ref.uri!: ref,
      };
    }
    final ref = libraries[uri];
    final id = ref?.id;
    if (ref == null || id == null) {
      return null;
    }
    return _libraries.putIfAbsent(uri, () async {
      rpcCalls++;
      try {
        final object = await api.getObject(isolateId, id);
        return object is vms.Library ? object : null;
      } on Object catch (_) {
        return null;
      }
    });
  }

  Future<vms.Class?> _class(
    VmApi api,
    String isolateId,
    vms.ClassRef ref,
  ) {
    final id = ref.id;
    if (id == null) {
      return Future.value();
    }
    if (_classes.length > maxCachedClasses) {
      _classes.clear();
    }
    return _classes.putIfAbsent(id, () async {
      rpcCalls++;
      try {
        final object = await api.getObject(isolateId, id);
        return object is vms.Class ? object : null;
      } on Object catch (_) {
        return null;
      }
    });
  }
}
