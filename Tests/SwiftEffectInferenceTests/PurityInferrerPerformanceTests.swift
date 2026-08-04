import Foundation
import SwiftParser
@testable import SwiftEffectInference
import SwiftSyntax
import Testing

/// A wall-clock budget for the shared purity oracle.
///
/// **Why this repo needs one.** Issue #1 was a ~2× regression on
/// `inferredEffect(for:)` that this package's own suite could not see — it was
/// found two repositories downstream, by five PRD §13 budgets failing in
/// SwiftInferProperties, and diagnosed by bisecting a pin. `PurityInferrer` is
/// called once per function by every consumer that scans a corpus, so its
/// per-call cost is multiplied by every function in every project any of them
/// look at. A regression here should fail here.
///
/// **The budget is deliberately loose and the RATIO is the assertion.** An
/// absolute millisecond figure on a shared oracle is a machine measurement, and
/// this suite runs wherever CI runs. What issue #1 actually broke was the
/// *relationship* between the two entry points: the whole-domain question got as
/// expensive as the domain-narrowing one, on a corpus where most functions
/// `throw`. That is checkable without trusting the clock's absolute value.
@Suite("PurityInferrer — cost budget (issue #1)")
struct PurityInferrerPerformanceTests {

    /// A throwing-dense corpus, which is the population issue #1 was about:
    /// Swift test code especially is full of `throws`, and those are exactly the
    /// functions that used to pay two full body walks to reach a verdict their
    /// signature already settled.
    static func throwingCorpus(count: Int) -> [FunctionDeclSyntax] {
        let source = (0 ..< count).map { index in
            """
            func subject\(index)(_ text: String) throws -> Int {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: ",")
                guard let first = parts.first else { throw MyError.bad }
                guard let value = Int(first) else { throw MyError.bad }
                return value + parts.count
            }
            """
        }.joined(separator: "\n")
        return Parser.parse(source: source).statements
            .compactMap { $0.item.as(FunctionDeclSyntax.self) }
    }

    /// The regression, stated as a ratio.
    ///
    /// On a throwing-dense corpus the whole-domain question rejects on the
    /// SIGNATURE and never walks a body, while `verdict` must walk each one to
    /// separate `.pureButPartial` from `.refuted`. So `inferredEffect` should be
    /// **substantially cheaper**. Before the fix it delegated, making them equal
    /// by construction — a ratio near 1.0 is precisely the regression.
    ///
    /// The threshold is 0.75 rather than something tight: this asserts "the cheap
    /// path is still cheap", not a specific speedup. A delegating implementation
    /// scores ~1.0 and fails; anything genuinely short-circuiting clears it with
    /// room, on any machine.
    @Test("The whole-domain path stays cheaper than the verdict path on throwing code")
    func inferredEffectDoesNotPayForVerdictsWalk() {
        let corpus = Self.throwingCorpus(count: 400)
        let inferrer = PurityInferrer()

        // Warm the caches equally so the first arm does not pay for both.
        for function in corpus {
            _ = inferrer.inferredEffect(for: function)
            _ = inferrer.verdict(for: function)
        }

        let inferredStart = ContinuousClock.now
        for _ in 0 ..< 5 {
            for function in corpus { _ = inferrer.inferredEffect(for: function) }
        }
        let inferredCost = ContinuousClock.now - inferredStart

        let verdictStart = ContinuousClock.now
        for _ in 0 ..< 5 {
            for function in corpus { _ = inferrer.verdict(for: function) }
        }
        let verdictCost = ContinuousClock.now - verdictStart

        let ratio = inferredCost / verdictCost
        #expect(
            ratio < 0.75,
            """
            inferredEffect cost \(ratio)× verdict on a throwing-dense corpus. \
            At ~1.0 the whole-domain path is walking bodies it does not need — \
            the shape of issue #1. See PurityInferrer.inferredEffect(for:).
            """
        )
    }

    /// The control the ratio test needs: on NON-throwing code the two do the same
    /// work, so the ratio must NOT be small. Without this, an `inferredEffect`
    /// that simply returned `nil` for everything would pass the test above.
    @Test("On non-throwing code the two paths cost about the same — the control")
    func nonThrowingCorpusCostsAreComparable() {
        let source = (0 ..< 400).map { index in
            """
            func subject\(index)(_ text: String) -> Int {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                return trimmed.count + \(index)
            }
            """
        }.joined(separator: "\n")
        let corpus = Parser.parse(source: source).statements
            .compactMap { $0.item.as(FunctionDeclSyntax.self) }
        let inferrer = PurityInferrer()
        for function in corpus {
            _ = inferrer.inferredEffect(for: function)
            _ = inferrer.verdict(for: function)
        }

        let inferredStart = ContinuousClock.now
        for _ in 0 ..< 5 {
            for function in corpus { _ = inferrer.inferredEffect(for: function) }
        }
        let inferredCost = ContinuousClock.now - inferredStart

        let verdictStart = ContinuousClock.now
        for _ in 0 ..< 5 {
            for function in corpus { _ = inferrer.verdict(for: function) }
        }
        let verdictCost = ContinuousClock.now - verdictStart

        // Wide band on purpose — this is a "did not collapse to a stub" check,
        // not a measurement. Both walk the same body once.
        let ratio = inferredCost / verdictCost
        #expect(
            ratio > 0.4,
            """
            inferredEffect is implausibly cheap (\(ratio)×) on non-throwing code — \
            is it still doing the body walk?
            """
        )
    }
}
