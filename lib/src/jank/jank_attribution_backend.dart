import 'package:dev_tools_light/src/jank/cpu_attribution.dart';
import 'package:dev_tools_light/src/jank/jank_candidate.dart';
import 'package:dev_tools_light/src/jank/slow_operation_report.dart';

/// What attributing one jank candidate produced.
class JankAttributionOutcome {
  /// Creates an outcome.
  const JankAttributionOutcome({
    required this.state,
    this.attribution,
    this.hint,
    this.selfInflicted = false,
    this.rpcMicros = 0,
  });

  /// How attribution went.
  final AttributionState state;

  /// The attribution, when samples were obtained.
  final CpuAttribution? attribution;

  /// Advice for the report when attribution is missing or weak.
  final String? hint;

  /// True when the samples show that this isolate was serving one of our
  /// own RPCs during the window: the candidate is ours and is dropped.
  final bool selfInflicted;

  /// How long the RPCs blocked the UI isolate (drives the cooldown before
  /// the next fetch).
  final int rpcMicros;
}

/// Fetches and attributes CPU samples for a jank window.
///
/// This is the only part of jank detection that needs the VM service; the
/// coordinator works without a backend (release builds) and then reports
/// candidates with [AttributionState.unsupported].
abstract class JankAttributionBackend {
  /// Attributes [candidate]; never throws.
  Future<JankAttributionOutcome> attribute(JankCandidate candidate);

  /// Clears the VM's sample buffer so the next fetch stays cheap (best
  /// effort). With [guarded], the RPC is marked as our own work for the
  /// stall guard; the idle maintenance does not do that, since a guard
  /// interval spanning an await would also swallow genuine app stalls.
  Future<void> clearSampleBuffer({bool guarded = false});
}
