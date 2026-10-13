import 'dart:async';

import 'package:dev_tools_light_example/globals.dart';
import 'package:flutter/material.dart';

/// Leaks its `State` through a stream subscription that is never cancelled.
class LeakyStreamPage extends StatefulWidget {
  const LeakyStreamPage({super.key});

  @override
  State<LeakyStreamPage> createState() => _LeakyStreamPageState();
}

class _LeakyStreamPageState extends State<LeakyStreamPage> {
  // The subscription is intentionally never cancelled: that is the leak.
  // ignore: unused_field, cancel_subscriptions
  late final StreamSubscription<int> _subscription;
  int _events = 0;

  @override
  void initState() {
    super.initState();
    // BUG: never cancelled in dispose(); the closure captures `this`.
    _subscription = AppEvents.stream.listen((event) {
      if (mounted) {
        setState(() => _events = event);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'Leaky stream subscription',
      body:
          'This State listens to AppEvents.stream in initState() and forgets '
          'to cancel the subscription in dispose(). Pop this page and the '
          'State stays reachable through the stream controller.\n\n'
          'Events seen: $_events',
    );
  }
}

/// Leaks a `TextEditingController` through a listener on a global notifier.
class LeakyNotifierPage extends StatefulWidget {
  const LeakyNotifierPage({super.key});

  @override
  State<LeakyNotifierPage> createState() => _LeakyNotifierPageState();
}

class _LeakyNotifierPageState extends State<LeakyNotifierPage> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    // BUG: the tear-off keeps the controller reachable from the global
    // notifier; the listener is never removed.
    globalCounter.addListener(_controller.clear);
  }

  @override
  void dispose() {
    _controller.dispose(); // disposed, but still reachable → leak
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'Leaky ChangeNotifier',
      body:
          'A TextEditingController is disposed here but a global '
          'ValueNotifier still holds a listener that references it.',
      child: TextField(controller: _controller),
    );
  }
}

/// Leaks its `State` through a static list.
class LeakyStaticPage extends StatefulWidget {
  const LeakyStaticPage({super.key});

  @override
  State<LeakyStaticPage> createState() => _LeakyStaticPageState();
}

class _LeakyStaticPageState extends State<LeakyStaticPage> {
  @override
  void initState() {
    super.initState();
    // BUG: a static list keeps this State alive forever.
    AppEvents.retained.add(this);
  }

  @override
  Widget build(BuildContext context) {
    return const _PageScaffold(
      title: 'Leaky static field',
      body:
          'This State adds itself to a static List in initState() and never '
          'removes itself.',
    );
  }
}

/// A well-behaved page: subscribes and cancels.
class CleanPage extends StatefulWidget {
  const CleanPage({super.key});

  @override
  State<CleanPage> createState() => _CleanPageState();
}

class _CleanPageState extends State<CleanPage> {
  late final StreamSubscription<int> _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = AppEvents.stream.listen((_) {});
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const _PageScaffold(
      title: 'Clean page',
      body:
          'This page cancels its subscription in dispose(); no leak should '
          'be reported after popping it.',
    );
  }
}

class _PageScaffold extends StatelessWidget {
  const _PageScaffold({required this.title, required this.body, this.child});

  final String title;
  final String body;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            if (child != null) ...[const SizedBox(height: 16), child!],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Pop this page'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A plain data object nobody disposes or watches.
class CacheEntry {
  /// Creates an entry.
  CacheEntry(this.key) : payload = List<int>.filled(256, key.length);

  /// Cache key.
  final String key;

  /// Some bytes, so the growth is visible in bytes too.
  final List<int> payload;
}

/// An "image cache" without an upper bound.
class ImageCacheLike {
  ImageCacheLike._();

  /// BUG: entries are added on every visit and never evicted.
  static final List<CacheEntry> entries = <CacheEntry>[];

  static int _generation = 0;

  /// Adds a batch of entries.
  static void fill(int count) {
    final generation = _generation++;
    for (var i = 0; i < count; i++) {
      entries.add(CacheEntry('image-$generation-$i'));
    }
  }
}

/// Fills [ImageCacheLike] on every visit: no lifecycle object leaks, so only
/// the heap-growth trend can see it.
class LeakyCachePage extends StatelessWidget {
  /// Creates the page.
  const LeakyCachePage({super.key});

  @override
  Widget build(BuildContext context) {
    ImageCacheLike.fill(200);
    return _PageScaffold(
      title: 'Leaky cache',
      body:
          'Every visit adds 200 CacheEntry objects to a static list that is '
          'never trimmed (${ImageCacheLike.entries.length} so far). Nothing '
          'here is disposed, so the leak detector cannot see it; the Growth '
          'tab can.',
    );
  }
}
