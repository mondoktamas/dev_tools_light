/// In-app memory-leak detection with LeakCanary-style leak traces and jank
/// attribution to your own code, built on the Dart VM service.
library;

export 'src/core/app_code_classifier.dart' show AppUriPredicate;
export 'src/core/code_origin.dart';
export 'src/core/config.dart';
export 'src/core/dev_tools_light.dart';
export 'src/core/report_store.dart';
export 'src/core/status.dart';
export 'src/jank/cpu_attribution.dart';
export 'src/jank/jank_candidate.dart' show JankKind;
export 'src/jank/slow_operation_report.dart';
export 'src/leaks/heap_trend_report.dart';
export 'src/leaks/leak_report.dart';
export 'src/leaks/leak_trace.dart';
export 'src/leaks/reference_matchers.dart';
export 'src/leaks/watched_kind.dart' show WatchedKind;
export 'src/leaks/watched_packages.dart';
export 'src/ui/dev_tools_light_overlay.dart';
export 'src/ui/overlay_controller.dart' show OverlayController;
