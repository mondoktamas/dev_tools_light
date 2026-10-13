/// 32-bit FNV-1a hash of [input] (UTF-16 code units).
///
/// Implemented with 16-bit partial products so the result is identical on the
/// VM and on the web (where integers are doubles).
int fnv1a32(String input, {int seed = 0x811C9DC5}) {
  var hash = seed;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = _mul32(hash, 0x01000193);
  }
  return hash;
}

int _mul32(int a, int b) {
  final lo = a & 0xFFFF;
  final hi = (a >> 16) & 0xFFFF;
  return ((lo * b) + (((hi * b) & 0xFFFF) << 16)) & 0xFFFFFFFF;
}

/// A stable 16-hex-character signature for a sequence of strings.
String stableSignature(Iterable<String> parts) {
  final joined = parts.join('\u0000');
  final a = fnv1a32(joined);
  final b = fnv1a32(joined, seed: 0x9747B28C);
  return '${a.toRadixString(16).padLeft(8, '0')}'
      '${b.toRadixString(16).padLeft(8, '0')}';
}
