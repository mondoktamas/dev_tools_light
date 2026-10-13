import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/jank/cpu_attribution.dart';
import 'package:dev_tools_light/src/jank/slow_operation_report.dart';
import 'package:dev_tools_light/src/ui/store_selector.dart';
import 'package:dev_tools_light/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows one slow operation with its app-code attribution.
class SlowOpDetailPage extends StatelessWidget {
  /// Creates the page for the report with [reportId] (kept live via the
  /// store because merges can update it).
  const SlowOpDetailPage({
    required this.reportId,
    required this.store,
    super.key,
  });

  /// The report id.
  final String reportId;

  /// Findings.
  final ReportStore store;

  @override
  Widget build(BuildContext context) {
    return StoreSelector<SlowOperationReport?>(
      store: store,
      select: (store) => store.slowOpById(reportId),
      builder: (context, report) {
        if (report == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Report was cleared.')),
          );
        }
        return _SlowOpDetail(report: report);
      },
    );
  }
}

class _SlowOpDetail extends StatelessWidget {
  const _SlowOpDetail({required this.report});

  final SlowOperationReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final attribution = report.attribution;
    return Scaffold(
      appBar: AppBar(
        title: Text(report.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy report',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report.toText()));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Report copied')));
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final kind in report.kinds) Chip(label: Text(kind.label)),
              Chip(label: Text('×${report.occurrences}')),
              if (report.frameNumber != null)
                Chip(label: Text('frame ${report.frameNumber}')),
            ],
          ),
          const SizedBox(height: 8),
          _DurationRow('Window', report.duration),
          if (report.buildDuration != null)
            _DurationRow('Build (UI thread)', report.buildDuration!),
          if (report.rasterDuration != null)
            _DurationRow('Raster', report.rasterDuration!),
          if (report.vsyncOverhead != null)
            _DurationRow('Vsync overhead', report.vsyncOverhead!),
          if (report.stallLateness != null)
            _DurationRow('Heartbeat lateness', report.stallLateness!),
          Text(
            'First seen ${report.firstSeen}\nLast seen ${report.lastSeen}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (report.attributionHint != null)
            Card(
              color: theme.colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(report.attributionHint!),
              ),
            ),
          if (attribution != null) ...[
            Text(_sampleSummary(attribution), style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            _OriginBar(attribution: attribution),
            const SizedBox(height: 16),
            if (attribution.hasAppCode) ...[
              Text('Hot app functions', style: theme.textTheme.titleMedium),
              Text(
                'responsible · self · inclusive',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              for (final f in attribution.hotAppFunctions)
                _HotFunctionTile(function: f, attribution: attribution),
              const SizedBox(height: 16),
              Text('App call tree', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              _CallTree(
                nodes: attribution.appCallTree,
                attribution: attribution,
              ),
            ] else ...[
              Card(
                color: theme.colorScheme.tertiaryContainer,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'No app code was on the UI thread during this window. '
                    'The time went to framework / SDK work (layout, paint, '
                    'GC, JIT). The hottest leaf functions were:',
                  ),
                ),
              ),
              for (final f in attribution.hotOtherFunctions)
                ListTile(
                  dense: true,
                  leading: OriginChip(f.origin),
                  title: Text(
                    f.name,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  trailing: Text(
                    '${attribution.percent(f.selfTicks).toStringAsFixed(0)}%',
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

String _sampleSummary(CpuAttribution a) {
  final samples = '${a.usedSamples} of ${a.sampleCount}';
  final parts = <String>[
    'Samples: $samples @ ${a.samplePeriodMicros} µs',
    if (a.truncatedSamples > 0) '${a.truncatedSamples} truncated',
    if (a.gcTicks > 0) '${a.gcTicks} in GC',
    if (a.compileTicks > 0) '${a.compileTicks} in JIT',
  ];
  return parts.join(' · ');
}

class _DurationRow extends StatelessWidget {
  const _DurationRow(this.label, this.duration);

  final String label;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            '${(duration.inMicroseconds / 1000).toStringAsFixed(1)} ms',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class _OriginBar extends StatelessWidget {
  const _OriginBar({required this.attribution});

  final CpuAttribution attribution;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries =
        attribution.selfTicksByOrigin.entries.where((e) => e.value > 0).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Where the leaf frames were',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 12,
            child: Row(
              children: [
                for (final entry in entries)
                  Expanded(
                    flex: entry.value,
                    child: ColoredBox(color: scheme.originColor(entry.key)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 12,
          children: [
            for (final entry in entries)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    color: scheme.originColor(entry.key),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${entry.key.label} '
                    '${attribution.percent(entry.value).toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _HotFunctionTile extends StatelessWidget {
  const _HotFunctionTile({required this.function, required this.attribution});

  final HotFunction function;
  final CpuAttribution attribution;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String pct(int ticks) =>
        '${attribution.percent(ticks).toStringAsFixed(0)}%';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  function.name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OriginChip(function.origin),
            ],
          ),
          if (function.location != null)
            Text(function.location!, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            '${pct(function.responsibleTicks)} · '
            '${pct(function.selfTicks)} · '
            '${pct(function.inclusiveTicks)}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _CallTree extends StatelessWidget {
  const _CallTree({
    required this.nodes,
    required this.attribution,
    this.depth = 0,
  });

  final List<AppCallNode> nodes;
  final CpuAttribution attribution;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final node in nodes) ...[
          if (node.skippedFrameworkFrames > 0)
            Padding(
              padding: EdgeInsets.only(left: 16.0 * depth + 4),
              child: Text(
                '· ${node.skippedFrameworkFrames} framework frames',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(left: 16.0 * depth),
            child: Row(
              children: [
                const Text('▸ '),
                Expanded(
                  child: Text(
                    '${node.name}'
                    '${node.location == null ? '' : '  ${node.location}'}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
                Text(
                  '${attribution.percent(node.ticks).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          _CallTree(
            nodes: node.children,
            attribution: attribution,
            depth: depth + 1,
          ),
        ],
      ],
    );
  }
}
