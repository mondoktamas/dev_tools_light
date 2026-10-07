import 'package:dev_tools_light/src/core/status.dart';
import 'package:dev_tools_light/src/vm/vm_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_runtime_bridge.dart';

void main() {
  final rawUri = Uri.parse('http://127.0.0.1:1111/raw=/');
  final ddsUri = Uri.parse('http://127.0.0.1:2222/dds=/');

  VmSession session(
    FakeRuntimeBridge bridge, {
    String? connected,
    Duration grace = const Duration(seconds: 10),
    int Function()? now,
  }) {
    var ticks = 0;
    return VmSession(
      bridge: bridge,
      now: now ?? () => ticks++ * 1000000, // one second per call
      discoveryGrace: grace,
      pollInterval: Duration.zero,
      connectedUri: () => connected,
    );
  }

  test('toWebSocketUri converts http URIs and keeps ws ones', () {
    expect(
      VmSession.toWebSocketUri(rawUri).toString(),
      'ws://127.0.0.1:1111/raw=/ws',
    );
    expect(
      VmSession.toWebSocketUri(Uri.parse('https://h:1/t=/')).toString(),
      'wss://h:1/t=/ws',
    );
    expect(
      VmSession.toWebSocketUri(Uri.parse('ws://h:1/t=/ws')).toString(),
      'ws://h:1/t=/ws',
    );
  });

  test('uses connectedVmServiceUri as soon as the tool sets it', () async {
    final bridge = FakeRuntimeBridge(serviceUris: [rawUri]);
    final s = session(bridge, connected: ddsUri.toString());
    expect((await s.discover()).toString(), 'ws://127.0.0.1:2222/dds=/ws');
    expect(bridge.serviceUriCalls, 1, reason: 'only the initial lookup');
  });

  test('switches to the advertised URI when DDS takes over', () async {
    final bridge = FakeRuntimeBridge(serviceUris: [rawUri, rawUri, ddsUri]);
    final s = session(bridge);
    expect((await s.discover()).toString(), 'ws://127.0.0.1:2222/dds=/ws');
  });

  test('falls back to the initial URI after the grace period', () async {
    final bridge = FakeRuntimeBridge(serviceUris: [rawUri]);
    final s = session(bridge, grace: const Duration(seconds: 3));
    expect((await s.discover()).toString(), 'ws://127.0.0.1:1111/raw=/ws');
    expect(bridge.serviceUriCalls, greaterThan(1));
  });

  test('starts the server itself when none is running', () async {
    final bridge = FakeRuntimeBridge(serviceUris: [null], enabledUri: rawUri);
    final s = session(bridge);
    expect((await s.discover()).toString(), 'ws://127.0.0.1:1111/raw=/ws');
  });

  test('fails when there is no VM service at all', () async {
    final bridge = FakeRuntimeBridge(serviceUris: [null]);
    final s = session(bridge);
    expect(await s.discover(), isNull);
    expect(s.state, VmConnectionState.failed);
    await expectLater(
      s.run((api) async => 1),
      throwsA(isA<VmUnavailableException>()),
    );
  });

  test('is unsupported on platforms without a VM service', () async {
    final bridge = FakeRuntimeBridge(isSupported: false);
    final s = session(bridge);
    expect(await s.discover(), isNull);
    expect(s.state, VmConnectionState.unsupported);
  });

  test(
    'run shares one connection and disposes it after the last caller',
    () async {
      final bridge = FakeRuntimeBridge(serviceUris: [rawUri]);
      final s = session(bridge, connected: rawUri.toString());
      final results = await Future.wait([
        s.run((api) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 'a';
        }),
        s.run((api) async => 'b'),
      ]);
      expect(results, ['a', 'b']);
      expect(bridge.apis, hasLength(1));
      expect(bridge.apis.single.disposeCount, 1);
      expect(s.state, VmConnectionState.reachable);

      await s.run((api) async => 'c');
      expect(bridge.apis, hasLength(2), reason: 'a fresh ephemeral connection');
    },
  );

  test(
    'a failed connection marks the session failed and re-discovers',
    () async {
      var t = 0;
      final bridge = FakeRuntimeBridge(serviceUris: [rawUri])
        ..connectError = Exception('refused');
      final s = session(bridge, connected: rawUri.toString(), now: () => t);
      await expectLater(
        s.run((api) async => 1),
        throwsA(isA<VmUnavailableException>()),
      );
      expect(s.state, VmConnectionState.failed);
      expect(s.lastError, contains('refused'));
      expect(s.webSocketUri, isNull);
      expect(s.unreachableUris, hasLength(1));

      bridge.connectError = null;
      // The URI is left alone for a minute before it is tried again.
      await expectLater(
        s.run((api) async => 1),
        throwsA(isA<VmUnavailableException>()),
      );
      expect(bridge.connectedTo, hasLength(1));
      t += const Duration(seconds: 61).inMicroseconds;
      expect(await s.run((api) async => 2), 2);
      expect(s.state, VmConnectionState.reachable);
    },
  );

  test('tries the emulator host alias when the loopback URI refuses', () async {
    final bridge =
        FakeRuntimeBridge(
            serviceUris: [rawUri, ddsUri],
            loopbackAlias: '10.0.2.2',
          )
          ..connectErrorFor = (uri) =>
              uri.host == '127.0.0.1' ? Exception('refused') : null;
    final s = session(bridge, connected: ddsUri.toString());
    expect(await s.run((api) async => 1), 1);
    expect(bridge.connectedTo.map((u) => u.toString()), [
      'ws://127.0.0.1:2222/dds=/ws',
      'ws://10.0.2.2:2222/dds=/ws',
    ]);
    expect(s.webSocketUri.toString(), 'ws://10.0.2.2:2222/dds=/ws');
  });

  test('explains an unreachable DDS on a device and stops retrying', () async {
    final bridge = FakeRuntimeBridge(
      serviceUris: [rawUri, ddsUri],
      isMobile: true,
    )..connectError = Exception('Connection refused');
    final s = session(
      bridge,
      connected: ddsUri.toString(),
      grace: Duration.zero,
    );
    await expectLater(
      s.run((api) async => 1),
      throwsA(isA<VmUnavailableException>()),
    );
    expect(s.lastError, contains('--no-dds'));
    final attempts = bridge.connectedTo.length;
    await expectLater(
      s.run((api) async => 1),
      throwsA(isA<VmUnavailableException>()),
    );
    expect(
      bridge.connectedTo.length,
      attempts,
      reason: 'known unreachable URIs are not retried immediately',
    );
  });

  test('uses the in-process service once the tool has detached', () async {
    // When DDS goes away the advertised URI reverts to the in-process one,
    // while connectedVmServiceUri keeps pointing at the dead DDS.
    final bridge =
        FakeRuntimeBridge(
            serviceUris: [rawUri, ddsUri, ddsUri, ddsUri, ddsUri, rawUri],
          )
          ..connectErrorFor = (uri) =>
              uri.port == 2222 ? Exception('refused') : null;
    final s = session(
      bridge,
      connected: ddsUri.toString(),
      grace: Duration.zero,
    );
    int? result;
    for (var i = 0; i < 8 && result == null; i++) {
      try {
        result = await s.run((api) async => 2);
      } on VmUnavailableException {
        // Keep polling, like the engine does.
      }
    }
    expect(result, 2);
    expect(s.webSocketUri.toString(), 'ws://127.0.0.1:1111/raw=/ws');
    expect(bridge.connectedTo.where((u) => u.port == 1111), hasLength(1));
  });

  test('a missing VM service is a terminal failure', () async {
    final bridge = FakeRuntimeBridge(serviceUris: [null]);
    final s = session(bridge);
    try {
      await s.run((api) async => 1);
      fail('expected VmUnavailableException');
    } on VmUnavailableException catch (error) {
      expect(error.retryable, isFalse);
    }
    expect(s.isTerminal, isTrue);
  });
}
