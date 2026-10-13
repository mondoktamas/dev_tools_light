import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// A scriptable [VmApi].
class FakeVmApi implements VmApi {
  FakeVmApi({
    Map<String, vms.Obj>? objects,
    this.retainingPaths = const {},
    this.samples,
    this.perfettoSamples,
    this.packageUris = const {},
    this.libraries = const [],
    this.flags = const {'profiler': 'true', 'profile_period': '1000'},
    this.allocationProfiles = const [],
    this.instanceSets = const {},
    this.resolvedPackageUris = const {},
    this.rootLibraryUri = 'package:my_app/main.dart',
    this.inboundReferences = const {},
  }) : objects = objects ?? {};

  /// Answers of [getInboundReferences] by target id (empty otherwise).
  final Map<String, vms.InboundReferences> inboundReferences;

  /// Answers of [lookupResolvedPackageUris].
  final Map<String, String?> resolvedPackageUris;

  /// The root library reported by [getIsolate].
  final String rootLibraryUri;

  /// Successive answers of [getAllocationProfile]; the last one repeats.
  final List<vms.AllocationProfile> allocationProfiles;

  /// Answers of [getInstances] by class id.
  final Map<String, vms.InstanceSet> instanceSets;
  int allocationProfileCalls = 0;

  final Map<String, vms.Obj> objects;
  final Map<String, vms.RetainingPath> retainingPaths;
  final vms.CpuSamples? samples;

  /// Base64 Perfetto trace returned by [getPerfettoCpuSamples]; null makes
  /// the RPC fail like an old VM.
  final String? perfettoSamples;

  /// Answers of [lookupPackageUris].
  final Map<String, String?> packageUris;

  /// `{id, uri}` maps listed by [getIsolate].
  final List<Map<String, String>> libraries;
  final Map<String, String> flags;
  final List<String> calls = [];
  final List<(String, String)> setFlags = [];
  int disposeCount = 0;
  int gcRequests = 0;
  Exception? getVersionError;

  /// Called by [collectAllGarbage] (e.g. to advance a fake barrier).
  void Function()? onCollectAllGarbage;

  /// Called by [getAllocationProfile] with `gc: true`.
  void Function()? onGcRequest;

  @override
  Future<vms.Version> getVersion() async {
    calls.add('getVersion');
    final error = getVersionError;
    if (error != null) {
      throw error;
    }
    return vms.Version(major: 4, minor: 22);
  }

  @override
  Future<vms.Isolate> getIsolate(String isolateId) async {
    calls.add('getIsolate');
    return vms.Isolate.parse({
      'type': 'Isolate',
      'id': isolateId,
      'number': '1',
      'name': 'main',
      'isSystemIsolate': false,
      'isolateGroupId': 'g',
      'isolateFlags': <Object?>[],
      'startTime': 0,
      'runnable': true,
      'livePorts': 1,
      'pauseOnExit': false,
      'pauseEvent': {
        'type': 'Event',
        'kind': 'Resume',
        'timestamp': 0,
        'isolate': {
          'type': '@Isolate',
          'id': isolateId,
          'number': '1',
          'name': 'main',
          'isSystemIsolate': false,
          'isolateGroupId': 'g',
        },
      },
      'rootLib': {
        'type': '@Library',
        'id': 'libraries/root',
        'name': 'main',
        'uri': rootLibraryUri,
      },
      'libraries': [
        for (final library in libraries)
          {
            'type': '@Library',
            'id': library['id'],
            'name': library['uri'],
            'uri': library['uri'],
          },
      ],
      'breakpoints': <Object?>[],
      'exceptionPauseMode': 'None',
    })!;
  }

  @override
  Future<vms.FlagList> getFlagList() async {
    calls.add('getFlagList');
    return vms.FlagList(
      flags: [
        for (final entry in flags.entries)
          vms.Flag(
            name: entry.key,
            comment: '',
            modified: false,
            valueAsString: entry.value,
          ),
      ],
    );
  }

  @override
  Future<vms.Response> setFlag(String name, String value) async {
    calls.add('setFlag');
    setFlags.add((name, value));
    return vms.Success();
  }

  @override
  Future<vms.AllocationProfile> getAllocationProfile(
    String isolateId, {
    bool? gc,
  }) async {
    calls.add('getAllocationProfile');
    if (gc ?? false) {
      gcRequests++;
      onGcRequest?.call();
    }
    if (allocationProfiles.isEmpty) {
      return vms.AllocationProfile(members: []);
    }
    final index = allocationProfileCalls.clamp(
      0,
      allocationProfiles.length - 1,
    );
    allocationProfileCalls++;
    return allocationProfiles[index];
  }

  @override
  Future<vms.InstanceSet> getInstances(
    String isolateId,
    String classId,
    int limit,
  ) async {
    calls.add('getInstances');
    return instanceSets[classId] ??
        vms.InstanceSet(totalCount: 0, instances: []);
  }

  @override
  Future<void> collectAllGarbage(String isolateId) async {
    calls.add('collectAllGarbage');
    gcRequests++;
    onCollectAllGarbage?.call();
  }

  @override
  Future<void> clearCpuSamples(String isolateId) async {
    calls.add('clearCpuSamples');
  }

  @override
  Future<vms.RetainingPath> getRetainingPath(
    String isolateId,
    String targetId,
    int limit,
  ) async {
    calls.add('getRetainingPath');
    final path = retainingPaths[targetId];
    if (path == null) {
      throw vms.SentinelException.parse('getRetainingPath', {
        'type': 'Sentinel',
        'kind': 'Collected',
        'valueAsString': '<collected>',
      });
    }
    return path;
  }

  @override
  Future<vms.Obj> getObject(String isolateId, String objectId) async {
    calls.add('getObject');
    final object = objects[objectId];
    if (object == null) {
      throw vms.RPCError('getObject', 105, 'not found');
    }
    return object;
  }

  @override
  Future<vms.InboundReferences> getInboundReferences(
    String isolateId,
    String targetId,
    int limit,
  ) async {
    calls.add('getInboundReferences');
    return inboundReferences[targetId] ?? vms.InboundReferences(references: []);
  }

  @override
  Future<vms.CpuSamples> getCpuSamples(
    String isolateId,
    int timeOriginMicros,
    int timeExtentMicros,
  ) async {
    calls.add('getCpuSamples');
    return samples ??
        vms.CpuSamples(
          samplePeriod: 1000,
          maxStackDepth: 128,
          sampleCount: 0,
          timeOriginMicros: timeOriginMicros,
          timeExtentMicros: timeExtentMicros,
          pid: 1,
          functions: [],
          samples: [],
        );
  }

  @override
  Future<vms.PerfettoCpuSamples> getPerfettoCpuSamples(
    String isolateId,
    int timeOriginMicros,
    int timeExtentMicros,
  ) async {
    calls.add('getPerfettoCpuSamples');
    final encoded = perfettoSamples;
    if (encoded == null) {
      throw vms.RPCError('getPerfettoCpuSamples', 100, 'not supported');
    }
    return vms.PerfettoCpuSamples(
      samplePeriod: 1000,
      maxStackDepth: 128,
      sampleCount: -1,
      timeOriginMicros: timeOriginMicros,
      timeExtentMicros: timeExtentMicros,
      pid: 1,
      samples: encoded,
    );
  }

  @override
  Future<vms.UriList> lookupPackageUris(
    String isolateId,
    List<String> uris,
  ) async {
    calls.add('lookupPackageUris');
    return vms.UriList(uris: [for (final uri in uris) packageUris[uri]]);
  }

  @override
  Future<vms.UriList> lookupResolvedPackageUris(
    String isolateId,
    List<String> uris,
  ) async {
    calls.add('lookupResolvedPackageUris');
    return vms.UriList(
      uris: [for (final uri in uris) resolvedPackageUris[uri]],
    );
  }

  @override
  Future<vms.Timestamp> getVMTimelineMicros() async {
    calls.add('getVMTimelineMicros');
    return vms.Timestamp(timestamp: 0);
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}
