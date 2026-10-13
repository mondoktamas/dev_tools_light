# dev_tools_light

In-app memory-leak detection with LeakCanary-style leak traces, heap growth
trends, and jank detection that points at **your** code instead of the
framework's — built on the Dart VM service. Debug/profile builds; an optional
detect-only mode in release; a no-op on the web.

## What it does

**Leak detection (LeakCanary for Flutter).** Every `State`, `ChangeNotifier`
(controllers, `ValueNotifier`s, view models), `AnimationController`, `Route`
and `OverlayEntry` is watched automatically once Flutter disposes it. If the
object is still reachable five seconds later, the detector forces a garbage
collection, re-checks, asks the VM for the *retaining path* and shows a leak
trace like this, with your own classes and closures highlighted:

```
┬───
│ GC Root: user global
│
├─ AppEvents  [APP]  lib/globals.dart:8
│    Leaking: NOT LEAKING (static field)
│    ↓ static AppEvents.controller   ~~~ suspect
├─ _BroadcastStreamController  [DART]
│    Leaking: UNKNOWN
│    ↓ _BroadcastStreamController._firstSubscription   ~~~ suspect
├─ _BroadcastSubscription  [DART]
│    Leaking: UNKNOWN
│    ↓ _BroadcastSubscription._onData   ~~~ suspect
├─ closure _LeakyStreamPageState.initState.<anonymous closure>  [APP]  lib/leaky_pages.dart:24
│    Leaking: UNKNOWN
│    ↓ captured variable #0   ~~~ suspect
╰→ _LeakyStreamPageState  [APP]
     Leaking: LEAKING (disposed and still reachable after GC)
```

**Heap growth trends.** Not every leak goes through `dispose()`: cache
entries, listeners and plain data objects are never watched. A heap snapshot
(per-class live counts) is taken right after each of the VM's own garbage
collections — no forced GC, no pause beyond the profile itself — and a class
whose instance count keeps rising across snapshots is listed in the Growth
tab; one tap fetches the retaining path of a live instance, rendered as the
same leak trace.

**Jank attribution.** Slow frames (`SchedulerBinding` frame timings) and UI
isolate stalls (a heartbeat timer) are detected, the VM's CPU samples for
exactly that window are fetched, and every sampled stack is collapsed to the
frames that belong to your package(s). Instead of a flame chart full of
`package:flutter/…` frames you get "hot app functions" with `file:line`, an
app-only call tree, and a breakdown of where the time went.

**In-app overlay.** A floating badge shows the number of findings, a toast
announces each new one, and a report panel inside your app lists leaks,
growing classes and slow operations with all the details (copyable as text).

## Usage

```yaml
dependencies:
  dev_tools_light: ^0.1.0
```

It is a normal dependency because `main.dart` imports it; release builds
compile it down to nothing (see [Release builds](#release-builds)).

```dart
import 'package:dev_tools_light/dev_tools_light.dart';

Future<void> main() async {
  // Before runApp, so the Android back button can close the report panel.
  await DevToolsLight.start();
  runApp(
    MaterialApp(
      builder: DevToolsLight.builder, // badge, toasts and the report panel
      home: const HomePage(),
    ),
  );
}
```

That is all that is needed in debug builds. Optional extras:

```dart
// Watch anything else once you expect it to be unreachable
// (LeakCanary's expectWeaklyReachable). Debug builds only by default.
DevToolsLight.watch(myBloc, description: 'closed by HomeScreen');

// Force a check right now (also available from the panel's search button).
await DevToolsLight.checkLeaksNow();

// Take a heap snapshot now (after a forced GC) instead of waiting for the
// VM's next collection, and get the retaining path of a live instance of a
// growing class.
await DevToolsLight.snapshotHeapNow();
for (final trend in DevToolsLight.reports.heapTrends) {
  await DevToolsLight.fetchHeapTrendTrace(trend.id);
}

// React to findings programmatically.
DevToolsLight.reports.addListener(() {
  for (final leak in DevToolsLight.reports.leaks) { /* … */ }
  for (final op in DevToolsLight.reports.slowOps) { /* … */ }
});
```

### Choosing what runs

Each feature has its own switch, decided once at `start()`. Disabled features
cost nothing, have no tab in the panel, and when none of them needs the VM
service the engine does not even connect to it. By default a debug build
runs leak detection and heap growth trends, and a profile build runs jank
detection and heap growth trends. `JankDetectionConfig(allowInDebug: true)`
and `LeakDetectionConfig(allowInProfile: true)` cross that line; release
builds need `allowInRelease` and only ever detect jank.

```dart
// Only heap growth trends.
await DevToolsLight.start(
  config: const DevToolsLightConfig(
    leaks: LeakDetectionConfig(enabled: false),
    jank: JankDetectionConfig(enabled: false),
  ),
);

// Only leak detection.
await DevToolsLight.start(
  config: const DevToolsLightConfig(
    jank: JankDetectionConfig(enabled: false),
    heapTrend: HeapTrendConfig(enabled: false),
  ),
);

// Only jank attribution.
await DevToolsLight.start(
  config: const DevToolsLightConfig(
    leaks: LeakDetectionConfig(enabled: false),
    heapTrend: HeapTrendConfig(enabled: false),
  ),
);
```

### Which packages' objects are watched

Automatic leak watching is decided per package, by the package that declares
the disposed object's class:

* **your app's** classes are always watched;
* the **Flutter SDK's** (the `State` of a framework widget, a
  `TextEditingController`, …) are watched by default;
* **third-party packages** are not, unless you ask: their internal `State`s
  and controllers usually stay reachable only as a consequence of an app leak
  that is reported anyway.

```dart
LeakDetectionConfig(
  watchedPackages: WatchedPackages(
    include: {...KnownPackages.goRouter, 'my_design_system'},
    // flutter: false,          // app objects only
    // thirdParty: true,        // everything, minus `exclude`
    // exclude: {'some_pkg'},   // never, wins over everything
  ),
)
```

Objects handed to `DevToolsLight.watch` or admitted by `watchFilter` bypass
the policy. The package of a class is learned from the VM when its first
retained instance is analyzed (one retaining path); from then on instances of
an unwatched class are skipped before any VM work, and the Status tab counts
them under "Skipped by package policy".

Objects that are not Flutter lifecycle objects never reach the detector on
their own: a `Bloc`, a Riverpod notifier or a `GetxController` is closed by
its own package. Hand them over from that package's hook — no extra
dependency needed:

```dart
// bloc / flutter_bloc
class LeakWatchingObserver extends BlocObserver {
  @override
  void onClose(BlocBase<Object?> bloc) {
    super.onClose(bloc);
    DevToolsLight.watch(bloc, description: 'closed ${bloc.runtimeType}');
  }
}

// GetX
class MyController extends GetxController {
  @override
  void onClose() {
    DevToolsLight.watch(this);
    super.onClose();
  }
}

// Riverpod: a notifier's dispose hook
ref.onDispose(() => DevToolsLight.watch(this));
```

### Configuration

```dart
await DevToolsLight.start(
  config: DevToolsLightConfig(
    log: true, // debugPrint engine events
    allowInRelease: true, // jank detection without attribution in release
    appCode: const AppCodeConfig(
      // Auto-detected from the main isolate's root library; add internal
      // packages of a monorepo here.
      extraPackagePrefixes: {'package:my_core/', 'package:my_ui/'},
    ),
    leaks: LeakDetectionConfig(
      retainedDelay: const Duration(seconds: 5),
      watchedKinds: const {WatchedKind.state, WatchedKind.changeNotifier},
      watchedPackages: const WatchedPackages(include: KnownPackages.bloc),
      watchFilter: (object) => object is MyDisposable, // widen the set
      ignoredTypeNames: const {'MyKnownFalsePositive'},
      strongPathLookups: 16, // RPC budget for paths behind weak references
      referenceMatchers: [
        ...defaultReferenceMatchers,
        const IgnoredReferenceMatcher(
          ClassNamePattern('SomeCachingService'),
          'Cached on purpose.',
        ),
      ],
    ),
    heapTrend: const HeapTrendConfig(
      trigger: HeapSnapshotTrigger.afterVmGc, // or forcedGc / periodic
      interval: Duration(seconds: 60), // minimum spacing between snapshots
      minInstanceGrowth: 100, // or minBytesGrowth; both are floors
      ignoredClassNames: {'ThumbnailCacheEntry'}, // grows on purpose
    ),
    jank: const JankDetectionConfig(
      allowInDebug: true, // off in debug builds by default
      frameBuildThreshold: Duration(milliseconds: 16),
      stallThreshold: Duration(milliseconds: 100),
      samplePeriodMicros: 250, // finer CPU sampling (VM default: 1000)
      warmUp: Duration(seconds: 5), // ignore startup frames
      sampleFormat: SampleFormat.json, // if you need the JSON fetch
    ),
    overlay: const OverlayConfig(initialAlignment: Alignment.bottomLeft),
  ),
);
```

## Modes and platforms

|                          | Debug | Profile | Release ³ | Web |
|--------------------------|:-----:|:-------:|:---------:|:---:|
| Automatic leak watching  | ✔     | ✘ ¹     | ✘         | ✘   |
| `DevToolsLight.watch()`  | ✔     | opt-in ¹ | ✘        | ✘   |
| Leak traces              | ✔     | opt-in ¹ | ✘        | ✘   |
| Heap growth trends       | ✔     | ✔       | ✘         | ✘   |
| Jank detection           | opt-in ² | ✔    | ✔         | ✘   |
| CPU-sample attribution   | opt-in ² | ✔    | ✘         | ✘   |

¹ Leak detection runs in debug builds only. Flutter dispatches disposal
events only inside `assert`s, so a profile build could check nothing but
objects passed to `DevToolsLight.watch`; `LeakDetectionConfig(allowInProfile:
true)` turns that on.
² Off in debug builds unless `JankDetectionConfig(allowInDebug: true)`:
debug-mode timings are dominated by the JIT and asserts, and the sample
fetches cost the most there. Profile mode is where the numbers mean
something.
³ Only with `DevToolsLightConfig(allowInRelease: true)`; see below.

### Release builds

A release build has no VM service, so by default `start()` returns at once
and the overlay returns your app unchanged. With `allowInRelease: true` the
frame-timing and heartbeat detectors run anyway, for QA builds: slow builds,
delayed frames, slow rasters and UI stalls are reported with their durations
(grouped by kind and severity), the badge, toasts and panel work, and the
Status tab says what is unavailable. A late frame start on its own is listed
without a toast: with no samples to confirm a busy UI thread it is weak
evidence, and a desktop window in the background produces one per frame
because the OS throttles its frame rate. Leak detection and heap trends report
themselves as unsupported and `DevToolsLight.isVmSupported` is false. The VM
layer (`package:vm_service` included) is behind compile-time constants and is
tree-shaken out of every release build, opted in or not.

Everything is a compile-time no-op on the web (`DevToolsLight.isSupported ==
false`), so the package can stay a normal dependency of an app that also ships
to the web.

### Phones, tablets and emulators

`flutter run` attaches DDS on the development machine, and the app's
advertised VM-service URI switches to it. The iOS Simulator shares the
machine's loopback interface and the Android emulator reaches it through
`10.0.2.2`, so both work out of the box. A physical device cannot reach DDS:
the engine says so in its status (and in the log with `log: true`), reports
leaks without traces and jank without attribution, and keeps checking
cheaply until the VM service becomes reachable, which happens when you

* run with `flutter run --no-dds` (the app talks to its in-process service),
* detach the tool (`d` in `flutter run`; the in-process service accepts
  connections again), or
* start the app from the launcher without the tool.

## How it works

* **Watching** — `FlutterMemoryAllocations` reports every disposed framework
  object; the detector keeps a `WeakReference` per object and nothing else.
* **Retained check** — after `retainedDelay` the weak reference is inspected;
  survivors are batched, a full GC is requested from the VM
  (`getAllocationProfile(gc: true)`, with allocation pressure as a fallback)
  and confirmed through `dart:developer`'s `reachabilityBarrier`.
* **Trace** — `Service.getObjectId` + `getRetainingPath` give the path from a
  GC root; closures and their contexts are collapsed, static fields are named,
  and objects are labelled LEAKING / NOT LEAKING by inspecting their lifecycle
  fields (`_debugLifecycleState`, `_debugDisposed`, …) like LeakCanary's
  object inspectors. The references between the last NOT LEAKING and the first
  LEAKING object are the *suspects*, and identical suspect chains are grouped
  by signature.
* **Strong paths** — the VM's path search follows an `Expando`'s weak
  property, so an object that is also an `Expando` key may come back with a
  path that does not keep it alive. The detector keeps the strongly held
  prefix, asks `getInboundReferences` for the retainers of its last object,
  skips weak holders (`_WeakProperty`, `_WeakReference`, finalizer entries)
  and objects the VM only pins through its object-id ring, and splices in a
  strong retainer's own path, repeating up to `strongPathLookups` RPCs. The
  trace notes when that happened; when it fails, the weak path is shown with
  a warning.
* **Jank** — frame timings are converted to the VM timeline clock with an
  offset calibrated per frame number, a 50 ms heartbeat catches stalls that
  never reach a frame, overlapping detections of one event (a slow build and
  the frame it delays) are merged, and the window's CPU samples are fetched
  as a Perfetto trace (`getPerfettoCpuSamples`), whose script paths are mapped
  back to `package:` URIs with `lookupPackageUris`. Line numbers of the hot
  app functions are looked up through their library and class objects.
  Samples are collapsed to the first app frame from the leaf
  ("responsible"), plus self/inclusive counts and an app-only call tree with
  "· N framework frames" gaps.
* **Not breaking your tooling** — connecting to the raw VM service while
  `flutter run` is still attaching DDS would silently disable DDS. The engine
  therefore waits for the advertised URI to switch to DDS (or for
  `connectedVmServiceUri`, or a 10 s grace period) and only opens short-lived
  connections. URIs that refuse a connection are remembered for a minute and
  the next candidate is tried (the emulator's host alias, the in-process
  service once the tool has detached). Its own RPCs run on the UI isolate, so
  the windows they occupy are excluded from jank detection, and everything
  before the first rendered frame plus `warmUp` after it is ignored.
* **Heap trends** — `reachabilityBarrier` is polled every second; when it
  has advanced (the VM ran a major collection on its own) and at least
  `interval` has passed since the last snapshot, new space is cleared with a
  few milliseconds of allocation pressure (a probe held only weakly tells
  when the scavenge happened) and `getAllocationProfile` is read without a
  forced GC: old space is clean right after the collection, so the counts
  are live objects. A class is reported once it has grown in
  `minRisingSnapshots` consecutive snapshots by at least `minInstanceGrowth`
  instances or `minBytesGrowth` bytes and `minRelativeGrowth` of its starting
  count. `dart:` core classes are never reported (they grow with
  everything), app classes always, framework and package classes unless
  disabled. "Find retaining path" runs `getInstances` on the class and
  `getRetainingPath` on a live instance (with the same strong-path search),
  through the normal trace builder. `HeapSnapshotTrigger.forcedGc` restores
  the fixed-cadence forced-GC snapshots.
* **Deferred checks** — the framework releases routes, overlay entries and
  controllers from post-frame callbacks, so an object disposed after the
  last completed frame is not checked until a frame has rendered (at most
  `maxDeferredChecks` times); a retaining path through
  `_postFrameCallbacks` is ignored.

## Limitations

* Plain `ChangeNotifier` subclasses are only tracked by Flutter once they have
  had a listener; `ValueNotifier` and the framework controllers are tracked
  from construction.
* Widgets, streams and timers are not lifecycle objects and are not watched.
* Leak detection is debug-only by default (see the table above).
* Retaining-path and CPU-sample RPCs are executed by the UI isolate. On a
  desktop a leak check costs ~50–200 ms and a CPU-sample fetch ~40–160 ms
  with the default Perfetto format (`getPerfettoCpuSamples`, ~1–3 MB); on a
  mid-range phone in debug mode the fetch RPC takes ~0.5 s (the decode runs
  in a background isolate). The JSON fallback (`getCpuSamples`, used on VMs
  without Perfetto support or with `SampleFormat.json`) carries the isolate's
  whole function table — ~20 MB and ~0.5 s per fetch on a desktop regardless
  of window size. Fetches are merged and rate-limited, the sample buffer is
  kept small, and the stalls the fetches cause are never reported.
* Heap trends follow the VM's GC cadence: a quiet app that never collects
  takes no snapshots (the Status tab shows how many collections were seen),
  and a leak of one object per screen visit needs many visits before it
  crosses the floors. Objects allocated between the collection and the
  snapshot (at most a second) are counted too. Caches that legitimately grow
  trip the thresholds; list them in `ignoredClassNames`. Framework classes
  (semantics data, observer lists, keys) often grow as a consequence of an
  app leak that retains widget subtrees; they point at the same leak, or can
  be hidden with `includeFrameworkClasses: false`. The snapshot itself walks
  the heap on the UI isolate: ~0.2 s on a desktop or simulator and ~0.5 s on
  a mid-range phone in debug mode (moto g72: 460–563 ms). A forced-GC
  snapshot (the manual button, or `HeapSnapshotTrigger.forcedGc`) cost
  457–690 ms on the same phone, so the walk dominates and the collection
  adds little there; up to 2 s was seen on a throttled phone. What the
  default trigger buys is that no collection is ever forced on the app.
* Every object the VM service hands out an id for (a retaining path, an
  inbound reference, a live instance) stays alive until the VM's object-id
  ring wraps; the detector tolerates that, but a session that inspects many
  objects keeps some garbage around for a while.
* The package policy is keyed by runtime type, learned from the first
  analyzed instance of each class; two classes with the same name in
  different libraries are told apart, but the first instance of an unwatched
  class still costs one retaining-path RPC.
* The JIT can inline a hot function into its caller; samples of inlined
  code are attributed to the caller (with Perfetto traces the inlined frame
  is not expanded). Compare with the JSON format or profile mode if a hot
  function seems to be missing.
* In a debug build much of the UI thread's time goes to the Dart VM itself:
  the JIT compiling every function a screen touches for the first time,
  and garbage collection. On Android those frames come back unsymbolized
  (`libflutter.so+0x…`); the report labels them `[Engine]` and `[System]`
  and says when a window was mostly that. Profile mode shows what remains.
* A jank whose window holds no CPU sample at all means the UI isolate ran
  nothing: native code blocked the thread, or the OS throttled the process
  (a backgrounded desktop window). Such reports are listed but not announced
  (no toast, no badge highlight), and ignored while the app is known to be
  inactive, so that the overlay's own frames cannot keep producing them.
* Slow devices (a phone or emulator in debug mode) fetch samples in
  ~0.25–2 s, and in debug mode almost every navigation frame on such a
  device crosses the 32 ms threshold. The engine keeps the UI isolate's
  share of fetch time at about a tenth (`fetchCooldownFactor`), attributes
  the longest waiting jank first, reports the least significant ones
  without samples when more than `maxQueuedCandidates` are waiting, never
  clears the sample buffer while janks are still waiting for it, and does
  not fetch for a jank whose samples were already cleared. Even so, the
  remaining fetches are felt as short hiccups; use profile mode, or disable
  jank detection, when testing something else on a slow phone.
* Under `flutter test` the engine does not start unless
  `DevToolsLightConfig(allowInTests: true)` is set (its timers would fail
  `testWidgets`), and the VM service is only available with
  `flutter test --enable-vmservice`. Test runners start the main isolate on
  the test file itself, so the app package is found by resolving the loaded
  packages against the test file's location instead of the root library;
  set `AppCodeConfig(packagePrefixes: ...)` if that guess is wrong.

## Future work

* Automatic hooks for state-management packages would need a dependency on
  each of them; the observer snippets above are the dependency-free way.
* A detect-only leak check in release builds (`watch()` plus allocation
  pressure, no traces) is possible but not offered: forcing collections in a
  production build is too intrusive.

## Example

`example/` contains pages that leak a `State` through a stream subscription,
a `ChangeNotifier` through a global listener and a `State` through a static
field, an unbounded cache that only the heap trend can see, plus pages with a
slow `build`, a blocking tap handler and raster-heavy animation.
`flutter run -d macos --dart-define=DTL_DEMO=true` makes it drive itself and
print every report; `flutter run --release -d macos` shows the detect-only
mode.

## Tests

```bash
flutter test --exclude-tags vm            # unit and widget tests
flutter test --enable-vmservice --tags vm # tests against the live VM service
```
