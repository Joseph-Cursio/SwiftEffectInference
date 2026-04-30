/// Classifies call expressions by callee name plus the file's imported
/// frameworks. Returns `nil` when no heuristic applies — deliberately tight
/// whitelist so unannotated code defaults to silent.
///
/// Real implementation lifted from SwiftProjectLint's `HeuristicEffectInferrer`
/// (~538 lines) in migration step 3. Renamed to `CallSiteEffectInferrer` per
/// design v0.2 Q1.
public enum CallSiteEffectInferrer {}
