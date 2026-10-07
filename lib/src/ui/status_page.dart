import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/core/status.dart';
import 'package:flutter/material.dart';

/// Shows what the engine is doing.
class StatusPage extends StatelessWidget {
  /// Creates the page.
  const StatusPage({required this.store, super.key});

  /// Findings and status.
  final ReportStore store;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DevToolsLightStatus>(
      valueListenable: store.statusListenable,
      builder: (context, s, _) {
        final vmDetail = s.vmDetail == null ? '' : ' — ${s.vmDetail}';
        final period = s.samplePeriodMicros;
        final offset = s.clockOffsetMicros;
        final rows = <(String, String)>[
          ('Mode', s.mode.name),
          ('VM service', '${s.vm.name}$vmDetail'),
          if (s.vmUri != null) ('VM URI', s.vmUri!),
          ('Leak detection', s.leaks.name),
          ('Jank detection', s.jank.name),
          (
            'Heap growth trends',
            '${s.heapTrends.name}'
                '${s.heapTrendDetail == null ? '' : ' — ${s.heapTrendDetail}'}',
          ),
          ('Profiler', s.profilerEnabled?.toString() ?? 'unknown'),
          ('Sample period', period == null ? 'unknown' : '$period µs'),
          (
            'App packages',
            s.appPackagePrefixes.isEmpty
                ? '(auto-detect pending)'
                : s.appPackagePrefixes.join(', '),
          ),
          (
            'Frame clock offset',
            offset == null ? 'uncalibrated' : '$offset µs',
          ),
          ('Watched objects', '${s.watchedObjects}'),
          ('Retained candidates', '${s.retainedCandidates}'),
          ('Dropped candidates', '${s.droppedCandidates}'),
          ('Skipped by package policy', '${s.skippedByPackagePolicy}'),
          ('Leak checks run', '${s.leakChecksRun}'),
          (
            'Self-inflicted stalls suppressed',
            '${s.selfInflictedStallsSuppressed}',
          ),
          ('Heap snapshots', '${s.heapSnapshots}'),
          (
            'Last heap snapshot',
            s.lastHeapSnapshotMicros == null
                ? 'none yet'
                : '${s.lastHeapSnapshotMicros! ~/ 1000} ms',
          ),
          if (s.lastError != null) ('Last error', s.lastError!),
        ];
        return ListView(
          children: [
            for (final row in rows)
              ListTile(
                dense: true,
                title: Text(row.$1),
                subtitle: SelectableText(row.$2),
              ),
          ],
        );
      },
    );
  }
}
