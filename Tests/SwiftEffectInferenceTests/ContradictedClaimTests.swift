@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax
import Testing

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
