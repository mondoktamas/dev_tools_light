import 'package:dev_tools_light/src/vm/runtime_bridge.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';

import 'fake_vm_api.dart';

/// A scriptable [RuntimeBridge].
class FakeRuntimeBridge implements RuntimeBridge {
  FakeRuntimeBridge({
    this.serviceUris = const [],
    this.enabledUri,
    this.isSupported = true,
    this.isFlutterTestEnvironment = false,
    this.isMobile = false,
    this.loopbackAlias,
    FakeVmApi Function()? apiFactory,
  }) : apiFactory = apiFactory ?? FakeVmApi.new;

  /// Successive answers of [serviceUri]; the last one repeats.
  final List<Uri?> serviceUris;

  /// Answer of [serviceUri] with `enableIfNeeded: true`.
  final Uri? enabledUri;

  /// Answer of [hostLoopbackAlias].
  final String? loopbackAlias;

  final FakeVmApi Function() apiFactory;
  final List<Uri> connectedTo = [];
  final List<FakeVmApi> apis = [];
  int serviceUriCalls = 0;
  int barrier = 0;

  /// Thrown by every [connect].
  Exception? connectError;

  /// Thrown by [connect] for the given URI (takes precedence).
  Exception? Function(Uri uri)? connectErrorFor;

  @override
  final bool isSupported;

  @override
  final bool isFlutterTestEnvironment;

  @override
  final bool isMobile;

  @override
  int get reachabilityBarrier => barrier;

  @override
  String? get currentIsolateId => 'isolates/1';

  @override
  String? objectIdOf(Object object) => 'objects/${identityHashCode(object)}';

  @override
  Future<Uri?> serviceUri({bool enableIfNeeded = false}) async {
    if (enableIfNeeded) {
      return enabledUri;
    }
    if (serviceUris.isEmpty) {
      return null;
    }
    final index = serviceUriCalls.clamp(0, serviceUris.length - 1);
    serviceUriCalls++;
    return serviceUris[index];
  }

  @override
  Future<VmApi> connect(Uri wsUri) async {
    connectedTo.add(wsUri);
    final error = connectErrorFor?.call(wsUri) ?? connectError;
    if (error != null) {
      throw error;
    }
    final api = apiFactory();
    apis.add(api);
    return api;
  }

  @override
  Future<String?> hostLoopbackAlias() async => loopbackAlias;

  @override
  Future<R> compute<R>(R Function() computation) => Future.sync(computation);
}
