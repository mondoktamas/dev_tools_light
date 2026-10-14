import 'dart:async';

import 'package:dev_tools_light/src/core/internal_marker.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/ui/heap_trend_detail_page.dart';
import 'package:dev_tools_light/src/ui/leak_detail_page.dart';
import 'package:dev_tools_light/src/ui/overlay_controller.dart';
import 'package:dev_tools_light/src/ui/reports_page.dart';
import 'package:dev_tools_light/src/ui/slow_op_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The full-screen report panel with its own navigator.
///
/// It lives above the host app's navigator (inside `MaterialApp.builder`), so
/// it brings its own `Navigator` (and therefore `Overlay`) and opts out of the
/// host's `HeroController`.
class ReportsPanel extends StatefulWidget {
  /// Creates the panel.
  const ReportsPanel({
    required this.store,
    required this.controller,
    super.key,
  });

  /// Findings.
  final ReportStore store;

  /// Shared UI state.
  final OverlayController controller;

  @override
  State<ReportsPanel> createState() => _ReportsPanelState();
}

class _ReportsPanelState extends State<ReportsPanel>
    with DevToolsLightInternal {
  @override
  void initState() {
    super.initState();
    widget.controller.pendingChanged.addListener(_openPending);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPending());
  }

  @override
  void dispose() {
    widget.controller.pendingChanged.removeListener(_openPending);
    super.dispose();
  }

  void _openPending() {
    final pending = widget.controller.takePendingReport();
    final navigator = widget.controller.navigatorKey.currentState;
    if (pending == null || navigator == null) {
      return;
    }
    navigator.popUntil((route) => route.isFirst);
    final Widget? page = switch (pending.kind) {
      ReportKind.leak => switch (widget.store.leakById(pending.id)) {
        final report? => LeakDetailPage(report: report),
        null => null,
      },
      ReportKind.slowOp =>
        widget.store.slowOpById(pending.id) == null
            ? null
            : SlowOpDetailPage(reportId: pending.id, store: widget.store),
      ReportKind.heapTrend =>
        widget.store.heapTrendById(pending.id) == null
            ? null
            : HeapTrendDetailPage(
                reportId: pending.id,
                store: widget.store,
                controller: widget.controller,
              ),
    };
    if (page != null) {
      // The route's result is not needed.
      navigator.push(MaterialPageRoute<void>(builder: (_) => page)).ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape):
            widget.controller.handleBack,
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: HeroControllerScope.none(
            child: Navigator(
              key: widget.controller.navigatorKey,
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => ReportsPage(
                  store: widget.store,
                  controller: widget.controller,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
