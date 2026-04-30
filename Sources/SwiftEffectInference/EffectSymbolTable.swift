/// Cross-file declared+inferred effect lookup with collision-withdrawal
/// semantics: when annotated declarations of the same signature disagree
/// on effect, the entry is withdrawn (`lookup` returns `nil`).
///
/// Real implementation lifted from SwiftProjectLint in migration step 3.
/// Skeleton only fixes the public type name and the `EffectProvenance`
/// shape so consumers can compile against the planned surface.
public final class EffectSymbolTable {
    public init() {}
}

/// Origin of an effect resolution, used by consumers (SPL for diagnostic
/// prose, SwiftInfer for explainability blocks) to distinguish declared
/// effects from inferred ones.
public enum EffectProvenance: Sendable {
    case declared
    case bodyInferred(depth: Int)
    case callSite(reason: String)
}
