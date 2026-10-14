import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// What classifying a call costs, on the shape that once made it cost the call's depth.
///
/// A call's position is its first token's, and in a member chain `x.a().a()…` that token is at the
/// bottom of the chain. The classifier located every call before asking whether it was a source,
/// so classifying a chain was quadratic in its length — and `PurityInferrer` classifies every call
/// in every body it checks. Found downstream: in SwiftProjectLint, every rule that reads purity took
/// ~5.5 s on an 8,000-link chain, nearly all of it descending to first tokens.
///
/// **The ratio is the assertion**, as in `PurityInferrerPerformanceTests`: a millisecond figure is
/// a measurement of the machine, and the relationship between two lengths is not.
@Suite("NondeterminismSources — cost budget")
struct NondeterminismSourcesCostTests {

    /// Every call in `_ = x.a().a()…`, none of which is a source.
    static func chainCalls(links: Int) -> [FunctionCallExprSyntax] {
        final class Collector: SourceAccurateSyntaxVisitor {
            var calls: [FunctionCallExprSyntax] = []
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                calls.append(node)
                return .visitChildren
            }
        }
        let collector = Collector()
        collector.walk(Parser.parse(source: "_ = x" + String(repeating: ".a()", count: links)))
        return collector.calls
    }

    /// The best of several timings of classifying every call, so that a trial which shared the
    /// machine with another test does not decide the ratio.
    static func cost(of calls: [FunctionCallExprSyntax]) -> Duration {
        let trials = (0..<5).map { _ in
            let start = ContinuousClock.now
            for _ in 0..<20 {
                for call in calls { _ = NondeterminismSources.source(of: call) }
            }
            return ContinuousClock.now - start
        }
        return trials.min() ?? .zero
    }

    /// Four times the links should cost about four times as much: linear scores ~4, and locating
    /// every call scores ~16. The chain stays at 400 links because past ~600 a debug build's
    /// `SyntaxVisitor` walk overflows the stack of the thread a test runs on.
    @Test("a chain four times as long costs about four times as much to classify")
    func chainClassifiesInLinearTime() {
        let short = Self.chainCalls(links: 100)
        let long = Self.chainCalls(links: 400)
        #expect(long.count == 400)
        #expect(long.allSatisfy { NondeterminismSources.source(of: $0) == nil })

        let ratio = Self.cost(of: long) / Self.cost(of: short)
        #expect(
            ratio < 8,
            """
            classifying 4× the links cost \(ratio)× as much. At ~16 every call is being located \
            whether or not it is a source — see NondeterminismSources.source(of:).
            """
        )
    }
}
