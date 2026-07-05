import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Behavioural suite for `BodyEffectInferrer.inferEffects` — the single-pass,
/// resolver-driven core of upward (body-based) inference.
///
/// Each test supplies its own `resolveCalleeEffect` as a name→`BodyInference`
/// map, so the inferrer's own logic — lub of contributing callees, depth as
/// `1 + max(contributing depth)`, and the walk boundaries (nested `func`,
/// escaping closures, annotated-decl skipping) — is exercised in isolation
/// from the call-site classifier that supplies real effects in production.
@Suite("BodyEffectInferrer inference")
struct BodyEffectInferrerTests {

    private static func parse(_ source: String) -> SourceFileSyntax {
        Parser.parse(source: source)
    }

    /// Runs the inferrer resolving each call by its callee base name.
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

    /// A declared/heuristic anchor — depth 0, as `EffectSymbolTable` supplies
    /// for declared and heuristic-downward callees.
    private func anchor(_ effect: Effect, depth: Int = 0) -> BodyInference {
        BodyInference(effect: effect, depth: depth)
    }

    @Test("effect is the lub of resolvable callees")
    func takesLubOfCallees() {
        let inferred = infer("""
        func doWork() {
            logSomething()
            saveRecord()
        }
        """, resolving: [
            "logSomething": anchor(.observational),
            "saveRecord": anchor(.nonIdempotent)
        ])

        #expect(inferred[sig("doWork")]?.effect == .nonIdempotent)
        // All lub-contributing callees are depth-0 anchors → one hop.
        #expect(inferred[sig("doWork")]?.depth == 1)
    }

    @Test("no resolvable callee yields no entry")
    func noResolvableCallees_yieldsNoEntry() {
        let inferred = infer("""
        func doWork() { unknownThing() }
        """, resolving: [:])

        #expect(inferred[sig("doWork")] == nil)
        #expect(inferred.isEmpty)
    }

    @Test("depth follows the longest contributing chain")
    func depthCountsContributingChain() {
        let inferred = infer("""
        func doWork() { deepCall() }
        """, resolving: [
            "deepCall": anchor(.nonIdempotent, depth: 2)
        ])

        #expect(inferred[sig("doWork")]?.effect == .nonIdempotent)
        #expect(inferred[sig("doWork")]?.depth == 3)
    }

    @Test("a deeper non-lub callee does not inflate depth")
    func nonContributingCalleeDoesNotInflateDepth() {
        let inferred = infer("""
        func doWork() {
            shallowStrong()
            deepWeak()
        }
        """, resolving: [
            // Determines the lub, contributes its depth.
            "shallowStrong": anchor(.nonIdempotent, depth: 1),
            // Higher depth but lower rank — walked and counted, but its depth
            // must not contribute since it isn't at the lub rank.
            "deepWeak": anchor(.observational, depth: 5)
        ])

        #expect(inferred[sig("doWork")]?.effect == .nonIdempotent)
        #expect(inferred[sig("doWork")]?.depth == 2)
    }

    @Test("annotated functions are not inference sites")
    func annotatedFunctionIsSkipped() {
        let inferred = infer("""
        @Pure
        func annotated() { saveRecord() }
        """, resolving: [
            "saveRecord": anchor(.nonIdempotent)
        ])

        #expect(inferred[sig("annotated")] == nil)
    }

    @Test("nested function is its own site; the outer body is not recursed into")
    func nestedFunctionIsSeparateSite() {
        let inferred = infer("""
        func outer() {
            inner()
            func inner() {
                saveRecord()
            }
        }
        """, resolving: [
            "inner": anchor(.observational),
            "saveRecord": anchor(.nonIdempotent)
        ])

        // `outer` sees the `inner()` call but must not walk into `inner`'s
        // body, so it never observes `saveRecord`.
        #expect(inferred[sig("outer")]?.effect == .observational)
        #expect(inferred[sig("outer")]?.depth == 1)
        // `inner` is inferred independently from its own body.
        #expect(inferred[sig("inner")]?.effect == .nonIdempotent)
        #expect(inferred[sig("inner")]?.depth == 1)
    }

    @Test("calls inside an escaping closure do not propagate")
    func escapingClosureStopsPropagation() {
        let inferred = infer("""
        func launch() {
            Task {
                saveRecord()
            }
        }
        """, resolving: [
            "saveRecord": anchor(.nonIdempotent)
        ])

        // `saveRecord` runs in a `Task { }` retry boundary → not counted, and
        // `Task` itself is unresolved → `launch` gets no inference.
        #expect(inferred[sig("launch")] == nil)
    }

    @Test("a non-escaping closure body is walked inline")
    func nonEscapingClosureBodyIsWalked() {
        let inferred = infer("""
        func launch() {
            saveRecord()
        }
        """, resolving: [
            "saveRecord": anchor(.nonIdempotent)
        ])

        #expect(inferred[sig("launch")]?.effect == .nonIdempotent)
        #expect(inferred[sig("launch")]?.depth == 1)
    }

    @Test("a top-level closure binding participates in inference")
    func closureLiteralBindingParticipates() {
        let inferred = infer("""
        let handler: () -> Void = { saveRecord() }
        """, resolving: [
            "saveRecord": anchor(.nonIdempotent)
        ])

        #expect(inferred[sig("handler")]?.effect == .nonIdempotent)
        #expect(inferred[sig("handler")]?.depth == 1)
    }

    @Test("a function-local closure binding is not its own site")
    func functionLocalClosureBindingIsSkipped() {
        let inferred = infer("""
        func container() {
            let local: () -> Void = { saveRecord() }
        }
        """, resolving: [
            "saveRecord": anchor(.nonIdempotent)
        ])

        // `local` can't be called by name from outside `container`, so it is
        // not registered as a pseudo-method inference site …
        #expect(inferred[sig("local")] == nil)
        // … but its closure body is a non-escaping part of `container`, so
        // `container` picks up the enclosed `saveRecord` call.
        #expect(inferred[sig("container")]?.effect == .nonIdempotent)
        #expect(inferred[sig("container")]?.depth == 1)
    }
}
