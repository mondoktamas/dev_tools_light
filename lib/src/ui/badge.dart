import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/core/internal_marker.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/ui/overlay_controller.dart';
import 'package:flutter/material.dart';

/// The draggable floating badge showing leak / slow-op counts.
class FindingsBadge extends StatefulWidget {
  /// Creates the badge.
  const FindingsBadge({
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

  /// Key of the tappable pill (the widget itself spans the screen).
  static const Key pillKey = ValueKey<String>('dev_tools_light.badge');

  @override
  State<FindingsBadge> createState() => _FindingsBadgeState();
}

class _FindingsBadgeState extends State<FindingsBadge>
    with DevToolsLightInternal {
  late _BadgeCounts _counts = _BadgeCounts.of(widget.store);

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
  }

  @override
  void didUpdateWidget(FindingsBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
      _counts = _BadgeCounts.of(widget.store);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// Rebuilds only when a number on the pill changes. A notification for a
  /// merged report must not schedule a frame: in a throttled background app
  /// that frame arrives late, becomes a jank candidate, and its report
  /// would schedule the next one.
  void _onStoreChanged() {
    final next = _BadgeCounts.of(widget.store);
    if (next != _counts) {
      setState(() => _counts = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ValueListenableBuilder<Alignment>(
            valueListenable: widget.controller.badgeAlignment,
            builder: (context, alignment, child) {
              return Align(
                alignment: alignment,
                child: Padding(
                  padding: EdgeInsets.all(widget.config.margin),
                  child: GestureDetector(
                    onTap: widget.controller.open,
                    onPanUpdate: (details) {
                      final halfWidth = constraints.maxWidth / 2;
                      final halfHeight = constraints.maxHeight / 2;
                      if (halfWidth <= 0 || halfHeight <= 0) {
                        return;
                      }
                      final next = Alignment(
                        (alignment.x + details.delta.dx / halfWidth).clamp(
                          -1.0,
                          1.0,
                        ),
                        (alignment.y + details.delta.dy / halfHeight).clamp(
                          -1.0,
                          1.0,
                        ),
                      );
                      widget.controller.badgeAlignment.value = next;
                    },
                    child: child,
                  ),
                ),
              );
            },
            child: _BadgePill(counts: _counts),
          );
        },
      ),
    );
  }
}

/// The numbers shown on the pill.
@immutable
class _BadgeCounts {
  const _BadgeCounts({
    required this.leaks,
    required this.slowOps,
    required this.heapTrends,
    required this.hasUnseen,
  });

  factory _BadgeCounts.of(ReportStore store) => _BadgeCounts(
    leaks: store.leaks.length,
    slowOps: store.slowOps.length,
    heapTrends: store.heapTrends.length,
    hasUnseen:
        store.unseenLeaks > 0 ||
        store.unseenSlowOps > 0 ||
        store.unseenHeapTrends > 0,
  );

  final int leaks;
  final int slowOps;
  final int heapTrends;
  final bool hasUnseen;

  @override
  bool operator ==(Object other) =>
      other is _BadgeCounts &&
      other.leaks == leaks &&
      other.slowOps == slowOps &&
      other.heapTrends == heapTrends &&
      other.hasUnseen == hasUnseen;

  @override
  int get hashCode => Object.hash(leaks, slowOps, heapTrends, hasUnseen);
}

class _BadgePill extends StatelessWidget {
  const _BadgePill({required this.counts});

  final _BadgeCounts counts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = counts.hasUnseen ? scheme.error : scheme.inverseSurface;
    final foreground = counts.hasUnseen
        ? scheme.onError
        : scheme.onInverseSurface;
    return Material(
      key: FindingsBadge.pillKey,
      color: background,
      elevation: 4,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.water_drop, size: 16, color: foreground),
            const SizedBox(width: 4),
            Text(
              '${counts.leaks}',
              style: TextStyle(color: foreground, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 10),
            Icon(Icons.speed, size: 16, color: foreground),
            const SizedBox(width: 4),
            Text(
              '${counts.slowOps}',
              style: TextStyle(color: foreground, fontWeight: FontWeight.bold),
            ),
            if (counts.heapTrends > 0) ...[
              const SizedBox(width: 10),
              Icon(Icons.trending_up, size: 16, color: foreground),
              const SizedBox(width: 4),
              Text(
                '${counts.heapTrends}',
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
