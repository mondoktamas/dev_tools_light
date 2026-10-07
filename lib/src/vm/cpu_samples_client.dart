import 'dart:math' as math;

import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/jank/perfetto_profile_decoder.dart';
import 'package:dev_tools_light/src/jank/sampled_profile.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// The profiler flags as found (and possibly changed) on the VM.
class ProfilerSetup {
  /// Creates a setup description.
  const ProfilerSetup({
    required this.profilerEnabled,
    required this.samplePeriodMicros,
    required this.originalSamplePeriodMicros,
    required this.changedPeriod,
  });

  /// Whether the profiler is on.
  final bool profilerEnabled;

  /// The sampling period now in effect.
  final int? samplePeriodMicros;

  /// The sampling period before we touched it.
  final int? originalSamplePeriodMicros;

  /// Whether we lowered the period (and must restore it).
  final bool changedPeriod;
}

/// Runs a computation, possibly off the UI isolate.
typedef ComputeFunction = Future<R> Function<R>(R Function() computation);

/// Marks the span of [body] as our own work (see `SelfInflictedStallGuard`).
typedef GuardFunction = Future<T> Function<T>(Future<T> Function() body);

/// Reads/sets profiler flags and fetches CPU samples.
class CpuSamplesClient {
  /// Creates a client. With [compute], Perfetto traces are decoded off the
  /// UI isolate (the decode takes about a second on a mid-range phone in
  /// debug mode).
  const CpuSamplesClient({ComputeFunction? compute}) : _compute = compute;

  final ComputeFunction? _compute;

  /// Makes sure the profiler is on and, if [desiredSamplePeriodMicros] is
  /// lower than the VM's current period, lowers it.
  Future<ProfilerSetup> ensureProfiler(
    VmApi api, {
    int? desiredSamplePeriodMicros,
  }) async {
    final flags = (await api.getFlagList()).flags ?? const <vms.Flag>[];
    String? valueOf(String name) {
      for (final flag in flags) {
        if (flag.name == name) {
          return flag.valueAsString;
        }
      }
      return null;
    }

    var profiler = valueOf('profiler') == 'true';
    if (!profiler) {
      final response = await api.setFlag('profiler', 'true');
      profiler = response is vms.Success;
    }
    final current = int.tryParse(valueOf('profile_period') ?? '');
    var period = current;
    var changed = false;
    final desired = desiredSamplePeriodMicros;
    if (desired != null && (current == null || desired < current)) {
      final response = await api.setFlag('profile_period', '$desired');
      if (response is vms.Success) {
        period = desired;
        changed = true;
      }
    }
    return ProfilerSetup(
      profilerEnabled: profiler,
      samplePeriodMicros: period,
      originalSamplePeriodMicros: current,
      changedPeriod: changed,
    );
  }

  /// Fetches the samples of `[startMicros, endMicros]` (timeline clock).
  Future<vms.CpuSamples> fetch(
    VmApi api, {
    required String isolateId,
    required int startMicros,
    required int endMicros,
  }) => api.getCpuSamples(
    isolateId,
    startMicros,
    math.max(1, endMicros - startMicros),
  );

  /// Fetches the samples of `[startMicros, endMicros]` as a [SampledProfile],
  /// preferring Perfetto and falling back to JSON.
  Future<SampledProfile> fetchProfile(
    VmApi api, {
    required String isolateId,
    required int startMicros,
    required int endMicros,
    required AppCodeClassifier classifier,
    SampleFormat format = SampleFormat.perfetto,
    GuardFunction? guard,
    void Function(String message)? log,
  }) async {
    final extent = math.max(1, endMicros - startMicros);
    // The RPCs execute on the UI isolate and are guarded; the decode runs
    // elsewhere and is not.
    Future<T> guarded<T>(Future<T> Function() body) =>
        guard == null ? body() : guard(body);
    if (format == SampleFormat.perfetto) {
      try {
        final response = await guarded(
          () => api.getPerfettoCpuSamples(isolateId, startMicros, extent),
        );
        final encoded = response.samples ?? '';
        final compute = _compute;
        final stopwatch = Stopwatch()..start();
        var background = compute != null;
        RawPerfettoProfile raw;
        if (compute == null) {
          raw = PerfettoProfileDecoder.decodeBase64(encoded);
        } else {
          try {
            raw = await _decodeInBackground(compute, encoded);
          } on Object catch (error) {
            log?.call('background decode failed ($error); decoding inline');
            background = false;
            raw = PerfettoProfileDecoder.decodeBase64(encoded);
          }
        }
        log?.call(
          'decoded ${raw.sampleCount} Perfetto samples in '
          '${stopwatch.elapsedMilliseconds} ms'
          '${background ? ' (background isolate)' : ''}',
        );
        final paths = raw.mappingPaths.toList();
        final packageUris = <String, String?>{};
        if (paths.isNotEmpty) {
          try {
            final uris =
                (await guarded(
                  () => api.lookupPackageUris(isolateId, paths),
                )).uris ??
                const <String?>[];
            for (var i = 0; i < paths.length && i < uris.length; i++) {
              packageUris[paths[i]] = uris[i];
            }
          } on Object catch (error) {
            log?.call('lookupPackageUris failed: $error');
          }
        }
        return PerfettoProfileDecoder.toProfileFrom(
          raw,
          classifier: classifier,
          samplePeriodMicros: response.samplePeriod ?? 1000,
          sampleCount: response.sampleCount,
          packageUriByPath: packageUris,
        );
      } on Object catch (error) {
        log?.call(
          'Perfetto samples unavailable ($error); falling back to '
          'getCpuSamples',
        );
      }
    }
    final samples = await guarded(
      () => api.getCpuSamples(isolateId, startMicros, extent),
    );
    return SampledProfile.fromCpuSamples(samples, classifier);
  }

  /// Runs the decode through [compute] from a scope that captures nothing but
  /// the payload: a closure created inside [fetchProfile] would drag the whole
  /// context (the `VmApi`, the logger, …) into the isolate message and be
  /// unsendable.
  static Future<RawPerfettoProfile> _decodeInBackground(
    ComputeFunction compute,
    String encoded,
  ) => compute(() => PerfettoProfileDecoder.decodeBase64(encoded));

  /// Restores the sampling period changed by [ensureProfiler].
  Future<void> restore(VmApi api, ProfilerSetup setup) async {
    final original = setup.originalSamplePeriodMicros;
    if (setup.changedPeriod && original != null) {
      await api.setFlag('profile_period', '$original');
    }
  }
}
