import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/jank/cpu_attribution.dart';
import 'package:dev_tools_light/src/jank/sampled_profile.dart';
import 'package:dev_tools_light/src/vm/function_locator.dart';
import 'package:dev_tools_light/src/vm/function_names.dart' as names;
import 'package:dev_tools_light/src/vm/script_line_resolver.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// The core of "recognise my own code": collapses every sampled stack to the
/// frames that belong to the app.
class CpuSampleAttributor {
  /// Creates an attributor.
  CpuSampleAttributor({required this.classifier, required this.config});

  /// Classifies script URIs.
  final AppCodeClassifier classifier;

  /// Limits for the output.
  final JankDetectionConfig config;

  /// Processes a JSON `CpuSamples` response.
  AttributionDraft attribute(vms.CpuSamples samples) =>
      attributeProfile(SampledProfile.fromCpuSamples(samples, classifier));

  /// Native frames of the VM service serving one of our own RPCs on this
  /// isolate (retaining paths, CPU-sample serialisation).
  static const List<String> serviceMarkers = [
    'dart::Service',
    'dart::ProfilerService',
    'dart::Profile',
    'dart::CpuProfile',
    'dart::JSONStream',
    'dart::ObjectGraph',
    'dart::RetainingPath',
    'dart::Perfetto',
  ];

  /// Processes [profile] into a draft that can still resolve line numbers.
  AttributionDraft attributeProfile(SampledProfile profile) {
    final draft = AttributionDraft(
      source: profile.source,
      sampleCount: profile.sampleCount,
      samplePeriodMicros: profile.samplePeriodMicros,
      functions: {for (final f in profile.functions) f.index: f},
    );
    final tree = draft.tree;
    for (final sample in profile.samples) {
      final tag = sample.vmTag;
      if (tag == 'Idle') {
        draft.idleTicks++;
        continue;
      }
      if (sample.stack.isEmpty) {
        continue;
      }
      final frames = [
        for (final index in sample.stack) profile.functions[index],
      ];
      if (frames.any(
        (f) =>
            f.origin == CodeOrigin.unknown &&
            serviceMarkers.any(f.name.contains),
      )) {
        draft.serviceTicks++;
      }
      if (frames.any((f) => f.origin == CodeOrigin.tooling)) {
        draft.toolingTicks++;
        continue;
      }
      draft.usedSamples++;
      if (tag.startsWith('GC')) {
        draft.gcTicks++;
      } else if (tag.startsWith('Compile')) {
        draft.compileTicks++;
      } else if (tag == 'VM') {
        draft.vmTicks++;
      }
      if (sample.truncated) {
        draft.truncatedSamples++;
      }
      final leaf = frames.first;
      draft.selfTicksByOrigin[leaf.origin] =
          (draft.selfTicksByOrigin[leaf.origin] ?? 0) + 1;
      if (leaf.origin == CodeOrigin.unknown) {
        if (names.isEngineFrame(leaf.name)) {
          draft.engineTicks++;
        } else if (names.isSystemFrame(leaf.name)) {
          draft.systemTicks++;
        }
      }

      final firstApp = frames.indexWhere((f) => f.origin == CodeOrigin.app);
      if (firstApp < 0) {
        draft.ticksWithoutAppCode++;
        draft.otherLeafTicks[leaf.index] =
            (draft.otherLeafTicks[leaf.index] ?? 0) + 1;
        continue;
      }
      draft.ticksWithAppCode++;
      draft.hot(frames[firstApp].index).responsible++;
      final seen = <int>{};
      for (var i = 0; i < frames.length; i++) {
        final frame = frames[i];
        if (frame.origin != CodeOrigin.app) {
          continue;
        }
        if (seen.add(frame.index)) {
          draft.hot(frame.index).inclusive++;
        }
        if (i == 0) {
          draft.hot(frame.index).self++;
        }
      }
      var node = tree;
      var gap = 0;
      var depth = 0;
      for (var i = frames.length - 1; i >= 0; i--) {
        final frame = frames[i];
        if (frame.origin != CodeOrigin.app) {
          // Native/unknown frames are not "framework frames".
          if (frame.origin != CodeOrigin.unknown) {
            gap++;
          }
          continue;
        }
        if (depth++ >= config.maxCallTreeDepth) {
          break;
        }
        node = node.child(frame.index, gap);
        node.ticks++;
        gap = 0;
      }
    }
    return draft;
  }

  /// Fills in missing line numbers of the hottest app functions: through the
  /// script's token table for JSON profiles, or by locating the function in
  /// its library for Perfetto profiles.
  Future<void> resolveLines(
    AttributionDraft draft, {
    required VmApi api,
    required String isolateId,
    required ScriptLineResolver resolver,
    FunctionLocator? locator,
    int maxLookups = 20,
    void Function(String message)? log,
  }) async {
    var lookups = 0;
    for (final index in draft.hotIndicesByResponsibility()) {
      if (lookups >= maxLookups) {
        break;
      }
      final function = draft.functions[index];
      if (function == null || function.line != null) {
        continue;
      }
      final script = function.script;
      final tokenPos = function.tokenPos;
      if (script != null && tokenPos != null) {
        lookups++;
        function.line = await resolver.lineFor(
          api,
          isolateId,
          script,
          tokenPos,
        );
        continue;
      }
      if (locator != null && function.uri.startsWith('package:')) {
        lookups++;
        function.line = await locator.lineFor(
          api,
          isolateId,
          uri: function.uri,
          qualifiedName: function.name,
        );
        if (function.line == null) {
          log?.call(
            'no line for ${function.name} in ${function.uri}: '
            '${locator.lastFailure}',
          );
        }
      } else if (locator != null) {
        log?.call('no line for ${function.name}: uri is ${function.uri}');
      }
    }
  }

  /// Produces the immutable result.
  CpuAttribution finish(AttributionDraft draft) {
    final hot = draft
        .hotIndicesByResponsibility()
        .take(config.maxHotFunctions)
        .map((index) {
          final f = draft.functions[index]!;
          final acc = draft.hot(index);
          return HotFunction(
            name: f.name,
            uri: f.uri,
            location: f.location,
            origin: f.origin,
            responsibleTicks: acc.responsible,
            selfTicks: acc.self,
            inclusiveTicks: acc.inclusive,
          );
        })
        .toList();
    final otherEntries = draft.otherLeafTicks.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final other = otherEntries.take(10).map((entry) {
      final f = draft.functions[entry.key]!;
      return HotFunction(
        name: f.name,
        uri: f.uri,
        location: f.location,
        origin: f.origin,
        responsibleTicks: 0,
        selfTicks: entry.value,
        inclusiveTicks: entry.value,
      );
    }).toList();
    return CpuAttribution(
      source: draft.source,
      sampleCount: draft.sampleCount,
      usedSamples: draft.usedSamples,
      samplePeriodMicros: draft.samplePeriodMicros,
      truncatedSamples: draft.truncatedSamples,
      idleTicks: draft.idleTicks,
      gcTicks: draft.gcTicks,
      compileTicks: draft.compileTicks,
      vmTicks: draft.vmTicks,
      serviceTicks: draft.serviceTicks,
      engineTicks: draft.engineTicks,
      systemTicks: draft.systemTicks,
      toolingTicks: draft.toolingTicks,
      selfTicksByOrigin: Map.unmodifiable(draft.selfTicksByOrigin),
      ticksWithAppCode: draft.ticksWithAppCode,
      ticksWithoutAppCode: draft.ticksWithoutAppCode,
      hotAppFunctions: hot,
      hotOtherFunctions: other,
      appCallTree: _toNodes(draft, draft.tree),
    );
  }

  List<AppCallNode> _toNodes(AttributionDraft draft, TreeNode node) {
    final children = node.children.values.toList()
      ..sort((a, b) => b.ticks.compareTo(a.ticks));
    return [
      for (final child in children)
        AppCallNode(
          name: draft.functions[child.functionIndex]!.name,
          uri: draft.functions[child.functionIndex]!.uri,
          location: draft.functions[child.functionIndex]!.location,
          ticks: child.ticks,
          skippedFrameworkFrames: child.minGap,
          children: _toNodes(draft, child),
        ),
    ];
  }

  /// `Owner.function.<anonymous closure>` for [function].
  static String qualifiedName(vms.FuncRef function) =>
      names.qualifiedFunctionName(function);

  /// Removes `[Optimized] `-style prefixes from a VM function name.
  static String stripCodeTags(String name) => names.stripCodeTags(name);
}

/// Per-function tick counters.
class HotAccumulator {
  /// Samples where this was the nearest app function to the leaf.
  int responsible = 0;

  /// Samples where this was the leaf.
  int self = 0;

  /// Samples with this function anywhere on the stack.
  int inclusive = 0;
}

/// A node of the app-only call trie.
class TreeNode {
  /// Creates a node for [functionIndex] (-1 for the root).
  TreeNode(this.functionIndex);

  /// Index into the profile's functions, or -1.
  final int functionIndex;

  /// Samples through this node.
  int ticks = 0;

  /// Smallest number of framework frames seen between the parent and this
  /// node.
  int minGap = 1 << 30;

  /// Children by function index.
  final Map<int, TreeNode> children = {};

  /// The child for [index], recording [gap].
  TreeNode child(int index, int gap) {
    final node = children.putIfAbsent(index, () => TreeNode(index));
    if (gap < node.minGap) {
      node.minGap = gap;
    }
    return node;
  }
}

/// Mutable intermediate result of [CpuSampleAttributor.attributeProfile].
class AttributionDraft {
  /// Creates a draft.
  AttributionDraft({
    required this.source,
    required this.sampleCount,
    required this.samplePeriodMicros,
    required this.functions,
  });

  /// Where the samples came from.
  final ProfileSource source;

  /// Samples returned by the VM.
  final int sampleCount;

  /// Sampling period.
  final int samplePeriodMicros;

  /// Function descriptions by index.
  final Map<int, FunctionInfo> functions;

  /// Root of the app call trie.
  final TreeNode tree = TreeNode(-1);

  /// Counters per app function index.
  final Map<int, HotAccumulator> hotFunctions = {};

  /// Leaf ticks of samples without app code, by function index.
  final Map<int, int> otherLeafTicks = {};

  /// Leaf ticks by origin.
  final Map<CodeOrigin, int> selfTicksByOrigin = {};

  /// Samples used.
  int usedSamples = 0;

  /// Samples tagged idle.
  int idleTicks = 0;

  /// Samples during GC.
  int gcTicks = 0;

  /// Samples during JIT compilation.
  int compileTicks = 0;

  /// Samples tagged `VM` (runtime-internal work such as service RPCs).
  int vmTicks = 0;

  /// Samples whose leaf is inside the engine / VM binary.
  int engineTicks = 0;

  /// Samples whose leaf is a system library or kernel entry point.
  int systemTicks = 0;

  /// Samples containing tooling frames.
  int toolingTicks = 0;

  /// Samples in which this isolate was serving one of our VM-service RPCs.
  int serviceTicks = 0;

  /// Samples with truncated stacks.
  int truncatedSamples = 0;

  /// Samples with app code.
  int ticksWithAppCode = 0;

  /// Samples without app code.
  int ticksWithoutAppCode = 0;

  /// The counters for app function [index].
  HotAccumulator hot(int index) =>
      hotFunctions.putIfAbsent(index, HotAccumulator.new);

  /// App function indices, most responsible first.
  List<int> hotIndicesByResponsibility() {
    final entries = hotFunctions.entries.toList()
      ..sort((a, b) {
        final byResponsible = b.value.responsible.compareTo(
          a.value.responsible,
        );
        if (byResponsible != 0) {
          return byResponsible;
        }
        return b.value.inclusive.compareTo(a.value.inclusive);
      });
    return [for (final entry in entries) entry.key];
  }
}
