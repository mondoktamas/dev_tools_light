import 'dart:async';

import 'package:flutter/foundation.dart';

/// App-wide singletons that (deliberately) retain things.
class AppEvents {
  AppEvents._();

  /// A broadcast stream that outlives every page.
  static final StreamController<int> controller =
      StreamController<int>.broadcast();

  static Stream<int> get stream => controller.stream;

  /// A static list that some pages (wrongly) add themselves to.
  static final List<Object> retained = <Object>[];

  static int _tick = 0;

  static void emit() => controller.add(_tick++);
}

/// A global notifier pages (wrongly) subscribe to without unsubscribing.
final ValueNotifier<int> globalCounter = ValueNotifier<int>(0);
