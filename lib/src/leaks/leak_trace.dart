import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:meta/meta.dart';

/// LeakCanary-style verdict for a node of a leak trace.
enum LeakStatus {
  /// The object is known to be dead (for example a defunct `State`).
  leaking,

  /// The object is known to be alive (a GC root, a live binding, ...).
  notLeaking,

  /// Nothing is known.
  unknown;

  /// Text used in reports.
  String get label => switch (this) {
    LeakStatus.leaking => 'LEAKING',
    LeakStatus.notLeaking => 'NOT LEAKING',
    LeakStatus.unknown => 'UNKNOWN',
  };
}

/// How a node references the next node (towards the leaked object).
enum ReferenceKind {
  /// An instance field.
  instanceField,

  /// A static field or top-level variable.
  staticField,

  /// A list element.
  listElement,

  /// A map key or value.
  mapEntry,

  /// A variable captured by a closure.
  closureCapture,

  /// Unknown.
  unknown,
}

/// One object on the path from a GC root to the leaked object.
@immutable
class LeakTraceNode {
  /// Creates a node.
  const LeakTraceNode({
    required this.className,
    required this.origin,
    this.libraryUri,
    this.status = LeakStatus.unknown,
    this.statusReason,
    this.referenceKind = ReferenceKind.unknown,
    this.referenceName,
    this.location,
    this.functionName,
    this.isSuspect = false,
  });

  /// The class name (`_HomePageState`, `List`, `_Closure`, ...).
  final String className;

  /// The library that declares the class (or the closure's script).
  final String? libraryUri;

  /// Whether this is app / framework / SDK / package code.
  final CodeOrigin origin;

  /// LEAKING / NOT LEAKING / UNKNOWN.
  final LeakStatus status;

  /// Why [status] was chosen.
  final String? statusReason;

  /// How this node references the next node.
  final ReferenceKind referenceKind;

  /// The field / index / key of this node that holds the next node.
  final String? referenceName;

  /// `lib/path.dart:line` for closures and static fields.
  final String? location;

  /// For closures: the enclosing function.
  final String? functionName;

  /// Whether the reference from this node to the next is a suspect
  /// (between the last NOT LEAKING and the first LEAKING node).
  final bool isSuspect;

  /// `closure Foo.bar.<anonymous closure>` for closures,
  /// `library lib/x.dart` for top-level variables, else [className].
  String get displayName {
    if (functionName != null) {
      return 'closure $functionName';
    }
    if (referenceKind == ReferenceKind.staticField && isTopLevel) {
      return 'library $className';
    }
    return className;
  }

  /// Whether this node is a library holding a top-level variable.
  bool get isTopLevel => className.endsWith('.dart');

  /// The reference as `Class.field`, `[index]` or `captured variable`.
  String get referenceDescription {
    final name = referenceName;
    return switch (referenceKind) {
      ReferenceKind.closureCapture =>
        name == 'context' || name == '_context'
            ? 'bound receiver / captured context'
            : 'captured variable${name == null ? '' : ' $name'}',
      ReferenceKind.listElement => '[$name]',
      ReferenceKind.mapEntry => '[$name]',
      ReferenceKind.staticField =>
        isTopLevel ? 'static $name' : 'static $className.$name',
      ReferenceKind.instanceField => '$className.${name ?? '?'}',
      ReferenceKind.unknown => name ?? '?',
    };
  }

  /// Returns a copy with the given fields replaced.
  LeakTraceNode copyWith({
    LeakStatus? status,
    String? statusReason,
    bool? isSuspect,
    String? location,
  }) {
    return LeakTraceNode(
      className: className,
      libraryUri: libraryUri,
      origin: origin,
      status: status ?? this.status,
      statusReason: statusReason ?? this.statusReason,
      referenceKind: referenceKind,
      referenceName: referenceName,
      location: location ?? this.location,
      functionName: functionName,
      isSuspect: isSuspect ?? this.isSuspect,
    );
  }
}

/// The path from a GC root to a leaked object.
@immutable
class LeakTrace {
  /// Creates a trace; [nodes] run from the root to the leaked object.
  const LeakTrace({
    required this.gcRootType,
    required this.nodes,
    required this.signature,
    this.libraryLeakDescription,
    this.viaWeakReference = false,
    this.note,
  });

  /// Shown when [viaWeakReference] is set.
  static const String weakReferenceWarning =
      'This path goes through a weak reference, which does not keep the '
      'object alive; a path of strong references exists but was not found.';

  /// Classes whose references the GC treats as weak but the VM's
  /// retaining-path search does not.
  static const Set<String> weakClasses = {
    '_WeakProperty',
    '_WeakReference',
    '_WeakReferenceImpl',
    'WeakReference',
    'Expando',
    '_Expando',
    'Finalizer',
    '_FinalizerImpl',
    '_FinalizerEntry',
    'FinalizerEntry',
  };

  /// The VM's description of the root (`user global`, `stack`, ...).
  final String gcRootType;

  /// Root first, leaked object last.
  final List<LeakTraceNode> nodes;

  /// Stable hash of the leaked class and the suspect references.
  final String signature;

  /// Set when a known library leak matched.
  final String? libraryLeakDescription;

  /// Whether the path goes through a weak reference (`Expando`,
  /// `WeakReference`, `Finalizer`). The object is still reachable through
  /// some strong path, but the VM reported this one first and the search
  /// for a strong one failed.
  final bool viaWeakReference;

  /// How the path was obtained when it is not the VM's first answer (for
  /// example a strong path found behind a weak reference).
  final String? note;

  /// Returns a copy with the given fields replaced.
  LeakTrace copyWith({
    String? libraryLeakDescription,
    bool? viaWeakReference,
    String? note,
  }) {
    return LeakTrace(
      gcRootType: gcRootType,
      nodes: nodes,
      signature: signature,
      libraryLeakDescription:
          libraryLeakDescription ?? this.libraryLeakDescription,
      viaWeakReference: viaWeakReference ?? this.viaWeakReference,
      note: note ?? this.note,
    );
  }

  /// The leaked object.
  LeakTraceNode get leakedObject => nodes.last;

  /// Nodes whose outgoing reference is a suspect.
  Iterable<LeakTraceNode> get suspects => nodes.where((n) => n.isSuspect);

  /// One-line summary: the first suspect reference, or the root.
  String get summary {
    final suspect = nodes.cast<LeakTraceNode?>().firstWhere(
      (n) => n!.isSuspect,
      orElse: () => null,
    );
    final node = suspect ?? nodes.first;
    return '${node.displayName} → ${node.referenceDescription}';
  }

  /// Renders the trace in LeakCanary's text format.
  String toText() {
    final buffer = StringBuffer()
      ..writeln('┬───')
      ..writeln('│ GC Root: $gcRootType')
      ..writeln('│');
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final last = i == nodes.length - 1;
      final prefix = last ? '╰→ ' : '├─ ';
      final gutter = last ? '   ' : '│  ';
      final location = node.location == null ? '' : '  ${node.location}';
      final reason = node.statusReason == null ? '' : ' (${node.statusReason})';
      buffer
        ..writeln('$prefix${node.displayName}  [${node.origin.label}]$location')
        ..writeln('$gutter  Leaking: ${node.status.label}$reason');
      if (!last) {
        final suspect = node.isSuspect ? '   ~~~ suspect' : '';
        buffer.writeln('$gutter  ↓ ${node.referenceDescription}$suspect');
      }
    }
    if (libraryLeakDescription != null) {
      buffer
        ..writeln()
        ..writeln('Library leak: $libraryLeakDescription');
    }
    if (viaWeakReference) {
      buffer
        ..writeln()
        ..writeln('Note: $weakReferenceWarning');
    }
    if (note != null) {
      buffer
        ..writeln()
        ..writeln('Note: $note');
    }
    return buffer.toString();
  }
}
