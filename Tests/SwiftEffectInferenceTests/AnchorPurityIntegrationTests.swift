@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax
import Testing

/// The same field, driven through `EffectSymbolTable.applyBodyInference` rather
/// than through a stubbed resolver.
///
/// **Why both suites exist.** `AnchorPurityTests` hands `inferEffects` a resolver map
/// and checks the combine rule; it never executes the three real anchor sites
/// (declared lookup, prior-pass inheritance, heuristic fallback) or the
/// cross-pass merge. A resolver stub can only confirm the logic I wrote does
/// what I wrote — the production wiring is where a field ends up silently
/// unreachable, which has already happened once in this toolchain this week.
@Suite("Anchor purity — through the symbol table")
struct AnchorPurityIntegrationTests {

    private static func parse(_ source: String) -> SourceFileSyntax {
        Parser.parse(source: source)
    }

    private func sig(_ name: String, _ labels: [String] = []) -> FunctionSignature {
        FunctionSignature(name: name, argumentLabels: labels)
    }

    /// The real declared path: an annotation, reached through the call graph
    /// with the heuristic resolver returning nothing.
    @Test("an annotated callee anchors the caller in a declaration")
    func declaredCalleeAnchorsCaller() {
        let source = Self.parse("""
        func wrapper() { charge() }
        @NonIdempotent
        func charge() {}
        """)
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(to: [source]) { _, _ in nil }
        #expect(table.upwardInference(for: sig("wrapper"))?.anchor == .declared)
    }

    /// The real heuristic path: no annotation anywhere, the name inferrer
    /// supplying the only effect in play.
    @Test("a heuristic-only callee anchors the caller in a guess")
    func heuristicCalleeAnchorsCaller() {
        let source = Self.parse("func wrapper() { save() }")
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(to: [source]) { call, _ in
            call.calledExpression.referenceBaseName == "save" ? .nonIdempotent : nil
        }
        #expect(table.upwardInference(for: sig("wrapper"))?.anchor == .heuristic)
    }

    /// **The case this whole change exists to make expressible.** Three hops,
    /// every one of them unannotated, bottoming out on a single annotation — the
    /// reach a one-hop local pass cannot have, with the purity a consumer needs
    /// before it will act.
    @Test("a multi-hop chain to an annotation stays declared-anchored")
    func multiHopToAnnotationStaysDeclared() {
        let source = Self.parse("""
        func outer() { middle() }
        func middle() { inner() }
        func inner() { charge() }
        @NonIdempotent
        func charge() {}
        """)
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(to: [source], multiHop: true) { _, _ in nil }
        let outer = table.upwardInference(for: sig("outer"))
        #expect(outer?.effect == .nonIdempotent)
        #expect(outer?.anchor == .declared)
        #expect((outer?.depth ?? 0) >= 3, "expected a genuinely multi-hop chain")
    }

    /// The mirror, and the one a consumer must be able to decline: the chain
    /// reaches the same tier, over the same distance, but the bottom of it is a
    /// name match rather than something a human wrote.
    @Test("a multi-hop chain to a guess is heuristic-anchored")
    func multiHopToGuessIsHeuristic() {
        let source = Self.parse("""
        func outer() { middle() }
        func middle() { inner() }
        func inner() { save() }
        """)
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(to: [source], multiHop: true) { call, _ in
            call.calledExpression.referenceBaseName == "save" ? .nonIdempotent : nil
        }
        let outer = table.upwardInference(for: sig("outer"))
        #expect(outer?.effect == .nonIdempotent)
        #expect(outer?.anchor == .heuristic)
    }
}
