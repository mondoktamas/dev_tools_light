import 'package:dev_tools_light/src/vm/function_locator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' as vms;

import '../helpers/fake_vm_api.dart';
import '../helpers/fixtures.dart';

void main() {
  const page = 'package:my_app/page.dart';
  late FakeVmApi api;

  setUp(() {
    final script = scriptRef(page);
    final scriptId = script['id'] as String;
    api = FakeVmApi(
      libraries: const [
        {'id': 'libraries/1', 'uri': page},
      ],
      objects: {
        'libraries/1': vms.Library.parse({
          'type': 'Library',
          'id': 'libraries/1',
          'name': 'page',
          'uri': page,
          'debuggable': true,
          'dependencies': <Object?>[],
          'scripts': [script],
          'variables': <Object?>[],
          'functions': [
            funcRef(
              'topLevel',
              owner: libraryRef(page),
              location: sourceLocation(page),
            ),
          ],
          'classes': [classRef('Thing', page)],
        })!,
        'classes/Thing': vms.Class.parse({
          'type': 'Class',
          'id': 'classes/Thing',
          'name': 'Thing',
          'library': libraryRef(page),
          'abstract': false,
          'const': false,
          'isSealed': false,
          'isMixinClass': false,
          'isBaseClass': false,
          'isInterfaceClass': false,
          'isFinal': false,
          'traceAllocations': false,
          'interfaces': <Object?>[],
          'fields': <Object?>[],
          'functions': [
            funcRef(
              'slow',
              owner: classRef('Thing', page),
              location: sourceLocation(page, tokenPos: 700),
            ),
          ],
          'subclasses': <Object?>[],
        })!,
        scriptId: vms.Script.parse({
          'type': 'Script',
          'id': scriptId,
          'uri': page,
          'library': libraryRef(page),
          'tokenPosTable': [
            [3, 100, 1],
            [31, 700, 5],
          ],
        })!,
      },
    );
  });

  test('locates a method, a closure and a top-level function', () async {
    final locator = FunctionLocator();
    expect(
      await locator.lineFor(
        api,
        'isolates/1',
        uri: page,
        qualifiedName: 'Thing.slow',
      ),
      31,
    );
    expect(
      await locator.lineFor(
        api,
        'isolates/1',
        uri: page,
        qualifiedName: 'Thing.slow.<anonymous closure>',
      ),
      31,
      reason: 'closures resolve to their enclosing method',
    );
    expect(
      await locator.lineFor(
        api,
        'isolates/1',
        uri: page,
        qualifiedName: 'topLevel',
      ),
      3,
    );
    expect(
      await locator.lineFor(
        api,
        'isolates/1',
        uri: page,
        qualifiedName: 'Missing.nope',
      ),
      isNull,
    );
    expect(
      await locator.lineFor(
        api,
        'isolates/1',
        uri: 'package:other/x.dart',
        qualifiedName: 'Thing.slow',
      ),
      isNull,
    );
    // Isolate, library, class and script were each fetched once.
    expect(api.calls.where((c) => c == 'getIsolate'), hasLength(1));
    expect(api.calls.where((c) => c == 'getObject'), hasLength(3));
  });
}
