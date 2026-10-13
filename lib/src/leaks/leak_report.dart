import 'package:dev_tools_light/src/leaks/leak_trace.dart';
import 'package:dev_tools_light/src/leaks/watched_kind.dart';
import 'package:meta/meta.dart';

/// Why a leak report has no retaining path.
enum LeakTraceUnavailableReason {
  /// The VM service could not be reached.
  noVmService,

  /// `Service.getObjectId` returned null (no service protocol).
  noObjectId,

  /// The `getRetainingPath` RPC failed.
  rpcError,

  /// The platform does not support retaining paths.
  unsupported;

  /// Human-readable text.
  String get description => switch (this) {
    LeakTraceUnavailableReason.noVmService => 'VM service not connected',
    LeakTraceUnavailableReason.noObjectId => 'no VM object id available',
    LeakTraceUnavailableReason.rpcError => 'getRetainingPath failed',
    LeakTraceUnavailableReason.unsupported => 'unsupported on this platform',
  };
}

/// A detected leak: a watched object that stayed reachable after a GC.
@immutable
class LeakReport {
  /// Creates a report.
  const LeakReport({
    required this.id,
    required this.detectedAt,
    required this.typeName,
    required this.kind,
    required this.signature,
    required this.firstSeen,
    required this.lastSeen,
    this.description,
    this.trace,
    this.traceUnavailableReason,
    this.traceUnavailableDetail,
    this.occurrences = 1,
    this.isLibraryLeak = false,
  });

  /// Unique id of the first occurrence.
  final String id;

  /// When the leak was detected.
  final DateTime detectedAt;

  /// Runtime type of the leaked object.
  final String typeName;

  /// How the object came to be watched.
  final WatchedKind kind;

  /// Optional description given to `DevToolsLight.watch`.
  final String? description;

  /// The leak trace, when one could be obtained.
  final LeakTrace? trace;

  /// Why [trace] is null.
  final LeakTraceUnavailableReason? traceUnavailableReason;

  /// Extra detail for [traceUnavailableReason].
  final String? traceUnavailableDetail;

  /// Groups identical leaks.
  final String signature;

  /// How many times this signature was seen.
  final int occurrences;

  /// First detection.
  final DateTime firstSeen;

  /// Latest detection.
  final DateTime lastSeen;

  /// Whether a known library leak matched.
  final bool isLibraryLeak;

  /// Short title for lists and toasts.
  String get title => 'Leak: $typeName';

  /// One-line explanation for lists and toasts.
  String get subtitle {
    final trace = this.trace;
    if (trace != null) {
      return '← ${trace.summary}';
    }
    final reason = traceUnavailableReason?.description ?? 'unknown';
    return 'retained after GC (no retaining path: $reason)';
  }

  /// Merges a newer detection of the same signature into this report.
  LeakReport merge(LeakReport newer) {
    return LeakReport(
      id: id,
      detectedAt: detectedAt,
      typeName: typeName,
      kind: kind,
      description: description ?? newer.description,
      trace: newer.trace ?? trace,
      traceUnavailableReason: newer.trace != null
          ? null
          : traceUnavailableReason ?? newer.traceUnavailableReason,
      traceUnavailableDetail: newer.trace != null
          ? null
          : traceUnavailableDetail ?? newer.traceUnavailableDetail,
      signature: signature,
      occurrences: occurrences + 1,
      firstSeen: firstSeen,
      lastSeen: newer.lastSeen,
      isLibraryLeak: isLibraryLeak || newer.isLibraryLeak,
    );
  }

  /// Full text report (for copying).
  String toText() {
    final buffer = StringBuffer()
      ..writeln('$title (${kind.label})')
      ..writeln('Detected: $detectedAt, occurrences: $occurrences');
    if (description != null) {
      buffer.writeln('Description: $description');
    }
    if (isLibraryLeak) {
      buffer.writeln('Known library leak.');
    }
    final trace = this.trace;
    if (trace != null) {
      buffer
        ..writeln()
        ..write(trace.toText());
    } else {
      buffer.writeln(subtitle);
      if (traceUnavailableDetail != null) {
        buffer.writeln(traceUnavailableDetail);
      }
    }
    return buffer.toString();
  }
}
