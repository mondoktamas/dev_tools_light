import 'package:dev_tools_light/src/vm/runtime_bridge.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';

/// Creates the web bridge (everything unsupported).
RuntimeBridge createRuntimeBridge() => const WebRuntimeBridge();

/// [RuntimeBridge] for the web, where there is no VM service.
class WebRuntimeBridge implements RuntimeBridge {
  /// Const constructor.
  const WebRuntimeBridge();

  @override
  bool get isSupported => false;

  @override
  int get reachabilityBarrier => 0;

  @override
  String? get currentIsolateId => null;

  @override
  String? objectIdOf(Object object) => null;

  @override
  bool get isFlutterTestEnvironment => false;

  @override
  Future<Uri?> serviceUri({bool enableIfNeeded = false}) async => null;

  @override
  Future<VmApi> connect(Uri wsUri) =>
      throw UnsupportedError('The VM service is not available on the web.');

  @override
  bool get isMobile => false;

  @override
  Future<String?> hostLoopbackAlias() async => null;

  @override
  Future<R> compute<R>(R Function() computation) => Future.sync(computation);
}
