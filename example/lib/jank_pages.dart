import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// Synchronous work that is far too heavy for a build method.
class DemoParser {
  DemoParser._();

  /// Encodes and decodes a large JSON document on the UI isolate.
  static List<dynamic> parse(int items) {
    final json = jsonEncode(
      List.generate(
        items,
        (i) => {
          'id': i,
          'name': 'item $i',
          'tags': ['alpha', 'beta', 'gamma'],
        },
      ),
    );
    return jsonDecode(json) as List<dynamic>;
  }
}

/// Parses JSON inside `build`, producing a slow frame.
class SlowBuildPage extends StatefulWidget {
  const SlowBuildPage({super.key});

  @override
  State<SlowBuildPage> createState() => _SlowBuildPageState();
}

class _SlowBuildPageState extends State<SlowBuildPage> {
  int _items = 20000;

  @override
  Widget build(BuildContext context) {
    // BUG: heavy synchronous work in build().
    final data = DemoParser.parse(_items);
    return Scaffold(
      appBar: AppBar(title: const Text('Slow build')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'build() parsed ${data.length} JSON items synchronously. '
              'Tap the button to rebuild with more items.',
            ),
          ),
          FilledButton(
            onPressed: () => setState(() => _items += 20000),
            child: const Text('Rebuild with more items'),
          ),
        ],
      ),
    );
  }
}

/// Blocks the UI isolate inside a tap handler.
class JankPage extends StatefulWidget {
  const JankPage({super.key});

  @override
  State<JankPage> createState() => _JankPageState();
}

class _JankPageState extends State<JankPage> {
  double _result = 0;

  /// Burns CPU for [duration] on the UI isolate.
  void _blockUi(Duration duration) {
    final stopwatch = Stopwatch()..start();
    var acc = 0.0;
    while (stopwatch.elapsed < duration) {
      for (var i = 1; i < 2000; i++) {
        acc += math.sqrt(i.toDouble());
      }
    }
    _result = acc;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UI stall')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'These buttons block the UI isolate inside the tap handler.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _blockUi(const Duration(milliseconds: 300)),
              child: const Text('Block UI 300 ms (no rebuild)'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () {
                _blockUi(const Duration(milliseconds: 600));
                setState(() {});
              },
              child: const Text('Block UI 600 ms, then rebuild'),
            ),
            const SizedBox(height: 16),
            Text('last result: ${_result.toStringAsFixed(0)}'),
          ],
        ),
      ),
    );
  }
}

/// Animates many blurred layers to overload the raster thread.
class RasterPage extends StatefulWidget {
  const RasterPage({super.key});

  @override
  State<RasterPage> createState() => _RasterPageState();
}

class _RasterPageState extends State<RasterPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Raster jank')),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Stack(
            children: [
              for (var i = 0; i < 40; i++)
                Positioned(
                  left: 20.0 * i + 60 * _controller.value,
                  top: 12.0 * i,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        color: Colors.primaries[i % Colors.primaries.length]
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const [
                          BoxShadow(blurRadius: 30, spreadRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
