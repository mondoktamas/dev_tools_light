# dev_tools_light example

Demo app that intentionally leaks `State`/`ChangeNotifier` objects, fills an
unbounded cache and produces janky frames so you can see `dev_tools_light` at
work.

```bash
flutter run -d macos            # leak detection, heap trends, jank attribution
flutter run -d macos --profile  # representative jank numbers (manual watch only)
flutter run -d macos --release  # detect-only mode (allowInRelease: true)
flutter run -d macos --dart-define=DTL_DEMO=true  # drives itself, prints reports
flutter test integration_test -d macos
```

On a physical phone add `--no-dds` so the app can reach its own VM service.
`--dart-define=DTL_EXIT=true` quits 15 s after the self-driving demo is done,
and `--dart-define=DTL_JSON=true` fetches CPU samples as JSON instead of
Perfetto. The example turns jank detection on in debug builds (the package
leaves it off there); `--dart-define=DTL_NO_JANK=true` restores the default.
