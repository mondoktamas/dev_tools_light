// Several settings depend on --dart-define values; at analysis time they
// equal the defaults, which this lint would flag.
// ignore_for_file: avoid_redundant_argument_values

import 'dart:async';

import 'package:dev_tools_light/dev_tools_light.dart';
import 'package:dev_tools_light_example/demo_driver.dart';
import 'package:dev_tools_light_example/globals.dart';
import 'package:dev_tools_light_example/jank_pages.dart';
import 'package:dev_tools_light_example/leaky_pages.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  // Start before runApp so the back button can close the report panel.
  await DevToolsLight.start(
    config: const DevToolsLightConfig(
      log: true,
      allowInTests: true,
      // `flutter run --release`: jank detection without attribution.
      allowInRelease: true,
      // The self-driving demo takes snapshots itself and leaks small batches.
      // (The analyzer sees the define's default and reports these as
      // redundant; see the ignore at the top of the file.)
      heapTrend: HeapTrendConfig(
        interval: kDemo ? Duration(seconds: 5) : Duration(seconds: 30),
        minRisingSnapshots: kDemo ? 3 : 4,
        minInstanceGrowth: 50,
        minBytesGrowth: kDemo ? 4096 : 512 * 1024,
      ),
      // Jank detection is off in debug builds by default; the demo and the
      // integration test run in debug mode, so turn it on here unless
      // `--dart-define=DTL_NO_JANK=true` asks for the package's default.
      // `--dart-define=DTL_JSON=true` switches to the JSON sample format.
      jank: JankDetectionConfig(
        allowInDebug: !bool.fromEnvironment('DTL_NO_JANK'),
        sampleFormat: bool.fromEnvironment('DTL_JSON')
            ? SampleFormat.json
            : SampleFormat.perfetto,
      ),
    ),
  );
  runApp(const ExampleApp());
  if (kDemo) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(DemoDriver(navigatorKey).run());
    });
  }
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'dev_tools_light example',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      // The overlay: badge, toasts and the report panel.
      builder: DevToolsLight.builder,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void _push(BuildContext context, Widget page) {
    unawaited(
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('dev_tools_light example')),
      body: ListView(
        children: [
          const _Header('Leaks (open a page, then pop it)'),
          ListTile(
            leading: const Icon(Icons.water_drop),
            title: const Text('Leak a State via a stream subscription'),
            onTap: () => _push(context, const LeakyStreamPage()),
          ),
          ListTile(
            leading: const Icon(Icons.water_drop),
            title: const Text('Leak a ChangeNotifier via a global listener'),
            onTap: () => _push(context, const LeakyNotifierPage()),
          ),
          ListTile(
            leading: const Icon(Icons.water_drop),
            title: const Text('Leak a State via a static field'),
            onTap: () => _push(context, const LeakyStaticPage()),
          ),
          ListTile(
            leading: const Icon(Icons.check_circle_outline),
            title: const Text('Well-behaved page (no leak)'),
            onTap: () => _push(context, const CleanPage()),
          ),
          const ListTile(
            leading: Icon(Icons.search),
            title: Text('Check leaks now'),
            subtitle: Text('Forces a GC and analyzes retained objects'),
            onTap: DevToolsLight.checkLeaksNow,
          ),
          const Divider(),
          const _Header('Jank'),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('Slow build (JSON parsing in build)'),
            onTap: () => _push(context, const SlowBuildPage()),
          ),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('Block the UI in a tap handler'),
            onTap: () => _push(context, const JankPage()),
          ),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('Raster-heavy page'),
            onTap: () => _push(context, const RasterPage()),
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.send),
            title: Text('Emit an AppEvents event'),
            onTap: AppEvents.emit,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}
