import 'dart:async';

import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/internal_marker.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/ui/overlay_controller.dart';
import 'package:flutter/material.dart';

/// Shows a transient banner for each new finding.
class ToastLayer extends StatefulWidget {
  /// Creates the layer.
  const ToastLayer({
    required this.store,
    required this.controller,
    required this.config,
    super.key,
  });

  /// Findings.
  final ReportStore store;

  /// Shared UI state.
  final OverlayController controller;

  /// Overlay settings.
  final OverlayConfig config;

  @override
  State<ToastLayer> createState() => _ToastLayerState();
}

class _ToastLayerState extends State<ToastLayer> with DevToolsLightInternal {
  ToastEvent? _current;
  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
    _onStoreChanged();
  }

  @override
  void didUpdateWidget(ToastLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _timer?.cancel();
    super.dispose();
  }

  void _onStoreChanged() {
    if (_current != null) {
      return;
    }
    final next = widget.store.takeToast();
    if (next == null) {
      return;
    }
    setState(() {
      _current = next;
      _visible = true;
    });
    _timer?.cancel();
    _timer = Timer(widget.config.toastDuration, _hide);
  }

  void _hide() {
    if (!mounted) {
      return;
    }
    setState(() => _visible = false);
    _timer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) {
        return;
      }
      setState(() => _current = null);
      _onStoreChanged();
    });
  }

  @override
  Widget build(BuildContext context) {
    final toast = _current;
    if (toast == null) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: AnimatedSlide(
          offset: _visible ? Offset.zero : const Offset(0, -1.5),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Material(
              color: scheme.inverseSurface,
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  _timer?.cancel();
                  widget.controller.openReport(
                    id: toast.reportId,
                    kind: toast.kind,
                  );
                  _hide();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        switch (toast.kind) {
                          ReportKind.leak => Icons.water_drop,
                          ReportKind.slowOp => Icons.speed,
                          ReportKind.heapTrend => Icons.trending_up,
                        },
                        color: scheme.onInverseSurface,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              toast.title,
                              style: TextStyle(
                                color: scheme.onInverseSurface,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              toast.subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: scheme.onInverseSurface,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
