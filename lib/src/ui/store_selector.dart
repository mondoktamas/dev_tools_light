import 'package:dev_tools_light/src/core/internal_marker.dart';
import 'package:dev_tools_light/src/core/report_store.dart';
import 'package:flutter/widgets.dart';

/// Rebuilds [builder] only when [select] returns a different object than
/// last time.
///
/// Reports are immutable and replaced when they change, so identity is the
/// right test: a heavy detail page must not rebuild because some other
/// report arrived (in debug mode on a phone that rebuild is a jank, which
/// would be reported, which would rebuild the page again).
class StoreSelector<T> extends StatefulWidget {
  /// Creates the selector.
  const StoreSelector({
    required this.store,
    required this.select,
    required this.builder,
    super.key,
  });

  /// Findings.
  final ReportStore store;

  /// Picks the value the subtree depends on.
  final T Function(ReportStore store) select;

  /// Builds the subtree for the selected value.
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<StoreSelector<T>> createState() => _StoreSelectorState<T>();
}

class _StoreSelectorState<T> extends State<StoreSelector<T>>
    with DevToolsLightInternal {
  late T _value = widget.select(widget.store);

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
  }

  @override
  void didUpdateWidget(StoreSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
    }
    _value = widget.select(widget.store);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    final next = widget.select(widget.store);
    if (!identical(next, _value)) {
      setState(() => _value = next);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
