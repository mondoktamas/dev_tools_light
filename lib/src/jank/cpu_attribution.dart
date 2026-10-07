import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/jank/sampled_profile.dart';
import 'package:meta/meta.dart';

/// A function that showed up in the CPU samples of a slow window.
@immutable
class HotFunction {
  /// Creates a hot function entry.
  const HotFunction({
    required this.name,
    required this.uri,
    required this.origin,
    required this.responsibleTicks,
    required this.selfTicks,
    required this.inclusiveTicks,
    this.location,
  });

  /// `Owner.method` or `outer.<anonymous closure>`.
  final String name;

  /// The script URI.
  final String uri;

  /// `lib/path.dart:line` when known.
  final String? location;

  /// Whether this is app / framework / SDK / package code.
  final CodeOrigin origin;

  /// Samples in which this was the nearest app function to the leaf
  /// ("what the developer should look at").
  final int responsibleTicks;

  /// Samples in which this function was the leaf.
  final int selfTicks;

  /// Samples that had this function anywhere on the stack.
  final int inclusiveTicks;

  /// Returns a copy with [location] replaced.
  HotFunction withLocation(String? location) => HotFunction(
    name: name,
    uri: uri,
    location: location ?? this.location,
    origin: origin,
    responsibleTicks: responsibleTicks,
    selfTicks: selfTicks,
    inclusiveTicks: inclusiveTicks,
  );
}

/// A node of the app-only call tree (root first).
@immutable
class AppCallNode {
  /// Creates a node.
  const AppCallNode({
    required this.name,
    required this.uri,
    required this.ticks,
    required this.skippedFrameworkFrames,
    required this.children,
    this.location,
  });

  /// Function name.
  final String name;

  /// Script URI.
  final String uri;

  /// `lib/path.dart:line` when known.
  final String? location;

  /// Samples passing through this node.
  final int ticks;

  /// Typical number of non-app frames between the parent and this node.
  final int skippedFrameworkFrames;

  /// Callees (app code only), hottest first.
  final List<AppCallNode> children;
}

/// The result of collapsing CPU samples to app code.
@immutable
class CpuAttribution {
  /// Creates an attribution.
  const CpuAttribution({
    required this.sampleCount,
    required this.usedSamples,
    required this.samplePeriodMicros,
    required this.truncatedSamples,
    required this.idleTicks,
    required this.gcTicks,
    required this.compileTicks,
    required this.toolingTicks,
    required this.selfTicksByOrigin,
    required this.ticksWithAppCode,
    required this.ticksWithoutAppCode,
    required this.hotAppFunctions,
    required this.hotOtherFunctions,
    required this.appCallTree,
    this.vmTicks = 0,
    this.serviceTicks = 0,
    this.engineTicks = 0,
    this.systemTicks = 0,
    this.source = ProfileSource.json,
  });

  /// Where the samples came from.
  final ProfileSource source;

  /// Samples the VM returned for the window.
  final int sampleCount;

  /// Samples used after dropping idle and tooling samples.
  final int usedSamples;

  /// The VM sampling period.
  final int samplePeriodMicros;

  /// Samples whose stack was cut at the VM's maximum depth.
  final int truncatedSamples;

  /// Samples tagged idle.
  final int idleTicks;

  /// Samples taken during garbage collection.
  final int gcTicks;

  /// Samples taken while the JIT was compiling (debug builds).
  final int compileTicks;

  /// Samples tagged `VM`: runtime-internal work such as VM-service RPCs
  /// being served by this isolate.
  final int vmTicks;

  /// Samples containing `dev_tools_light` frames (excluded).
  final int toolingTicks;

  /// Samples in which this isolate was serving one of our own VM-service
  /// RPCs (a window dominated by them is our stall, not the app's).
  final int serviceTicks;

  /// Samples whose leaf frame is inside the Flutter engine / Dart VM binary
  /// (unsymbolized on Android): the JIT compiling, the garbage collector,
  /// or the VM service at work.
  final int engineTicks;

  /// Samples whose leaf frame is a system library or kernel entry point
  /// (`syscall`, `munmap`, `libc.so`): memory management or waiting.
  final int systemTicks;

  /// Whether most of the sampled time went to the engine, the VM or system
  /// calls rather than to Dart code of any origin.
  bool get isMostlyEngineWork =>
      usedSamples > 0 && (engineTicks + systemTicks) * 2 >= usedSamples;

  /// Where the leaf frame of each sample lives.
  final Map<CodeOrigin, int> selfTicksByOrigin;

  /// Samples with at least one app frame on the stack.
  final int ticksWithAppCode;

  /// Samples without any app frame (pure framework/SDK work).
  final int ticksWithoutAppCode;

  /// App functions sorted by responsibility.
  final List<HotFunction> hotAppFunctions;

  /// Leaf functions of samples without app code, hottest first.
  final List<HotFunction> hotOtherFunctions;

  /// Call tree restricted to app functions.
  final List<AppCallNode> appCallTree;

  /// Whether any app code was on the UI thread during the window.
  bool get hasAppCode => ticksWithAppCode > 0;

  /// Approximate CPU time covered by [usedSamples].
  Duration get sampledDuration =>
      Duration(microseconds: usedSamples * samplePeriodMicros);

  /// Percentage of [usedSamples] for [ticks].
  double percent(int ticks) => usedSamples == 0 ? 0 : ticks * 100 / usedSamples;
}
