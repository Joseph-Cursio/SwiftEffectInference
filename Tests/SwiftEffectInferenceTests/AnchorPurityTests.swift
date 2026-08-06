import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// `BodyInference.anchor` — whether the chain justifying an inferred effect
/// bottoms out on annotations or on a guess.
///
/// **What it is for.** SwiftInferProperties' `EffectResolver` runs its own
/// upward inference with the heuristic classifier switched off, because *"a veto
/// built on a name guess would suppress a true law because a callee was called
/// `save`."* That forced a choice: SwiftProjectLint resolves multi-hop across
/// files but supplies `HeuristicEffectInferrer` as its anchor resolver, so its
/// results could not be trusted wholesale — and the consumer withheld all of
/// them, keeping only the direct-callee case it could verify itself. This field
/// lets it take the reach and keep the stance.
///
/// `depth` and `anchor` are independent axes and the tests below treat them so:
/// a one-hop guess is weaker than a four-hop chain of annotations, and nothing
/// about the hop count says which you have.
@Suite("Anchor purity — what an inferred effect rests on")
struct AnchorPurityTests {

    private static func parse(_ source: String) -> SourceFileSyntax {
        Parser.parse(source: source)
    }

    private func infer(
        _ source: String,
        resolving map: [String: BodyInference]
    ) -> [FunctionSignature: BodyInference] {
        BodyEffectInferrer.inferEffects(in: Self.parse(source)) { call in
            guard let name = call.calledExpression.referenceBaseName else { return nil }
            return map[name]
        }
    }

    private func sig(_ name: String, _ labels: [String] = []) -> FunctionSignature {
        FunctionSignature(name: name, argumentLabels: labels)
    }

    private func declared(_ effect: Effect, depth: Int = 0) -> BodyInference {
        BodyInference(effect: effect, depth: depth, anchor: .declared)
    }

    private func guessed(_ effect: Effect, depth: Int = 0) -> BodyInference {
        BodyInference(effect: effect, depth: depth, anchor: .heuristic)
    }

    // MARK: - The two clean cases

    @Test("a body whose lub comes from an annotation is declared-anchored")
    func declaredCalleeGivesDeclaredAnchor() {
        let results = infer(
            "func caller() { chargeCard() }",
            resolving: ["chargeCard": declared(.nonIdempotent)]
        )
        #expect(results[sig("caller")]?.anchor == .declared)
        #expect(results[sig("caller")]?.effect == .nonIdempotent)
    }

    @Test("a body whose lub comes from a name guess is heuristic-anchored")
    func heuristicCalleeGivesHeuristicAnchor() {
        let results = infer(
            "func caller() { save() }",
            resolving: ["save": guessed(.nonIdempotent)]
        )
        #expect(results[sig("caller")]?.anchor == .heuristic)
        #expect(results[sig("caller")]?.effect == .nonIdempotent)
    }

    // MARK: - Propagation, which is the whole point

    /// The case the consumer wants and could not previously have: a chain that
    /// travelled several hops and never touched a guess. Depth rises; the anchor
    /// does not degrade.
    @Test("a multi-hop chain of annotations stays declared-anchored")
    func multiHopDeclaredStaysDeclared() {
        let results = infer(
            "func caller() { settle() }",
            resolving: ["settle": declared(.nonIdempotent, depth: 3)]
        )
        let inference = results[sig("caller")]
        #expect(inference?.anchor == .declared)
        #expect(inference?.depth == 4)
    }

    /// …and the case it must still refuse. One guess anywhere in the chain that
    /// determines the answer is enough.
    @Test("one guessed step taints the whole chain")
    func oneGuessTaintsTheChain() {
        let results = infer(
            "func caller() { settle() }",
            resolving: ["settle": guessed(.nonIdempotent, depth: 3)]
        )
        #expect(results[sig("caller")]?.anchor == .heuristic)
    }

    // MARK: - Which callees get a vote

    /// A redundant guess alongside an annotation of the same tier does not
    /// downgrade the result. The declaration alone fully justifies the lub, and
    /// withholding trust because a guess happened to agree would penalise
    /// corroboration.
    @Test("a guess agreeing with an annotation does not downgrade it")
    func redundantGuessDoesNotDowngrade() {
        let results = infer(
            "func caller() { chargeCard(); save() }",
            resolving: [
                "chargeCard": declared(.nonIdempotent),
                "save": guessed(.nonIdempotent)
            ]
        )
        #expect(results[sig("caller")]?.anchor == .declared)
    }

    /// A guess *below* the lub did not determine the answer, so it cannot taint
    /// it — the same contributors-only rule `depth` already followed.
    @Test("a lower-tier guess does not taint a declared lub")
    func lowerTierGuessDoesNotTaint() {
        let results = infer(
            "func caller() { chargeCard(); readCache() }",
            resolving: [
                "chargeCard": declared(.nonIdempotent),
                "readCache": guessed(.observational)
            ]
        )
        let inference = results[sig("caller")]
        #expect(inference?.effect == .nonIdempotent)
        #expect(inference?.anchor == .declared)
    }

    /// The mirror: when the guess *is* what raises the lub, it is load-bearing
    /// and the result is heuristic — even though a declared callee is present.
    @Test("a guess that raises the lub is load-bearing")
    func guessRaisingTheLubIsLoadBearing() {
        let results = infer(
            "func caller() { readCache(); save() }",
            resolving: [
                "readCache": declared(.observational),
                "save": guessed(.nonIdempotent)
            ]
        )
        let inference = results[sig("caller")]
        #expect(inference?.effect == .nonIdempotent)
        #expect(inference?.anchor == .heuristic)
    }

    // MARK: - The default

    /// Constructing without stating an anchor must not claim annotation
    /// backing. The cost is asymmetric: `.declared` by default would let a guess
    /// reach a consumer wearing an annotation's authority, which is the exact
    /// failure the field exists to prevent.
    @Test("an unstated anchor is heuristic, not declared")
    func defaultAnchorIsConservative() {
        #expect(BodyInference(effect: .nonIdempotent, depth: 1).anchor == .heuristic)
    }

    // MARK: - The join

    @Test("strongest prefers a declaration", arguments: [
        (BodyInference.Anchor.declared, BodyInference.Anchor.declared, BodyInference.Anchor.declared),
        (.declared, .heuristic, .declared),
        (.heuristic, .declared, .declared),
        (.heuristic, .heuristic, .heuristic)
    ])
    func strongestTable(
        lhs: BodyInference.Anchor,
        rhs: BodyInference.Anchor,
        expected: BodyInference.Anchor
    ) {
        #expect(BodyInference.Anchor.strongest(lhs, rhs) == expected)
    }
}

/// The same field, driven through `EffectSymbolTable.applyBodyInference` rather
/// than through a stubbed resolver.
///
/// **Why both suites exist.** The tests above hand `inferEffects` a resolver map
/// and check the combine rule; they never execute the three real anchor sites
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
        table.applyBodyInference(to: [source], heuristicEffectForCall: { _, _ in nil })
        #expect(table.upwardInference(for: sig("wrapper"))?.anchor == .declared)
    }

    /// The real heuristic path: no annotation anywhere, the name inferrer
    /// supplying the only effect in play.
    @Test("a heuristic-only callee anchors the caller in a guess")
    func heuristicCalleeAnchorsCaller() {
        let source = Self.parse("func wrapper() { save() }")
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(
            to: [source],
            heuristicEffectForCall: { call, _ in
                call.calledExpression.referenceBaseName == "save" ? .nonIdempotent : nil
            }
        )
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
        table.applyBodyInference(
            to: [source], multiHop: true, heuristicEffectForCall: { _, _ in nil }
        )
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
        table.applyBodyInference(
            to: [source],
            multiHop: true,
            heuristicEffectForCall: { call, _ in
                call.calledExpression.referenceBaseName == "save" ? .nonIdempotent : nil
            }
        )
        let outer = table.upwardInference(for: sig("outer"))
        #expect(outer?.effect == .nonIdempotent)
        #expect(outer?.anchor == .heuristic)
    }
}
