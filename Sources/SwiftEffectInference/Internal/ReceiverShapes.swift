/// Receiver-shape detection for `CallSiteEffectInferrer`. Lifted from
/// SwiftProjectLint in migration step 3.
///
/// Will hold:
/// - Logger-shaped receivers (`logger`, `requestLogger`, `os_log`, any name
///   containing "log" case-insensitive) called with logger-level methods
///   (`trace`/`debug`/`info`/`notice`/`warning`/`error`/`critical`/`fault`/`log`)
///   — observational.
/// - Metric-shaped receivers (`counter`, `gauge`, `meter`, `timer`,
///   `recorder`, suffixed variants like `activeRequestCounter`) called with
///   metric methods (`increment`/`decrement`/`record`/`recordNanoseconds`/
///   `observe`/`startTimer`) — observational.
package enum ReceiverShapes {}
