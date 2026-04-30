/// Body-based call-graph inference that computes the lub of a function's
/// direct callees' effects with depth tracking. Closure boundaries
/// (`Task { }`, `withTaskGroup`, `Task.detached`, SwiftUI `.task { }`) are
/// not recursed into — those represent retry-context boundaries.
///
/// Real implementation lifted from SwiftProjectLint's `UpwardEffectInferrer`
/// (~276 lines) in migration step 3. Renamed to `BodyEffectInferrer` per
/// design v0.2 Q1.
public enum BodyEffectInferrer {}

/// Result of one body-pass inference: the inferred effect plus the longest
/// unannotated-chain depth back to a declared or call-site-heuristic anchor.
/// Consumed by `EffectSymbolTable.lookupWithProvenance(name:)` to render
/// diagnostic prose.
public struct BodyInference: Sendable {
    public let effect: Effect
    public let depth: Int

    public init(effect: Effect, depth: Int) {
        self.effect = effect
        self.depth = depth
    }
}
