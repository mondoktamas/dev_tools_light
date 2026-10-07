import 'package:dev_tools_light/src/core/clock.dart';
import 'package:dev_tools_light/src/core/internal_marker.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:flutter/widgets.dart';

/// A pending request to open a report's detail page.
class PendingReport {
  /// Creates a request.
  const PendingReport({required this.id, required this.kind});

  /// Report id.
  final String id;

  /// Which category the report belongs to.
  final ReportKind kind;

  /// Whether it is a leak.
  bool get isLeak => kind == ReportKind.leak;
}

/// UI state shared between the engine (back button) and the overlay widgets.
class OverlayController with DevToolsLightInternal {
  /// Creates a controller.
  OverlayController({required Alignment initialAlignment, NowMicros? now})
    : badgeAlignment = InternalValueNotifier<Alignment>(initialAlignment),
      _now = now ?? timelineNowMicros;

  final NowMicros _now;
  int? _panelOpenedAtMicros;
  int? _panelClosedAtMicros;

  /// How long after the panel closes its frames (the closing transition)
  /// still count as the panel's.
  static const Duration panelCloseTail = Duration(seconds: 1);

  /// Whether the report panel is open.
  final ValueNotifier<bool> isPanelOpen = InternalValueNotifier<bool>(false);

  /// Whether the frames in `[startMicros, endMicros]` (timeline clock) were
  /// rendered while the report panel was open or closing. Jank in those
  /// frames is the panel's, not the app's: in debug mode on a phone the
  /// panel's pages are slow to build, and reporting that would schedule
  /// more of its frames.
  bool coversWindow(int startMicros, int endMicros) {
    final openedAt = _panelOpenedAtMicros;
    if (openedAt == null || endMicros < openedAt) {
      return false;
    }
    final closedAt = _panelClosedAtMicros;
    return closedAt == null ||
        startMicros <= closedAt + panelCloseTail.inMicroseconds;
  }

  /// Where the badge sits.
  final ValueNotifier<Alignment> badgeAlignment;

  /// Key of the panel's own navigator.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'dev_tools_light panel',
  );

  /// Invoked by the "Check leaks now" button.
  Future<void> Function()? onCheckLeaksNow;

  /// Invoked by the "Snapshot heap now" button.
  Future<void> Function()? onSnapshotHeapNow;

  /// Invoked by a growing-class report's "Find retaining path" button.
  Future<void> Function(String reportId)? onFetchHeapTrendTrace;

  PendingReport? _pending;

  /// The detail page to open once the panel is built, if any.
  PendingReport? takePendingReport() {
    final pending = _pending;
    _pending = null;
    return pending;
  }

  /// Opens the panel.
  void open() {
    if (!isPanelOpen.value) {
      _panelOpenedAtMicros = _now();
      _panelClosedAtMicros = null;
    }
    isPanelOpen.value = true;
  }

  /// Opens the panel on the given report.
  void openReport({required String id, required ReportKind kind}) {
    _pending = PendingReport(id: id, kind: kind);
    if (isPanelOpen.value) {
      // Panel already open: the pages listen for this.
      pendingChanged.value++;
    } else {
      open();
    }
  }

  /// Bumped when a pending report is set while the panel is open.
  final ValueNotifier<int> pendingChanged = InternalValueNotifier<int>(0);

  /// Closes the panel.
  void close() {
    if (isPanelOpen.value) {
      _panelClosedAtMicros = _now();
    }
    isPanelOpen.value = false;
  }

  /// Handles a back gesture; returns true when it was consumed.
  bool handleBack() {
    if (!isPanelOpen.value) {
      return false;
    }
    final navigator = navigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
    } else {
      close();
    }
    return true;
  }
}

/// A `ValueNotifier` the leak detector ignores.
class InternalValueNotifier<T> extends ValueNotifier<T>
    with DevToolsLightInternal {
  /// Creates the notifier.
  ///
  /// `ValueNotifier`'s constructor parameter is private (`_value`), so a
  /// super parameter cannot share its name.
  // ignore: use_super_parameters
  InternalValueNotifier(T value) : super(value);
}
