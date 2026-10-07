import 'package:dev_tools_light/src/leaks/leak_report.dart';
import 'package:dev_tools_light/src/ui/leak_trace_view.dart';
import 'package:dev_tools_light/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows one leak with its LeakCanary-style trace.
class LeakDetailPage extends StatelessWidget {
  /// Creates the page.
  const LeakDetailPage({required this.report, super.key});

  /// The leak.
  final LeakReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trace = report.trace;
    return Scaffold(
      appBar: AppBar(
        title: Text(report.typeName),
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
              if (trace != null) OriginChip(trace.leakedObject.origin),
              Chip(label: Text(report.kind.label)),
              Chip(label: Text('×${report.occurrences}')),
              if (report.isLibraryLeak)
                const Chip(
                  avatar: Icon(Icons.info_outline, size: 16),
                  label: Text('Library leak'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'First seen ${report.firstSeen}\nLast seen ${report.lastSeen}',
            style: theme.textTheme.bodySmall,
          ),
          if (report.description != null) ...[
            const SizedBox(height: 8),
            Text(report.description!),
          ],
          if (trace?.libraryLeakDescription != null) ...[
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(trace!.libraryLeakDescription!),
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (trace == null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '${report.subtitle}\n${report.traceUnavailableDetail ?? ''}',
                ),
              ),
            )
          else
            LeakTraceView(trace: trace),
        ],
      ),
    );
  }
}
