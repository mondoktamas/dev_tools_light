import 'dart:async';

import 'package:dev_tools_light/src/core/clock.dart';
import 'package:dev_tools_light/src/core/status.dart';
import 'package:dev_tools_light/src/vm/runtime_bridge.dart';
import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:flutter/foundation.dart' show connectedVmServiceUri;

/// Thrown by [VmSession.run] when no VM service can be reached.
class VmUnavailableException implements Exception {
  /// Creates the exception.
  VmUnavailableException(this.message, {this.retryable = true});

  /// Why the VM service is unavailable.
  final String message;

  /// False when this process has no VM service at all, so retrying is
  /// pointless.
  final bool retryable;

  @override
  String toString() => 'VmUnavailableException: $message';
}

/// Provides the URI the Flutter tool connected to, if any.
typedef ConnectedUriProvider = String? Function();

/// Discovers the VM-service URI safely and runs short-lived sessions.
///
/// Connecting to the *raw* VM service while `flutter run` is still attaching
/// DDS makes DDS's `_yieldControlToDDS` fail and silently degrades the
/// developer's tooling. Once DDS is attached, `Service.getInfo()` advertises
/// the DDS URI and the tool sets `connectedVmServiceUri`, so discovery waits
/// for either signal (or a grace period) before connecting.
///
/// On a phone or tablet DDS runs on the development machine, so the
/// advertised URI may be unreachable from the app. URIs that refuse a
/// connection are remembered and skipped for [unreachableRetryInterval], the
/// Android emulator's host alias (`10.0.2.2`) is tried as an alternative, and
/// the in-process URI is used once the tool has detached.
class VmSession {
  /// Creates a session manager.
  VmSession({
    required RuntimeBridge bridge,
    required NowMicros now,
    this.discoveryGrace = const Duration(seconds: 10),
    this.pollInterval = const Duration(milliseconds: 500),
    this.unreachableRetryInterval = const Duration(seconds: 60),
    ConnectedUriProvider? connectedUri,
    void Function(String message)? log,
  }) : _bridge = bridge,
       _now = now,
       _connectedUri = connectedUri ?? _defaultConnectedUri,
       _log = log;

  final RuntimeBridge _bridge;
  final NowMicros _now;
  final ConnectedUriProvider _connectedUri;
  final void Function(String message)? _log;

  /// How long to wait for DDS before connecting directly.
  final Duration discoveryGrace;

  /// How often `Service.getInfo()` is polled during discovery.
  final Duration pollInterval;

  /// How long a URI that refused a connection is left alone before it is
  /// tried again (a change of the advertised URI resets this).
  final Duration unreachableRetryInterval;

  static const int _maxAttemptsPerRun = 6;

  Uri? _wsUri;
  Uri? _initialUri;
  int? _firstDiscoveryMicros;
  bool _terminal = false;
  final Map<Uri, _UnreachableUri> _unreachable = {};
  Future<Uri?>? _discovering;
  _SharedConnection? _shared;
  Future<_SharedConnection>? _connecting;
  int _waiters = 0;
  VmConnectionState _state = VmConnectionState.idle;
  String? _lastError;
  String? _lastLoggedError;

  static String? _defaultConnectedUri() => connectedVmServiceUri;

  /// Current connection state.
  VmConnectionState get state => _state;

  /// Last error message, if any.
  String? get lastError => _lastError;

  /// Whether discovery failed for good (no VM service in this process).
  bool get isTerminal => _terminal;

  /// The WebSocket URI in use, once discovered.
  Uri? get webSocketUri => _wsUri;

  /// WebSocket URIs currently known to refuse connections.
  Iterable<Uri> get unreachableUris => _unreachable.keys;

  /// Converts an HTTP VM-service URI to its WebSocket form.
  static Uri toWebSocketUri(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty || segments.last != 'ws') {
      segments.add('ws');
    }
    final scheme = switch (uri.scheme) {
      'https' || 'wss' => 'wss',
      _ => 'ws',
    };
    return uri.replace(scheme: scheme, pathSegments: segments);
  }

  static bool _isLoopback(Uri uri) => const {
    '127.0.0.1',
    'localhost',
    '::1',
    '[::1]',
  }.contains(uri.host);

  /// Discovers the VM-service WebSocket URI (cached).
  Future<Uri?> discover() {
    final cached = _wsUri;
    if (cached != null) {
      return Future.value(cached);
    }
    return _discovering ??= _discover().whenComplete(() => _discovering = null);
  }

  Future<Uri?> _discover() async {
    if (!_bridge.isSupported) {
      _state = VmConnectionState.unsupported;
      return null;
    }
    if (_terminal) {
      _state = VmConnectionState.failed;
      return null;
    }
    _state = VmConnectionState.discovering;
    final firstMicros = _firstDiscoveryMicros ??= _now();
    var current = await _bridge.serviceUri();
    if (current == null && _initialUri == null) {
      // No server is running, so no tool can be about to attach DDS.
      current = await _bridge.serviceUri(enableIfNeeded: true);
      if (current == null) {
        _terminal = true;
        _fail(
          'no VM service in this process (run with the VM service enabled)',
        );
        return null;
      }
      _log?.call('started the VM service ourselves');
    }
    final initial = _initialUri ??= current!;
    final alias = await _bridge.hostLoopbackAlias();
    while (true) {
      _expireUnreachable();
      final graceElapsed =
          _now() - firstMicros >= discoveryGrace.inMicroseconds;
      final options = <(Uri, String)>[];
      void offer(Uri? uri, String reason) {
        if (uri == null) {
          return;
        }
        options.add((uri, reason));
        if (alias != null && _isLoopback(uri)) {
          options.add((
            uri.replace(host: alias),
            '$reason, through the emulator host alias',
          ));
        }
      }

      final connected = _connectedUri();
      if (connected != null) {
        offer(Uri.tryParse(connected), 'connectedVmServiceUri set by the tool');
      }
      if (current != null && current != initial) {
        offer(current, 'advertised URI changed (DDS attached)');
      }
      if (graceElapsed) {
        offer(current ?? initial, 'grace period elapsed');
      }
      final seen = <Uri>{};
      for (final (uri, reason) in options) {
        final ws = toWebSocketUri(uri);
        if (!seen.add(ws) || _unreachable.containsKey(ws)) {
          continue;
        }
        return _use(uri, reason);
      }
      if (seen.isNotEmpty) {
        // Everything we could try refused a connection recently.
        _fail(
          _unreachable[seen.first]?.message ?? _unreachable.values.last.message,
        );
        return null;
      }
      await Future<void>.delayed(pollInterval);
      current = await _bridge.serviceUri();
    }
  }

  void _expireUnreachable() {
    final now = _now();
    _unreachable.removeWhere((_, entry) => entry.retryAtMicros <= now);
  }

  Uri _use(Uri httpUri, String reason) {
    final ws = toWebSocketUri(httpUri);
    _wsUri = ws;
    _log?.call('VM service URI $ws ($reason)');
    return ws;
  }

  void _fail(String message) {
    _state = VmConnectionState.failed;
    _lastError = message;
    if (message != _lastLoggedError) {
      _lastLoggedError = message;
      _log?.call('VM service unavailable: $message');
    }
  }

  /// Forgets the discovered URI so the next [run] discovers again.
  void invalidate() {
    _wsUri = null;
  }

  /// Runs [body] with a connection, sharing it with concurrent callers and
  /// closing it when the last caller finishes.
  ///
  /// A URI that refuses the connection is remembered and the next candidate
  /// is tried, so one call walks through every option before failing.
  Future<T> run<T>(Future<T> Function(VmApi api) body) async {
    for (var attempt = 0; attempt < _maxAttemptsPerRun; attempt++) {
      final uri = await discover();
      if (uri == null) {
        throw VmUnavailableException(
          _lastError ?? 'VM service not available',
          retryable: !_terminal,
        );
      }
      final _SharedConnection shared;
      try {
        shared = await _acquire(uri);
      } on VmUnavailableException {
        continue;
      }
      try {
        final result = await body(shared.api);
        _state = VmConnectionState.reachable;
        return result;
      } finally {
        await _release(shared);
      }
    }
    throw VmUnavailableException(_lastError ?? 'VM service not available');
  }

  Future<_SharedConnection> _acquire(Uri uri) async {
    final existing = _shared;
    if (existing != null) {
      existing.refs++;
      return existing;
    }
    final pending = _connecting;
    if (pending != null) {
      // Join the connection being established; its reference is counted
      // when the connection is created.
      _waiters++;
      return pending;
    }
    final connecting = _connecting = _connect(uri);
    try {
      return await connecting;
    } finally {
      _connecting = null;
    }
  }

  Future<_SharedConnection> _connect(Uri uri) async {
    _waiters = 0;
    final VmApi api;
    try {
      api = await _bridge.connect(uri);
      await api.getVersion();
    } on Object catch (error) {
      final message = _describeConnectFailure(uri, error);
      _unreachable[uri] = _UnreachableUri(
        message: message,
        retryAtMicros: _now() + unreachableRetryInterval.inMicroseconds,
      );
      _fail(message);
      invalidate();
      throw VmUnavailableException(message);
    }
    final shared = _SharedConnection(api, refs: 1 + _waiters);
    _waiters = 0;
    _shared = shared;
    return shared;
  }

  String _describeConnectFailure(Uri uri, Object error) {
    var detail = '$error';
    final cut = detail.indexOf(' (OS Error');
    if (cut > 0) {
      detail = detail.substring(0, cut);
    }
    final buffer = StringBuffer('connecting to $uri failed: $detail');
    if (_bridge.isMobile) {
      buffer.write(
        '. On a phone or tablet this usually means the URI belongs to DDS on '
        'the development machine, which the app cannot reach: run '
        '`flutter run --no-dds`, detach the tool (press d), or start the app '
        'from the launcher.',
      );
    }
    return buffer.toString();
  }

  Future<void> _release(_SharedConnection shared) async {
    shared.refs--;
    if (shared.refs > 0) {
      return;
    }
    if (identical(_shared, shared)) {
      _shared = null;
    }
    try {
      await shared.api.dispose();
    } on Object catch (_) {
      // Closing a dying socket is best effort.
    }
  }
}

class _SharedConnection {
  _SharedConnection(this.api, {required this.refs});

  final VmApi api;
  int refs;
}

class _UnreachableUri {
  const _UnreachableUri({required this.message, required this.retryAtMicros});

  final String message;
  final int retryAtMicros;
}
