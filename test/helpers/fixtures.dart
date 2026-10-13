import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:vm_service/vm_service.dart' as vms;
import 'package:vm_service_protos/vm_service_protos.dart' as pf;

/// JSON builders for `package:vm_service` model fixtures.
Map<String, dynamic> libraryRef(String uri) => {
  'type': '@Library',
  'id': 'libraries/${uri.hashCode}',
  'name': uri.split('/').last,
  'uri': uri,
};

Map<String, dynamic> classRef(String name, String libraryUri) => {
  'type': '@Class',
  'id': 'classes/$name',
  'name': name,
  'library': libraryRef(libraryUri),
};

Map<String, dynamic> scriptRef(String uri) => {
  'type': '@Script',
  'id': 'scripts/${uri.hashCode}',
  'uri': uri,
};

Map<String, dynamic> sourceLocation(
  String uri, {
  int tokenPos = 100,
  int? line,
}) => {
  'type': 'SourceLocation',
  'script': scriptRef(uri),
  'tokenPos': tokenPos,
  'line': ?line,
};

Map<String, dynamic> instanceRef(
  String className,
  String libraryUri, {
  String kind = 'PlainInstance',
  String? id,
  String? valueAsString,
}) => {
  'type': '@Instance',
  'id': id ?? 'objects/$className',
  'kind': kind,
  'class': classRef(className, libraryUri),
  'valueAsString': ?valueAsString,
};

Map<String, dynamic> funcRef(
  String name, {
  required Map<String, dynamic> owner,
  Map<String, dynamic>? location,
  String? id,
}) => {
  'type': '@Function',
  'id': id ?? 'functions/${name.hashCode}',
  'name': name,
  'owner': owner,
  'static': false,
  'const': false,
  'implicit': false,
  'abstract': false,
  'isGetter': false,
  'isSetter': false,
  'location': ?location,
};

Map<String, dynamic> closureRef({
  required Map<String, dynamic> function,
  String id = 'objects/closure',
}) => {
  'type': '@Instance',
  'id': id,
  'kind': 'Closure',
  'class': classRef('_Closure', 'dart:core'),
  'closureFunction': function,
  'closureContext': contextRef(),
};

Map<String, dynamic> contextRef({String id = 'objects/context'}) => {
  'type': '@Context',
  'id': id,
  'length': 2,
};

Map<String, dynamic> staticFieldRef(
  String name, {
  required Map<String, dynamic> owner,
  required String uri,
  int? line,
}) => {
  'type': '@Field',
  'id': 'fields/$name',
  'name': name,
  'owner': owner,
  'declaredType': {
    'type': '@Instance',
    'id': 'objects/type-$name',
    'kind': 'Type',
    'name': 'dynamic',
    'class': classRef('_Type', 'dart:core'),
  },
  'const': false,
  'final': true,
  'static': true,
  'location': sourceLocation(uri, line: line),
};

Map<String, dynamic> retainingObject(
  Map<String, dynamic> value, {
  Object? parentField,
  int? parentListIndex,
  Map<String, dynamic>? parentMapKey,
}) => {
  'type': 'RetainingObject',
  'value': value,
  'parentField': ?parentField,
  'parentListIndex': ?parentListIndex,
  'parentMapKey': ?parentMapKey,
};

/// An inbound reference from [source] (an `@Instance` map) to the target.
Map<String, dynamic> inboundReference(
  Map<String, dynamic> source, {
  Object? parentField,
  int? parentListIndex,
}) => {
  'type': 'InboundReference',
  'source': source,
  'parentField': ?parentField,
  'parentListIndex': ?parentListIndex,
};

/// An `InboundReferences` response.
vms.InboundReferences inboundReferences(
  List<Map<String, dynamic>> references,
) => vms.InboundReferences.parse({
  'type': 'InboundReferences',
  'references': references,
})!;

/// A retaining path; [elements] run from the leaked object to the root.
vms.RetainingPath retainingPath(
  List<Map<String, dynamic>> elements, {
  String gcRootType = 'user global',
}) => vms.RetainingPath.parse({
  'type': 'RetainingPath',
  'length': elements.length,
  'gcRootType': gcRootType,
  'elements': elements,
})!;

Map<String, dynamic> boundField(String name, Map<String, dynamic> value) => {
  'type': 'BoundField',
  'decl': {
    'type': '@Field',
    'id': 'fields/$name',
    'name': name,
    'owner': classRef('Owner', 'dart:core'),
    'declaredType': {
      'type': '@Instance',
      'id': 'objects/type-$name',
      'kind': 'Type',
      'name': 'dynamic',
      'class': classRef('_Type', 'dart:core'),
    },
    'const': false,
    'final': false,
    'static': false,
  },
  'name': name,
  'value': value,
};

vms.Instance instance(
  String id,
  String className,
  String libraryUri,
  List<Map<String, dynamic>> fields,
) => vms.Instance.parse({
  'type': 'Instance',
  'id': id,
  'kind': 'PlainInstance',
  'class': classRef(className, libraryUri),
  'identityHashCode': id.hashCode,
  'fields': fields,
})!;

Map<String, dynamic> profileFunction(
  Map<String, dynamic> function, {
  String resolvedUrl = '',
}) => {
  'type': 'ProfileFunction',
  'kind': 'Dart',
  'inclusiveTicks': 0,
  'exclusiveTicks': 0,
  'resolvedUrl': resolvedUrl,
  'function': function,
};

Map<String, dynamic> nativeFunction(String name) => {
  'type': 'ProfileFunction',
  'kind': 'Native',
  'inclusiveTicks': 0,
  'exclusiveTicks': 0,
  'resolvedUrl': '',
  'function': {'type': 'NativeFunction', 'name': name},
};

Map<String, dynamic> cpuSample(
  List<int> stack, {
  String vmTag = 'Dart',
  bool? truncated,
  int timestamp = 0,
}) => {
  'type': 'CpuSample',
  'tid': 1,
  'timestamp': timestamp,
  'vmTag': vmTag,
  'stack': stack,
  'truncated': ?truncated,
};

vms.CpuSamples cpuSamples({
  required List<Map<String, dynamic>> functions,
  required List<Map<String, dynamic>> samples,
  int samplePeriod = 1000,
}) => vms.CpuSamples.parse({
  'type': 'CpuSamples',
  'samplePeriod': samplePeriod,
  'maxStackDepth': 128,
  'sampleCount': samples.length,
  'timeOriginMicros': 0,
  'timeExtentMicros': 1000000,
  'pid': 1,
  'functions': functions,
  'samples': samples,
})!;

/// A function of a Perfetto fixture; a null `path` means a native frame.
typedef PerfettoFunction = ({String name, String? path});

/// Builds a base64 Perfetto trace like the VM's `getPerfettoCpuSamples`.
/// [stacks] are lists of indices into [functions], ROOT first; each stack is
/// one sample at [timestampsMicros] (or 1 ms apart).
String perfettoTrace({
  required List<PerfettoFunction> functions,
  required List<List<int>> stacks,
  List<int>? timestampsMicros,
}) {
  final data = pf.InternedData();
  final pathIds = <String, int>{};
  for (var i = 0; i < functions.length; i++) {
    data.functionNames.add(
      pf.InternedString()
        ..iid = Int64(i + 1)
        ..str = utf8.encode(functions[i].name),
    );
    final path = functions[i].path;
    var mappingId = 0;
    if (path != null) {
      final pathId = pathIds.putIfAbsent(path, () {
        final id = pathIds.length + 1;
        data.mappingPaths.add(
          pf.InternedString()
            ..iid = Int64(id)
            ..str = utf8.encode(path),
        );
        data.mappings.add(
          pf.Mapping()
            ..iid = Int64(id)
            ..pathStringIds.add(Int64(id)),
        );
        return id;
      });
      mappingId = pathId;
    }
    data.frames.add(
      pf.Frame()
        ..iid = Int64(i + 1)
        ..functionNameId = Int64(i + 1)
        ..mappingId = Int64(mappingId),
    );
  }
  for (var i = 0; i < stacks.length; i++) {
    data.callstacks.add(
      pf.Callstack()
        ..iid = Int64(i + 1)
        ..frameIds.addAll([for (final f in stacks[i]) Int64(f + 1)]),
    );
  }
  final trace = pf.Trace()
    ..packet.add(
      pf.TracePacket()
        ..trustedPacketSequenceId = 1
        ..sequenceFlags = 1
        ..internedData = data,
    );
  for (var i = 0; i < stacks.length; i++) {
    final micros = timestampsMicros?[i] ?? (i + 1) * 1000;
    trace.packet.add(
      pf.TracePacket()
        ..trustedPacketSequenceId = 1
        ..sequenceFlags = 2
        ..timestamp = Int64(micros * 1000)
        ..timestampClockId = 3
        ..perfSample = (pf.PerfSample()
          ..callstackIid = Int64(i + 1)
          ..tid = 1
          ..pid = 1),
    );
  }
  return base64Encode(trace.writeToBuffer());
}

/// A class-heap-stats entry for an allocation profile.
Map<String, dynamic> classHeapStats(
  String className,
  String libraryUri, {
  required int instances,
  required int bytes,
  String? classId,
}) => {
  'type': 'ClassHeapStats',
  'class': {
    'type': '@Class',
    'id': classId ?? 'classes/${className.hashCode.abs()}',
    'name': className,
    'library': {
      'type': '@Library',
      'id': 'libraries/${libraryUri.hashCode.abs()}',
      'name': libraryUri,
      'uri': libraryUri,
    },
  },
  'accumulatedSize': bytes,
  'bytesCurrent': bytes,
  'instancesAccumulated': instances,
  'instancesCurrent': instances,
};

/// An allocation profile with the given members.
vms.AllocationProfile allocationProfile(List<Map<String, dynamic>> members) =>
    vms.AllocationProfile.parse({
      'type': 'AllocationProfile',
      'dateLastAccumulatorReset': '0',
      'dateLastServiceGC': '0',
      'members': members,
    })!;

/// An instance set of the given object ids.
vms.InstanceSet instanceSet(List<String> ids, {int? totalCount}) =>
    vms.InstanceSet.parse({
      'type': 'InstanceSet',
      'totalCount': totalCount ?? ids.length,
      'instances': [
        for (final id in ids)
          {
            'type': '@Instance',
            'id': id,
            'kind': 'PlainInstance',
            'class': classRef('CacheEntry', 'package:my_app/cache.dart'),
          },
      ],
    })!;
