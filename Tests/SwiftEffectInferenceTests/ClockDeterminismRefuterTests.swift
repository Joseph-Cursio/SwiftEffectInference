@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax
import Testing

/// The refuter's contract is asymmetric — it may say *contradicted* or *no
/// opinion*, never *confirmed* — so these suites are split the same way: what
/// must refute, and what must survive. The second half is the load-bearing one.
/// A refuter that fires on the marker's correct use would have to be switched
/// off, which is worse than not having it.
@Suite("Clock-determinism: what refutes the claim")
struct ClockDeterminismRefuterTests {

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
