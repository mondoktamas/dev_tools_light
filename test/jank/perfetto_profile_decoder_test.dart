import 'dart:convert';

import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/jank/perfetto_profile_decoder.dart';
import 'package:dev_tools_light/src/jank/sampled_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';

void main() {
  const appFile = 'file:///Users/x/proj/lib/page.dart';
  const sdkFile = 'org-dartlang-sdk:///sdk/lib/core/double.dart';
  const flutterFile =
      'file:///Users/x/flutter/packages/flutter/lib/src/widgets/binding.dart';
  final functions = <PerfettoFunction>[
    (name: 'start', path: null), // 0 native
    (name: 'main', path: null), // 1 native (embedder)
    (name: 'SchedulerBinding.handleDrawFrame', path: flutterFile), // 2
    (name: 'MyPage.build', path: appFile), // 3
    (name: 'DemoParser.parse', path: appFile), // 4
    (name: 'new _Double.fromInteger', path: sdkFile), // 5
    (name: 'dart::Scavenger::Scavenge()', path: null), // 6
  ];
  final classifier = AppCodeClassifier(appPrefixes: {'package:my_app/'});
  const packageUris = {
    appFile: 'package:my_app/page.dart',
    sdkFile: 'dart:core',
    flutterFile: 'package:flutter/src/widgets/binding.dart',
  };

  test('labels engine and system frames behind the VM native prefix', () {
    final encoded = perfettoTrace(
      functions: [
        (
          name: [
            '[Native] /data/app/~~x==/com.example.example-y==/base.apk!',
            'lib/arm64-v8a/libflutter.so+0x1f89ed0',
          ].join('/'),
          path: null,
        ),
        (
          name:
              '[Native] /apex/com.android.runtime/lib64/bionic/libc.so+0x41ae8',
          path: null,
        ),
        (name: '[Native] syscall', path: null),
        (name: 'start', path: null),
      ],
      stacks: [
        [3, 0, 1, 2],
      ],
    );
    final profile = PerfettoProfileDecoder(
      base64Decode(encoded),
    ).toProfile(classifier: classifier, samplePeriodMicros: 1000);
    final names = [
      for (final i in profile.samples.single.stack) profile.functions[i].name,
    ];
    expect(names, [
      '[System] syscall',
      '[System] libc.so+0x41ae8',
      '[Engine] libflutter.so+0x1f89ed0',
      '[Native] start',
    ]);
  });

  test('decodes root-first callstacks into leaf-first samples', () {
    final encoded = perfettoTrace(
      functions: functions,
      stacks: [
        [0, 1, 2, 3, 4, 5],
        [0, 1, 2, 3, 4],
        [0, 1, 2, 3, 6],
      ],
      timestampsMicros: [5000, 6000, 7000],
    );
    final decoder = PerfettoProfileDecoder(base64Decode(encoded));
    expect(decoder.sampleCount, 3);
    expect(decoder.mappingPaths, {appFile, sdkFile, flutterFile});

    final profile = decoder.toProfile(
      classifier: classifier,
      samplePeriodMicros: 1000,
      packageUriByPath: packageUris,
    );
    expect(profile.source, ProfileSource.perfetto);
    expect(profile.sampleCount, 3);
    expect(profile.samples, hasLength(3));

    final first = profile.samples[0];
    expect(first.timestampMicros, 5000);
    final names = [for (final i in first.stack) profile.functions[i].name];
    expect(names, [
      'new _Double.fromInteger',
      'DemoParser.parse',
      'MyPage.build',
      'SchedulerBinding.handleDrawFrame',
      '[Native] main',
      '[Native] start',
    ]);
    final origins = [for (final i in first.stack) profile.functions[i].origin];
    expect(origins, [
      CodeOrigin.dart,
      CodeOrigin.app,
      CodeOrigin.app,
      CodeOrigin.flutter,
      CodeOrigin.unknown,
      CodeOrigin.unknown,
    ]);
    expect(profile.functions[first.stack[1]].uri, 'package:my_app/page.dart');
    expect(first.vmTag, 'Dart');
    expect(profile.samples[2].vmTag, startsWith('GC'));
  });

  test('strips the debug-mode line suffix and keeps the line', () {
    final encoded = perfettoTrace(
      functions: [
        (name: 'Thing.slow', path: '$appFile:39:3'),
        (
          name: 'Engine._log',
          path: 'file:///Users/x/dev_tools_light/lib/src/core/engine.dart:12:5',
        ),
      ],
      stacks: [
        [1, 0],
      ],
    );
    final decoder = PerfettoProfileDecoder(base64Decode(encoded));
    expect(decoder.mappingPaths, contains(appFile));
    final profile = decoder.toProfile(
      classifier: classifier,
      samplePeriodMicros: 1000,
      packageUriByPath: packageUris,
    );
    final leaf = profile.functions[profile.samples.single.stack.first];
    expect(leaf.uri, 'package:my_app/page.dart');
    expect(leaf.line, 39);
    expect(leaf.location, 'lib/page.dart:39');
    final tooling = profile.functions[profile.samples.single.stack.last];
    expect(tooling.origin, CodeOrigin.tooling);
    expect(
      PerfettoProfileDecoder.splitPathAndLine('org-dartlang-sdk:///sdk/x.dart'),
      (path: 'org-dartlang-sdk:///sdk/x.dart', line: null),
    );
  });

  test('falls back to the raw path when no package URI is known', () {
    final encoded = perfettoTrace(
      functions: functions,
      stacks: [
        [0, 3],
      ],
    );
    final profile = PerfettoProfileDecoder(
      base64Decode(encoded),
    ).toProfile(classifier: classifier, samplePeriodMicros: 500);
    final leaf = profile.functions[profile.samples.single.stack.first];
    expect(leaf.uri, appFile);
    expect(leaf.origin, CodeOrigin.app, reason: 'file: outside SDK/pub-cache');
    expect(profile.samplePeriodMicros, 500);
  });
}
