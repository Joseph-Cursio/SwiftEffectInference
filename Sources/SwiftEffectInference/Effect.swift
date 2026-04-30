/// Four-tier effect lattice for Swift function classification.
///
/// Real implementation lifted from SwiftProjectLint's `DeclaredEffect` in
/// migration step 3. This skeleton only declares the namespace so the rest
/// of the package compiles before the lift.
///
/// Final shape per design v0.2 §5:
/// ```
/// public enum Effect: Hashable, Sendable, Comparable {
///     case observational
///     case idempotent
///     case externallyIdempotent(keyParameter: String?)
///     case nonIdempotent
///     public func lub(_ other: Effect) -> Effect
/// }
/// ```
public enum Effect: Hashable, Sendable {
    case observational
    case idempotent
    case externallyIdempotent(keyParameter: String?)
    case nonIdempotent
}
