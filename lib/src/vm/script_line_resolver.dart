import 'dart:collection';

import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// Resolves token positions to line numbers, caching `Script` objects.
class ScriptLineResolver {
  /// Creates a resolver keeping at most [maxCachedScripts] scripts.
  ScriptLineResolver({this.maxCachedScripts = 50});

  /// Cache bound.
  final int maxCachedScripts;

  final LinkedHashMap<String, vms.Script> _cache = LinkedHashMap();

  /// The 1-based line of [tokenPos] in [script], or null.
  Future<int?> lineFor(
    VmApi api,
    String isolateId,
    vms.ScriptRef script,
    int tokenPos,
  ) async {
    final id = script.id;
    if (id == null) {
      return null;
    }
    var full = _cache[id];
    if (full == null) {
      final vms.Obj object;
      try {
        object = await api.getObject(isolateId, id);
      } on Object catch (_) {
        return null;
      }
      if (object is! vms.Script) {
        return null;
      }
      full = object;
      _cache[id] = full;
      if (_cache.length > maxCachedScripts) {
        _cache.remove(_cache.keys.first);
      }
    }
    return full.getLineNumberFromTokenPos(tokenPos);
  }
}
