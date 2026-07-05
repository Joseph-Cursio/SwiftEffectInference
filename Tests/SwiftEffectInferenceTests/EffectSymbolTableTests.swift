import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Behavioural suite for `EffectSymbolTable` — cross-file declared-effect
/// storage, the collision-withdrawal policy, and the body-inference
/// orchestration (`applyBodyInference`) that populates the upward cache and
/// drives the multi-hop fixed point.
@Suite("EffectSymbolTable")
struct EffectSymbolTableTests {

    private static func parse(_ source: String) -> SourceFileSyntax {
        Parser.parse(source: source)
    }

    private func sig(_ name: String, _ labels: [String] = []) -> FunctionSignature {
        FunctionSignature(name: name, argumentLabels: labels)
    }

    // MARK: - record / collision policy

    @Test("a single recorded declaration is looked up, not flagged as a collision")
    func recordSingleDeclaration() {
        var table = EffectSymbolTable()
        table.record(signature: sig("save", ["_"]), effect: .nonIdempotent)

        #expect(table.effect(for: sig("save", ["_"])) == .nonIdempotent)
        #expect(table.isCollision(signature: sig("save", ["_"])) == false)
    }

    @Test("duplicate declarations with the same effect are kept as one logical entry")
    func matchingDuplicatesAreKept() {
        var table = EffectSymbolTable()
        table.record(signature: sig("save", ["_"]), effect: .idempotent)
        table.record(signature: sig("save", ["_"]), effect: .idempotent)

        #expect(table.effect(for: sig("save", ["_"])) == .idempotent)
        #expect(table.isCollision(signature: sig("save", ["_"])) == true)
    }

    @Test("duplicate declarations with conflicting effects are withdrawn")
    func conflictingDuplicatesAreWithdrawn() {
        var table = EffectSymbolTable()
        table.record(signature: sig("save", ["_"]), effect: .idempotent)
        table.record(signature: sig("save", ["_"]), effect: .nonIdempotent)

        #expect(table.effect(for: sig("save", ["_"])) == nil)
        #expect(table.isCollision(signature: sig("save", ["_"])) == true)
    }

    // MARK: - build / merge

    @Test("build records annotated functions and ignores unannotated ones")
    func buildMergesAnnotatedFunctions() {
        let table = EffectSymbolTable.build(from: Self.parse("""
        @Idempotent
        func upsert(_ key: String) {}
        @NonIdempotent
        func create(_ key: String) {}
        func plain() {}
        """))

        #expect(table.effect(for: sig("upsert", ["_"])) == .idempotent)
        #expect(table.effect(for: sig("create", ["_"])) == .nonIdempotent)
        // Unannotated declarations do not become declared entries.
        #expect(table.effect(for: sig("plain")) == nil)
    }

    @Test("annotated closure-typed properties register as pseudo-methods")
    func closureTypedPropertyRegisters() {
        let table = EffectSymbolTable.build(from: Self.parse("""
        @Observational
        var search: @Sendable (_ query: String) async -> Void
        """))

        #expect(table.effect(for: sig("search", ["query"])) == .observational)
    }

    // MARK: - provenance

    @Test("lookupWithProvenance reports a declared effect as .declared")
    func provenanceForDeclaredEffect() {
        let table = EffectSymbolTable.build(from: Self.parse("""
        @NonIdempotent
        func save() {}
        """))

        let resolved = table.lookupWithProvenance(for: sig("save"))
        #expect(resolved?.0 == .nonIdempotent)
        #expect(resolved?.1 == .declared)
    }

    @Test("lookupWithProvenance returns nil for an unknown signature")
    func provenanceForUnknownSignature() {
        let table = EffectSymbolTable()
        #expect(table.lookupWithProvenance(for: sig("mystery")) == nil)
    }

    // MARK: - applyBodyInference (single-pass)

    @Test("single-pass body inference infers a caller of a declared function")
    func singlePassInfersFromDeclaredCallee() {
        let source = Self.parse("""
        func wrapper() {
            save()
        }
        @NonIdempotent
        func save() {}
        """)
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(
            to: [source],
            heuristicEffectForCall: { _, _ in nil }
        )

        #expect(table.upwardInferredEffect(for: sig("wrapper")) == .nonIdempotent)
        #expect(table.upwardInference(for: sig("wrapper"))?.depth == 1)
        // Provenance now falls through declared → body-inferred.
        let resolved = table.lookupWithProvenance(for: sig("wrapper"))
        #expect(resolved?.1 == .bodyInferred(depth: 1))
    }

    @Test("a declared effect is never overwritten by body inference")
    func declaredEffectBeatsUpward() {
        let source = Self.parse("""
        func wrapper() {
            save()
        }
        @NonIdempotent
        func save() {}
        """)
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(
            to: [source],
            heuristicEffectForCall: { _, _ in nil }
        )

        // `save` keeps its declared provenance; no upward entry shadows it.
        #expect(table.lookupWithProvenance(for: sig("save"))?.1 == .declared)
        #expect(table.upwardInferredEffect(for: sig("save")) == nil)
    }

    @Test("a heuristic-classified callee drives inference")
    func heuristicCalleeDrivesInference() {
        let source = Self.parse("""
        func usesHeuristic() {
            mysteryCall()
        }
        """)
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(
            to: [source],
            heuristicEffectForCall: { call, _ in
                call.calledExpression.referenceBaseName == "mysteryCall" ? .idempotent : nil
            }
        )

        #expect(table.upwardInferredEffect(for: sig("usesHeuristic")) == .idempotent)
        #expect(table.upwardInference(for: sig("usesHeuristic"))?.depth == 1)
    }

    // MARK: - applyBodyInference (multi-hop)

    @Test("single-pass does not chain through an inferred callee")
    func singlePassDoesNotChain() {
        let source = Self.parse("""
        func top() {
            middle()
        }
        func middle() {
            save()
        }
        @NonIdempotent
        func save() {}
        """)
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(
            to: [source],
            heuristicEffectForCall: { _, _ in nil }
        )

        // `middle` reaches the declared anchor in one hop …
        #expect(table.upwardInferredEffect(for: sig("middle")) == .nonIdempotent)
        // … but `top` calls the *inferred* `middle`, which single-pass ignores.
        #expect(table.upwardInferredEffect(for: sig("top")) == nil)
    }

    @Test("multi-hop chains through an inferred callee to a fixed point")
    func multiHopChainsThroughInferredCallee() {
        let source = Self.parse("""
        func top() {
            middle()
        }
        func middle() {
            save()
        }
        @NonIdempotent
        func save() {}
        """)
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(
            to: [source],
            multiHop: true,
            heuristicEffectForCall: { _, _ in nil }
        )

        #expect(table.upwardInferredEffect(for: sig("middle")) == .nonIdempotent)
        #expect(table.upwardInferredEffect(for: sig("top")) == .nonIdempotent)
        // top → middle (depth 1) → save anchor, so top sits two hops out.
        #expect(table.upwardInference(for: sig("top"))?.depth == 2)
    }

    @Test("maxHops caps the recorded depth")
    func maxHopsCapsDepth() {
        let source = Self.parse("""
        func top() {
            middle()
        }
        func middle() {
            save()
        }
        @NonIdempotent
        func save() {}
        """)
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(
            to: [source],
            multiHop: true,
            maxHops: 1,
            heuristicEffectForCall: { _, _ in nil }
        )

        // `top`'s natural depth is 2, capped to `maxHops`.
        #expect(table.upwardInferredEffect(for: sig("top")) == .nonIdempotent)
        #expect(table.upwardInference(for: sig("top"))?.depth == 1)
    }

    @Test("a collided callee contributes no effect to its caller")
    func collidedCalleeIsSilentInInference() {
        let source = Self.parse("""
        @Idempotent
        func amb(_ x: Int) {}
        @NonIdempotent
        func amb(_ x: Int) {}
        func caller() {
            amb(1)
        }
        """)
        var table = EffectSymbolTable.build(from: source)
        table.applyBodyInference(
            to: [source],
            heuristicEffectForCall: { _, _ in nil }
        )

        // The conflicting `amb` declarations withdraw the entry …
        #expect(table.effect(for: sig("amb", ["_"])) == nil)
        #expect(table.isCollision(signature: sig("amb", ["_"])) == true)
        // … and the resolver treats a collision as silent, so `caller` gets
        // no upward inference from it.
        #expect(table.upwardInferredEffect(for: sig("caller")) == nil)
    }
}
