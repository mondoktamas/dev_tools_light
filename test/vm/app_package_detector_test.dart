import 'package:dev_tools_light/src/vm/app_package_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' as vms;

import '../helpers/fake_vm_api.dart';

void main() {
  test('packageDirectoryOf finds the package root of a test file', () {
    expect(
      AppPackageDetector.packageDirectoryOf(
        'file:///Users/x/proj/example/integration_test/leak_test.dart',
      ),
      '/Users/x/proj/example',
    );
    expect(
      AppPackageDetector.packageDirectoryOf(
        'file:///Users/x/proj/test/widgets/home_test.dart',
      ),
      '/Users/x/proj',
    );
    expect(
      AppPackageDetector.packageDirectoryOf(
        'file:///C:/dev/app/lib/main.dart',
      ),
      '/C:/dev/app',
    );
    expect(
      AppPackageDetector.packageDirectoryOf('package:my_app/main.dart'),
      isNull,
    );
    expect(
      AppPackageDetector.packageDirectoryOf('file:///tmp/scratch.dart'),
      isNull,
    );
  });

  test(
    'detect picks the package whose lib/ contains the root directory',
    () async {
      final api = FakeVmApi(
        rootLibraryUri:
            'file:///Users/x/proj/example/integration_test/leak_test.dart',
        libraries: const [
          {'id': 'libraries/1', 'uri': 'package:flutter/material.dart'},
          {
            'id': 'libraries/2',
            'uri': 'package:dev_tools_light/dev_tools_light.dart',
          },
          {'id': 'libraries/3', 'uri': 'package:my_app_example/main.dart'},
          {'id': 'libraries/4', 'uri': 'package:my_app_example/pages.dart'},
          {'id': 'libraries/5', 'uri': 'dart:core'},
        ],
        resolvedPackageUris: const {
          'package:flutter/material.dart':
              'file:///Users/x/flutter/packages/flutter/lib/material.dart',
          'package:dev_tools_light/dev_tools_light.dart':
              'file:///Users/x/proj/lib/dev_tools_light.dart',
          'package:my_app_example/main.dart':
              'file:///Users/x/proj/example/lib/main.dart',
        },
      );
      final learned = <String>[];
      final prefix = await const AppPackageDetector().detect(
        api,
        isolateId: 'isolates/1',
        isolate: await api.getIsolate('isolates/1'),
        learn: (packageUri, fileUri) => learned.add('$packageUri -> $fileUri'),
      );
      expect(prefix, 'package:my_app_example/');
      const mainLibrary = 'package:my_app_example/main.dart';
      expect(learned, [
        '$mainLibrary -> file:///Users/x/proj/example/lib/main.dart',
      ]);
      expect(
        api.calls.where((c) => c == 'lookupResolvedPackageUris'),
        hasLength(1),
      );
    },
  );

  test('detect follows a generated listener to the test file', () async {
    const listener =
        'file:///var/folders/T/flutter_tools.x/flutter_test_listener.y/'
        'listener.dart';
    final api = FakeVmApi(
      rootLibraryUri: listener,
      objects: {
        'libraries/root': vms.Library(
          id: 'libraries/root',
          uri: listener,
          name: '',
          debuggable: true,
          dependencies: [
            vms.LibraryDependency(
              isImport: true,
              isDeferred: false,
              target: vms.LibraryRef(
                id: 'libraries/8',
                uri: 'package:flutter_test/flutter_test.dart',
                name: '',
              ),
            ),
            vms.LibraryDependency(
              isImport: true,
              isDeferred: false,
              target: vms.LibraryRef(
                id: 'libraries/9',
                uri: 'file:///Users/x/proj/test/vm/real_vm_test.dart',
                name: '',
              ),
            ),
          ],
          scripts: [],
          variables: [],
          functions: [],
          classes: [],
        ),
      },
      libraries: const [
        {'id': 'libraries/2', 'uri': 'package:my_pkg/my_pkg.dart'},
        {'id': 'libraries/3', 'uri': 'package:flutter_test/flutter_test.dart'},
      ],
      resolvedPackageUris: const {
        'package:my_pkg/my_pkg.dart': 'file:///Users/x/proj/lib/my_pkg.dart',
        'package:flutter_test/flutter_test.dart':
            'file:///Users/x/flutter/packages/flutter_test/lib/flutter_test.dart',
      },
    );
    expect(
      await const AppPackageDetector().detect(
        api,
        isolateId: 'isolates/1',
        isolate: await api.getIsolate('isolates/1'),
      ),
      'package:my_pkg/',
    );
  });

  test('detect gives up without a file root or a matching package', () async {
    final api = FakeVmApi(
      libraries: const [
        {'id': 'libraries/3', 'uri': 'package:my_app/main.dart'},
      ],
    );
    expect(
      await const AppPackageDetector().detect(
        api,
        isolateId: 'isolates/1',
        isolate: await api.getIsolate('isolates/1'),
      ),
      isNull,
      reason: 'a package: root is handled elsewhere',
    );
    final noMatch = FakeVmApi(
      rootLibraryUri: 'file:///Users/x/other/test/a_test.dart',
      libraries: const [
        {'id': 'libraries/3', 'uri': 'package:my_app/main.dart'},
      ],
      resolvedPackageUris: const {
        'package:my_app/main.dart': 'file:///Users/x/proj/lib/main.dart',
      },
    );
    expect(
      await const AppPackageDetector().detect(
        noMatch,
        isolateId: 'isolates/1',
        isolate: await noMatch.getIsolate('isolates/1'),
      ),
      isNull,
    );
  });
}
