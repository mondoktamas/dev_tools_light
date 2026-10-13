import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/leaks/leak_trace.dart';
import 'package:meta/meta.dart';

/// One heap snapshot's numbers for a class.
@immutable
class HeapTrendSample {
  /// Creates a sample.
  const HeapTrendSample({
    required this.at,
    required this.instances,
    required this.bytes,
  });

  /// When the snapshot was taken.
  final DateTime at;

  /// Live instances of the class.
  final int instances;

  /// Bytes used by them (shallow).
  final int bytes;
}

/// Whether a retaining path was fetched for a growing class.
enum HeapTrendTraceState {
  /// Not requested yet.
  notFetched,

  /// A request is in flight.
  fetching,

  /// A trace is available.
  fetched,

  /// The request failed (see the detail).
  failed,
}

/// A class whose number of live instances keeps growing across heap
/// snapshots: a leak suspect even when none of its instances was ever
/// watched.
@immutable
class HeapTrendReport {
  /// Creates a report.
  const HeapTrendReport({
    required this.id,
    required this.className,
    required this.libraryUri,
    required this.origin,
    required this.classId,
    required this.samples,
    required this.firstSeen,
    required this.lastSeen,
    this.trace,
    this.traceState = HeapTrendTraceState.notFetched,
    this.traceDetail,
  });

  /// Unique id.
  final String id;

  /// The growing class.
  final String className;

  /// The library that declares it.
  final String libraryUri;

  /// App / framework / package.
  final CodeOrigin origin;

  /// The VM-service id of the class (for `getInstances`).
  final String classId;

  /// The rising run of snapshots, oldest first.
  final List<HeapTrendSample> samples;

  /// When the class was first reported.
  final DateTime firstSeen;

  /// When the trend was last confirmed.
  final DateTime lastSeen;

  /// Retaining path of one live instance, once fetched.
  final LeakTrace? trace;

  /// State of the retaining-path request.
  final HeapTrendTraceState traceState;

  /// Why [trace] could not be fetched, or how it was found.
  final String? traceDetail;

  /// Groups reports of the same class.
  String get signature => '$libraryUri|$className';

  /// Instances gained over the rising run.
  int get instanceGrowth => samples.last.instances - samples.first.instances;

  /// Bytes gained over the rising run.
  int get bytesGrowth => samples.last.bytes - samples.first.bytes;

  /// Length of the rising run.
  Duration get span => samples.last.at.difference(samples.first.at);

  /// `lib/path.dart` of the declaring library.
  String get location => AppCodeClassifier.displayPath(libraryUri);

  /// Short title for lists and toasts.
  String get title => 'Growing: $className';

  /// One-line explanation for lists and toasts.
  String get subtitle =>
      '+$instanceGrowth instances (${formatBytes(bytesGrowth, signed: true)}) '
      'over '
      '${formatSpan(span)}, now ${samples.last.instances} live';

  /// Returns a copy with the given fields replaced.
  HeapTrendReport copyWith({
    String? classId,
    List<HeapTrendSample>? samples,
    DateTime? lastSeen,
    LeakTrace? trace,
    HeapTrendTraceState? traceState,
    String? traceDetail,
  }) {
    return HeapTrendReport(
      id: id,
      className: className,
      libraryUri: libraryUri,
      origin: origin,
      classId: classId ?? this.classId,
      samples: samples ?? this.samples,
      firstSeen: firstSeen,
      lastSeen: lastSeen ?? this.lastSeen,
      trace: trace ?? this.trace,
      traceState: traceState ?? this.traceState,
      traceDetail: traceDetail ?? this.traceDetail,
    );
  }

  /// Full text report (for copying).
  String toText() {
    final buffer = StringBuffer()
      ..writeln('$title  [${origin.label}]  $location')
      ..writeln(subtitle)
      ..writeln('First seen $firstSeen, last confirmed $lastSeen')
      ..writeln()
      ..writeln('Snapshots:');
    for (final sample in samples) {
      buffer.writeln(
        '  ${sample.at}  ${sample.instances} instances  '
        '${formatBytes(sample.bytes)}',
      );
    }
    final trace = this.trace;
    buffer.writeln();
    if (trace != null) {
      buffer
        ..writeln('Retaining path of one live instance:')
        ..write(trace.toText());
    } else {
      buffer.writeln(
        switch (traceState) {
          HeapTrendTraceState.notFetched =>
            'Retaining path not fetched yet (open the report and tap '
                '"Find retaining path").',
          HeapTrendTraceState.fetching => 'Fetching a retaining path…',
          HeapTrendTraceState.fetched => 'No retaining path.',
          HeapTrendTraceState.failed =>
            'Retaining path unavailable: ${traceDetail ?? 'unknown error'}',
        },
      );
    }
    return buffer.toString();
  }
}

/// `1.2 MB`, `640 KB`, `12 B`; with [signed], a `+`/`-` prefix for deltas.
String formatBytes(int bytes, {bool signed = false}) {
  final sign = bytes < 0 ? '-' : (signed ? '+' : '');
  final value = bytes.abs();
  if (value >= 1024 * 1024) {
    return '$sign${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (value >= 1024) {
    return '$sign${(value / 1024).toStringAsFixed(0)} KB';
  }
  return '$sign$value B';
}

/// `2 min 30 s`, `45 s`.
String formatSpan(Duration span) {
  final minutes = span.inMinutes;
  final seconds = span.inSeconds % 60;
  if (minutes == 0) {
    return '$seconds s';
  }
  return seconds == 0 ? '$minutes min' : '$minutes min $seconds s';
}
