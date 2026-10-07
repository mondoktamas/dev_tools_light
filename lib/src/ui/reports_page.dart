import 'package:dev_tools_light/src/core/internal_marker.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/status.dart';
import 'package:dev_tools_light/src/ui/heap_trend_detail_page.dart';
import 'package:dev_tools_light/src/ui/leak_detail_page.dart';
import 'package:dev_tools_light/src/ui/overlay_controller.dart';
import 'package:dev_tools_light/src/ui/slow_op_detail_page.dart';
import 'package:dev_tools_light/src/ui/status_page.dart';
import 'package:dev_tools_light/src/ui/theme.dart';
import 'package:flutter/material.dart';

/// The panel's home page: a tab per enabled feature (Leaks, Slow ops,
/// Growth) plus Status.
class ReportsPage extends StatefulWidget {
  /// Creates the page.
  const ReportsPage({
    required this.store,
    required this.controller,
    super.key,
  });

  /// Findings.
  final ReportStore store;

  /// Shared UI state.
  final OverlayController controller;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

enum _Tab { leaks, slowOps, growth, status }

class _ReportsPageState extends State<ReportsPage>
    with SingleTickerProviderStateMixin, DevToolsLightInternal {
  // The feature set is fixed at `DevToolsLight.start`; the panel is rebuilt
  // every time it opens, so reading it once per page is enough.
  late final List<_Tab> _specs = _tabsFor(widget.store.status);
  late final TabController _tabs = TabController(
    length: _specs.length,
    vsync: this,
  );
  bool _checking = false;
  bool _snapshotting = false;

  // Features that are disabled or unsupported in this build have no tab.
  static List<_Tab> _tabsFor(DevToolsLightStatus status) => [
    if (status.leaks != LeakDetectionState.disabled &&
        status.leaks != LeakDetectionState.debugOnly &&
        status.leaks != LeakDetectionState.unsupported)
      _Tab.leaks,
    if (status.jank != JankDetectionState.disabled &&
        status.jank != JankDetectionState.notInDebug &&
        status.jank != JankDetectionState.unsupported)
      _Tab.slowOps,
    if (status.heapTrends != HeapTrendState.disabled &&
        status.heapTrends != HeapTrendState.unsupported)
      _Tab.growth,
    _Tab.status,
  ];

  bool get _leaksEnabled => _specs.contains(_Tab.leaks);
  bool get _growthEnabled => _specs.contains(_Tab.growth);

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTab);
    // Not synchronously: notifying the store during the first build would
    // mark listeners dirty mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _markSeen(_specs.first);
      }
    });
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTab)
      ..dispose();
    super.dispose();
  }

  void _onTab() => _markSeen(_specs[_tabs.index]);

  void _markSeen(_Tab tab) {
    switch (tab) {
      case _Tab.leaks:
        widget.store.markLeaksSeen();
      case _Tab.slowOps:
        widget.store.markSlowOpsSeen();
      case _Tab.growth:
        widget.store.markHeapTrendsSeen();
      case _Tab.status:
        break;
    }
  }

  Future<void> _checkNow() async {
    final action = widget.controller.onCheckLeaksNow;
    if (action == null || _checking) {
      return;
    }
    setState(() => _checking = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _snapshotNow() async {
    final action = widget.controller.onSnapshotHeapNow;
    if (action == null || _snapshotting) {
      return;
    }
    setState(() => _snapshotting = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _snapshotting = false);
      }
    }
  }

  Widget _tabLabel(_Tab tab) => switch (tab) {
    _Tab.leaks => ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) =>
          Tab(text: 'Leaks (${widget.store.leaks.length})'),
    ),
    _Tab.slowOps => ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) =>
          Tab(text: 'Slow ops (${widget.store.slowOps.length})'),
    ),
    _Tab.growth => ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) =>
          Tab(text: 'Growth (${widget.store.heapTrends.length})'),
    ),
    _Tab.status => const Tab(text: 'Status'),
  };

  Widget _tabBody(_Tab tab) => switch (tab) {
    _Tab.leaks => _LeakList(store: widget.store),
    _Tab.slowOps => _SlowOpList(store: widget.store),
    _Tab.growth => _HeapTrendList(
      store: widget.store,
      controller: widget.controller,
    ),
    _Tab.status => StatusPage(store: widget.store),
  };

  static const _busyIndicator = SizedBox(
    width: 18,
    height: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('dev_tools_light'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: widget.controller.close,
        ),
        actions: [
          if (_leaksEnabled)
            IconButton(
              icon: _checking ? _busyIndicator : const Icon(Icons.search),
              tooltip: 'Check leaks now',
              onPressed: _checking ? null : _checkNow,
            ),
          if (_growthEnabled)
            IconButton(
              icon: _snapshotting ? _busyIndicator : const Icon(Icons.memory),
              tooltip: 'Snapshot heap now (forces a GC)',
              onPressed: _snapshotting ? null : _snapshotNow,
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear all reports',
            onPressed: widget.store.clear,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [for (final tab in _specs) _tabLabel(tab)],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [for (final tab in _specs) _tabBody(tab)],
      ),
    );
  }
}

class _LeakList extends StatelessWidget {
  const _LeakList({required this.store});

  final ReportStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final leaks = store.leaks;
        if (leaks.isEmpty) {
          return const _Empty(
            icon: Icons.water_drop_outlined,
            text:
                'No leaks detected yet.\n'
                'Disposed States, controllers and routes are watched '
                'automatically in debug builds.',
          );
        }
        return ListView.builder(
          itemCount: leaks.length,
          itemBuilder: (context, index) {
            final report = leaks[index];
            final origin = report.trace?.leakedObject.origin;
            return ListTile(
              key: ValueKey(report.id),
              leading: Icon(
                Icons.water_drop,
                color: report.isLibraryLeak
                    ? Theme.of(context).colorScheme.tertiary
                    : Theme.of(context).colorScheme.error,
              ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      report.typeName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (origin != null) ...[
                    const SizedBox(width: 8),
                    OriginChip(origin),
                  ],
                ],
              ),
              subtitle: Text(
                report.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: report.occurrences > 1
                  ? Text('×${report.occurrences}')
                  : null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => LeakDetailPage(report: report),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _SlowOpList extends StatelessWidget {
  const _SlowOpList({required this.store});

  final ReportStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final slowOps = store.slowOps;
        if (slowOps.isEmpty) {
          return const _Empty(
            icon: Icons.speed_outlined,
            text:
                'No slow operations detected yet.\n'
                'Janky frames and UI stalls are attributed to your code with '
                'CPU samples.',
          );
        }
        return ListView.builder(
          itemCount: slowOps.length,
          itemBuilder: (context, index) {
            final report = slowOps[index];
            return ListTile(
              key: ValueKey(report.id),
              leading: Icon(
                Icons.speed,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(report.title),
              subtitle: Text(
                report.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: report.occurrences > 1
                  ? Text('×${report.occurrences}')
                  : null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      SlowOpDetailPage(reportId: report.id, store: store),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _HeapTrendList extends StatelessWidget {
  const _HeapTrendList({required this.store, required this.controller});

  final ReportStore store;
  final OverlayController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final trends = store.heapTrends;
        if (trends.isEmpty) {
          return const _Empty(
            icon: Icons.trending_up,
            text:
                'No growing classes yet.\n'
                'Heap snapshots are taken periodically; a class whose live '
                'instances keep increasing shows up here, even when nothing '
                'watched them. Use the chip icon above to snapshot now.',
          );
        }
        return ListView.builder(
          itemCount: trends.length,
          itemBuilder: (context, index) {
            final report = trends[index];
            return ListTile(
              key: ValueKey(report.id),
              leading: Icon(
                Icons.trending_up,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(report.className),
              subtitle: Text(
                report.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: report.trace != null
                  ? const Icon(Icons.account_tree_outlined)
                  : null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HeapTrendDetailPage(
                    reportId: report.id,
                    store: store,
                    controller: controller,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
