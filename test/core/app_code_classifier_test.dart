import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppCodeClassifier', () {
    late AppCodeClassifier classifier;

    setUp(() {
      classifier = AppCodeClassifier(appPrefixes: {'package:my_app/'});
    });

    test('classifies package and dart URIs', () {
      expect(classifier.classify('dart:core'), CodeOrigin.dart);
      expect(
        classifier.classify('package:flutter/src/widgets/framework.dart'),
        CodeOrigin.flutter,
      );
      expect(
        classifier.classify('package:flutter_test/flutter_test.dart'),
        CodeOrigin.flutter,
      );
      expect(classifier.classify('package:my_app/main.dart'), CodeOrigin.app);
      expect(classifier.classify('package:http/http.dart'), CodeOrigin.library);
      expect(
        classifier.classify('package:dev_tools_light/src/core/engine.dart'),
        CodeOrigin.tooling,
      );
      expect(
        classifier.classify('package:vm_service/vm_service.dart'),
        CodeOrigin.tooling,
      );
      expect(classifier.classify(null), CodeOrigin.unknown);
      expect(classifier.classify(''), CodeOrigin.unknown);
    });

    test('classifies file URIs', () {
      expect(
        classifier.classify(
          'file:///Users/x/.pub-cache/hosted/pub.dev/foo-1.0.0/lib/foo.dart',
        ),
        CodeOrigin.library,
      );
      expect(
        classifier.classify(
          'file:///Users/x/flutter/packages/flutter/lib/src/widgets/a.dart',
        ),
        CodeOrigin.flutter,
      );
      expect(
        classifier.classify('file:///Users/x/proj/lib/other.dart'),
        CodeOrigin.app,
      );
    });

    test('learns the app file root from a package/file pair', () {
      classifier.learnAppFileRoot(
        packageUri: 'package:my_app/pages/home.dart',
        fileUri: 'file:///Users/x/proj/lib/pages/home.dart',
      );
      expect(
        classifier.classify('file:///Users/x/proj/lib/other.dart'),
        CodeOrigin.app,
      );
      // A non-app package must not teach a root.
      classifier.learnAppFileRoot(
        packageUri: 'package:http/http.dart',
        fileUri: 'file:///Users/x/.pub-cache/hosted/pub.dev/http/lib/http.dart',
      );
      expect(
        classifier.classify(
          'file:///Users/x/.pub-cache/hosted/pub.dev/http/lib/other.dart',
        ),
        CodeOrigin.library,
      );
    });

    test('recognises the tooling by file path', () {
      expect(
        classifier.classify(
          'file:///Users/x/dev_tools_light/lib/src/core/engine.dart',
        ),
        CodeOrigin.tooling,
      );
      expect(
        classifier.classify(
          'file:///Users/x/.pub-cache/hosted/pub.dev/vm_service-15.3.0/lib/a.dart',
        ),
        CodeOrigin.tooling,
      );
    });

    test('isAppUri override wins over every other rule', () {
      final custom = AppCodeClassifier(
        isAppUri: (uri) => uri.contains('special'),
      );
      expect(
        custom.classify('package:flutter/special.dart'),
        CodeOrigin.app,
      );
      expect(custom.classify('package:flutter/a.dart'), CodeOrigin.flutter);
    });

    test('addAppPrefixes extends the app set', () {
      expect(classifier.classify('package:my_core/a.dart'), CodeOrigin.library);
      classifier.addAppPrefixes({'package:my_core/'});
      expect(classifier.classify('package:my_core/a.dart'), CodeOrigin.app);
    });

    test('displayPath and packageNameOf', () {
      expect(
        AppCodeClassifier.displayPath('package:my_app/a/b.dart'),
        'lib/a/b.dart',
      );
      expect(
        AppCodeClassifier.displayPath('file:///x/proj/lib/a.dart'),
        'lib/a.dart',
      );
      expect(
        AppCodeClassifier.displayPath('file:///x/proj/test/a_test.dart'),
        'test/a_test.dart',
      );
      expect(AppCodeClassifier.displayPath('dart:core'), 'dart:core');
      expect(AppCodeClassifier.packageNameOf('package:foo/bar.dart'), 'foo');
      expect(AppCodeClassifier.packageNameOf('dart:core'), isNull);
    });
  });
}
