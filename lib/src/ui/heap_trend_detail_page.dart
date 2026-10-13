import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:dev_tools_light/src/leaks/heap_trend_report.dart';
import 'package:dev_tools_light/src/ui/leak_trace_view.dart';
import 'package:dev_tools_light/src/ui/overlay_controller.dart';
import 'package:dev_tools_light/src/ui/store_selector.dart';
import 'package:dev_tools_light/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows a growing class: its snapshots and, on demand, the retaining path
/// of one live instance.
class HeapTrendDetailPage extends StatelessWidget {
  /// Creates the page.
  const HeapTrendDetailPage({
    required this.reportId,
    required this.store,
    required this.controller,
    super.key,
  });

  /// The report to show (looked up live, it keeps updating).
  final String reportId;

  /// Findings.
  final ReportStore store;

  /// Shared UI state (for the fetch action).
  final OverlayController controller;

  @override
  Widget build(BuildContext context) {
    return StoreSelector<HeapTrendReport?>(
      store: store,
      select: (store) => store.heapTrendById(reportId),
      builder: (context, report) {
        if (report == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This report was cleared.')),
          );
        }
        return _HeapTrendDetail(report: report, controller: controller);
      },
    );
  }
}

class _HeapTrendDetail extends StatelessWidget {
  const _HeapTrendDetail({required this.report, required this.controller});

  final HeapTrendReport report;
  final OverlayController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trace = report.trace;
    final fetching = report.traceState == HeapTrendTraceState.fetching;
    final fetch = controller.onFetchHeapTrendTrace;
    return Scaffold(
      appBar: AppBar(
        title: Text(report.className),
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
              OriginChip(report.origin),
              Chip(label: Text(report.location)),
            ],
          ),
          const SizedBox(height: 12),
          Text(report.subtitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'First seen ${report.firstSeen}\nLast confirmed ${report.lastSeen}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Text('Snapshots', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(2),
              1: FlexColumnWidth(),
              2: FlexColumnWidth(),
            },
            children: [
              for (final sample in report.samples)
                TableRow(
                  children: [
                    Text(
                      _time(sample.at),
                      style: theme.textTheme.bodySmall,
                    ),
                    Text('${sample.instances}', textAlign: TextAlign.end),
                    Text(
                      formatBytes(sample.bytes),
                      textAlign: TextAlign.end,
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 24),
          if (trace == null) ...[
            FilledButton.icon(
              onPressed: fetch == null || fetching
                  ? null
                  : () => fetch(report.id),
              icon: fetching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.account_tree_outlined),
              label: Text(
                fetching ? 'Fetching retaining path…' : 'Find retaining path',
              ),
            ),
            if (report.traceState == HeapTrendTraceState.failed &&
                report.traceDetail != null) ...[
              const SizedBox(height: 8),
              Text(
                report.traceDetail!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ] else ...[
            Text(
              'Retaining path of one live instance',
              style: theme.textTheme.titleSmall,
            ),
            if (report.traceDetail != null)
              Text(report.traceDetail!, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            LeakTraceView(trace: trace),
          ],
        ],
      ),
    );
  }

  static String _time(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }
}
