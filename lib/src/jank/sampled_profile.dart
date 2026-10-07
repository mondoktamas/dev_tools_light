import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/vm/function_names.dart' as names;
import 'package:vm_service/vm_service.dart' as vms;

/// Where a [SampledProfile] came from.
enum ProfileSource {
  /// `getCpuSamples` (JSON; carries token positions and line numbers).
  json,

  /// `getPerfettoCpuSamples` (protobuf; ~20× smaller, no line numbers).
  perfetto,
}

/// A sampled function as seen by the attributor.
class FunctionInfo {
  /// Creates a function description.
  FunctionInfo({
    required this.index,
    required this.name,
    required this.uri,
    required this.origin,
    this.script,
    this.tokenPos,
    this.line,
  });

  /// Index into [SampledProfile.functions].
  final int index;

  /// Qualified name (`Owner.method`, `outer.<anonymous closure>`).
  final String name;

  /// Script URI (`package:`, `dart:`, or a resolved `file:` URI).
  final String uri;

  /// Classification.
  final CodeOrigin origin;

  /// Script reference for line lookups (JSON profiles only).
  final vms.ScriptRef? script;

  /// Token position for line lookups (JSON profiles only).
  final int? tokenPos;

  /// Line number, when known.
  int? line;

  /// `lib/path.dart:line`, when the line is known.
  String? get location =>
      line == null ? null : '${AppCodeClassifier.displayPath(uri)}:$line';
}

/// One CPU sample: a stack of function indices, leaf first.
class ProfileSample {
  /// Creates a sample.
  const ProfileSample({
    required this.timestampMicros,
    required this.stack,
    this.vmTag = 'Dart',
    this.truncated = false,
  });

  /// Timeline-clock timestamp.
  final int timestampMicros;

  /// Function indices, leaf (top of stack) first.
  final List<int> stack;

  /// The VM tag (`Dart`, `Native`, `GC…`, `Idle`, `VM`, …).
  final String vmTag;

  /// Whether the stack was cut at the VM's maximum depth.
  final bool truncated;
}

/// CPU samples of a time window in a source-independent form.
class SampledProfile {
  /// Creates a profile.
  SampledProfile({
    required this.source,
    required this.samplePeriodMicros,
    required this.sampleCount,
    required this.functions,
    required this.samples,
  });

  /// Converts a JSON `CpuSamples` response, keeping only the functions that
  /// samples reference (the response carries the isolate's whole table).
  factory SampledProfile.fromCpuSamples(
    vms.CpuSamples raw,
    AppCodeClassifier classifier,
  ) {
    final rawFunctions = raw.functions ?? const <vms.ProfileFunction>[];
    final compact = <int, int>{};
    final functions = <FunctionInfo>[];
    final samples = <ProfileSample>[];
    for (final sample in raw.samples ?? const <vms.CpuSample>[]) {
      final stack = <int>[];
      for (final index in sample.stack ?? const <int>[]) {
        stack.add(
          compact.putIfAbsent(index, () {
            functions.add(
              describeProfileFunction(
                functions.length,
                index < rawFunctions.length ? rawFunctions[index] : null,
                classifier,
              ),
            );
            return functions.length - 1;
          }),
        );
      }
      samples.add(
        ProfileSample(
          timestampMicros: sample.timestamp ?? 0,
          stack: stack,
          vmTag: sample.vmTag ?? '',
          truncated: sample.truncated ?? false,
        ),
      );
    }
    return SampledProfile(
      source: ProfileSource.json,
      samplePeriodMicros: raw.samplePeriod ?? 1000,
      sampleCount: raw.sampleCount ?? samples.length,
      functions: functions,
      samples: samples,
    );
  }

  /// Origin of the data.
  final ProfileSource source;

  /// The VM sampling period.
  final int samplePeriodMicros;

  /// Samples the VM reported for the window.
  final int sampleCount;

  /// Functions referenced by [samples].
  final List<FunctionInfo> functions;

  /// The samples, each a leaf-first stack of indices into [functions].
  final List<ProfileSample> samples;

  /// Describes a JSON `ProfileFunction`, teaching [classifier] the app's
  /// `file:` root when both URI forms are present.
  static FunctionInfo describeProfileFunction(
    int index,
    vms.ProfileFunction? profile,
    AppCodeClassifier classifier,
  ) {
    final Object? function = profile?.function;
    if (function is vms.FuncRef) {
      final location = function.location;
      final scriptUri = location?.script?.uri;
      final resolved = profile?.resolvedUrl;
      if (scriptUri != null && resolved != null) {
        classifier.learnAppFileRoot(packageUri: scriptUri, fileUri: resolved);
      }
      final uri = scriptUri ?? resolved ?? '';
      return FunctionInfo(
        index: index,
        name: names.qualifiedFunctionName(function),
        uri: uri,
        origin: classifier.classify(uri),
        script: location?.script,
        tokenPos: location?.tokenPos,
        line: location?.line,
      );
    }
    if (function is vms.NativeFunction) {
      return FunctionInfo(
        index: index,
        name: names.nativeDisplayName(function.name),
        uri: profile?.resolvedUrl ?? '',
        origin: CodeOrigin.unknown,
      );
    }
    return FunctionInfo(
      index: index,
      name: profile?.resolvedUrl ?? '<unknown>',
      uri: profile?.resolvedUrl ?? '',
      origin: CodeOrigin.unknown,
    );
  }
}
