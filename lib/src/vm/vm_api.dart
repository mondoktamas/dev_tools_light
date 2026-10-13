import 'package:vm_service/vm_service.dart' as vms;

/// The subset of the VM service protocol used by `dev_tools_light`.
///
/// Kept small so tests can provide fakes; the models are the plain
/// `package:vm_service` classes, which parse from JSON fixtures.
abstract class VmApi {
  /// `getVersion`.
  Future<vms.Version> getVersion();

  /// `getIsolate`.
  Future<vms.Isolate> getIsolate(String isolateId);

  /// `getFlagList`.
  Future<vms.FlagList> getFlagList();

  /// `setFlag`; returns `Success` or `Error`, never throws for bad values.
  Future<vms.Response> setFlag(String name, String value);

  /// `getAllocationProfile`; `gc: true` requests a full GC.
  Future<vms.AllocationProfile> getAllocationProfile(
    String isolateId, {
    bool? gc,
  });

  /// Requests a full GC as cheaply as the VM allows.
  Future<void> collectAllGarbage(String isolateId);

  /// `clearCpuSamples`: empties the profiler's sample buffer.
  Future<void> clearCpuSamples(String isolateId);

  /// `getRetainingPath`.
  Future<vms.RetainingPath> getRetainingPath(
    String isolateId,
    String targetId,
    int limit,
  );

  /// `getObject`.
  Future<vms.Obj> getObject(String isolateId, String objectId);

  /// `getInboundReferences`: the objects referencing [targetId].
  Future<vms.InboundReferences> getInboundReferences(
    String isolateId,
    String targetId,
    int limit,
  );

  /// Live instances of a class (`getInstances`).
  Future<vms.InstanceSet> getInstances(
    String isolateId,
    String classId,
    int limit,
  );

  /// `getCpuSamples` for `(timeOriginMicros, timeOriginMicros + extent)`.
  Future<vms.CpuSamples> getCpuSamples(
    String isolateId,
    int timeOriginMicros,
    int timeExtentMicros,
  );

  /// `getPerfettoCpuSamples` for the same window (protobuf, much smaller).
  Future<vms.PerfettoCpuSamples> getPerfettoCpuSamples(
    String isolateId,
    int timeOriginMicros,
    int timeExtentMicros,
  );

  /// `lookupPackageUris`: resolved `file:` / `org-dartlang-sdk:` URIs to
  /// `package:` / `dart:` URIs (null entries for unknown URIs).
  Future<vms.UriList> lookupPackageUris(String isolateId, List<String> uris);

  /// `lookupResolvedPackageUris`: `package:` URIs to resolved `file:` URIs.
  Future<vms.UriList> lookupResolvedPackageUris(
    String isolateId,
    List<String> uris,
  );

  /// `getVMTimelineMicros` (the same clock as `Timeline.now`).
  Future<vms.Timestamp> getVMTimelineMicros();

  /// Closes the connection.
  Future<void> dispose();
}

/// [VmApi] backed by a real [vms.VmService] connection.
class VmServiceApi implements VmApi {
  /// Wraps [service].
  VmServiceApi(this.service);

  /// The underlying connection.
  final vms.VmService service;

  /// Receives timing diagnostics for expensive RPCs (debug logging).
  static void Function(String message)? diagnostics;

  @override
  Future<vms.Version> getVersion() => service.getVersion();

  @override
  Future<vms.Isolate> getIsolate(String isolateId) =>
      service.getIsolate(isolateId);

  @override
  Future<vms.FlagList> getFlagList() => service.getFlagList();

  @override
  Future<vms.Response> setFlag(String name, String value) =>
      service.setFlag(name, value);

  @override
  Future<vms.AllocationProfile> getAllocationProfile(
    String isolateId, {
    bool? gc,
  }) async {
    final stopwatch = Stopwatch()..start();
    final profile = await service.getAllocationProfile(isolateId, gc: gc);
    diagnostics?.call(
      'getAllocationProfile(gc: ${gc ?? false}): '
      '${stopwatch.elapsedMilliseconds} ms, '
      '${profile.members?.length ?? 0} classes',
    );
    return profile;
  }

  @override
  Future<void> collectAllGarbage(String isolateId) async {
    // `_collectAllGarbage` only runs the GC; `getAllocationProfile(gc: true)`
    // also walks the heap for per-class statistics, which is far slower.
    try {
      await service.callMethod('_collectAllGarbage', isolateId: isolateId);
    } on vms.RPCError {
      await service.getAllocationProfile(isolateId, gc: true);
    }
  }

  @override
  Future<void> clearCpuSamples(String isolateId) =>
      service.clearCpuSamples(isolateId);

  @override
  Future<vms.RetainingPath> getRetainingPath(
    String isolateId,
    String targetId,
    int limit,
  ) => service.getRetainingPath(isolateId, targetId, limit);

  @override
  Future<vms.Obj> getObject(String isolateId, String objectId) =>
      service.getObject(isolateId, objectId);

  @override
  Future<vms.InboundReferences> getInboundReferences(
    String isolateId,
    String targetId,
    int limit,
  ) => service.getInboundReferences(isolateId, targetId, limit);

  @override
  Future<vms.InstanceSet> getInstances(
    String isolateId,
    String classId,
    int limit,
  ) async {
    final stopwatch = Stopwatch()..start();
    final set = await service.getInstances(isolateId, classId, limit);
    diagnostics?.call(
      'getInstances($limit of ${set.totalCount}): '
      '${stopwatch.elapsedMilliseconds} ms',
    );
    return set;
  }

  @override
  Future<vms.CpuSamples> getCpuSamples(
    String isolateId,
    int timeOriginMicros,
    int timeExtentMicros,
  ) async {
    final log = diagnostics;
    if (log == null) {
      return service.getCpuSamples(
        isolateId,
        timeOriginMicros,
        timeExtentMicros,
      );
    }
    final stopwatch = Stopwatch()..start();
    int? rawLength;
    int? rawAtMillis;
    final subscription = service.onReceive.listen((message) {
      if (message.contains('"samplePeriod"')) {
        rawLength = message.length;
        rawAtMillis = stopwatch.elapsedMilliseconds;
      }
    });
    try {
      final samples = await service.getCpuSamples(
        isolateId,
        timeOriginMicros,
        timeExtentMicros,
      );
      log(
        'getCpuSamples(${timeExtentMicros ~/ 1000} ms window): '
        'response of ${rawLength ?? '?'} chars after ${rawAtMillis ?? '?'} ms, '
        'parsed after ${stopwatch.elapsedMilliseconds} ms, '
        '${samples.sampleCount} samples, '
        '${samples.functions?.length ?? 0} functions',
      );
      return samples;
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<vms.PerfettoCpuSamples> getPerfettoCpuSamples(
    String isolateId,
    int timeOriginMicros,
    int timeExtentMicros,
  ) async {
    final stopwatch = Stopwatch()..start();
    final response = await service.getPerfettoCpuSamples(
      isolateId,
      timeOriginMicros: timeOriginMicros,
      timeExtentMicros: timeExtentMicros,
    );
    diagnostics?.call(
      'getPerfettoCpuSamples(${timeExtentMicros ~/ 1000} ms window): '
      '${response.samples?.length ?? 0} base64 chars, '
      '${response.sampleCount} samples in ${stopwatch.elapsedMilliseconds} ms',
    );
    return response;
  }

  @override
  Future<vms.UriList> lookupPackageUris(String isolateId, List<String> uris) =>
      service.lookupPackageUris(isolateId, uris);

  @override
  Future<vms.UriList> lookupResolvedPackageUris(
    String isolateId,
    List<String> uris,
  ) => service.lookupResolvedPackageUris(isolateId, uris);

  @override
  Future<vms.Timestamp> getVMTimelineMicros() => service.getVMTimelineMicros();

  @override
  Future<void> dispose() => service.dispose();
}
