import 'dart:developer' as developer;

/// A monotonic microsecond clock. Defaults to [timelineNowMicros].
typedef NowMicros = int Function();

/// The VM timeline clock (`Timeline.now`), which is the clock the VM uses
/// for CPU sample timestamps.
int timelineNowMicros() => developer.Timeline.now;
