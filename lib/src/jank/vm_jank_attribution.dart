import 'package:dev_tools_light/src/core/clock.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/stall_guard.dart';
import 'package:dev_tools_light/src/jank/cpu_attribution.dart';
import 'package:dev_tools_light/src/jank/cpu_sample_attributor.dart';
import 'package:dev_tools_light/src/jank/jank_attribution_backend.dart';
import 'package:dev_tools_light/src/jank/jank_candidate.dart';
import 'package:dev_tools_light/src/jank/slow_operation_report.dart';
import 'package:dev_tools_light/src/vm/cpu_samples_client.dart';
import 'package:dev_tools_light/src/vm/function_locator.dart';
import 'package:dev_tools_light/src/vm/script_line_resolver.dart';
import 'package:dev_tools_light/src/vm/vm_session.dart';

/// [JankAttributionBackend] on the VM service: fetches the window's CPU
/// samples (Perfetto first, JSON fallback) and collapses them to app code.
class VmJankAttribution implements JankAttributionBackend {
  /// Creates the backend.
  VmJankAttribution({
    required JankDetectionConfig config,
    required VmSession session,
    required CpuSampleAttributor attributor,
    required SelfInflictedStallGuard guard,
    required NowMicros now,
    required String? Function() isolateId,
    CpuSamplesClient samplesClient = const CpuSamplesClient(),
    bool Function()? profilerEnabled,
    ScriptLineResolver? lineResolver,
    void Function(String message)? log,
  }) : _config = config,
       _session = session,
       _attributor = attributor,
       _guard = guard,
       _now = now,
       _isolateId = isolateId,
       _samples = samplesClient,
       _profilerEnabled = profilerEnabled,
       _lineResolver = lineResolver ?? ScriptLineResolver(),
       _log = log {
    _locator = FunctionLocator(lineResolver: _lineResolver);
  }

  final JankDetectionConfig _config;
  final VmSession _session;
  final CpuSampleAttributor _attributor;
  final SelfInflictedStallGuard _guard;
  final NowMicros _now;
  final String? Function() _isolateId;
  final CpuSamplesClient _samples;
  final bool Function()? _profilerEnabled;
  final ScriptLineResolver _lineResolver;
  late final FunctionLocator _locator;
  final void Function(String message)? _log;

  @override
  Future<void> clearSampleBuffer({bool guarded = false}) async {
    final isolateId = _isolateId();
    if (isolateId == null) {
      return;
    }
    try {
      await _session.run(
        (api) => guarded
            ? _guard.guard(() => api.clearCpuSamples(isolateId), label: 'clear')
            : api.clearCpuSamples(isolateId),
      );
    } on Object catch (_) {
      // Not reachable yet; try again later.
    }
  }

  @override
  Future<JankAttributionOutcome> attribute(JankCandidate candidate) async {
    final isolateId = _isolateId();
    if (isolateId == null) {
      return const JankAttributionOutcome(
        state: AttributionState.noVmService,
        hint: 'No VM service isolate id (is the service protocol enabled?).',
      );
    }
    final padding = _config.windowPadding.inMicroseconds;
    var start = candidate.windowStartMicros - padding;
    final end = candidate.windowEndMicros + padding;
    final maxWindow = _config.maxSampleWindow.inMicroseconds;
    if (end - start > maxWindow) {
      start = end - maxWindow;
    }
    // Only the RPCs run on the UI isolate and are guarded; the Perfetto
    // decode runs in a background isolate. The RPC time also drives the
    // cooldown before the next fetch.
    var rpcMicros = 0;
    Future<T> timedGuard<T>(Future<T> Function() body) async {
      final started = _now();
      try {
        return await _guard.guard(body, label: 'samples');
      } finally {
        rpcMicros += _now() - started;
      }
    }

    try {
      final result = await _session.run<CpuAttribution>((api) async {
        final fetchStart = _now();
        final profile = await _samples.fetchProfile(
          api,
          isolateId: isolateId,
          startMicros: start,
          endMicros: end,
          classifier: _attributor.classifier,
          format: _config.sampleFormat,
          guard: timedGuard,
          log: _log,
        );
        final fetchMicros = _now() - fetchStart;
        _log?.call(
          'CPU samples ready after ${fetchMicros ~/ 1000} ms '
          '(RPCs ${rpcMicros ~/ 1000} ms)',
        );
        return _guard.guard<CpuAttribution>(() async {
          final draft = _attributor.attributeProfile(profile);
          await _attributor.resolveLines(
            draft,
            api: api,
            isolateId: isolateId,
            resolver: _lineResolver,
            locator: _locator,
            log: _log,
          );
          return _attributor.finish(draft);
        }, label: 'attribution');
      });
      if (result.sampleCount >= _config.minSamples &&
          result.serviceTicks * 2 >= result.sampleCount) {
        // This isolate was serving one of our own RPCs: the guard missed it
        // (an inflated section) but the samples do not lie.
        return JankAttributionOutcome(
          state: AttributionState.attributed,
          attribution: result,
          selfInflicted: true,
          rpcMicros: rpcMicros,
          hint:
              '${result.serviceTicks}/${result.sampleCount} samples served '
              'the VM service',
        );
      }
      if (result.usedSamples < _config.minSamples) {
        return JankAttributionOutcome(
          state: AttributionState.insufficientSamples,
          attribution: result,
          rpcMicros: rpcMicros,
          hint: (_profilerEnabled?.call() ?? false)
              ? 'Only ${result.usedSamples} CPU samples in this window: '
                    'the UI thread was mostly idle or blocked outside Dart '
                    '(waiting for the raster thread, a platform channel or '
                    'I/O).'
              : 'Only ${result.usedSamples} CPU samples in this window. '
                    'Make sure the VM profiler is enabled, use profile '
                    'mode, or lower the sampling period.',
        );
      }
      return JankAttributionOutcome(
        state: AttributionState.attributed,
        attribution: result,
        rpcMicros: rpcMicros,
      );
    } on VmUnavailableException catch (error) {
      return JankAttributionOutcome(
        state: AttributionState.noVmService,
        rpcMicros: rpcMicros,
        hint: 'CPU samples unavailable: ${error.message}',
      );
    } on Object catch (error) {
      final hint = 'Fetching CPU samples failed: $error';
      _log?.call(hint);
      return JankAttributionOutcome(
        state: AttributionState.failed,
        rpcMicros: rpcMicros,
        hint: hint,
      );
    }
  }
}
