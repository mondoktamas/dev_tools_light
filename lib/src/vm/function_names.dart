import 'package:vm_service/vm_service.dart' as vms;

/// `Owner.function.<anonymous closure>` for [function], walking closure
/// owners up to the enclosing class. A tear-off's implicit closure repeats
/// its method name; the repetition is collapsed.
String qualifiedFunctionName(vms.FuncRef function) {
  final parts = <String>[stripCodeTags(function.name ?? '?')];
  Object? owner = function.owner;
  while (owner != null) {
    if (owner is vms.FuncRef) {
      final name = stripCodeTags(owner.name ?? '?');
      if (parts.first != name) {
        parts.insert(0, name);
      }
      owner = owner.owner;
    } else if (owner is vms.ClassRef) {
      parts.insert(0, owner.name ?? '?');
      owner = null;
    } else {
      owner = null;
    }
  }
  return parts.join('.');
}

/// Removes `[Optimized] `-style prefixes from a VM function name.
String stripCodeTags(String name) =>
    name.replaceFirst(RegExp(r'^(\[[^\]]+\]\s*)+'), '');

/// Markers of the Flutter engine / Dart VM binary in a native frame name
/// (an unsymbolized `libflutter.so+0x…` address on Android, a symbolized
/// `dart::` frame on a desktop).
const List<String> engineFrameMarkers = [
  'libflutter.so',
  'libdart',
  'libapp.so',
  'FlutterMacOS',
  'Flutter.framework',
  'libflutter_',
  'dart::',
  'flutter::',
  'fml::',
  'impeller::',
];

/// Markers of system libraries and kernel entry points.
const List<String> systemFrameMarkers = [
  '/libc.so',
  '/libc++',
  '/libm.so',
  '/libdl.so',
  '/apex/',
  'libsystem_',
  'libdyld',
  'libobjc',
  'syscall',
  '__kernel_',
  'futex',
  'munmap',
  'mmap',
  'madvise',
  'pthread_',
];

/// Whether [name] (raw, or already a display name) is a frame of the
/// Flutter engine or the Dart VM.
bool isEngineFrame(String name) =>
    name.startsWith('[Engine] ') || engineFrameMarkers.any(name.contains);

/// Whether [name] (raw, or already a display name) is a frame of a system
/// library or a kernel entry point.
bool isSystemFrame(String name) =>
    name.startsWith('[System] ') || systemFrameMarkers.any(name.contains);

/// Display name of a native frame: `[Engine] libflutter.so+0x1f89ed0`,
/// `[System] libc.so+0x41ae8` or `[Native] name`, with long mapping paths
/// cut down to the library's file name. The VM's own `[Native] ` prefix
/// (Perfetto frame names carry it) is replaced, so the result is the same
/// whether or not the input had one.
String nativeDisplayName(String? name) {
  var raw = name ?? '?';
  if (raw.startsWith('[Engine] ') || raw.startsWith('[System] ')) {
    return raw;
  }
  if (raw.startsWith('[Native] ')) {
    raw = raw.substring('[Native] '.length);
  }
  final prefix = isEngineFrame(raw)
      ? '[Engine]'
      : isSystemFrame(raw)
      ? '[System]'
      : '[Native]';
  return '$prefix ${_shortenMappingPath(raw)}';
}

/// `/data/app/…/base.apk!/lib/arm64-v8a/libflutter.so+0x1f89ed0` →
/// `libflutter.so+0x1f89ed0`.
String _shortenMappingPath(String name) {
  if (!name.startsWith('/')) {
    return name;
  }
  final slash = name.lastIndexOf('/');
  return slash < 0 ? name : name.substring(slash + 1);
}
