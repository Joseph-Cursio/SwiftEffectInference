import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Characterization suite for `CallSiteEffectInferrer`.
///
/// Pins the observable behaviour of `infer(call:)` and `inferenceReason(for:)`
/// across every inference path. Its primary contract is the **consistency
/// invariant**: for any call site, `infer` returns non-nil if and only if
/// `inferenceReason` returns non-nil. The two methods walk the same decision
/// tree, so an effect without a reason (or vice versa) is a divergence bug.
/// This suite was written to guard the merge of the two methods onto a single
/// `resolve(...)` pass.
@Suite("CallSiteEffectInferrer paths")
struct CallSiteEffectInferrerTests {

    /// Parses `source` and returns its first `FunctionCallExprSyntax`.
    private static func firstCall(in source: String) -> FunctionCallExprSyntax {
        let tree = Parser.parse(source: source)
        final class Finder: SyntaxVisitor {
            var found: FunctionCallExprSyntax?
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .visitChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(tree)
        guard let call = finder.found else {
            fatalError("no FunctionCallExprSyntax found in: \(source)")
        }
        return call
    }

    struct Case: Sendable {
        let label: String
        let source: String
        let imports: Set<String>
        let expectedEffect: Effect?
        /// Substring the reason must contain (nil ⇔ effect is nil).
        let reasonContains: String?
    }

    static let cases: [Case] = [
        Case(label: "logger receiver", source: "logger.info(\"x\")",
             imports: [], expectedEffect: .observational,
             reasonContains: "logger-shaped"),
        Case(label: "metric receiver", source: "counter.increment()",
             imports: ["Metrics"], expectedEffect: .observational,
             reasonContains: "metric-primitive"),
        Case(label: "type constructor", source: "JSONDecoder()",
             imports: ["Foundation"], expectedEffect: .idempotent,
             reasonContains: "known-idempotent"),
        Case(label: "codec receiver", source: "decoder.decode(Foo.self)",
             imports: ["Foundation"], expectedEffect: .idempotent,
             reasonContains: "codec-pattern"),
        Case(label: "idempotent receiver pair", source: "request.decode(Foo.self)",
             imports: ["Hummingbird"], expectedEffect: .idempotent,
             reasonContains: "Hummingbird primitive"),
        Case(label: "cross-framework pair", source: "parameters.get(\"id\")",
             imports: ["Vapor"], expectedEffect: .idempotent,
             reasonContains: "primitive"),
        Case(label: "bare-name override", source: "send(.action)",
             imports: ["ComposableArchitecture"], expectedEffect: .idempotent,
             reasonContains: "closure-parameter primitive"),
        Case(label: "whitelist idempotent", source: "upsert()",
             imports: [], expectedEffect: .idempotent,
             reasonContains: "callee name"),
        Case(label: "whitelist non-idempotent", source: "create()",
             imports: [], expectedEffect: .nonIdempotent,
             reasonContains: "callee name"),
        Case(label: "framework idempotent method", source: "query(on: db)",
             imports: ["FluentKit"], expectedEffect: .idempotent,
             reasonContains: "query-builder read"),
        Case(label: "framework non-idempotent method", source: "model.save()",
             imports: ["FluentKit"], expectedEffect: .nonIdempotent,
             reasonContains: "ORM verb"),
        Case(label: "non-idempotent prefix", source: "sendEmail()",
             imports: [], expectedEffect: .nonIdempotent,
             reasonContains: "callee-name prefix"),
        Case(label: "no match", source: "doThing()",
             imports: [], expectedEffect: nil,
             reasonContains: nil),
        // Gate inactive: metric receiver without the `Metrics` import does
        // not classify, so both methods must agree on nil.
        Case(label: "metric gate inactive", source: "counter.increment()",
             imports: [], expectedEffect: nil,
             reasonContains: nil)
    ]

    @Test("effect matches expectation", arguments: cases)
    func effectMatches(_ testCase: Case) {
        let call = Self.firstCall(in: testCase.source)
        let effect = CallSiteEffectInferrer.infer(call: call, imports: testCase.imports)
        #expect(effect == testCase.expectedEffect, "\(testCase.label)")
    }

    @Test("reason matches expectation", arguments: cases)
    func reasonMatches(_ testCase: Case) {
        let call = Self.firstCall(in: testCase.source)
        let reason = CallSiteEffectInferrer.inferenceReason(for: call, imports: testCase.imports)
        if let expected = testCase.reasonContains {
            #expect(reason?.contains(expected) == true, "\(testCase.label): \(reason ?? "nil")")
        } else {
            #expect(reason == nil, "\(testCase.label): \(reason ?? "nil")")
        }
    }

    /// The consistency invariant: effect and reason are present together or
    /// absent together. This is the property the single-pass merge must keep.
    @Test("infer and inferenceReason agree on presence", arguments: cases)
    func presenceAgrees(_ testCase: Case) {
        let call = Self.firstCall(in: testCase.source)
        let effect = CallSiteEffectInferrer.infer(call: call, imports: testCase.imports)
        let reason = CallSiteEffectInferrer.inferenceReason(for: call, imports: testCase.imports)
        #expect((effect == nil) == (reason == nil), "\(testCase.label)")
    }
}
