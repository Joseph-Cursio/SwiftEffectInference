import SwiftSyntax

/// A syntactic witness that a declaration reaches for **ambient** time — a clock
/// nobody passed in.
///
/// Carries the marker's spelling and position so a consumer can report *where*
/// the contradiction is. A rule that can only say "this function is not
/// clock-deterministic" makes the author hunt; one that can say "`Date()`, here"
/// does not.
public struct AmbientTimeWitness: Sendable, Equatable {

    /// The ambient source as written — `"Date()"`, `"ContinuousClock()"`,
    /// `"Task.sleep"`, `"CFAbsoluteTimeGetCurrent()"`.
    public let marker: String

    /// Where the marker starts, for a consumer that converts to line/column.
    public let position: AbsolutePosition

    public init(marker: String, position: AbsolutePosition) {
        self.marker = marker
        self.position = position
    }
}

/// Refutes `@ClockDeterministic` — and **only ever refutes it**.
///
/// `@ClockDeterministic` claims *"my result does not vary with wall-clock time,
/// **given** an injected `Clock`."* That claim is conjunctive in exactly the way
/// purity is (see `PurityInferrer`): it holds only when nothing in the function,
/// or anything it transitively calls, reaches for ambient time. A narrow
/// syntactic analyzer can produce one witness that the claim is false; it cannot
/// establish absence across a call graph. So this type answers *contradicted* or
/// *no opinion*, and there is deliberately no method that answers *confirmed*.
///
/// **The unsound direction is the permissive one, which is why refutation is
/// worth having at all.** The marker's whole function downstream is to relax an
/// async veto — it admits code to verification that would otherwise be rejected.
/// A false *positive* therefore hands a time-dependent function to a generated
/// property test, which then flakes; a false *negative* merely rejects something
/// that was verifiable. Same asymmetry as purity, same conclusion: refuting is
/// the direction a narrow analyzer may take.
///
/// `EffectAnnotationParser.isClockDeterministic(declaration:)` reads the claim;
/// this reads the body. Both live here so the two can never disagree about what
/// the claim asserts — the same one-oracle argument that put `PurityInferrer` in
/// this package rather than in each consumer.
///
/// ## Ambient *acquisition*, not ambient *use*
///
/// The obvious implementation asks "is this `.now` reached on an injected clock
/// or an ambient one?" and needs receiver-type resolution to answer, which
/// `ReceiverShapes` cannot settle here: a `clock` parameter annotated
/// `ContinuousClock` and a literal `ContinuousClock()` both resolve to
/// `.named("ContinuousClock")`, so the two cases the rule most needs to separate
/// are the two it cannot.
///
/// Refuting the **acquisition** dissolves that. An ambient clock has to be
/// obtained somewhere, and obtaining it is syntactically distinctive
/// (`ContinuousClock()`, `Date()`, `Task.sleep`) in a way that *using* one is
/// not. A function whose only clock arrives as a parameter performs no
/// acquisition, so the canonical correct use —
/// `try await clock.sleep(until: clock.now.advanced(by: .seconds(1)))` — is not
/// refuted, without the resolver ever being consulted. A local
/// `let clock = ContinuousClock()` is still caught, because the acquisition is
/// right there in the body.
///
/// ## Precision, and why it does not contradict `PurityInferrer`'s crudeness
///
/// `PurityInferrer` matches nondeterminism markers by bare identifier token and
/// says so: it refutes `Date(timeIntervalSince1970:)` alongside `Date()`, and
/// over-refutation is free there because the cost is one withheld `.pure`.
///
/// It is not free here. A clock-deterministic function is *precisely* one that
/// reads time from an injected clock, so a refuter that fires on every mention
/// of a time type would contradict every correct use of the marker and the rule
/// would have to be turned off. This scan is therefore expression-shaped and
/// argument-aware: `Date()` and `Date(timeIntervalSinceNow:)` refute,
/// `Date(timeIntervalSince1970:)` does not, and `Date` in a type annotation is
/// not an acquisition at all. That is a different question being asked more
/// precisely, not a gate being relaxed.
///
/// Nested closures are walked. An ambient acquisition inside `Task { }` in this
/// body is still this function reaching for a clock nobody passed in.
public struct ClockDeterminismRefuter: Sendable {

    public init() {}

    /// Clock types whose no-argument construction *is* the acquisition.
    /// `ContinuousClock()` and `SuspendingClock()` read the host's clock; a
    /// clock that arrives as a parameter is constructed in the caller, where
    /// this refuter is not looking and the claim does not apply.
    private static let ambientClockTypes: Set<String> = [
        "ContinuousClock", "SuspendingClock"
    ]

    /// Types carrying a static `now` that reads the host clock.
    private static let ambientNowTypes: Set<String> = [
        "Date", "ContinuousClock", "SuspendingClock", "DispatchTime", "DispatchWallTime"
    ]

    /// Free functions that read the host clock. These have no injected form —
    /// there is no argument that makes `mach_absolute_time()` deterministic —
    /// so the bare call is the acquisition.
    private static let ambientTimeFunctions: Set<String> = [
        "CFAbsoluteTimeGetCurrent", "mach_absolute_time", "mach_continuous_time",
        "clock_gettime", "gettimeofday"
    ]

    /// The witness that `function`'s body reaches for ambient time, or `nil` for
    /// **no opinion** — which is not the same as "clock-deterministic". A
    /// body-less declaration (a protocol requirement) has nothing to inspect and
    /// so yields no opinion rather than a refutation.
    public func refutation(for function: FunctionDeclSyntax) -> AmbientTimeWitness? {
        guard let body = function.body else { return nil }
        return refutation(in: Syntax(body))
    }

    /// Same question for a handler-style closure bound to a property, mirroring
    /// `EffectAnnotationParser.isClockDeterministic(declaration:)`'s
    /// `VariableDeclSyntax` overload — the claim can be written on either, so
    /// both have to be checkable.
    public func refutation(for variable: VariableDeclSyntax) -> AmbientTimeWitness? {
        refutation(in: Syntax(variable.bindings))
    }

    /// Same question for a closure body.
    public func refutation(for closure: ClosureExprSyntax) -> AmbientTimeWitness? {
        refutation(in: Syntax(closure.statements))
    }

    /// Boolean form of `refutation(for:)`, for callers that do not report a site.
    public func refutesClockDeterminism(_ function: FunctionDeclSyntax) -> Bool {
        refutation(for: function) != nil
    }

    /// The whole question a lint rule asks, in one call: the author claimed
    /// clock-determinism **and** the body contradicts it.
    ///
    /// Deliberately *not* left to the consumer to compose out of
    /// `EffectAnnotationParser.isClockDeterministic` and `refutation(for:)`.
    /// Composing it there would put the claim's spelling in one repository and
    /// its contradiction in another, which is the arrangement this package
    /// exists to prevent: the two could then disagree about which declarations
    /// carry the claim.
    ///
    /// Returns `nil` when the claim is absent — an unannotated function reaching
    /// for a clock is not contradicting anything, and this must not become a
    /// back door to inferring the marker's absence into a violation.
    public func contradictedClaim(in function: FunctionDeclSyntax) -> AmbientTimeWitness? {
        guard EffectAnnotationParser.isClockDeterministic(declaration: function) else { return nil }
        return refutation(for: function)
    }

    private func refutation(in syntax: Syntax) -> AmbientTimeWitness? {
        let collector = AmbientTimeCollector()
        collector.walk(syntax)
        return collector.witness
    }

    // MARK: - Shape predicates
    //
    // Static and internal so the collector can consult them without holding the
    // refuter, and so the tests can pin the argument-aware cases directly.

    /// Whether a call expression acquires ambient time.
    static func acquiresAmbientTime(_ call: FunctionCallExprSyntax) -> String? {
        // `ContinuousClock()`, `Date()`, `Date(timeIntervalSinceNow:)`,
        // `CFAbsoluteTimeGetCurrent()` — a bare type or function name callee.
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            if ambientClockTypes.contains(name) || ambientTimeFunctions.contains(name) {
                return "\(name)()"
            }
            if name == "Date", acquiresAmbientDate(call) {
                return "Date()"
            }
            return nil
        }

        // `Task.sleep(…)`, `DispatchTime.now()` — a `Type.member(…)` callee.
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           let base = member.base?.as(DeclReferenceExprSyntax.self) {
            let typeName = base.baseName.text
            let memberName = member.declName.baseName.text
            if typeName == "Task", memberName == "sleep", !sleepsOnSuppliedClock(call) {
                return "Task.sleep"
            }
            if ambientNowTypes.contains(typeName), memberName == "now" {
                return "\(typeName).now"
            }
        }

        return nil
    }

    /// `Date()` reads the host clock; so does `Date(timeIntervalSinceNow:)`,
    /// whose argument is an *offset from* now rather than an absolute instant.
    /// Every other initializer names a fixed reference point
    /// (`timeIntervalSince1970:`, `timeIntervalSinceReferenceDate:`,
    /// `timeInterval:since:`) and is deterministic, so it is not an acquisition.
    private static func acquiresAmbientDate(_ call: FunctionCallExprSyntax) -> Bool {
        guard let first = call.arguments.first else { return true }
        return first.label?.text == "timeIntervalSinceNow"
    }

    /// `Task.sleep(for:tolerance:clock:)` takes the clock it sleeps on, so the
    /// injected form is not an acquisition. `Task.sleep(for:)` and
    /// `Task.sleep(nanoseconds:)` fall back to the host clock and are.
    private static func sleepsOnSuppliedClock(_ call: FunctionCallExprSyntax) -> Bool {
        call.arguments.contains { $0.label?.text == "clock" }
    }

    /// Whether a member access *not* in call position reads ambient time —
    /// `Date.now`, `ContinuousClock.now`. The base must be a bare type name:
    /// `clock.now` on an injected parameter is the correct use of the marker and
    /// must survive, and it is distinguishable here precisely because `clock` is
    /// not a type this set knows.
    static func readsAmbientNow(_ member: MemberAccessExprSyntax) -> String? {
        guard member.declName.baseName.text == "now",
              let base = member.base?.as(DeclReferenceExprSyntax.self),
              ambientNowTypes.contains(base.baseName.text) else {
            return nil
        }
        return "\(base.baseName.text).now"
    }
}

/// Finds the first ambient-time acquisition anywhere under a body, closures
/// included, and stops.
///
/// First rather than all: the consumer is a lint rule, one witness settles the
/// question, and walking on would cost a full traversal to report sites the
/// author has to fix before the rule can pass anyway.
private final class AmbientTimeCollector: SourceAccurateSyntaxVisitor {

    private(set) var witness: AmbientTimeWitness?

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard witness == nil else { return .skipChildren }
        if let marker = ClockDeterminismRefuter.acquiresAmbientTime(node) {
            witness = AmbientTimeWitness(marker: marker, position: node.positionAfterSkippingLeadingTrivia)
            return .skipChildren
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard witness == nil else { return .skipChildren }
        if let marker = ClockDeterminismRefuter.readsAmbientNow(node) {
            witness = AmbientTimeWitness(marker: marker, position: node.positionAfterSkippingLeadingTrivia)
            return .skipChildren
        }
        return .visitChildren
    }
}
