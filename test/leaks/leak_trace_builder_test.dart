import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/leaks/leak_trace.dart';
import 'package:dev_tools_light/src/leaks/leak_trace_builder.dart';
import 'package:dev_tools_light/src/leaks/reference_matchers.dart';
import 'package:dev_tools_light/src/vm/object_inspector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' as vms;

import '../helpers/fake_vm_api.dart';
import '../helpers/fixtures.dart';

void main() {
  const app = 'package:my_app/home.dart';
  const globals = 'package:my_app/globals.dart';
  final classifier = AppCodeClassifier(appPrefixes: {'package:my_app/'});
  final builder = LeakTraceBuilder(classifier: classifier);

  group('LeakTraceBuilder', () {
    test('renders a static list root, root first, with suspects', () async {
      final path = retainingPath([
        retainingObject(instanceRef('_HomePageState', app)),
        retainingObject(
          instanceRef('_GrowableList', 'dart:core', kind: 'List'),
          parentListIndex: 0,
        ),
        retainingObject(
          staticFieldRef(
            'retained',
            owner: classRef('AppEvents', globals),
            uri: globals,
            line: 12,
          ),
        ),
      ]);
      final trace = await builder.build(path, leakedTypeName: '_HomePageState');

      expect(trace.gcRootType, 'user global');
      expect(trace.nodes, hasLength(3));
      final root = trace.nodes[0];
      expect(root.className, 'AppEvents');
      expect(root.referenceKind, ReferenceKind.staticField);
      expect(root.referenceName, 'retained');
      expect(root.status, LeakStatus.notLeaking);
      expect(root.origin, CodeOrigin.app);
      expect(root.location, 'lib/globals.dart:12');
      expect(root.isSuspect, isTrue);
      final list = trace.nodes[1];
      expect(list.className, '_GrowableList');
      expect(list.referenceKind, ReferenceKind.listElement);
      expect(list.referenceName, '0');
      expect(list.origin, CodeOrigin.dart);
      expect(list.isSuspect, isTrue);
      final leaked = trace.leakedObject;
      expect(leaked.className, '_HomePageState');
      expect(leaked.status, LeakStatus.leaking);
      expect(leaked.origin, CodeOrigin.app);
      expect(leaked.isSuspect, isFalse);

      final text = trace.toText();
      expect(text, contains('GC Root: user global'));
      expect(text, contains('static AppEvents.retained'));
      expect(text, contains('~~~ suspect'));
      expect(text, contains('╰→ _HomePageState  [APP]'));
      expect(trace.summary, contains('AppEvents'));

      final again = await builder.build(path, leakedTypeName: '_HomePageState');
      expect(again.signature, trace.signature);
    });

    test('collapses closure contexts into one closure node', () async {
      final path = retainingPath([
        retainingObject(instanceRef('_HomePageState', app)),
        retainingObject(contextRef(), parentField: 1),
        retainingObject(
          closureRef(
            function: funcRef(
              '<anonymous closure>',
              owner: funcRef(
                'initState',
                owner: classRef('_HomePageState', app),
              ),
              location: sourceLocation(app, line: 40),
            ),
          ),
          parentField: 'context',
        ),
        retainingObject(
          instanceRef('_BroadcastSubscription', 'dart:async'),
          parentField: '_onData',
        ),
        retainingObject(
          instanceRef('_BroadcastStreamController', 'dart:async'),
          parentField: '_firstSubscription',
        ),
        retainingObject(
          staticFieldRef(
            'controller',
            owner: classRef('AppEvents', globals),
            uri: globals,
            line: 8,
          ),
        ),
      ]);
      final trace = await builder.build(path, leakedTypeName: '_HomePageState');

      expect(
        trace.nodes.map((n) => n.displayName),
        [
          'AppEvents',
          '_BroadcastStreamController',
          '_BroadcastSubscription',
          'closure _HomePageState.initState.<anonymous closure>',
          '_HomePageState',
        ],
      );
      final closure = trace.nodes[3];
      expect(closure.referenceKind, ReferenceKind.closureCapture);
      expect(closure.referenceName, '#1');
      expect(closure.location, 'lib/home.dart:40');
      expect(closure.origin, CodeOrigin.app);
      expect(closure.referenceDescription, 'captured variable #1');
      expect(
        trace.nodes[1].referenceDescription,
        '_BroadcastStreamController._firstSubscription',
      );
      // Different suspect chain → different signature.
      expect(
        trace.signature,
        isNot(
          equals(
            (await builder.build(
              retainingPath([
                retainingObject(instanceRef('_HomePageState', app)),
                retainingObject(
                  staticFieldRef(
                    'x',
                    owner: classRef('Other', globals),
                    uri: globals,
                  ),
                ),
              ]),
              leakedTypeName: '_HomePageState',
            )).signature,
          ),
        ),
      );
    });

    test('labels nodes with the inspector and narrows the suspects', () async {
      final statePath = retainingPath([
        retainingObject(
          instanceRef('_HomePageState', app, id: 'objects/state'),
        ),
        retainingObject(
          instanceRef('MyController', app, id: 'objects/ctrl'),
          parentField: '_state',
        ),
        retainingObject(
          instanceRef(
            'FocusManager',
            'package:flutter/src/widgets/focus_manager.dart',
            id: 'objects/fm',
          ),
          parentField: '_listener',
        ),
      ]);
      final api = FakeVmApi(
        objects: {
          'objects/ctrl': instance('objects/ctrl', 'MyController', app, [
            boundField(
              '_debugDisposed@12345',
              instanceRef(
                'bool',
                'dart:core',
                kind: 'Bool',
                valueAsString: 'false',
              ),
            ),
          ]),
        },
      );
      final trace = await builder.build(
        statePath,
        leakedTypeName: '_HomePageState',
        api: api,
        isolateId: 'isolates/1',
        inspector: ObjectInspector(maxInspections: 10),
      );
      expect(trace.nodes[0].status, LeakStatus.notLeaking);
      expect(trace.nodes[0].statusReason, 'framework singleton');
      expect(trace.nodes[1].status, LeakStatus.notLeaking);
      expect(trace.nodes[1].statusReason, 'ChangeNotifier is not disposed');
      expect(trace.nodes[0].isSuspect, isFalse);
      expect(trace.nodes[1].isSuspect, isTrue);
      expect(api.calls.where((c) => c == 'getObject'), hasLength(1));
    });

    test('ObjectInspector reads a defunct State', () async {
      final api = FakeVmApi(
        objects: {
          'objects/mid': instance('objects/mid', '_OtherState', app, [
            boundField(
              '_debugLifecycleState',
              instanceRef(
                '_StateLifecycle',
                'package:flutter/src/widgets/framework.dart',
                id: 'objects/enum',
              ),
            ),
          ]),
          'objects/enum': instance(
            'objects/enum',
            '_StateLifecycle',
            'package:flutter/src/widgets/framework.dart',
            [
              boundField(
                '_name',
                instanceRef(
                  'String',
                  'dart:core',
                  kind: 'String',
                  valueAsString: 'defunct',
                ),
              ),
            ],
          ),
        },
      );
      final inspector = ObjectInspector(maxInspections: 5);
      final inspection = await inspector.inspect(
        api,
        'isolates/1',
        vms.InstanceRef.parse(
          instanceRef('_OtherState', app, id: 'objects/mid'),
        )!,
      );
      expect(inspection?.status, LeakStatus.leaking);
      expect(inspection?.reason, 'State is defunct (disposed)');
      // Budget: two getObject calls used (the State and the enum value).
      expect(api.calls.where((c) => c == 'getObject'), hasLength(2));
    });

    test(
      'reference matchers match by class, static and instance field',
      () async {
        final trace = await builder.build(
          retainingPath([
            retainingObject(instanceRef('_HomePageState', app)),
            retainingObject(
              instanceRef(
                'WidgetInspectorService',
                'package:flutter/src/widgets/widget_inspector.dart',
              ),
              parentField: '_selection',
            ),
            retainingObject(
              staticFieldRef(
                'instance',
                owner: classRef(
                  'WidgetInspectorService',
                  'package:flutter/src/widgets/widget_inspector.dart',
                ),
                uri: 'package:flutter/src/widgets/widget_inspector.dart',
              ),
            ),
          ]),
          leakedTypeName: '_HomePageState',
        );
        expect(
          defaultReferenceMatchers.any((m) => m.matches(trace)),
          isTrue,
        );
        expect(
          const IgnoredReferenceMatcher(
            StaticFieldPattern('WidgetInspectorService', 'instance'),
            '',
          ).matches(trace),
          isTrue,
        );
        expect(
          const LibraryLeakReferenceMatcher(
            InstanceFieldPattern('WidgetInspectorService', '_selection'),
            '',
          ).matches(trace),
          isTrue,
        );
        expect(
          const IgnoredReferenceMatcher(
            ClassNamePattern('Nope'),
            '',
          ).matches(trace),
          isFalse,
        );
        expect(
          IgnoredReferenceMatcher(
            CustomPattern((n) => n.origin == CodeOrigin.app),
            '',
          ).matches(trace),
          isTrue,
        );
      },
    );

    test('an empty path still yields the leaked object', () async {
      final trace = await builder.build(
        retainingPath(const []),
        leakedTypeName: 'Thing',
      );
      expect(trace.nodes.single.className, 'Thing');
      expect(trace.nodes.single.status, LeakStatus.leaking);
    });
  });
}
