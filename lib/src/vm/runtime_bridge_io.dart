import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:dev_tools_light/src/vm/runtime_bridge.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:vm_service/vm_service_io.dart';

/// Creates the `dart:io` bridge.
RuntimeBridge createRuntimeBridge() => const IoRuntimeBridge();

/// [RuntimeBridge] for VM platforms.
class IoRuntimeBridge implements RuntimeBridge {
  /// Const constructor.
  const IoRuntimeBridge();

  @override
  bool get isSupported => !kReleaseMode;

  @override
  int get reachabilityBarrier => developer.reachabilityBarrier;

  @override
  String? get currentIsolateId =>
      developer.Service.getIsolateId(Isolate.current);

  @override
  String? objectIdOf(Object object) => developer.Service.getObjectId(object);

  @override
  bool get isFlutterTestEnvironment =>
      Platform.environment['FLUTTER_TEST'] == 'true';

  @override
  Future<Uri?> serviceUri({bool enableIfNeeded = false}) async {
    var info = await developer.Service.getInfo();
    if (info.serverUri == null && enableIfNeeded) {
      info = await developer.Service.controlWebServer(enable: true);
    }
    return info.serverUri;
  }

  @override
  Future<VmApi> connect(Uri wsUri) async {
    final service = await vmServiceConnectUri(wsUri.toString());
    return VmServiceApi(service);
  }

  @override
  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  // Only the resolved value is cached: a `Future` kept in a static field
  // retains the zone it was created in, which in a test process reaches the
  // test framework and from there anything an in-flight test holds, and the
  // VM would happily report that as a retaining path.
  static String? _alias;
  static bool _aliasResolved = false;

  @override
  Future<String?> hostLoopbackAlias() async {
    if (!_aliasResolved) {
      _alias = await _detectHostLoopbackAlias();
      _aliasResolved = true;
    }
    return _alias;
  }

  /// The Android emulator's NAT puts the guest in `10.0.2.0/24` and exposes
  /// the host's loopback interface as `10.0.2.2`.
  static Future<String?> _detectHostLoopbackAlias() async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.address.startsWith('10.0.2.')) {
            return '10.0.2.2';
          }
        }
      }
    } on Object catch (_) {
      // Listing interfaces may be restricted; try the device nodes.
    }
    for (final path in const ['/dev/goldfish_pipe', '/dev/qemu_pipe']) {
      try {
        if (File(path).existsSync()) {
          return '10.0.2.2';
        }
      } on Object catch (_) {
        // Not accessible; keep looking.
      }
    }
    return null;
  }

  @override
  Future<R> compute<R>(R Function() computation) => Isolate.run(computation);
}
