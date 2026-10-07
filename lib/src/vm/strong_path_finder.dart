import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// Outcome of [StrongPathFinder.find].
class StrongPathResult {
  const StrongPathResult._({
    required this.lookups,
    required this.weakHolder,
    this.path,
    this.detail,
  });

  /// A path made of strong references only, or null when none was found.
  final vms.RetainingPath? path;

  /// RPCs spent on the search.
  final int lookups;

  /// The class of the weak holder in the VM's path (`_WeakProperty`, ...).
  final String weakHolder;

  /// Why [path] is null.
  final String? detail;
}

/// Finds a retaining path made of strong references only.
///
/// The VM's `getRetainingPath` reports the first path its depth-first
/// search finds, and that search follows an `Expando`'s `_WeakProperty` key
/// (verified on Dart 3.12). Such a path does not explain why the object is
/// alive. Starting from the last strongly held object on the VM's path, this
/// finder asks for its inbound references, skips the weak holders and fetches
/// the retaining path of a strong one, repeating until a path without weak
/// links is assembled or the RPC budget is spent.
class StrongPathFinder {
  /// Creates a finder spending at most [maxLookups] RPCs per search and
  /// looking at [inboundLimit] inbound references per object.
  const StrongPathFinder({this.maxLookups = 16, this.inboundLimit = 64});

  /// RPC budget per search.
  final int maxLookups;

  /// Inbound references fetched per object.
  final int inboundLimit;

  /// Classes whose outgoing references the GC treats as weak.
  static const Set<String> weakHolderClasses = {
    '_WeakProperty',
    'WeakProperty',
    '_WeakReference',
    'WeakReference',
    '_WeakReferenceImpl',
    '_WeakArray',
    'WeakArray',
    'FinalizerEntry',
    '_FinalizerEntry',
  };

  /// Whether [value] holds its referents weakly.
  static bool isWeakHolder(vms.ObjRef? value) =>
      value is vms.InstanceRef &&
      weakHolderClasses.contains(value.classRef?.name);

  /// Index of the first element of [path] (which runs from the target to the
  /// root) that holds the element before it weakly, or -1.
  static int firstWeakLink(vms.RetainingPath path) {
    final elements = path.elements ?? const <vms.RetainingObject>[];
    for (var i = 1; i < elements.length; i++) {
      if (isWeakHolder(elements[i].value)) {
        return i;
      }
    }
    return -1;
  }

  /// Searches a strong path for the target of [path]; [limit] bounds the
  /// length of the paths requested from the VM.
  Future<StrongPathResult> find(
    VmApi api, {
    required String isolateId,
    required vms.RetainingPath path,
    required int limit,
  }) async {
    final elements = path.elements ?? const <vms.RetainingObject>[];
    final weakAt = firstWeakLink(path);
    if (weakAt <= 0) {
      return const StrongPathResult._(
        lookups: 0,
        weakHolder: '',
        detail: 'the path has no weak link',
      );
    }
    final holder = _className(elements[weakAt].value);
    final budget = _Budget(maxLookups);
    final visited = <String>{
      for (final element in elements) ?element.value?.id,
    };
    final found = await _extend(
      api,
      isolateId,
      elements.sublist(0, weakAt),
      budget,
      visited,
      limit,
    );
    return StrongPathResult._(
      path: found,
      lookups: budget.used,
      weakHolder: holder,
      detail: found != null
          ? null
          : budget.exhausted
          ? 'lookup budget of $maxLookups RPCs spent'
          : 'no strong retainer found',
    );
  }

  /// Extends [prefix] (target first, last element strongly held so far) by
  /// a strong retainer of its last element, recursively.
  Future<vms.RetainingPath?> _extend(
    VmApi api,
    String isolateId,
    List<vms.RetainingObject> prefix,
    _Budget budget,
    Set<String> visited,
    int limit,
  ) async {
    final id = prefix.last.value?.id;
    if (id == null || !budget.take()) {
      return null;
    }
    final vms.InboundReferences inbound;
    try {
      inbound = await api.getInboundReferences(isolateId, id, inboundLimit);
    } on Object catch (_) {
      return null;
    }
    final references = (inbound.references ?? const <vms.InboundReference>[])
        .where((reference) {
          final source = reference.source;
          return source != null &&
              source.id != null &&
              !isWeakHolder(source) &&
              !visited.contains(source.id);
        })
        .toList();
    for (final reference in references) {
      final source = reference.source!;
      visited.add(source.id!);
      if (!budget.take()) {
        return null;
      }
      final vms.RetainingPath sourcePath;
      try {
        sourcePath = await api.getRetainingPath(isolateId, source.id!, limit);
      } on Object catch (_) {
        continue;
      }
      final sourceElements =
          sourcePath.elements ?? const <vms.RetainingObject>[];
      if (sourceElements.length <= 1) {
        // Garbage pinned by the VM's object-id ring, or held by a stack
        // frame only: not a retainer worth reporting.
        continue;
      }
      final weakAtSource = firstWeakLink(sourcePath);
      final parentField = reference.parentField;
      final head = vms.RetainingObject(
        value: sourceElements.first.value,
        parentField: parentField is vms.FieldRef
            ? parentField.name
            : parentField,
        parentListIndex: reference.parentListIndex,
      );
      final spliced = [
        ...prefix,
        head,
        ...sourceElements.sublist(
          1,
          weakAtSource < 0 ? sourceElements.length : weakAtSource,
        ),
      ];
      if (weakAtSource < 0) {
        return vms.RetainingPath(
          length: spliced.length,
          gcRootType: sourcePath.gcRootType,
          elements: spliced,
        );
      }
      final deeper = await _extend(
        api,
        isolateId,
        spliced,
        budget,
        visited,
        limit,
      );
      if (deeper != null) {
        return deeper;
      }
    }
    return null;
  }

  static String _className(vms.ObjRef? value) =>
      value is vms.InstanceRef ? value.classRef?.name ?? '?' : '?';
}

class _Budget {
  _Budget(this.limit);

  final int limit;
  int used = 0;
  bool exhausted = false;

  bool take() {
    if (used >= limit) {
      exhausted = true;
      return false;
    }
    used++;
    return true;
  }
}
