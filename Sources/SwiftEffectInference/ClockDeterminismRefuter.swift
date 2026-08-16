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
/// ## Where the markers live
///
/// Not here. `NondeterminismSources` owns the sets and the argument-aware
/// shape-matching, and this type is the `.clock`-shaped question asked of it —
/// one scan, one set of markers, filtered to the kind this question is about.
/// The same classifier answers SwiftProjectLint's `nonInjectedNondeterminism`
/// rule, which is what keeps a clock-reading expression from meaning one thing
/// to the linter and another to the oracle.
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
        return record(NondeterminismSources.source(of: node))
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard witness == nil else { return .skipChildren }
        return record(NondeterminismSources.source(of: node))
    }

    /// Every time-related kind refutes; the rest are discarded. A `UUID()` or a
    /// `.shuffled()` in the body says nothing about whether the function varies
    /// with wall-clock time, which is the whole of what the claim asserts —
    /// refuting on them would contradict annotations that are honest about time.
    ///
    /// Listed exhaustively rather than by a negative test, so a kind added
    /// upstream is a compile error here and gets a decision. The claim covers
    /// monotonic clocks and timed suspension as well as wall time: a function
    /// whose result depends on `mach_absolute_time()` or on how long it slept is
    /// not clock-deterministic either, whatever clock did the measuring.
    private static let refutingKinds: Set<NondeterminismSource.Kind> = [
        .wallClockNow, .wallClockOffset, .monotonicClock, .clockAcquisition, .timedSuspension
    ]

    private func record(_ source: NondeterminismSource?) -> SyntaxVisitorContinueKind {
        guard let source, Self.refutingKinds.contains(source.kind) else { return .visitChildren }
        witness = AmbientTimeWitness(marker: source.marker, position: source.position)
        return .skipChildren
    }
}
