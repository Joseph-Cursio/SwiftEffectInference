/// Declared idempotency effect for a Swift function. The five-tier lattice
/// classifies functions by retry-safety, with `pure` as the bottom:
///
/// ```
/// pure < observational < idempotent < externallyIdempotent < nonIdempotent
/// ```
///
/// - `pure`: referentially transparent — no side effects, deterministic, and
///   total. Strictly stronger than `observational`: a pure function is
///   trivially retry-safe, but an observational function that logs or reads a
///   clock is *not* pure. This is the tier a property-based test wants — the
///   result is a function of the inputs alone. Retry-safety (the original
///   lattice axis) and purity (referential transparency) are distinct
///   properties; `pure` sits below `observational` because every pure
///   function is also retry-safe, but not vice versa.
/// - `observational`: read or logging/metric calls — retry-safe and does not
///   affect program semantics, but may read external state (a clock, the
///   environment) or emit a log, so it is not necessarily pure.
/// - `idempotent`: subsequent invocations have the same effect as a single
///   invocation. `f(f(x))` is semantically equivalent to `f(x)`.
/// - `externallyIdempotent`: idempotent *only if* routed through a
///   caller-supplied deduplication key. Stripe / SES / SNS / Mailgun-style
///   APIs that accept a client-provided idempotency token. The optional
///   `keyParameter` names the parameter that carries the key when the
///   declaration spelled it via `(by: paramName)`. `nil` means the
///   annotation is documentary; the lattice behaviour still applies but
///   no key-routing verification runs.
/// - `nonIdempotent`: every invocation observably changes program state.
///   Calling twice is semantically distinct from calling once.
///
/// Equality compares the case *and* the associated `keyParameter`. The
/// lattice ordering is rank-only — `lub(_:)` ignores key-parameter values
/// for cross-rank cases and uses left-bias for same-rank ties.
///
/// Origin: lifted from SwiftProjectLint's `DeclaredEffect`
/// (`Packages/SwiftProjectLintVisitors/Sources/SwiftProjectLintVisitors/EffectAnnotationParser.swift`)
/// during migration step 3 of `docs/SwiftEffectInference Design v0.2.md` §10.
public enum Effect: Hashable, Sendable {

    case pure
    case observational
    case idempotent

    /// - Parameter keyParameter: the external label of the parameter that
    ///   holds the deduplication key, if the declaration specified one via
    ///   `@ExternallyIdempotent(by: paramName)` or
    ///   `/// @lint.effect externally_idempotent(by: paramName)`.
    case externallyIdempotent(keyParameter: String?)

    case nonIdempotent

    /// Lattice rank: 0 (most retry-safe — `pure`) to 4 (most retry-hostile —
    /// `nonIdempotent`). Used internally by `lub(_:)`; exposed for consumers
    /// that need to compare effects across cases without pattern-matching
    /// every variant. Ranks are relative ordinals, not a stable wire format —
    /// `lub(_:)` only compares them, so the absolute values may shift when the
    /// lattice grows (as it did when `pure` was inserted at the bottom).
    public var rank: Int {
        switch self {
        case .pure: return 0
        case .observational: return 1
        case .idempotent: return 2
        case .externallyIdempotent: return 3
        case .nonIdempotent: return 4
        }
    }

    /// Pairwise least-upper-bound. Returns the effect with the higher rank;
    /// for ties, returns `self` (left-bias).
    ///
    /// Tie semantics: when both sides are `externallyIdempotent` but carry
    /// different `keyParameter` values, the result preserves `self`'s key.
    /// `[a, b].reduce(initial) { $0.lub($1) }` therefore yields a result
    /// consistent with SwiftProjectLint's collection-form lub (first in
    /// iteration order wins for same-rank duplicates).
    public func lub(_ other: Effect) -> Effect {
        return rank >= other.rank ? self : other
    }

    /// Collection-form least-upper-bound. Returns the most-permissive effect
    /// in `effects`, or `nil` for an empty input. Same tie semantics as the
    /// pairwise `lub(_:)` — first occurrence of the highest-rank effect wins
    /// (matters for `externallyIdempotent` with different `keyParameter`s).
    public static func lub(of effects: [Effect]) -> Effect? {
        guard let first = effects.first else { return nil }
        return effects.dropFirst().reduce(first) { $0.lub($1) }
    }
}
