import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/engine.dart';
import 'package:dev_tools_light/src/core/internal_marker.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/support.dart';
import 'package:dev_tools_light/src/ui/badge.dart';
import 'package:dev_tools_light/src/ui/overlay_controller.dart';
import 'package:dev_tools_light/src/ui/panel.dart';
import 'package:dev_tools_light/src/ui/toast.dart';
import 'package:flutter/material.dart';

/// Wraps the app with the floating badge, toasts and the report panel.
///
/// Use it as `MaterialApp(builder: DevToolsLight.builder)` or wrap the
/// navigator yourself. When `DevToolsLight` is not running (the web, a
/// release build without `allowInRelease`, not started) it returns [child]
/// unchanged.
class DevToolsLightOverlay extends StatelessWidget {
  /// Creates the overlay around [child].
  const DevToolsLightOverlay({
    required this.child,
    super.key,
    this.store,
    this.controller,
    this.config,
  });

  /// The app (usually the navigator handed to `MaterialApp.builder`).
  final Widget? child;

  /// Overrides the engine's store (for tests).
  final ReportStore? store;

  /// Overrides the engine's controller (for tests).
  final OverlayController? controller;

  /// Overrides the engine's overlay settings (for tests).
  final OverlayConfig? config;

  @override
  Widget build(BuildContext context) {
    final child = this.child ?? const SizedBox.shrink();
    if (!kDetectionSupported) {
      return child;
    }
    if (store != null && controller != null) {
      return _OverlayBody(
        store: store!,
        controller: controller!,
        config: config ?? const OverlayConfig(),
        child: child,
      );
    }
    final engine = Engine.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: engine.runningNotifier,
      builder: (context, running, _) {
        if (!running) {
          return child;
        }
        return _OverlayBody(
          store: store ?? engine.store,
          controller: controller ?? engine.overlayController,
          config: config ?? engine.config.overlay,
          child: child,
        );
      },
    );
  }
}

class _OverlayBody extends StatefulWidget {
  const _OverlayBody({
    required this.store,
    required this.controller,
    required this.config,
    required this.child,
  });

  final ReportStore store;
  final OverlayController controller;
  final OverlayConfig config;
  final Widget child;

  @override
  State<_OverlayBody> createState() => _OverlayBodyState();
}

class _OverlayBodyState extends State<_OverlayBody> with DevToolsLightInternal {
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (widget.config.showToasts)
          ToastLayer(
            store: widget.store,
            controller: widget.controller,
            config: widget.config,
          ),
        if (widget.config.showBadge)
          FindingsBadge(
            store: widget.store,
            controller: widget.controller,
            config: widget.config,
          ),
        ValueListenableBuilder<bool>(
          valueListenable: widget.controller.isPanelOpen,
          builder: (context, open, _) {
            if (!open) {
              return const SizedBox.shrink();
            }
            return Positioned.fill(
              child: ReportsPanel(
                store: widget.store,
                controller: widget.controller,
              ),
            );
          },
        ),
      ],
    );
  }
}
