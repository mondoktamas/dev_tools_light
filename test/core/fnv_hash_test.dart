import 'package:dev_tools_light/src/core/fnv_hash.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fnv1a32 matches the reference vector', () {
    // FNV-1a 32-bit of "a" is 0xe40c292c.
    expect(fnv1a32('a'), 0xe40c292c);
    expect(fnv1a32(''), 0x811c9dc5);
  });

  test('stableSignature is stable, 16 hex chars and input sensitive', () {
    final a = stableSignature(['_HomePageState', 'x/y.z']);
    final b = stableSignature(['_HomePageState', 'x/y.z']);
    final c = stableSignature(['_HomePageState', 'x/y.w']);
    expect(a, b);
    expect(a, isNot(c));
    expect(a, hasLength(16));
    expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(a), isTrue);
    // Part boundaries matter.
    expect(stableSignature(['ab', 'c']), isNot(stableSignature(['a', 'bc'])));
  });
}
