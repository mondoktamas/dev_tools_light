import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/core/config.dart';
import 'package:dev_tools_light/src/jank/cpu_sample_attributor.dart';
import 'package:dev_tools_light/src/jank/jank_candidate.dart';
import 'package:dev_tools_light/src/jank/slow_operation_report.dart';
import 'package:dev_tools_light/src/vm/script_line_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' as vms;

import '../helpers/fake_vm_api.dart';
import '../helpers/fixtures.dart';

void main() {
  const page = 'package:my_app/page.dart';
  const parser = 'package:my_app/parser.dart';
  const framework = 'package:flutter/src/widgets/framework.dart';

  final functions = [
    // 0
    profileFunction(
      funcRef(
        'build',
        owner: classRef('MyPage', page),
        location: sourceLocation(page, line: 42),
      ),
      resolvedUrl: 'file:///Users/x/proj/lib/page.dart',
    ),
    // 1
    profileFunction(
      funcRef(
        'rebuild',
        owner: classRef('Element', framework),
        location: sourceLocation(framework, line: 1),
      ),
    ),
    // 2
    profileFunction(
      funcRef(
        'parse',
        owner: classRef('DemoParser', parser),
        location: sourceLocation(parser, line: 31),
      ),
    ),
    // 3
    profileFunction(
      funcRef(
        'handleString',
        owner: classRef('_JsonListener', 'dart:convert'),
        location: sourceLocation('dart:convert', line: 9),
      ),
    ),
    // 4
    nativeFunction('Dart_Something'),
    // 5
    profileFunction(
      funcRef(
        'layout',
        owner: classRef('RenderBox', 'package:flutter/src/rendering/box.dart'),
        location: sourceLocation('package:flutter/src/rendering/box.dart'),
      ),
    ),
    // 6
    profileFunction(
      funcRef(
        '_log',
        owner: classRef(
          'Engine',
          'package:dev_tools_light/src/core/engine.dart',
        ),
        location: sourceLocation(
          'package:dev_tools_light/src/core/engine.dart',
        ),
      ),
    ),
    // 7
    profileFunction(
      funcRef(
        'bar',
        owner: classRef('Foo', 'package:http/x.dart'),
        location: sourceLocation('package:http/x.dart', line: 3),
      ),
    ),
  ];

  final samples = [
    for (var i = 0; i < 5; i++) cpuSample([3, 2, 0, 1]),
    for (var i = 0; i < 3; i++) cpuSample([2, 0, 1]),
    for (var i = 0; i < 4; i++) cpuSample([5, 1]),
    cpuSample([4, 3, 2, 0], truncated: true),
    for (var i = 0; i < 2; i++) cpuSample([1], vmTag: 'Idle'),
    cpuSample([6, 0]),
    for (var i = 0; i < 2; i++) cpuSample([7, 0, 1]),
    cpuSample([3, 2, 0], vmTag: 'GCOldSpace'),
  ];

  CpuSampleAttributor attributor(AppCodeClassifier classifier) =>
      CpuSampleAttributor(
        classifier: classifier,
        config: const JankDetectionConfig(),
      );

  test('collapses stacks to app code', () {
    final classifier = AppCodeClassifier(appPrefixes: {'package:my_app/'});
    final a = attributor(classifier);
    final result = a.finish(
      a.attribute(cpuSamples(functions: functions, samples: samples)),
    );

    expect(result.sampleCount, 19);
    expect(result.idleTicks, 2);
    expect(result.toolingTicks, 1);
    expect(result.usedSamples, 16);
    expect(result.gcTicks, 1);
    expect(result.truncatedSamples, 1);
    expect(result.ticksWithAppCode, 12);
    expect(result.ticksWithoutAppCode, 4);
    expect(result.hasAppCode, isTrue);
    expect(result.selfTicksByOrigin, {
      CodeOrigin.dart: 6,
      CodeOrigin.app: 3,
      CodeOrigin.flutter: 4,
      CodeOrigin.unknown: 1,
      CodeOrigin.library: 2,
    });

    final hot = result.hotAppFunctions;
    expect(hot.map((f) => f.name), ['DemoParser.parse', 'MyPage.build']);
    expect(hot[0].responsibleTicks, 10);
    expect(hot[0].selfTicks, 3);
    expect(hot[0].inclusiveTicks, 10);
    expect(hot[0].location, 'lib/parser.dart:31');
    expect(hot[1].responsibleTicks, 2);
    expect(hot[1].selfTicks, 0);
    expect(hot[1].inclusiveTicks, 12);
    expect(hot[1].location, 'lib/page.dart:42');

    expect(result.hotOtherFunctions.single.name, 'RenderBox.layout');
    expect(result.hotOtherFunctions.single.selfTicks, 4);
    expect(result.hotOtherFunctions.single.origin, CodeOrigin.flutter);

    final tree = result.appCallTree;
    expect(tree, hasLength(1));
    expect(tree.single.name, 'MyPage.build');
    expect(tree.single.ticks, 12);
    expect(tree.single.skippedFrameworkFrames, 0);
    expect(tree.single.children.single.name, 'DemoParser.parse');
    expect(tree.single.children.single.ticks, 10);
    expect(result.percent(8), 50);
  });

  test(
    'learns the app file root from resolvedUrl and classifies file URIs',
    () {
      final classifier = AppCodeClassifier(appPrefixes: {'package:my_app/'});
      final a = attributor(classifier);
      final fns = [
        functions[0],
        // A function known only by its resolved file URL.
        {
          'type': 'ProfileFunction',
          'kind': 'Dart',
          'inclusiveTicks': 0,
          'exclusiveTicks': 0,
          'resolvedUrl': 'file:///Users/x/proj/lib/util.dart',
          'function': funcRef('helper', owner: libraryRef('file:///x')),
        },
      ];
      final result = a.finish(
        a.attribute(
          cpuSamples(
            functions: fns,
            samples: [
              cpuSample([1, 0]),
            ],
          ),
        ),
      );
      expect(
        classifier.classify('file:///Users/x/proj/lib/other.dart'),
        CodeOrigin.app,
      );
      expect(result.hotAppFunctions.first.name, 'helper');
      expect(result.hotAppFunctions.first.origin, CodeOrigin.app);
    },
  );

  test('counts samples that served the VM service', () {
    final attributor = CpuSampleAttributor(
      classifier: AppCodeClassifier(appPrefixes: {'package:my_app/'}),
      config: const JankDetectionConfig(),
    );
    final samples = cpuSamples(
      functions: [
        nativeFunction('dart::ProfilerService::PrintPerfettoCpuSamples'),
        profileFunction(
          funcRef('slow', owner: classRef('Thing', page)),
          resolvedUrl: 'file:///x/lib/page.dart',
        ),
      ],
      samples: [
        cpuSample([0, 1]),
        cpuSample([0, 1]),
        cpuSample([1]),
      ],
    );
    final result = attributor.finish(attributor.attribute(samples));
    expect(result.serviceTicks, 2);
    expect(result.usedSamples, 3);
  });

  test('recognises engine and system frames behind unsymbolized names', () {
    final attributor = CpuSampleAttributor(
      classifier: AppCodeClassifier(appPrefixes: {'package:my_app/'}),
      config: const JankDetectionConfig(),
    );
    final samples = cpuSamples(
      functions: [
        nativeFunction(
          '/data/app/~~x==/com.example.example-y==/base.apk!/lib/arm64-v8a/'
          'libflutter.so+0x1f89ed0',
        ),
        nativeFunction(
          '/apex/com.android.runtime/lib64/bionic/libc.so+0x41ae8',
        ),
        nativeFunction('syscall'),
        profileFunction(
          funcRef(
            'updateChild',
            owner: classRef(
              'Element',
              'package:flutter/src/widgets/framework.dart',
            ),
          ),
        ),
      ],
      samples: [
        cpuSample([0, 3]),
        cpuSample([0, 3]),
        cpuSample([1, 3]),
        cpuSample([2, 3]),
        cpuSample([3]),
      ],
    );
    final result = attributor.finish(attributor.attribute(samples));
    expect(result.engineTicks, 2);
    expect(result.systemTicks, 2);
    expect(result.isMostlyEngineWork, isTrue);
    expect(result.hasAppCode, isFalse);
    expect(
      result.hotOtherFunctions.first.name,
      '[Engine] libflutter.so+0x1f89ed0',
    );
    expect(
      result.hotOtherFunctions.map((f) => f.name),
      contains('[System] libc.so+0x41ae8'),
    );
    final report = SlowOperationReport(
      id: 'jank-1',
      detectedAt: DateTime(2026),
      kinds: const {JankKind.uiStall},
      windowStartMicros: 0,
      windowEndMicros: 200000,
      attribution: result,
      attributionState: AttributionState.attributed,
      signature: 'sig',
      firstSeen: DateTime(2026),
      lastSeen: DateTime(2026),
    );
    expect(report.subtitle, contains('Flutter engine / Dart VM'));
    expect(report.subtitle, contains('80%'));
    expect(report.toText(), contains('JIT compilation'));
  });

  test('reports no app code when only framework frames were sampled', () {
    final classifier = AppCodeClassifier(appPrefixes: {'package:my_app/'});
    final a = attributor(classifier);
    final result = a.finish(
      a.attribute(
        cpuSamples(
          functions: functions,
          samples: [
            cpuSample([5, 1]),
            cpuSample([1]),
          ],
        ),
      ),
    );
    expect(result.hasAppCode, isFalse);
    expect(result.hotAppFunctions, isEmpty);
    expect(result.appCallTree, isEmpty);
    expect(result.hotOtherFunctions.first.name, 'RenderBox.layout');
  });

  test('resolveLines fills missing line numbers from the script', () async {
    final classifier = AppCodeClassifier(appPrefixes: {'package:my_app/'});
    final a = attributor(classifier);
    final fns = [
      profileFunction(
        funcRef(
          'slow',
          owner: classRef('Thing', page),
          location: sourceLocation(page, tokenPos: 700),
        ),
      ),
    ];
    final draft = a.attribute(
      cpuSamples(
        functions: fns,
        samples: [
          cpuSample([0]),
        ],
      ),
    );
    final scriptId = scriptRef(page)['id'] as String;
    final api = FakeVmApi(
      objects: {
        scriptId: vms.Script.parse({
          'type': 'Script',
          'id': scriptId,
          'uri': page,
          'library': libraryRef(page),
          'tokenPosTable': [
            [30, 650, 1],
            [31, 700, 5, 710, 9],
          ],
        })!,
      },
    );
    await a.resolveLines(
      draft,
      api: api,
      isolateId: 'isolates/1',
      resolver: ScriptLineResolver(),
    );
    final result = a.finish(draft);
    expect(result.hotAppFunctions.single.location, 'lib/page.dart:31');
    expect(api.calls.where((c) => c == 'getObject'), hasLength(1));
  });

  test('qualifiedName walks closure owners and strips code tags', () {
    final ref = vms.FuncRef.parse(
      funcRef(
        '<anonymous closure>',
        owner: funcRef(
          '[Unoptimized] initState',
          owner: classRef('_PageState', page),
        ),
      ),
    )!;
    expect(
      CpuSampleAttributor.qualifiedName(ref),
      '_PageState.initState.<anonymous closure>',
    );
  });
}
