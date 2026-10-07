import 'package:dev_tools_light/src/leaks/leak_trace.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// A LEAKING / NOT LEAKING verdict with its reason.
class Inspection {
  /// Creates an inspection result.
  const Inspection(this.status, this.reason);

  /// The verdict.
  final LeakStatus status;

  /// Why.
  final String reason;
}

/// Labels retaining-path objects like LeakCanary's `ObjectInspector`s, by
/// looking at their private lifecycle fields through `getObject`.
class ObjectInspector {
  /// Creates an inspector that makes at most [maxInspections] RPC calls.
  ObjectInspector({required this.maxInspections});

  /// Budget of `getObject` calls.
  final int maxInspections;

  int _used = 0;

  /// Classes that are alive for the whole app lifetime.
  static const Set<String> liveSingletons = {
    'WidgetsFlutterBinding',
    'BuildOwner',
    'PipelineOwner',
    'FocusManager',
    'FlutterMemoryAllocations',
    'RestorationManager',
    'SemanticsOwner',
    '_RootZone',
  };

  /// A verdict that needs no RPC, or null.
  static Inspection? byClassName(String className) {
    if (liveSingletons.contains(className) || className.endsWith('Binding')) {
      return const Inspection(LeakStatus.notLeaking, 'framework singleton');
    }
    return null;
  }

  /// Inspects [ref] (one or two `getObject` calls), or returns null when the
  /// budget is exhausted or nothing is known about the class.
  Future<Inspection?> inspect(
    VmApi api,
    String isolateId,
    vms.InstanceRef ref,
  ) async {
    final id = ref.id;
    if (id == null || _used >= maxInspections) {
      return null;
    }
    _used++;
    final vms.Obj object;
    try {
      object = await api.getObject(isolateId, id);
    } on Object catch (_) {
      return null;
    }
    if (object is! vms.Instance) {
      return null;
    }
    final fields = <String, Object?>{};
    for (final field in object.fields ?? const <vms.BoundField>[]) {
      fields[normalizeFieldName(field)] = field.value;
    }
    final className = ref.classRef?.name ?? '';

    final stateLifecycle = fields['_debugLifecycleState'];
    if (stateLifecycle is vms.InstanceRef) {
      final name = await _enumName(api, isolateId, stateLifecycle);
      return switch (name) {
        'defunct' => const Inspection(
          LeakStatus.leaking,
          'State is defunct (disposed)',
        ),
        'ready' => const Inspection(
          LeakStatus.notLeaking,
          'State is ready (mounted)',
        ),
        _ => Inspection(LeakStatus.unknown, 'State lifecycle: $name'),
      };
    }
    final elementLifecycle = fields['_lifecycleState'];
    if (elementLifecycle is vms.InstanceRef && fields.containsKey('_widget')) {
      final name = await _enumName(api, isolateId, elementLifecycle);
      return switch (name) {
        'defunct' => const Inspection(
          LeakStatus.leaking,
          'Element is defunct (unmounted)',
        ),
        'active' => const Inspection(
          LeakStatus.notLeaking,
          'Element is active (mounted)',
        ),
        _ => Inspection(LeakStatus.unknown, 'Element lifecycle: $name'),
      };
    }
    final disposed = fields['_debugDisposed'];
    if (disposed is vms.InstanceRef) {
      return switch (disposed.valueAsString) {
        'true' => const Inspection(
          LeakStatus.leaking,
          'ChangeNotifier is disposed',
        ),
        'false' => const Inspection(
          LeakStatus.notLeaking,
          'ChangeNotifier is not disposed',
        ),
        _ => null,
      };
    }
    if (className == 'AnimationController' && fields.containsKey('_ticker')) {
      final ticker = fields['_ticker'];
      final isNull =
          ticker is vms.InstanceRef && ticker.kind == vms.InstanceKind.kNull;
      return isNull
          ? const Inspection(
              LeakStatus.leaking,
              'AnimationController is disposed (ticker is null)',
            )
          : const Inspection(
              LeakStatus.notLeaking,
              'AnimationController still has its ticker',
            );
    }
    if (fields.containsKey('_navigator') && fields.containsKey('_settings')) {
      final navigator = fields['_navigator'];
      final isNull =
          navigator is vms.InstanceRef &&
          navigator.kind == vms.InstanceKind.kNull;
      return isNull
          ? const Inspection(
              LeakStatus.leaking,
              'Route is disposed (navigator is null)',
            )
          : const Inspection(
              LeakStatus.notLeaking,
              'Route is attached to a navigator',
            );
    }
    final disposedByOwner = fields['_disposedByOwner'];
    if (disposedByOwner is vms.InstanceRef && fields.containsKey('_overlay')) {
      if (disposedByOwner.valueAsString == 'true') {
        return const Inspection(LeakStatus.leaking, 'OverlayEntry is disposed');
      }
    }
    return null;
  }

  Future<String?> _enumName(
    VmApi api,
    String isolateId,
    vms.InstanceRef value,
  ) async {
    final asString = value.valueAsString;
    if (asString != null) {
      return asString.split('.').last;
    }
    final id = value.id;
    if (id == null || _used >= maxInspections) {
      return null;
    }
    _used++;
    final vms.Obj object;
    try {
      object = await api.getObject(isolateId, id);
    } on Object catch (_) {
      return null;
    }
    if (object is! vms.Instance) {
      return null;
    }
    for (final field in object.fields ?? const <vms.BoundField>[]) {
      final name = normalizeFieldName(field);
      if (name == '_name' || name == 'name') {
        final v = field.value;
        if (v is vms.InstanceRef) {
          return v.valueAsString;
        }
      }
    }
    return null;
  }

  /// The field name of [field] without the VM's private-name suffix.
  static String normalizeFieldName(vms.BoundField field) {
    final raw = field.decl?.name ?? field.name?.toString() ?? '';
    return raw.replaceAll(RegExp(r'@\d+$'), '');
  }
}
