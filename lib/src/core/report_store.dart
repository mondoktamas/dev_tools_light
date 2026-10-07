import 'package:dev_tools_light/src/core/internal_marker.dart';
import 'package:dev_tools_light/src/core/status.dart';
import 'package:dev_tools_light/src/jank/slow_operation_report.dart';
import 'package:dev_tools_light/src/leaks/heap_trend_report.dart';
import 'package:dev_tools_light/src/leaks/leak_report.dart';
import 'package:flutter/foundation.dart';

/// The categories of findings.
enum ReportKind {
  /// A [LeakReport].
  leak,

  /// A [SlowOperationReport].
  slowOp,

  /// A [HeapTrendReport].
  heapTrend,
}

/// A new finding to announce briefly in the overlay.
@immutable
class ToastEvent {
  /// Creates a toast event.
  const ToastEvent({
    required this.reportId,
    required this.title,
    required this.subtitle,
    required this.kind,
  });

  /// The report the toast opens when tapped.
  final String reportId;

  /// Headline.
  final String title;

  /// Detail line.
  final String subtitle;

  /// Which category [reportId] belongs to.
  final ReportKind kind;

  /// Whether [reportId] is a leak.
  bool get isLeak => kind == ReportKind.leak;
}

class _StatusNotifier extends ValueNotifier<DevToolsLightStatus>
    with DevToolsLightInternal {
  _StatusNotifier() : super(const DevToolsLightStatus());
}

/// Holds every finding plus the engine status; the overlay listens to it.
///
/// Listeners of the store itself are notified about reports only. The
/// status, which the engine refreshes every second, notifies
/// [statusListenable] instead, so that report pages do not rebuild on every
/// tick (in debug mode on a phone such a rebuild is a jank of its own).
class ReportStore extends ChangeNotifier with DevToolsLightInternal {
  /// Creates a store keeping at most [maxReportsPerCategory] per category.
  ReportStore({this.maxReportsPerCategory = 100});

  /// Cap per category (oldest are dropped).
  final int maxReportsPerCategory;

  /// Notifies when [status] changes.
  final ValueNotifier<DevToolsLightStatus> statusListenable = _StatusNotifier();

  final List<LeakReport> _leaks = [];
  final List<SlowOperationReport> _slowOps = [];
  final List<HeapTrendReport> _heapTrends = [];
  final List<ToastEvent> _toasts = [];
  int _unseenLeaks = 0;
  int _unseenSlowOps = 0;
  int _unseenHeapTrends = 0;

  /// Leak reports, newest first.
  List<LeakReport> get leaks => List.unmodifiable(_leaks);

  /// Slow-operation reports, newest first.
  List<SlowOperationReport> get slowOps => List.unmodifiable(_slowOps);

  /// Growing-class reports, most recently updated first.
  List<HeapTrendReport> get heapTrends => List.unmodifiable(_heapTrends);

  /// Leaks added since [markLeaksSeen].
  int get unseenLeaks => _unseenLeaks;

  /// Slow operations added since [markSlowOpsSeen].
  int get unseenSlowOps => _unseenSlowOps;

  /// Growing classes added since [markHeapTrendsSeen].
  int get unseenHeapTrends => _unseenHeapTrends;

  /// Toasts not yet shown, oldest first.
  List<ToastEvent> get pendingToasts => List.unmodifiable(_toasts);

  /// The engine status (changes notify [statusListenable]).
  DevToolsLightStatus get status => statusListenable.value;

  set status(DevToolsLightStatus value) => statusListenable.value = value;

  /// Applies [update] to the status.
  void updateStatus(
    DevToolsLightStatus Function(DevToolsLightStatus status) update,
  ) {
    status = update(status);
  }

  /// Adds or merges a leak report (by signature).
  void addLeak(LeakReport report) {
    final index = _leaks.indexWhere((r) => r.signature == report.signature);
    if (index >= 0) {
      final merged = _leaks[index].merge(report);
      _leaks
        ..removeAt(index)
        ..insert(0, merged);
    } else {
      _leaks.insert(0, report);
      if (_leaks.length > maxReportsPerCategory) {
        _leaks.removeLast();
      }
      _unseenLeaks++;
      _toasts.add(
        ToastEvent(
          reportId: report.id,
          title: report.title,
          subtitle: report.subtitle,
          kind: ReportKind.leak,
        ),
      );
    }
    notifyListeners();
  }

  /// Adds or merges a slow-operation report (by signature). With [announce]
  /// false the report is listed but gets no toast and no unseen highlight.
  void addSlowOp(SlowOperationReport report, {bool announce = true}) {
    final index = _slowOps.indexWhere((r) => r.signature == report.signature);
    if (index >= 0) {
      final merged = _slowOps[index].merge(report);
      _slowOps
        ..removeAt(index)
        ..insert(0, merged);
    } else {
      _slowOps.insert(0, report);
      if (_slowOps.length > maxReportsPerCategory) {
        _slowOps.removeLast();
      }
      if (announce) {
        _unseenSlowOps++;
        _toasts.add(
          ToastEvent(
            reportId: report.id,
            title: report.title,
            subtitle: report.subtitle,
            kind: ReportKind.slowOp,
          ),
        );
      }
    }
    notifyListeners();
  }

  /// Replaces the slow-operation report with [id] using [update].
  void updateSlowOp(
    String id,
    SlowOperationReport Function(SlowOperationReport report) update,
  ) {
    final index = _slowOps.indexWhere((r) => r.id == id);
    if (index < 0) {
      return;
    }
    _slowOps[index] = update(_slowOps[index]);
    notifyListeners();
  }

  /// Adds a growing-class report, or refreshes the existing one for the same
  /// class (keeping its id, first-seen time and fetched trace).
  void addHeapTrend(HeapTrendReport report) {
    final index = _heapTrends.indexWhere(
      (r) => r.signature == report.signature,
    );
    if (index >= 0) {
      final existing = _heapTrends[index];
      _heapTrends
        ..removeAt(index)
        ..insert(
          0,
          existing.copyWith(
            classId: report.classId,
            samples: report.samples,
            lastSeen: report.lastSeen,
          ),
        );
    } else {
      _heapTrends.insert(0, report);
      if (_heapTrends.length > maxReportsPerCategory) {
        _heapTrends.removeLast();
      }
      _unseenHeapTrends++;
      _toasts.add(
        ToastEvent(
          reportId: report.id,
          title: report.title,
          subtitle: report.subtitle,
          kind: ReportKind.heapTrend,
        ),
      );
    }
    notifyListeners();
  }

  /// Replaces the growing-class report with [id] using [update].
  void updateHeapTrend(
    String id,
    HeapTrendReport Function(HeapTrendReport report) update,
  ) {
    final index = _heapTrends.indexWhere((r) => r.id == id);
    if (index < 0) {
      return;
    }
    _heapTrends[index] = update(_heapTrends[index]);
    notifyListeners();
  }

  /// The growing-class report with [id], if present.
  HeapTrendReport? heapTrendById(String id) {
    for (final report in _heapTrends) {
      if (report.id == id) {
        return report;
      }
    }
    return null;
  }

  /// The leak report with [id], if present.
  LeakReport? leakById(String id) {
    for (final report in _leaks) {
      if (report.id == id) {
        return report;
      }
    }
    return null;
  }

  /// The slow-operation report with [id], if present.
  SlowOperationReport? slowOpById(String id) {
    for (final report in _slowOps) {
      if (report.id == id) {
        return report;
      }
    }
    return null;
  }

  /// Removes and returns the oldest pending toast.
  ToastEvent? takeToast() => _toasts.isEmpty ? null : _toasts.removeAt(0);

  /// Resets the unseen leak counter.
  void markLeaksSeen() {
    if (_unseenLeaks == 0) {
      return;
    }
    _unseenLeaks = 0;
    notifyListeners();
  }

  /// Resets the unseen slow-operation counter.
  void markSlowOpsSeen() {
    if (_unseenSlowOps == 0) {
      return;
    }
    _unseenSlowOps = 0;
    notifyListeners();
  }

  /// Resets the unseen growing-class counter.
  void markHeapTrendsSeen() {
    if (_unseenHeapTrends == 0) {
      return;
    }
    _unseenHeapTrends = 0;
    notifyListeners();
  }

  /// Removes all reports.
  void clear() {
    _leaks.clear();
    _slowOps.clear();
    _heapTrends.clear();
    _toasts.clear();
    _unseenLeaks = 0;
    _unseenSlowOps = 0;
    _unseenHeapTrends = 0;
    notifyListeners();
  }
}
