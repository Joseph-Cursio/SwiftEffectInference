import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Exercises the canonical `PurityInferrer` — the shared oracle that decides
/// whether a function is `Effect.pure` (referential transparency).
@Suite
struct PurityInferrerTests {

    private let inferrer = PurityInferrer()

    /// Parses `source` and returns the inferred effect of the first `func`.
    private func effectOfFirstFunction(in source: String) -> Effect? {
        let tree = Parser.parse(source: source)
        let function = tree.statements.lazy
            .compactMap { $0.item.as(FunctionDeclSyntax.self) }
            .first
        guard let function else { return nil }
        return inferrer.inferredEffect(for: function)
    }

    @Test
    func transparentFunction_inferredPure() {
        let effect = effectOfFirstFunction(in: """
        func add(_ lhs: Int, _ rhs: Int) -> Int { lhs + rhs }
        """)
        #expect(effect == .pure)
    }

    @Test
    func loggingFunction_refutesPure() {
        // `print` is observational to the retry-safety lattice but NOT pure —
        // the case the `pure` tier exists to capture.
        let effect = effectOfFirstFunction(in: """
        func add(_ lhs: Int, _ rhs: Int) -> Int {
            print("adding")
            return lhs + rhs
        }
        """)
        #expect(effect == nil)
    }

    @Test
    func randomness_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func pick(_ values: [Int]) -> Int { values.randomElement() ?? 0 }
        """)
        #expect(effect == nil)
    }

    @Test
    func forceUnwrap_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func first(_ values: [Int]) -> Int { values.first! }
        """)
        #expect(effect == nil)
    }

    @Test
    func fatalError_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func parse(_ text: String) -> Int {
            guard let value = Int(text) else { fatalError("bad input") }
            return value
        }
        """)
        #expect(effect == nil)
    }

    @Test
    func asyncFunction_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func fetch(_ id: Int) async -> Int { id }
        """)
        #expect(effect == nil)
    }

    @Test
    func throwingFunction_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        func parse(_ text: String) throws -> Int { Int(text) ?? 0 }
        """)
        #expect(effect == nil)
    }

    @Test
    func bodylessDeclaration_refutesPure() {
        let effect = effectOfFirstFunction(in: """
        protocol P { func f(_ x: Int) -> Int }
        """)
        #expect(effect == nil)
    }

    @Test
    func isPure_matchesInferredEffect() throws {
        let tree = Parser.parse(source: "func square(_ x: Int) -> Int { x * x }")
        let function = try #require(tree.statements.first?.item.as(FunctionDeclSyntax.self))
        #expect(inferrer.isPure(function))
        #expect(inferrer.inferredEffect(for: function) == .pure)
    }
}
