import 'package:flutter/foundation.dart';

/// Whether the VM-service features (leak traces, heap snapshots, CPU-sample
/// attribution) can work in this build: debug and profile builds on VM
/// platforms.
///
/// A compile-time constant, so release and web builds tree-shake the VM
/// layer (`package:vm_service` included) away; code that uses it must sit
/// behind `if (kVmFeaturesSupported)`.
const bool kVmFeaturesSupported = !kIsWeb && !kReleaseMode;

/// Whether anything can run at all: false on the web, where frame timings
/// and heartbeats would work but nothing could explain them. In release
/// builds only jank detection runs, and only with
/// `DevToolsLightConfig.allowInRelease`.
const bool kDetectionSupported = !kIsWeb;
