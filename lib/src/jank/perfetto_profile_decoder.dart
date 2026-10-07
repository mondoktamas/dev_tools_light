import 'dart:convert';
import 'dart:typed_data';

import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/jank/sampled_profile.dart';
import 'package:dev_tools_light/src/vm/function_names.dart' as names;
import 'package:vm_service_protos/vm_service_protos.dart' as pf;

/// The sampled stacks of a Perfetto trace flattened to plain lists, so that
/// decoding can run in another isolate and the result is cheap to send back.
class RawPerfettoProfile {
  /// Creates a raw profile.
  RawPerfettoProfile({
    required this.functionNames,
    required this.functionPaths,
    required this.functionLines,
    required this.stacks,
    required this.timestampsMicros,
  });

  /// Function names, indexed by function.
  final List<String> functionNames;

  /// Resolved script path per function (null for native frames), without the
  /// `:line:column` suffix that unoptimized code carries.
  final List<String?> functionPaths;

  /// Line per function, when the path carried one.
  final List<int?> functionLines;

  /// Leaf-first function indices per sample.
  final List<List<int>> stacks;

  /// Timeline-clock timestamp per sample.
  final List<int> timestampsMicros;

  /// Number of samples.
  int get sampleCount => stacks.length;

  /// The script paths referenced by the sampled frames (resolved URIs).
  Set<String> get mappingPaths => {for (final path in functionPaths) ?path};
}

/// Decodes the Perfetto trace returned by `getPerfettoCpuSamples`.
///
/// The VM writes one `InternedData` dictionary per sequence (function names,
/// script paths, mappings, frames, callstacks) and one `PerfSample` packet per
/// sample. Callstacks are root-first and start with the native embedder
/// stack; Dart frames carry their script through the mapping path. Paths are
/// resolved (`file:` / `org-dartlang-sdk:`), so the caller maps them back to
/// `package:` / `dart:` URIs (`lookupPackageUris`) before classification.
class PerfettoProfileDecoder {
  /// Decodes [bytes] (the base64-decoded `samples` field).
  PerfettoProfileDecoder(Uint8List bytes) : raw = decode(bytes);

  /// Wraps an already decoded profile.
  PerfettoProfileDecoder.fromRaw(this.raw);

  /// The flattened trace.
  final RawPerfettoProfile raw;

  /// Native frame names that mean the sample was taken during a GC.
  static const List<String> gcMarkers = [
    'dart::Scavenger',
    'dart::GCMarker',
    'dart::GCSweeper',
    'dart::GCCompactor',
    'dart::Heap::CollectGarbage',
    'dart::Heap::CollectAllGarbage',
    'dart::PageSpace::Collect',
    'dart::MarkingVisitor',
    'dart::ParallelMark',
  ];

  /// Number of samples in the trace.
  int get sampleCount => raw.sampleCount;

  /// The script paths referenced by the sampled frames (resolved URIs).
  Set<String> get mappingPaths => raw.mappingPaths;

  static final RegExp _lineSuffix = RegExp(r'^(.*\.dart):(\d+):(\d+)$');

  /// Splits a mapping path into the script URI and the line the VM appended
  /// to it (unoptimized code carries `:line:column`; optimized code does not).
  static ({String path, int? line}) splitPathAndLine(String raw) {
    final match = _lineSuffix.firstMatch(raw);
    if (match == null) {
      return (path: raw, line: null);
    }
    return (path: match.group(1)!, line: int.tryParse(match.group(2)!));
  }

  /// Decodes the base64 `samples` field. Safe to run in another isolate.
  static RawPerfettoProfile decodeBase64(String encoded) =>
      decode(base64Decode(encoded));

  /// Decodes a trace. Safe to run in another isolate.
  static RawPerfettoProfile decode(Uint8List bytes) {
    final trace = pf.Trace.fromBuffer(bytes);
    final names = <int, String>{};
    final paths = <int, String>{};
    final mappingPath = <int, int>{};
    final frames = <int, pf.Frame>{};
    final callstacks = <int, List<int>>{};
    final samples = <({int timestampMicros, int callstackId})>[];
    for (final packet in trace.packet) {
      if (packet.hasInternedData()) {
        final data = packet.internedData;
        for (final name in data.functionNames) {
          names[name.iid.toInt()] = utf8.decode(name.str, allowMalformed: true);
        }
        for (final path in data.mappingPaths) {
          paths[path.iid.toInt()] = utf8.decode(path.str, allowMalformed: true);
        }
        for (final mapping in data.mappings) {
          if (mapping.pathStringIds.isNotEmpty) {
            mappingPath[mapping.iid.toInt()] = mapping.pathStringIds.first
                .toInt();
          }
        }
        for (final frame in data.frames) {
          frames[frame.iid.toInt()] = frame;
        }
        for (final callstack in data.callstacks) {
          callstacks[callstack.iid.toInt()] = callstack.frameIds
              .map((id) => id.toInt())
              .toList(growable: false);
        }
      }
      if (packet.hasPerfSample()) {
        samples.add((
          timestampMicros: packet.timestamp.toInt() ~/ 1000,
          callstackId: packet.perfSample.callstackIid.toInt(),
        ));
      }
    }

    final functionByFrame = <int, int>{};
    final functionNames = <String>[];
    final functionPaths = <String?>[];
    final functionLines = <int?>[];
    int functionFor(int frameId) {
      return functionByFrame.putIfAbsent(frameId, () {
        final frame = frames[frameId];
        final name = frame == null
            ? '?'
            : names[frame.functionNameId.toInt()] ?? '?';
        String? rawPath;
        if (frame != null) {
          final pathId = mappingPath[frame.mappingId.toInt()];
          rawPath = pathId == null ? null : paths[pathId];
        }
        final split = rawPath == null ? null : splitPathAndLine(rawPath);
        functionNames.add(name);
        functionPaths.add(split?.path);
        functionLines.add(split?.line);
        return functionNames.length - 1;
      });
    }

    final stacks = <List<int>>[];
    final timestamps = <int>[];
    for (final sample in samples) {
      final stack = callstacks[sample.callstackId];
      if (stack == null || stack.isEmpty) {
        continue;
      }
      stacks.add(<int>[
        for (var i = stack.length - 1; i >= 0; i--) functionFor(stack[i]),
      ]);
      timestamps.add(sample.timestampMicros);
    }
    return RawPerfettoProfile(
      functionNames: functionNames,
      functionPaths: functionPaths,
      functionLines: functionLines,
      stacks: stacks,
      timestampsMicros: timestamps,
    );
  }

  /// Builds the profile. [packageUriByPath] maps resolved paths to the
  /// `package:` / `dart:` URIs returned by `lookupPackageUris`.
  SampledProfile toProfile({
    required AppCodeClassifier classifier,
    required int samplePeriodMicros,
    Map<String, String?> packageUriByPath = const {},
    int? sampleCount,
  }) => toProfileFrom(
    raw,
    classifier: classifier,
    samplePeriodMicros: samplePeriodMicros,
    packageUriByPath: packageUriByPath,
    sampleCount: sampleCount,
  );

  /// Classifies the functions of [raw] and builds the profile.
  static SampledProfile toProfileFrom(
    RawPerfettoProfile raw, {
    required AppCodeClassifier classifier,
    required int samplePeriodMicros,
    Map<String, String?> packageUriByPath = const {},
    int? sampleCount,
  }) {
    final functions = <FunctionInfo>[];
    final isGc = <bool>[];
    for (var i = 0; i < raw.functionNames.length; i++) {
      final name = raw.functionNames[i];
      final path = raw.functionPaths[i];
      final uri = path == null ? null : packageUriByPath[path] ?? path;
      functions.add(
        FunctionInfo(
          index: i,
          // The VM prefixes native frame names with `[Native] `; an
          // unprefixed name without a path and without dots is native too.
          name: uri == null && (name.startsWith('[') || !name.contains('.'))
              ? names.nativeDisplayName(name)
              : name,
          uri: uri ?? '',
          origin: uri == null ? CodeOrigin.unknown : classifier.classify(uri),
          line: raw.functionLines[i],
        ),
      );
      isGc.add(gcMarkers.any(name.contains));
    }
    final samples = <ProfileSample>[
      for (var i = 0; i < raw.stacks.length; i++)
        ProfileSample(
          timestampMicros: raw.timestampsMicros[i],
          stack: raw.stacks[i],
          vmTag: raw.stacks[i].any((f) => isGc[f]) ? 'GCOldSpace' : 'Dart',
        ),
    ];
    return SampledProfile(
      source: ProfileSource.perfetto,
      samplePeriodMicros: samplePeriodMicros,
      sampleCount: sampleCount ?? samples.length,
      functions: functions,
      samples: samples,
    );
  }
}
