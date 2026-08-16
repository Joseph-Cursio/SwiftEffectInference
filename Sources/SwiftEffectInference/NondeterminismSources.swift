import SwiftSyntax

/// A syntactic source of nondeterminism, found in expression position.
///
/// The *classification* only. Whether a given source is a problem — and what to
/// say about it — is the consumer's question: a lint rule exempts parameter
/// defaults and test files, a purity oracle refutes outright, and a
/// clock-determinism check cares about `.clock` and nothing else. This type
/// answers "what is this, and where", and stops.
public struct NondeterminismSource: Sendable, Equatable {

    /// Which kind of unpredictability the source introduces. Consumers filter
    /// on this: they routinely want some kinds and not others, and a consumer
    /// that wants them all can ignore it.
    public enum Kind: Sendable, Equatable {

        /// Reads the host clock: `Date()`, `Date.now`, `ContinuousClock()`,
        /// `Task.sleep(for:)`, `CFAbsoluteTimeGetCurrent()`.
        case clock

        /// Draws from the system RNG: `arc4random()`, `.random(in:)`,
        /// `.shuffled()`.
        case randomness

        /// Generates a fresh identity: `UUID()`.
        case identity

        /// Reads ambient process or user environment: `Locale.current`,
        /// `TimeZone.current`.
        case ambientEnvironment
    }

    public let kind: Kind

    /// The source as written — `"Date()"`, `"Task.sleep"`, `".shuffled(…)"` —
    /// for a consumer that names it in a diagnostic.
    public let marker: String

    /// Where the source starts, for a consumer that converts to line/column.
    public let position: AbsolutePosition

    public init(kind: Kind, marker: String, position: AbsolutePosition) {
        self.kind = kind
        self.marker = marker
        self.position = position
    }
}

/// Classifies expressions that reach for something the inputs do not determine.
///
/// **This is the one place the marker sets live.** Before it, the same
/// argument-aware scan existed twice: here in the leaf, and in SwiftProjectLint's
/// `NonInjectedNondeterminismVisitor` — two implementations of "does this reach
/// for ambient time" in two repositories, which is the drift this package exists
/// to prevent. `PurityInferrer`'s own doc comment named that visitor as the
/// AST-precise counterpart its token scan approximates; the precise form now
/// lives here and the visitor consumes it.
///
/// ## Expression-shaped and argument-aware, unlike `PurityInferrer`'s token scan
///
/// `PurityInferrer` matches bare identifier tokens and deliberately over-refutes:
/// it treats `Date(timeIntervalSince1970:)` like `Date()` because the cost of
/// being wrong there is one withheld `.pure`. Consumers of *this* type pay
/// differently — a lint rule that fires on a deterministic initializer, or on a
/// type name in a signature, is a false positive an author has to suppress — so
/// this reads the expression's shape and its argument labels:
///
/// - `Date()` and `Date(timeIntervalSinceNow:)` are sources; every other `Date`
///   initializer names a fixed reference point and is not.
/// - `.random(in:using:)` and `Task.sleep(for:tolerance:clock:)` take the source
///   of unpredictability as an argument, so they are reproducible and are not
///   sources. Their un-injected siblings are.
/// - `Date` in a type annotation is not an expression and is never a source.
///
/// The two coexist deliberately: `PurityInferrer` answers a whole-domain question
/// where over-refutation is sound, and this answers a located one where it is not.
public enum NondeterminismSources {

    /// Clock types whose construction *is* the acquisition of a host clock. A
    /// clock that arrives as a parameter is constructed in the caller, which is
    /// the injection seam and is not visible here.
    private static let ambientClockTypes: Set<String> = [
        "ContinuousClock", "SuspendingClock"
    ]

    /// Types carrying a static `now` that reads the host clock.
    private static let ambientNowTypes: Set<String> = [
        "Date", "ContinuousClock", "SuspendingClock", "DispatchTime", "DispatchWallTime"
    ]

    /// Clock functions with no injected form — no argument makes
    /// `mach_absolute_time()` reproducible — so the bare call is the source.
    private static let ambientTimeFunctions: Set<String> = [
        "CFAbsoluteTimeGetCurrent", "mach_absolute_time", "mach_continuous_time",
        "clock_gettime", "gettimeofday"
    ]

    /// The legacy C RNG entry points.
    private static let randomFunctions: Set<String> = [
        "arc4random", "arc4random_uniform", "drand48"
    ]

    /// Stdlib members that draw from the system RNG unless handed one.
    private static let randomMembers: Set<String> = [
        "random", "randomElement", "shuffled"
    ]

    /// Types whose `current` reads ambient process or user environment.
    private static let ambientEnvironmentTypes: Set<String> = [
        "Locale", "TimeZone"
    ]

    /// Classifies a call expression, or `nil` when it is not a nondeterminism
    /// source.
    public static func source(of call: FunctionCallExprSyntax) -> NondeterminismSource? {
        let position = call.positionAfterSkippingLeadingTrivia

        // `Date()`, `UUID()`, `ContinuousClock()`, `arc4random()` — a bare type
        // or function name callee.
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            if name == "Date", readsAmbientDate(call) {
                return NondeterminismSource(kind: .clock, marker: "Date()", position: position)
            }
            if name == "UUID", call.arguments.isEmpty {
                return NondeterminismSource(kind: .identity, marker: "UUID()", position: position)
            }
            if ambientClockTypes.contains(name) || ambientTimeFunctions.contains(name) {
                return NondeterminismSource(kind: .clock, marker: "\(name)()", position: position)
            }
            if randomFunctions.contains(name) {
                return NondeterminismSource(kind: .randomness, marker: "\(name)()", position: position)
            }
            return nil
        }

        // `Task.sleep(…)`, `DispatchTime.now()`, `Int.random(in:)`,
        // `array.shuffled()` — a member callee.
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let memberName = member.declName.baseName.text

        if let base = member.base?.as(DeclReferenceExprSyntax.self) {
            let typeName = base.baseName.text
            if typeName == "Task", memberName == "sleep", !sleepsOnSuppliedClock(call) {
                return NondeterminismSource(kind: .clock, marker: "Task.sleep", position: position)
            }
            if ambientNowTypes.contains(typeName), memberName == "now" {
                return NondeterminismSource(kind: .clock, marker: "\(typeName).now", position: position)
            }
        }

        // Randomness reads on any receiver, including a chained one
        // (`values.map(…).shuffled()`), so the receiver is not inspected. A
        // supplied `using:` is the injection seam and disqualifies the match.
        if randomMembers.contains(memberName), !drawsFromSuppliedGenerator(call) {
            return NondeterminismSource(kind: .randomness, marker: ".\(memberName)(…)", position: position)
        }

        return nil
    }

    /// Classifies a member access **not** in call position — `Date.now`,
    /// `Locale.current` — or `nil`.
    ///
    /// The base must be a bare type name this classifier knows. That is what
    /// keeps `clock.now` on an injected parameter out of the results: `clock` is
    /// not a type, and reading an injected clock is reproducible.
    public static func source(of member: MemberAccessExprSyntax) -> NondeterminismSource? {
        guard let base = member.base?.as(DeclReferenceExprSyntax.self) else { return nil }
        let typeName = base.baseName.text
        let memberName = member.declName.baseName.text
        let position = member.positionAfterSkippingLeadingTrivia

        if memberName == "now", ambientNowTypes.contains(typeName) {
            return NondeterminismSource(kind: .clock, marker: "\(typeName).now", position: position)
        }
        if memberName == "current", ambientEnvironmentTypes.contains(typeName) {
            return NondeterminismSource(
                kind: .ambientEnvironment,
                marker: "\(typeName).current",
                position: position
            )
        }
        return nil
    }

    /// `Date()` reads the host clock; so does `Date(timeIntervalSinceNow:)`,
    /// whose argument is an *offset from* now rather than an absolute instant.
    /// Every other initializer names a fixed reference point
    /// (`timeIntervalSince1970:`, `timeIntervalSinceReferenceDate:`,
    /// `timeInterval:since:`) and is deterministic.
    private static func readsAmbientDate(_ call: FunctionCallExprSyntax) -> Bool {
        guard let first = call.arguments.first else { return true }
        return first.label?.text == "timeIntervalSinceNow"
    }

    /// `Task.sleep(for:tolerance:clock:)` sleeps on the clock it was handed.
    /// `Task.sleep(for:)` and `Task.sleep(nanoseconds:)` fall back to the host's.
    private static func sleepsOnSuppliedClock(_ call: FunctionCallExprSyntax) -> Bool {
        call.arguments.contains { $0.label?.text == "clock" }
    }

    /// `Int.random(in: r, using: &rng)` is reproducible from a seed — the
    /// testable form — so only the system-RNG spellings are sources.
    private static func drawsFromSuppliedGenerator(_ call: FunctionCallExprSyntax) -> Bool {
        call.arguments.contains { $0.label?.text == "using" }
    }
}
