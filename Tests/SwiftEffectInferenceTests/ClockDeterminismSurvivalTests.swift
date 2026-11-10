@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax
import Testing

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
