import 'package:dev_tools_light/src/vm/runtime_bridge_io.dart'
    if (dart.library.js_interop) 'package:dev_tools_light/src/vm/runtime_bridge_web.dart'
    as impl;
import 'package:dev_tools_light/src/vm/vm_api.dart';

/// Everything that needs `dart:io`, `dart:isolate` or the `dart:developer`
/// service APIs, behind an interface so the package compiles on the web and
/// so tests can fake the runtime.
abstract class RuntimeBridge {
  /// Whether the VM-service based features can work in this build.
  bool get isSupported;

  /// `dart:developer` `reachabilityBarrier` (0 on the web).
  int get reachabilityBarrier;

  /// The VM-service id of the current isolate, if the protocol is available.
  String? get currentIsolateId;

  /// The VM-service id of [object], if the protocol is available.
  String? objectIdOf(Object object);

  /// Whether the process runs under `flutter test`.
  bool get isFlutterTestEnvironment;

  /// The HTTP URI advertised by `Service.getInfo()`; optionally starts the
  /// server when it is not running.
  Future<Uri?> serviceUri({bool enableIfNeeded = false});

  /// Opens a connection to the VM service at [wsUri].
  Future<VmApi> connect(Uri wsUri);

  /// Whether this is a phone or tablet, where the tool's DDS runs on another
  /// machine.
  bool get isMobile;

  /// A host name that reaches the development machine's loopback interface
  /// from this device (`10.0.2.2` on the Android emulator), if any.
  Future<String?> hostLoopbackAlias();

  /// Runs [computation] off the UI isolate when the platform supports it.
  Future<R> compute<R>(R Function() computation);
}

/// The bridge for the current platform.
RuntimeBridge createRuntimeBridge() => impl.createRuntimeBridge();
