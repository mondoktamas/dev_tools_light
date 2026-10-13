import 'package:dev_tools_light/src/jank/cpu_attribution.dart';
import 'package:dev_tools_light/src/jank/jank_candidate.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:meta/meta.dart';

/// Whether and how a slow operation was attributed to code.
enum AttributionState {
  /// CPU samples were collapsed to app code.
  attributed,

  /// Too few samples in the window.
  insufficientSamples,

  /// The VM service was not reachable.
  noVmService,

  /// Not attributable (raster thread).
  notAttributable,

  /// The frame clock was not calibrated yet.
  uncalibrated,

  /// Fetching or processing samples failed.
  failed,

  /// Not attributed: too many janks were queued for attribution on this
  /// device, and this was the least significant one.
  skipped,

  /// Not attributable in this build (release mode has no VM service).
  unsupported,
}

/// A slow operation (janky frame or UI stall) with its attribution.
@immutable
class SlowOperationReport {
  /// Creates a report.
  const SlowOperationReport({
    required this.id,
    required this.detectedAt,
    required this.kinds,
    required this.windowStartMicros,
    required this.windowEndMicros,
    required this.attributionState,
    required this.signature,
    required this.firstSeen,
    required this.lastSeen,
    this.buildDuration,
    this.rasterDuration,
    this.vsyncOverhead,
    this.stallLateness,
    this.frameNumber,
    this.attribution,
    this.attributionHint,
    this.occurrences = 1,
  });

  /// Unique id of the first occurrence.
  final String id;

  /// When it was detected.
  final DateTime detectedAt;

  /// Kinds of slowness observed.
  final Set<JankKind> kinds;

  /// Start of the window (timeline clock).
  final int windowStartMicros;

  /// End of the window (timeline clock).
  final int windowEndMicros;

  /// UI-thread build duration, if a frame.
  final Duration? buildDuration;

  /// Raster duration, if a frame.
  final Duration? rasterDuration;

  /// Vsync-to-build-start delay, if a frame.
  final Duration? vsyncOverhead;

  /// Heartbeat lateness, if a UI stall.
  final Duration? stallLateness;

  /// Engine frame number, if a frame.
  final int? frameNumber;

  /// CPU-sample attribution, when available.
  final CpuAttribution? attribution;

  /// How attribution went.
  final AttributionState attributionState;

  /// Advice when attribution is missing or weak.
  final String? attributionHint;

  /// Groups identical operations.
  final String signature;

  /// How many times this signature was seen.
  final int occurrences;

  /// First detection.
  final DateTime firstSeen;

  /// Latest detection.
  final DateTime lastSeen;

  /// The window length.
  Duration get duration =>
      Duration(microseconds: windowEndMicros - windowStartMicros);

  /// The most meaningful duration for display.
  Duration get headlineDuration {
    final candidates = [
      buildDuration,
      rasterDuration,
      vsyncOverhead,
      stallLateness,
    ].whereType<Duration>();
    return candidates.fold(
      Duration.zero,
      (max, d) => d > max ? d : max,
    );
  }

  /// The top responsible app function, if any.
  HotFunction? get topAppFunction {
    final hot = attribution?.hotAppFunctions;
    return hot == null || hot.isEmpty ? null : hot.first;
  }

  /// Short title for lists and toasts.
  String get title {
    final kind = kinds.contains(JankKind.uiStall)
        ? JankKind.uiStall
        : kinds.contains(JankKind.slowBuild)
        ? JankKind.slowBuild
        : kinds.contains(JankKind.delayedFrame)
        ? JankKind.delayedFrame
        : kinds.first;
    return '${kind.label} ${headlineDuration.inMilliseconds} ms';
  }

  /// One-line explanation for lists and toasts.
  String get subtitle {
    if (attributionState != AttributionState.attributed) {
      return attributionHint ?? attributionState.name;
    }
    final attribution = this.attribution;
    final top = topAppFunction;
    if (attribution != null && top != null) {
      final location = top.location == null ? '' : ' (${top.location})';
      final share = attribution.percent(top.responsibleTicks);
      if (share >= 20) {
        return 'in ${top.name}$location';
      }
      return 'mostly framework/SDK work; app: ${top.name}$location '
          '${share.toStringAsFixed(0)}%';
    }
    if (attribution != null && !attribution.hasAppCode) {
      if (attribution.usedSamples > 0 &&
          attribution.gcTicks * 2 >= attribution.usedSamples) {
        return 'garbage collection pause '
            '(${attribution.percent(attribution.gcTicks).toStringAsFixed(0)}% '
            'of samples in GC)';
      }
      if (attribution.usedSamples > 0 &&
          attribution.vmTicks * 2 >= attribution.usedSamples) {
        return 'Dart VM internal work, e.g. a VM-service RPC '
            '(${attribution.percent(attribution.vmTicks).toStringAsFixed(0)}% '
            'of samples tagged VM)';
      }
      if (attribution.isMostlyEngineWork) {
        final share = attribution.percent(
          attribution.engineTicks + attribution.systemTicks,
        );
        return 'no app code on the UI thread: ${share.toStringAsFixed(0)}% '
            'of the time inside the Flutter engine / Dart VM or in system '
            'calls '
            '${kDebugMode ? '(JIT compilation, garbage collection, the VM '
                      'service, waiting on the raster thread); normal in a '
                      'debug build' : '(garbage collection, the VM service, '
                      'waiting on the raster thread, a lock or I/O)'}';
      }
      final other = attribution.hotOtherFunctions;
      if (other.isNotEmpty) {
        return 'no app code on the UI thread; time in ${other.first.name}';
      }
      return 'no app code on the UI thread';
    }
    return attributionHint ?? attributionState.name;
  }

  /// Merges a newer occurrence of the same signature into this report.
  SlowOperationReport merge(SlowOperationReport newer) {
    final keepNewer = newer.headlineDuration >= headlineDuration;
    return SlowOperationReport(
      id: id,
      detectedAt: detectedAt,
      kinds: {...kinds, ...newer.kinds},
      windowStartMicros: keepNewer
          ? newer.windowStartMicros
          : windowStartMicros,
      windowEndMicros: keepNewer ? newer.windowEndMicros : windowEndMicros,
      buildDuration: _max(buildDuration, newer.buildDuration),
      rasterDuration: _max(rasterDuration, newer.rasterDuration),
      vsyncOverhead: _max(vsyncOverhead, newer.vsyncOverhead),
      stallLateness: _max(stallLateness, newer.stallLateness),
      frameNumber: keepNewer ? newer.frameNumber : frameNumber,
      attribution: newer.attribution ?? attribution,
      attributionState: newer.attribution != null
          ? newer.attributionState
          : attributionState,
      attributionHint: newer.attribution != null
          ? newer.attributionHint
          : attributionHint,
      signature: signature,
      occurrences: occurrences + 1,
      firstSeen: firstSeen,
      lastSeen: newer.lastSeen,
    );
  }

  static Duration? _max(Duration? a, Duration? b) {
    if (a == null) {
      return b;
    }
    if (b == null) {
      return a;
    }
    return a > b ? a : b;
  }

  /// Full text report (for copying).
  String toText() {
    final buffer = StringBuffer()
      ..writeln(title)
      ..writeln('Kinds: ${kinds.map((k) => k.label).join(', ')}')
      ..writeln(
        'Window: ${duration.inMilliseconds} ms, detected $detectedAt, '
        'occurrences: $occurrences',
      );
    if (buildDuration != null) {
      buffer.writeln('Build: ${buildDuration!.inMilliseconds} ms');
    }
    if (rasterDuration != null) {
      buffer.writeln('Raster: ${rasterDuration!.inMilliseconds} ms');
    }
    if (vsyncOverhead != null) {
      buffer.writeln('Vsync overhead: ${vsyncOverhead!.inMilliseconds} ms');
    }
    if (stallLateness != null) {
      buffer.writeln('Stall: ${stallLateness!.inMilliseconds} ms');
    }
    final attribution = this.attribution;
    if (attribution == null) {
      buffer.writeln('Attribution: ${attributionState.name}');
      if (attributionHint != null) {
        buffer.writeln(attributionHint);
      }
      return buffer.toString();
    }
    buffer
      ..writeln(
        'Samples: ${attribution.usedSamples}/${attribution.sampleCount} '
        '@ ${attribution.samplePeriodMicros} µs (${attribution.source.name})'
        '${attribution.gcTicks > 0 ? ', ${attribution.gcTicks} in GC' : ''}'
        '${attribution.vmTicks > 0 ? ', ${attribution.vmTicks} in VM' : ''}'
        '${attribution.serviceTicks > 0 ? ', ${attribution.serviceTicks} '
                  'serving the VM service' : ''}',
      )
      ..writeln();
    String pct(int ticks) =>
        attribution.percent(ticks).toStringAsFixed(0).padLeft(3);
    if (attribution.hasAppCode) {
      buffer.writeln('Hot app functions (responsible / self / inclusive):');
      for (final f in attribution.hotAppFunctions) {
        buffer.writeln(
          '  ${pct(f.responsibleTicks)}% ${pct(f.selfTicks)}% '
          '${pct(f.inclusiveTicks)}%  '
          '${f.name}${f.location == null ? '' : '  ${f.location}'}',
        );
      }
      buffer
        ..writeln()
        ..writeln('App call tree:');
      _writeTree(buffer, attribution, attribution.appCallTree, 1);
    } else {
      buffer.writeln('No app code was on the UI thread during this window.');
      if (attribution.isMostlyEngineWork) {
        buffer.writeln(
          '${attribution.percent(attribution.engineTicks).toStringAsFixed(0)}% '
          'of the samples were inside the Flutter engine / Dart VM and '
          '${attribution.percent(attribution.systemTicks).toStringAsFixed(0)}% '
          'in system calls: garbage collection, the VM service, or waiting '
          '(on the raster thread, a lock, I/O)'
          '${kDebugMode ? ', and in a debug build above all JIT compilation '
                    'of code on first use; profile mode shows what '
                    'remains.' : '.'}',
        );
      }
      for (final f in attribution.hotOtherFunctions) {
        buffer.writeln(
          '  ${pct(f.selfTicks)}%  ${f.name}  [${f.origin.label}]',
        );
      }
    }
    buffer
      ..writeln()
      ..writeln('Where the leaf frames were:');
    for (final entry in attribution.selfTicksByOrigin.entries) {
      buffer.writeln(
        '  ${entry.key.label.padRight(8)} '
        '${attribution.percent(entry.value).toStringAsFixed(0)}%',
      );
    }
    return buffer.toString();
  }

  void _writeTree(
    StringBuffer buffer,
    CpuAttribution attribution,
    List<AppCallNode> nodes,
    int depth,
  ) {
    for (final node in nodes) {
      final indent = '  ' * depth;
      if (node.skippedFrameworkFrames > 0) {
        buffer.writeln(
          '$indent· ${node.skippedFrameworkFrames} framework frames',
        );
      }
      buffer.writeln(
        '$indent▸ ${node.name}'
        '${node.location == null ? '' : '  ${node.location}'}'
        '  ${attribution.percent(node.ticks).toStringAsFixed(0)}%',
      );
      _writeTree(buffer, attribution, node.children, depth + 1);
    }
  }
}
