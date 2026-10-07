import 'package:dev_tools_light/src/leaks/leak_trace.dart';
import 'package:dev_tools_light/src/ui/theme.dart';
import 'package:flutter/material.dart';

/// Renders a [LeakTrace] LeakCanary-style: root first, one tile per node,
/// suspect references highlighted, plus a copyable text version.
class LeakTraceView extends StatelessWidget {
  /// Creates the view.
  const LeakTraceView({required this.trace, super.key});

  /// The trace.
  final LeakTrace trace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('GC root: ${trace.gcRootType}', style: theme.textTheme.titleSmall),
        if (trace.viaWeakReference) ...[
          const SizedBox(height: 8),
          _Callout(
            icon: Icons.warning_amber_outlined,
            color: theme.colorScheme.tertiary,
            text: LeakTrace.weakReferenceWarning,
          ),
        ],
        if (trace.note != null) ...[
          const SizedBox(height: 8),
          _Callout(
            icon: Icons.info_outline,
            color: theme.colorScheme.primary,
            text: trace.note!,
          ),
        ],
        const SizedBox(height: 8),
        for (var i = 0; i < trace.nodes.length; i++)
          TraceNodeTile(
            node: trace.nodes[i],
            isLast: i == trace.nodes.length - 1,
          ),
        const SizedBox(height: 24),
        ExpansionTile(
          title: const Text('Text report'),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                trace.toText(),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// One node of a leak trace with the reference to the next node.
class TraceNodeTile extends StatelessWidget {
  /// Creates the tile.
  const TraceNodeTile({required this.node, required this.isLast, super.key});

  /// The node.
  final LeakTraceNode node;

  /// Whether this is the leaked object (no outgoing reference).
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final statusColor = scheme.leakStatusColor(node.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: node.origin.label == 'APP'
                ? scheme.primaryContainer.withValues(alpha: 0.35)
                : null,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isLast ? scheme.error : scheme.outlineVariant,
            ),
          ),
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      node.displayName,
                      style: textTheme.titleSmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OriginChip(node.origin),
                ],
              ),
              if (node.location != null)
                Text(node.location!, style: textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(
                'Leaking: ${node.status.label}'
                '${node.statusReason == null ? '' : ' (${node.statusReason})'}',
                style: textTheme.bodySmall?.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (!isLast)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Icon(
                  Icons.arrow_downward,
                  size: 16,
                  color: node.isSuspect ? scheme.error : scheme.outline,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    node.referenceDescription,
                    style: textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: node.isSuspect ? scheme.error : null,
                      fontWeight: node.isSuspect ? FontWeight.bold : null,
                    ),
                  ),
                ),
                if (node.isSuspect)
                  Text(
                    '~~~ suspect',
                    style: textTheme.bodySmall?.copyWith(color: scheme.error),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
