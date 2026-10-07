import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/core/fnv_hash.dart';
import 'package:dev_tools_light/src/leaks/leak_trace.dart';
import 'package:dev_tools_light/src/vm/function_names.dart' as names;
import 'package:dev_tools_light/src/vm/object_inspector.dart';
import 'package:dev_tools_light/src/vm/script_line_resolver.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// Turns a VM `RetainingPath` into a [LeakTrace]: root first, closures
/// collapsed with their contexts, static fields rendered as such, nodes
/// labelled LEAKING / NOT LEAKING, suspects marked and a signature computed.
class LeakTraceBuilder {
  /// Creates a builder.
  LeakTraceBuilder({required this.classifier, this.lineResolver});

  /// Classifies library URIs.
  final AppCodeClassifier classifier;

  /// Resolves closure locations when the VM omits line numbers.
  final ScriptLineResolver? lineResolver;

  /// Builds the trace. [api], [isolateId] and [inspector] are optional; without
  /// them nodes are labelled from class names only. [note] is attached to the
  /// trace as [LeakTrace.note].
  Future<LeakTrace> build(
    vms.RetainingPath path, {
    required String leakedTypeName,
    String leafStatusReason = 'disposed and still reachable after GC',
    VmApi? api,
    String? isolateId,
    ObjectInspector? inspector,
    String? note,
  }) async {
    final elements = (path.elements ?? const <vms.RetainingObject>[]).reversed
        .toList();
    final nodes = <LeakTraceNode>[];
    // The plain instance behind each node (null for collapsed closures).
    final instances = <vms.InstanceRef?>[];
    var index = 0;
    while (index < elements.length) {
      final element = elements[index];
      final value = element.value;
      if (value is vms.InstanceRef && value.kind == vms.InstanceKind.kClosure) {
        // Collapse `Closure → Context → Context…` into one closure node.
        var last = element;
        var next = index + 1;
        while (next < elements.length &&
            elements[next].value is vms.ContextRef) {
          last = elements[next];
          next++;
        }
        nodes.add(await _closureNode(value, last, api, isolateId));
        instances.add(null);
        index = next;
        continue;
      }
      nodes.add(_node(element));
      instances.add(
        value is vms.InstanceRef &&
                value.kind == vms.InstanceKind.kPlainInstance
            ? value
            : null,
      );
      index++;
    }
    if (nodes.isEmpty) {
      nodes.add(
        LeakTraceNode(
          className: leakedTypeName,
          origin: CodeOrigin.unknown,
          status: LeakStatus.leaking,
          statusReason: leafStatusReason,
        ),
      );
      instances.add(null);
    }

    // Label the leaked object and, if possible, the intermediate objects.
    final lastIndex = nodes.length - 1;
    nodes[lastIndex] = nodes[lastIndex].copyWith(
      status: LeakStatus.leaking,
      statusReason: leafStatusReason,
    );
    if (inspector != null && api != null && isolateId != null) {
      for (var i = lastIndex - 1; i >= 0; i--) {
        if (nodes[i].status != LeakStatus.unknown) {
          continue;
        }
        final value = instances[i];
        if (value == null) {
          continue;
        }
        final inspection = await inspector.inspect(api, isolateId, value);
        if (inspection != null) {
          nodes[i] = nodes[i].copyWith(
            status: inspection.status,
            statusReason: inspection.reason,
          );
        }
      }
    }

    // Suspects: the references between the last NOT LEAKING node before the
    // first LEAKING node and that LEAKING node.
    final firstLeaking = nodes.indexWhere(
      (n) => n.status == LeakStatus.leaking,
    );
    var start = 0;
    for (var i = firstLeaking - 1; i >= 0; i--) {
      if (nodes[i].status == LeakStatus.notLeaking) {
        start = i;
        break;
      }
    }
    for (var i = start; i < firstLeaking; i++) {
      nodes[i] = nodes[i].copyWith(isSuspect: true);
    }

    final signature = stableSignature([
      nodes.last.className,
      for (final node in nodes)
        if (node.isSuspect)
          '${node.libraryUri}/${node.className}.${node.referenceName ?? ''}',
    ]);
    return LeakTrace(
      gcRootType: path.gcRootType ?? 'unknown',
      nodes: nodes,
      signature: signature,
      viaWeakReference: nodes.any(
        (n) => LeakTrace.weakClasses.contains(n.className),
      ),
      note: note,
    );
  }

  LeakTraceNode _node(vms.RetainingObject element) {
    final value = element.value;
    final node = switch (value) {
      vms.InstanceRef() => _instanceNode(value, element),
      vms.ContextRef() => LeakTraceNode(
        className: 'Context',
        libraryUri: 'dart:core',
        origin: CodeOrigin.dart,
        referenceKind: ReferenceKind.closureCapture,
        referenceName: _slotName(element.parentField),
      ),
      vms.FieldRef() => _fieldNode(value),
      vms.ClassRef() => LeakTraceNode(
        className: 'Class ${value.name ?? '?'}',
        libraryUri: value.library?.uri,
        origin: classifier.classify(value.library?.uri),
        status: LeakStatus.notLeaking,
        statusReason: 'class',
        referenceName: _fieldName(element.parentField),
      ),
      vms.LibraryRef() => LeakTraceNode(
        className: 'Library ${value.name ?? value.uri ?? '?'}',
        libraryUri: value.uri,
        origin: classifier.classify(value.uri),
        status: LeakStatus.notLeaking,
        statusReason: 'library',
        referenceName: _fieldName(element.parentField),
      ),
      vms.FuncRef() => LeakTraceNode(
        className: 'Function ${qualifiedFunctionName(value)}',
        libraryUri: value.location?.script?.uri,
        origin: classifier.classify(value.location?.script?.uri),
        referenceName: _fieldName(element.parentField),
      ),
      vms.ObjRef() => LeakTraceNode(
        className: value.type,
        origin: CodeOrigin.unknown,
        referenceName: _fieldName(element.parentField),
      ),
      _ => const LeakTraceNode(className: '?', origin: CodeOrigin.unknown),
    };
    return node;
  }

  LeakTraceNode _instanceNode(
    vms.InstanceRef value,
    vms.RetainingObject element,
  ) {
    final kind = value.kind ?? vms.InstanceKind.kPlainInstance;
    final libraryUri = value.classRef?.library?.uri;
    final className = value.classRef?.name ?? kind;
    final origin = classifier.classify(libraryUri);
    final byName = ObjectInspector.byClassName(className);
    switch (kind) {
      case vms.InstanceKind.kList:
      case vms.InstanceKind.kSet:
        return LeakTraceNode(
          className: className,
          libraryUri: libraryUri,
          origin: origin,
          referenceKind: ReferenceKind.listElement,
          referenceName:
              element.parentListIndex?.toString() ??
              _fieldName(element.parentField) ??
              '?',
        );
      case vms.InstanceKind.kMap:
        final key = element.parentMapKey;
        return LeakTraceNode(
          className: className,
          libraryUri: libraryUri,
          origin: origin,
          referenceKind: ReferenceKind.mapEntry,
          referenceName: key is vms.InstanceRef
              ? key.valueAsString ?? key.classRef?.name ?? 'key'
              : _fieldName(element.parentField) ?? 'key',
        );
      default:
        return LeakTraceNode(
          className: className,
          libraryUri: libraryUri,
          origin: origin,
          status: byName?.status ?? LeakStatus.unknown,
          statusReason: byName?.reason,
          referenceKind: element.parentField is int
              ? ReferenceKind.listElement
              : ReferenceKind.instanceField,
          referenceName: _fieldName(element.parentField),
        );
    }
  }

  LeakTraceNode _fieldNode(vms.FieldRef field) {
    final owner = field.owner;
    final ownerName = switch (owner) {
      vms.ClassRef() => owner.name ?? '?',
      vms.LibraryRef() => AppCodeClassifier.displayPath(owner.uri ?? '?'),
      _ => '?',
    };
    final ownerLibrary = switch (owner) {
      vms.ClassRef() => owner.library?.uri,
      vms.LibraryRef() => owner.uri,
      _ => null,
    };
    final uri = field.location?.script?.uri ?? ownerLibrary;
    final line = field.location?.line;
    return LeakTraceNode(
      className: ownerName,
      libraryUri: uri,
      origin: classifier.classify(uri),
      status: LeakStatus.notLeaking,
      statusReason: field.isStatic ?? true ? 'static field' : 'field',
      referenceKind: ReferenceKind.staticField,
      referenceName: field.name,
      location: _locationOf(uri, line),
    );
  }

  Future<LeakTraceNode> _closureNode(
    vms.InstanceRef closure,
    vms.RetainingObject lastElement,
    VmApi? api,
    String? isolateId,
  ) async {
    final function = closure.closureFunction;
    final location = function?.location;
    final uri = location?.script?.uri;
    var line = location?.line;
    final script = location?.script;
    final tokenPos = location?.tokenPos;
    final resolver = lineResolver;
    if (line == null &&
        resolver != null &&
        api != null &&
        isolateId != null &&
        script != null &&
        tokenPos != null) {
      line = await resolver.lineFor(api, isolateId, script, tokenPos);
    }
    return LeakTraceNode(
      className: closure.classRef?.name ?? '_Closure',
      libraryUri: uri,
      origin: classifier.classify(uri),
      referenceKind: ReferenceKind.closureCapture,
      referenceName: _slotName(lastElement.parentField),
      functionName: function == null
          ? '<closure>'
          : qualifiedFunctionName(function),
      location: _locationOf(uri, line),
    );
  }

  /// `lib/path.dart:line` for [uri], or null.
  static String? _locationOf(String? uri, int? line) {
    if (uri == null) {
      return null;
    }
    final path = AppCodeClassifier.displayPath(uri);
    return line == null ? path : '$path:$line';
  }

  static String? _fieldName(Object? parentField) {
    if (parentField == null) {
      return null;
    }
    return parentField.toString().replaceAll(RegExp(r'@\d+$'), '');
  }

  static String? _slotName(Object? parentField) {
    if (parentField == null) {
      return null;
    }
    if (parentField is int) {
      return '#$parentField';
    }
    return _fieldName(parentField);
  }

  /// `Owner.function.<anonymous closure>` for [function].
  static String qualifiedFunctionName(vms.FuncRef function) =>
      names.qualifiedFunctionName(function);

  /// Removes `[Optimized] `-style prefixes from a VM function name.
  static String stripCodeTags(String name) => names.stripCodeTags(name);
}
