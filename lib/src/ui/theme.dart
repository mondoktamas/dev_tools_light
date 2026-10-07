import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/leaks/leak_trace.dart';
import 'package:flutter/material.dart';

/// Colours used by the overlay for origins and verdicts.
extension DevToolsLightColors on ColorScheme {
  /// Colour for [origin].
  Color originColor(CodeOrigin origin) => switch (origin) {
    CodeOrigin.app => primary,
    CodeOrigin.flutter => const Color(0xFF54C5F8),
    CodeOrigin.dart => const Color(0xFF9E9E9E),
    CodeOrigin.library => const Color(0xFFAB47BC),
    CodeOrigin.tooling => const Color(0xFF8D6E63),
    CodeOrigin.unknown => outline,
  };

  /// Colour for [status].
  Color leakStatusColor(LeakStatus status) => switch (status) {
    LeakStatus.leaking => error,
    LeakStatus.notLeaking => const Color(0xFF43A047),
    LeakStatus.unknown => outline,
  };
}

/// A small rounded label.
class OriginChip extends StatelessWidget {
  /// Creates a chip for [origin].
  const OriginChip(this.origin, {super.key});

  /// The origin to show.
  final CodeOrigin origin;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.originColor(origin);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        origin.label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
