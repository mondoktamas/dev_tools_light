import 'package:dev_tools_light/dev_tools_light.dart';
import 'package:dev_tools_light_example/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// End-to-end check against the real VM service. Run with
/// `flutter test integration_test -d macos` (or any device).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<T?> poll<T>(
    WidgetTester tester,
    T? Function() probe, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    return tester.runAsync<T?>(() async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final value = probe();
        if (value != null) {
          return value;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return null;
    });
  }

  testWidgets('detects a leaked State and attributes a UI stall', (
    tester,
  ) async {
    await app.main();
    await tester.pumpAndSettle();
    expect(DevToolsLight.isRunning, isTrue);

    final reachable = await poll(
      tester,
      () =>
          DevToolsLight.status.vm == VmConnectionState.reachable ? true : null,
      timeout: const Duration(seconds: 40),
    );
    expect(reachable, isTrue, reason: DevToolsLight.status.vmDetail);

    // Leak a State through the never-cancelled stream subscription.
    await tester.tap(find.text('Leak a State via a stream subscription'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pop this page'));
    await tester.pumpAndSettle();
    await tester.runAsync(DevToolsLight.checkLeaksNow);
    final leak = await poll(
      tester,
      () => DevToolsLight.reports.leaks
          .where((r) => r.typeName == '_LeakyStreamPageState')
          .firstOrNull,
    );
    expect(leak, isNotNull, reason: 'the leaked State should be reported');
    expect(leak!.trace, isNotNull);
    expect(
      leak.trace!.nodes.any(
        (n) =>
            n.referenceKind == ReferenceKind.staticField &&
            n.referenceName == 'controller',
      ),
      isTrue,
      reason: leak.toText(),
    );

    // Block the UI isolate from a tap handler. The JIT may inline `_blockUi`
    // into the tap handler's closure, in which case the samples name the
    // closure (`_JankPageState.build.<anonymous closure>`) instead.
    await tester.tap(find.text('Block the UI in a tap handler'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block UI 300 ms (no rebuild)'));
    await tester.pumpAndSettle();
    bool isBlockUi(SlowOperationReport report) {
      final name = report.topAppFunction?.name ?? '';
      return name.contains('_blockUi') ||
          name.startsWith('_JankPageState.build');
    }

    final slowOp = await poll(
      tester,
      () => DevToolsLight.reports.slowOps.where(isBlockUi).firstOrNull,
    );
    expect(
      slowOp,
      isNotNull,
      reason:
          'the stall should be attributed; reports: '
          '${DevToolsLight.reports.slowOps.map((r) => r.subtitle).join('; ')}',
    );
    expect(slowOp!.topAppFunction!.location, contains('jank_pages.dart'));
    expect(slowOp.attributionState, AttributionState.attributed);

    // The badge shows both findings.
    await tester.pumpAndSettle();
    expect(find.byType(DevToolsLightOverlay), findsOneWidget);
  });
}
