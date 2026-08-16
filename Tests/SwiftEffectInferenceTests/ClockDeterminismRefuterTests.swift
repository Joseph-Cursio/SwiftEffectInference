import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// The refuter's contract is asymmetric — it may say *contradicted* or *no
/// opinion*, never *confirmed* — so these suites are split the same way: what
/// must refute, and what must survive. The second half is the load-bearing one.
/// A refuter that fires on the marker's correct use would have to be switched
/// off, which is worse than not having it.
@Suite("Clock-determinism: what refutes the claim")
struct ClockDeterminismRefutationTests {

    private func firstFunction(in source: String) throws -> FunctionDeclSyntax {
        final class Finder: SyntaxVisitor {
            var found: FunctionDeclSyntax?
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: source))
        return try #require(finder.found)
    }

    private func marker(of source: String) throws -> String? {
        ClockDeterminismRefuter().refutation(for: try firstFunction(in: source))?.marker
    }

    @Test("constructing a host clock is an acquisition")
    func continuousClockConstruction_refutes() throws {
        #expect(try marker(of: """
        func tick() async -> Duration { ContinuousClock().measure { } }
        """) == "ContinuousClock()")
    }

    @Test("a host clock bound to a local is still acquired in this body")
    func clockBoundToLocal_refutes() throws {
        #expect(try marker(of: """
        func tick() async {
            let clock = SuspendingClock()
            _ = clock.now
        }
        """) == "SuspendingClock()")
    }

    @Test("Date() reads the host clock")
    func bareDate_refutes() throws {
        #expect(try marker(of: "func stamp() -> Date { Date() }") == "Date()")
    }

    @Test("Date(timeIntervalSinceNow:) is an offset from now, so it reads it too")
    func dateSinceNow_refutes() throws {
        // Named under its own spelling rather than folded into `Date()`, so the
        // witness points at the initializer the author actually wrote.
        #expect(try marker(of: """
        func soon() -> Date { Date(timeIntervalSinceNow: 60) }
        """) == "Date(timeIntervalSinceNow:)")
    }

    @Test("a static now reads the host clock")
    func staticNow_refutes() throws {
        #expect(try marker(of: "func stamp() -> Date { Date.now }") == "Date.now")
    }

    @Test("Task.sleep without a clock falls back to the host clock")
    func taskSleep_refutes() throws {
        #expect(try marker(of: """
        func wait() async throws { try await Task.sleep(for: .seconds(1)) }
        """) == "Task.sleep")
    }

    @Test("a C clock function has no injected form")
    func cClockFunction_refutes() throws {
        #expect(try marker(of: """
        func elapsed() -> Double { CFAbsoluteTimeGetCurrent() }
        """) == "CFAbsoluteTimeGetCurrent()")
    }

    @Test("an acquisition inside a nested closure still belongs to this body")
    func acquisitionInsideClosure_refutes() throws {
        #expect(try marker(of: """
        func schedule() async {
            Task { let stamp = Date(); print(stamp) }
        }
        """) == "Date()")
    }

    @Test("the witness carries where to look, not just that something is wrong")
    func witnessCarriesPosition() throws {
        let source = "func stamp() -> Date { Date() }"
        let witness = try #require(ClockDeterminismRefuter().refutation(for: try firstFunction(in: source)))
        // `Date()` opens at column 24 (1-indexed) of the single-line source.
        #expect(witness.position.utf8Offset == 23)
    }
}

@Suite("Clock-determinism: what the refuter must not fire on")
struct ClockDeterminismSurvivalTests {

    private func firstFunction(in source: String) throws -> FunctionDeclSyntax {
        final class Finder: SyntaxVisitor {
            var found: FunctionDeclSyntax?
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: source))
        return try #require(finder.found)
    }

    private func refutation(of source: String) throws -> AmbientTimeWitness? {
        ClockDeterminismRefuter().refutation(for: try firstFunction(in: source))
    }

    /// The canonical correct use of the marker. If this refutes, the rule is
    /// unusable — every honestly-annotated function would violate it.
    @Test("reading and sleeping on an injected clock is the whole point of the claim")
    func injectedClock_survives() throws {
        #expect(try refutation(of: """
        @ClockDeterministic
        func debounce<C: Clock>(clock: C) async throws {
            try await clock.sleep(until: clock.now.advanced(by: .seconds(1)), tolerance: nil)
        }
        """) == nil)
    }

    @Test("Task.sleep given a clock sleeps on the one it was handed")
    func taskSleepWithSuppliedClock_survives() throws {
        #expect(try refutation(of: """
        func wait<C: Clock>(clock: C) async throws {
            try await Task.sleep(for: .seconds(1), tolerance: nil, clock: clock)
        }
        """) == nil)
    }

    /// The precision that separates this from `PurityInferrer`'s token scan,
    /// which refutes every one of these.
    @Test("a Date built from a fixed reference point is deterministic")
    func dateFromFixedReference_survives() throws {
        #expect(try refutation(of: """
        func epoch() -> Date { Date(timeIntervalSince1970: 0) }
        """) == nil)
        #expect(try refutation(of: """
        func reference() -> Date { Date(timeIntervalSinceReferenceDate: 0) }
        """) == nil)
    }

    @Test("a time type named in a signature is not an acquisition")
    func typeAnnotation_survives() throws {
        #expect(try refutation(of: """
        func format(stamp: Date, clock: ContinuousClock) -> String { "\\(stamp)" }
        """) == nil)
    }

    @Test("`now` on something that is not a known clock type is not an acquisition")
    func nowOnUnknownReceiver_survives() throws {
        #expect(try refutation(of: """
        func read(state: Snapshot) -> Int { state.now }
        """) == nil)
    }

    @Test("a body-less requirement has nothing to inspect, so no opinion")
    func protocolRequirement_yieldsNoOpinion() throws {
        #expect(try refutation(of: "func tick() async -> Int") == nil)
    }
}

@Suite("Clock-determinism: the claim and its contradiction, together")
struct ContradictedClaimTests {

    private func firstFunction(in source: String) throws -> FunctionDeclSyntax {
        final class Finder: SyntaxVisitor {
            var found: FunctionDeclSyntax?
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: source))
        return try #require(finder.found)
    }

    @Test("an annotated function that reaches for a host clock contradicts itself")
    func annotatedAndRefuted_isContradiction() throws {
        let function = try firstFunction(in: """
        @ClockDeterministic
        func stale() async -> Date { Date() }
        """)
        #expect(ClockDeterminismRefuter().contradictedClaim(in: function)?.marker == "Date()")
    }

    @Test("the doc-comment spelling of the claim is read the same way")
    func docCommentSpelling_isContradictedToo() throws {
        let function = try firstFunction(in: """
        /// @lint.determinism clock_deterministic
        func stale() async -> Date { Date.now }
        """)
        #expect(ClockDeterminismRefuter().contradictedClaim(in: function)?.marker == "Date.now")
    }

    /// The guard against this becoming a back door to inferring the marker.
    /// An unannotated function reaching for a clock has claimed nothing and so
    /// contradicts nothing — reporting it would be the tool inventing the claim
    /// in order to violate it.
    @Test("an unannotated function contradicts nothing, however it reads the clock")
    func unannotated_isNotAContradiction() throws {
        let function = try firstFunction(in: "func stamp() -> Date { Date() }")
        let refuter = ClockDeterminismRefuter()
        #expect(refuter.contradictedClaim(in: function) == nil)
        // …though the body-level question still has an answer, which is what
        // keeps the two methods genuinely different.
        #expect(refuter.refutation(for: function)?.marker == "Date()")
    }

    @Test("an annotated function on an injected clock is not reported")
    func annotatedAndClean_isNotAContradiction() throws {
        let function = try firstFunction(in: """
        @ClockDeterministic
        func debounce<C: Clock>(clock: C) async throws {
            try await clock.sleep(until: clock.now, tolerance: nil)
        }
        """)
        #expect(ClockDeterminismRefuter().contradictedClaim(in: function) == nil)
    }
}
