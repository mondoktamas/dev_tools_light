# 0.1.0

Initial release.

* LeakCanary-style leak detection: automatic watching of disposed `State`,
  `ChangeNotifier`, `AnimationController`, `Route` and `OverlayEntry` objects,
  forced-GC confirmation, retaining paths rendered as leak traces with
  LEAKING / NOT LEAKING labels, suspect references, signatures and reference
  matchers for known library leaks.
* Strong-path search: when the VM's retaining path runs through a weak
  reference (an `Expando` key, a `WeakReference`), the inbound references of
  the last strongly held object are walked, weak holders skipped, until a
  path of strong references is assembled (`strongPathLookups`).
* Per-package watching (`WatchedPackages`): app classes are always watched,
  the Flutter SDK's by default, third-party packages on request, with
  per-package include and exclude sets and `KnownPackages` presets. The
  declaring package of a class is learned from the VM when its first
  retained instance is analyzed; later instances are skipped at once.
* Jank detection from frame timings and a UI-isolate heartbeat, with CPU
  samples collapsed to the app's own code (hot functions with `file:line`,
  app-only call tree, time breakdown by origin). Samples are fetched as
  Perfetto traces (`getPerfettoCpuSamples`, ~40–160 ms per fetch) with a JSON
  fallback for older VMs.
* Heap growth trends: per-class live counts, taken right after the VM's own
  major collections (observed through `reachabilityBarrier`) with a cheap
  allocation-pressure scavenge instead of a forced GC, so nothing pauses the
  UI isolate for more than the allocation profile itself. A forced-GC
  schedule and a plain periodic schedule remain available
  (`HeapSnapshotTrigger`). Classes that keep growing are reported in the
  Growth tab with their snapshots, and the retaining path of a live instance
  can be fetched on demand (`getInstances` + `getRetainingPath`).
* Every feature (leaks, jank, heap trends) can be switched off individually;
  the panel only shows tabs and actions for the enabled ones. Jank detection
  is off in debug builds unless `JankDetectionConfig(allowInDebug: true)`:
  debug timings are dominated by the JIT and the tool's own sample fetches
  cost the most there. Leak detection is off in profile builds unless
  `LeakDetectionConfig(allowInProfile: true)`: Flutter reports disposals
  only in debug builds.
* Release builds: with `allowInRelease`, jank is detected and reported with
  its durations (no VM service, so no attribution, leak traces or heap
  snapshots); the VM layer and `package:vm_service` are tree-shaken out of
  release builds either way.
* In-app overlay: floating badge, toasts and a report panel with copyable
  text reports.
* DDS-safe VM-service discovery that also works on phones, tablets and
  emulators: unreachable URIs are remembered, the Android emulator's host
  alias is tried, the in-process service is used once the tool detaches, and
  the status explains when `flutter run --no-dds` is needed. No-op on the
  web.
* Perfetto traces are decoded in a background isolate; on slow devices
  fetches are spaced out, the longest waiting jank is attributed first and
  the least significant ones are reported without samples. Jank warm-up
  starts at the first rendered frame; leak checks are deferred until a frame
  has completed since the object was disposed.
