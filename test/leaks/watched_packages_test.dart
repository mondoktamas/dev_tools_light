import 'package:dev_tools_light/src/core/app_code_classifier.dart';
import 'package:dev_tools_light/src/core/code_origin.dart';
import 'package:dev_tools_light/src/leaks/package_watch_policy.dart';
import 'package:dev_tools_light/src/leaks/watched_packages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WatchedPackages decides by origin and package', () {
    const defaults = WatchedPackages.defaults;
    expect(defaults.allows(CodeOrigin.app, 'my_app'), isTrue);
    expect(defaults.allows(CodeOrigin.flutter, 'flutter'), isTrue);
    expect(defaults.allows(CodeOrigin.library, 'go_router'), isFalse);
    expect(defaults.allows(CodeOrigin.dart, null), isTrue);
    expect(defaults.allows(CodeOrigin.tooling, 'dev_tools_light'), isFalse);
    expect(WatchedPackages.all.allows(CodeOrigin.library, 'go_router'), isTrue);
    expect(
      WatchedPackages.appOnly.allows(CodeOrigin.flutter, 'flutter'),
      isFalse,
    );
    const custom = WatchedPackages(
      include: KnownPackages.bloc,
      exclude: {'flutter'},
    );
    expect(custom.allows(CodeOrigin.library, 'flutter_bloc'), isTrue);
    expect(custom.allows(CodeOrigin.library, 'provider'), isFalse);
    expect(
      custom.allows(CodeOrigin.flutter, 'flutter'),
      isFalse,
      reason: 'exclude wins',
    );
    expect(
      custom.copyWith(thirdParty: true).allows(CodeOrigin.library, 'provider'),
      isTrue,
    );
  });

  group('PackageWatchPolicy', () {
    test('learns libraries per type and allows unknown types', () {
      final policy = PackageWatchPolicy(
        config: WatchedPackages.defaults,
        classifier: AppCodeClassifier(appPrefixes: {'package:my_app/'}),
      );
      expect(policy.allowsType(int), isNull);
      policy.learn(int, 'package:go_router/src/router.dart');
      expect(policy.allowsType(int), isFalse);
      policy.learn(String, 'package:my_app/home.dart');
      expect(policy.allowsType(String), isTrue);
      policy.learn(double, 'package:flutter/src/widgets/framework.dart');
      expect(policy.allowsType(double), isTrue);
      expect(policy.knownTypes, 3);
      expect(
        policy.describeLibrary('package:go_router/src/router.dart'),
        'package go_router',
      );
      expect(
        policy.describeLibrary('package:flutter/src/widgets/framework.dart'),
        'the Flutter SDK',
      );
      expect(policy.describeLibrary('dart:core'), 'dart:core');
    });

    test('allows everything until the app package is known', () {
      final classifier = AppCodeClassifier();
      final policy = PackageWatchPolicy(
        config: WatchedPackages.appOnly,
        classifier: classifier,
      );
      expect(policy.allowsLibrary('package:go_router/src/router.dart'), isTrue);
      classifier.addAppPrefixes({'package:my_app/'});
      expect(
        policy.allowsLibrary('package:go_router/src/router.dart'),
        isFalse,
      );
      expect(policy.allowsLibrary('package:my_app/home.dart'), isTrue);
    });
  });
}
