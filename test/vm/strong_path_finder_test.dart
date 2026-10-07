import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/leaks/leak_trace_builder.dart';
import 'package:dev_tools_light/src/vm/strong_path_finder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' as vms;

import '../helpers/fake_vm_api.dart';
import '../helpers/fixtures.dart';

void main() {
  const app = 'package:my_app/cache.dart';
  const core = 'dart:core';

  /// Class names along a path, target first (`@Field` for static fields).
  List<String> names(vms.RetainingPath path) => [
    for (final element in path.elements!)
      switch (element.value) {
        final vms.InstanceRef ref => ref.classRef!.name!,
        final value => value!.type,
      },
  ];

  /// The VM's answer for an object that is an `Expando` key: it runs through
  /// the weak property although something else holds the object strongly.
  vms.RetainingPath weakPath() => retainingPath([
    retainingObject(instanceRef('Holder', app, id: 'objects/h')),
    retainingObject(instanceRef('_WeakProperty', core, id: 'objects/wp')),
    retainingObject(
      instanceRef('_List', core, kind: 'List', id: 'objects/data'),
      parentListIndex: 5,
    ),
    retainingObject(
      instanceRef('Expando', core, id: 'objects/e'),
      parentField: '_data',
    ),
    retainingObject(
      staticFieldRef('expando', owner: libraryRef(app), uri: app),
    ),
  ]);

  Map<String, dynamic> list(String id) =>
      instanceRef('_GrowableList', core, kind: 'List', id: id);

  test('firstWeakLink finds the weak holder', () {
    expect(StrongPathFinder.firstWeakLink(weakPath()), 1);
    expect(
      StrongPathFinder.firstWeakLink(
        retainingPath([
          retainingObject(instanceRef('Holder', app)),
          retainingObject(list('objects/list'), parentListIndex: 0),
        ]),
      ),
      -1,
    );
    expect(StrongPathFinder.firstWeakLink(retainingPath(const [])), -1);
  });

  test('splices the strong retainer of the target in', () async {
    final api = FakeVmApi(
      inboundReferences: {
        'objects/h': inboundReferences([
          inboundReference(
            instanceRef('_WeakProperty', core, id: 'objects/wp'),
          ),
          inboundReference(
            list('objects/list'),
            parentField: 0,
            parentListIndex: 0,
          ),
        ]),
      },
      retainingPaths: {
        'objects/list': retainingPath([
          retainingObject(list('objects/list')),
          retainingObject(
            staticFieldRef(
              'entries',
              owner: classRef('Cache', app),
              uri: app,
              line: 3,
            ),
          ),
        ], gcRootType: 'static fields table'),
      },
    );
    final result = await const StrongPathFinder().find(
      api,
      isolateId: 'isolates/1',
      path: weakPath(),
      limit: 100,
    );
    final path = result.path;
    expect(path, isNotNull, reason: result.detail);
    expect(result.lookups, 2);
    expect(result.weakHolder, '_WeakProperty');
    expect(path!.gcRootType, 'static fields table');
    expect(names(path), ['Holder', '_GrowableList', '@Field']);
    expect(path.elements![1].parentListIndex, 0);

    final trace =
        await LeakTraceBuilder(
          classifier: AppCodeClassifier(appPrefixes: {'package:my_app/'}),
        ).build(
          path,
          leakedTypeName: 'Holder',
          note: 'found behind a weak reference',
        );
    expect(trace.viaWeakReference, isFalse);
    expect(
      trace.nodes.map((n) => n.displayName),
      ['Cache', '_GrowableList', 'Holder'],
    );
    expect(trace.nodes[1].referenceDescription, '[0]');
    expect(trace.nodes[0].location, 'lib/cache.dart:3');
    expect(trace.toText(), contains('Note: found behind a weak reference'));
  });

  test(
    'keeps the strong prefix and recurses through a second weak link',
    () async {
      final path = retainingPath([
        retainingObject(instanceRef('Holder', app, id: 'objects/h')),
        retainingObject(
          instanceRef('Owner', app, id: 'objects/a'),
          parentField: '_holder',
        ),
        retainingObject(instanceRef('_WeakReference', core, id: 'objects/wr')),
        retainingObject(
          instanceRef('Registry', app, id: 'objects/r'),
          parentField: '_ref',
        ),
        retainingObject(
          staticFieldRef('registry', owner: libraryRef(app), uri: app),
        ),
      ]);
      final api = FakeVmApi(
        inboundReferences: {
          'objects/a': inboundReferences([
            inboundReference(
              instanceRef('_WeakReference', core, id: 'objects/wr'),
            ),
            // Garbage pinned by the object-id ring: no path.
            inboundReference(
              instanceRef('Dead', app, id: 'objects/dead'),
              parentField: 'x',
            ),
            inboundReference(
              instanceRef('Service', app, id: 'objects/b'),
              parentField: '_owner',
            ),
          ]),
          'objects/b': inboundReferences([
            inboundReference(
              instanceRef('App', app, id: 'objects/c'),
              parentField: '_service',
            ),
          ]),
        },
        retainingPaths: {
          'objects/dead': retainingPath(const [], gcRootType: 'class table'),
          'objects/b': retainingPath([
            retainingObject(instanceRef('Service', app, id: 'objects/b')),
            retainingObject(
              instanceRef('_WeakProperty', core, id: 'objects/wp2'),
            ),
            retainingObject(
              instanceRef('Expando', core, id: 'objects/e2'),
              parentField: '_data',
            ),
          ]),
          'objects/c': retainingPath([
            retainingObject(instanceRef('App', app, id: 'objects/c')),
            retainingObject(
              staticFieldRef('app', owner: libraryRef(app), uri: app),
            ),
          ]),
        },
      );
      final result = await const StrongPathFinder().find(
        api,
        isolateId: 'isolates/1',
        path: path,
        limit: 100,
      );
      final found = result.path;
      expect(found, isNotNull, reason: result.detail);
      expect(names(found!), ['Holder', 'Owner', 'Service', 'App', '@Field']);
      expect(found.elements![1].parentField, '_holder');
      expect(found.elements![2].parentField, '_owner');
      expect(found.elements![3].parentField, '_service');
      expect(result.weakHolder, '_WeakReference');
      // inbound(a), path(dead), path(b), inbound(b), path(c)
      expect(result.lookups, 5);
      expect(api.calls.where((c) => c == 'getRetainingPath'), hasLength(3));
    },
  );

  test(
    'gives up without strong retainers or when the budget is spent',
    () async {
      final weakOnly = FakeVmApi(
        inboundReferences: {
          'objects/h': inboundReferences([
            inboundReference(
              instanceRef('_WeakProperty', core, id: 'objects/wp'),
            ),
            inboundReference(
              instanceRef('FinalizerEntry', core, id: 'objects/fe'),
            ),
          ]),
        },
      );
      final none = await const StrongPathFinder().find(
        weakOnly,
        isolateId: 'isolates/1',
        path: weakPath(),
        limit: 100,
      );
      expect(none.path, isNull);
      expect(none.detail, contains('no strong retainer'));
      expect(none.lookups, 1);

      final api = FakeVmApi(
        inboundReferences: {
          'objects/h': inboundReferences([
            inboundReference(list('objects/list'), parentField: 0),
          ]),
        },
        retainingPaths: {
          'objects/list': retainingPath([
            retainingObject(list('objects/list')),
            retainingObject(
              staticFieldRef(
                'entries',
                owner: classRef('Cache', app),
                uri: app,
              ),
            ),
          ]),
        },
      );
      final limited = await const StrongPathFinder(maxLookups: 1).find(
        api,
        isolateId: 'isolates/1',
        path: weakPath(),
        limit: 100,
      );
      expect(limited.path, isNull);
      expect(limited.detail, contains('budget'));

      final strong = await const StrongPathFinder().find(
        api,
        isolateId: 'isolates/1',
        path: retainingPath([
          retainingObject(instanceRef('Holder', app, id: 'objects/h')),
          retainingObject(list('objects/list'), parentListIndex: 0),
        ]),
        limit: 100,
      );
      expect(strong.path, isNull);
      expect(strong.lookups, 0);
    },
  );
}
