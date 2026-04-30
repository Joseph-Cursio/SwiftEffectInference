import SwiftSyntax

/// Cross-file declared+inferred effect lookup. Keys entries on
/// `FunctionSignature` (the canonical bare-receiver form
/// `name(label1:label2:…)`), so two declarations collide only if they
/// would be indistinguishable at a call site without type info.
///
/// ## Collision policy
///
/// Unannotated declarations do **not** participate in collision detection.
/// The user's annotation expresses intent; an unannotated sibling is noise,
/// not ambiguity.
///
/// - Zero annotated declarations for a signature → no entry.
/// - Exactly one annotated declaration → entry stored.
/// - Multiple annotated declarations with matching effect → entry stored
///   (counts as one logical declaration).
/// - Multiple annotated declarations with conflicting effect → entry
///   withdrawn (`lookup` returns `nil`).
///
/// ## Lookup precedence
///
/// Consumers consult effects in this order:
/// ```
///   declared > collision-withdraw (silent) > upward-inferred > heuristic-downward > silent
/// ```
///
/// `EffectSymbolTable` covers the first three; the heuristic-downward
/// fallback is consumer-supplied (typically backed by
/// `CallSiteEffectInferrer`).
///
/// Origin: lifted from SwiftProjectLint's `EffectSymbolTable` during
/// migration step 3 of `docs/SwiftEffectInference Design v0.2.md` §10.
/// SPL's context-tracking (`@lint.context replayable` etc.) and once-reach
/// machinery stay in SPL — they're SPL-specific concerns and out of scope
/// for the shared core (design v0.2 §6).
public struct EffectSymbolTable: Sendable {

    public struct Entry: Sendable, Equatable {
        public let effect: Effect

        public init(effect: Effect) {
            self.effect = effect
        }
    }

    public private(set) var entriesBySignature: [FunctionSignature: Entry] = [:]

    /// Count of **annotated** definitions seen per signature. Unannotated
    /// declarations are not recorded here — only annotated ones participate
    /// in collision detection.
    private var annotatedCounts: [FunctionSignature: Int] = [:]

    /// Effects inferred upward from un-annotated function bodies. Populated
    /// by `applyBodyInference(to:)` after declared effects are merged.
    /// Lookups go declared → collision → upward → silent, so these entries
    /// never override a declared one.
    private var upwardInferredEffects: [FunctionSignature: BodyInference] = [:]

    public init() {}

    /// Builds a symbol table by walking every annotated function and
    /// closure-typed property in the source.
    public static func build(from source: SourceFileSyntax) -> EffectSymbolTable {
        var table = EffectSymbolTable()
        table.merge(source: source, parser: EffectAnnotationParser())
        return table
    }

    /// Adds every annotated declaration in `source` to this table, applying
    /// the collision policy. Pass a configured `EffectAnnotationParser` to
    /// override the default attribute recognition.
    public mutating func merge(
        source: SourceFileSyntax,
        parser: EffectAnnotationParser = EffectAnnotationParser()
    ) {
        let funcCollector = FunctionDeclCollector()
        funcCollector.walk(source)
        for funcDecl in funcCollector.functions {
            guard let effect = parser.parseEffect(declaration: funcDecl) else { continue }
            let signature = FunctionSignature.from(declaration: funcDecl)
            record(signature: signature, effect: effect)
        }

        // Closure-typed stored properties as pseudo-method declarations.
        // `@DependencyClient`-style macros expose
        // `var search: @Sendable (_ query: String) async throws -> T` as
        // callable `search(query:)`. Closure-literal bindings without a
        // type annotation also register when their explicit parameter
        // clause yields a derivable signature. Function-local bindings are
        // skipped — they can't be called by name from outside their scope.
        let propCollector = ClosurePropertyDeclCollector()
        propCollector.walk(source)
        for varDecl in propCollector.properties {
            guard !isFunctionLocal(varDecl),
                  let signature = FunctionSignature.from(declaration: varDecl),
                  let effect = parser.parseEffect(declaration: varDecl) else {
                continue
            }
            record(signature: signature, effect: effect)
        }
    }

    /// Records one annotated occurrence of a function signature.
    /// Unannotated declarations are filtered out by `merge(source:parser:)`
    /// before reaching this method.
    public mutating func record(signature: FunctionSignature, effect: Effect) {
        annotatedCounts[signature, default: 0] += 1
        let count = annotatedCounts[signature] ?? 0

        if count == 1 {
            entriesBySignature[signature] = Entry(effect: effect)
            return
        }

        if let existing = entriesBySignature[signature], existing.effect == effect {
            return
        }
        entriesBySignature.removeValue(forKey: signature)
    }

    /// Returns the declared effect for `signature`, or `nil` if the signature
    /// has no annotated entry (zero declarations, or withdrawn by collision).
    public func effect(for signature: FunctionSignature) -> Effect? {
        entriesBySignature[signature]?.effect
    }

    /// `true` if two or more annotated declarations of `signature` were
    /// encountered.
    public func isCollision(signature: FunctionSignature) -> Bool {
        (annotatedCounts[signature] ?? 0) > 1
    }

    /// Returns the upward-inferred effect for `signature` if body analysis
    /// produced one, or `nil` otherwise.
    public func upwardInferredEffect(for signature: FunctionSignature) -> Effect? {
        upwardInferredEffects[signature]?.effect
    }

    /// Returns the upward-inferred effect *and depth* for `signature`. Use
    /// when callers need to surface hop depth in diagnostics.
    public func upwardInference(for signature: FunctionSignature) -> BodyInference? {
        upwardInferredEffects[signature]
    }

    /// Resolved-with-provenance lookup. Returns the most authoritative
    /// effect known for `signature` along with the path that produced it.
    /// Order: declared > upward-inferred > nil. Heuristic-downward is not
    /// consulted by the symbol table directly — call
    /// `CallSiteEffectInferrer.infer(call:imports:)` at the call site.
    public func lookupWithProvenance(
        for signature: FunctionSignature
    ) -> (Effect, EffectProvenance)? {
        if let declared = effect(for: signature) {
            return (declared, .declared)
        }
        if let upward = upwardInference(for: signature) {
            return (upward.effect, .bodyInferred(depth: upward.depth))
        }
        return nil
    }

    // MARK: - Body-based inference orchestration

    /// Runs body-based upward inference across every source in `sources`,
    /// using the supplied resolver to classify un-annotated callees via
    /// `CallSiteEffectInferrer`-equivalent logic. Populates the upward
    /// inference cache.
    ///
    /// `multiHop: false` (default) is single-pass: each function's effect
    /// is computed from its callees' declared and heuristic-downward
    /// effects. `multiHop: true` iterates to fixed-point so callers of
    /// upward-inferred functions can themselves be inferred.
    public mutating func applyBodyInference(
        to sources: [SourceFileSyntax],
        multiHop: Bool = false,
        maxHops: Int = 5,
        wallClockBudget: Duration = .seconds(30),
        heuristicEffectForCall: (FunctionCallExprSyntax, SourceFileSyntax) -> Effect?
    ) {
        let deadline = ContinuousClock.now.advanced(by: wallClockBudget)

        runInferencePass(
            sources: sources,
            includeUpward: false,
            maxHops: maxHops,
            deadline: deadline,
            heuristicEffectForCall: heuristicEffectForCall
        )

        guard multiHop else { return }

        for _ in 0..<maxHops {
            if ContinuousClock.now >= deadline { return }
            let previous = upwardInferredEffects.mapValues { $0.effect }
            runInferencePass(
                sources: sources,
                includeUpward: true,
                maxHops: maxHops,
                deadline: deadline,
                heuristicEffectForCall: heuristicEffectForCall
            )
            let current = upwardInferredEffects.mapValues { $0.effect }
            if previous == current { return }
        }
    }

    private mutating func runInferencePass(
        sources: [SourceFileSyntax],
        includeUpward: Bool,
        maxHops: Int,
        deadline: ContinuousClock.Instant,
        heuristicEffectForCall: (FunctionCallExprSyntax, SourceFileSyntax) -> Effect?
    ) {
        for source in sources {
            if ContinuousClock.now >= deadline { return }
            let inferred = BodyEffectInferrer.inferEffects(
                in: source,
                resolveCalleeEffect: { call in
                    if let sig = FunctionSignature.from(call: call) {
                        if isCollision(signature: sig) { return nil }
                        if let declared = self.effect(for: sig) {
                            return BodyInference(effect: declared, depth: 0)
                        }
                        if includeUpward, let upward = self.upwardInference(for: sig) {
                            return upward
                        }
                    }
                    if let heuristic = heuristicEffectForCall(call, source) {
                        return BodyInference(effect: heuristic, depth: 0)
                    }
                    return nil
                }
            )
            for (sig, result) in inferred {
                guard entriesBySignature[sig]?.effect == nil else { continue }
                let cappedDepth = min(maxHops, result.depth)
                let cappedResult = BodyInference(effect: result.effect, depth: cappedDepth)
                upwardInferredEffects[sig] = mergedInference(
                    existing: upwardInferredEffects[sig],
                    incoming: cappedResult
                )
            }
        }
    }

    /// Combines the prior pass's inference with this pass's inference for a
    /// single signature. Effect rises monotonically (lub of the two);
    /// depth takes the max so a long chain established earlier isn't
    /// shrunk by a subsequent shorter equivalent.
    private func mergedInference(
        existing: BodyInference?,
        incoming: BodyInference
    ) -> BodyInference {
        guard let existing else { return incoming }
        let mergedEffect = existing.effect.lub(incoming.effect)
        let mergedDepth = max(existing.depth, incoming.depth)
        return BodyInference(effect: mergedEffect, depth: mergedDepth)
    }
}

/// Origin of an effect resolution, used by consumers (SPL for diagnostic
/// prose, SwiftInfer for explainability blocks) to distinguish declared
/// effects from inferred ones.
public enum EffectProvenance: Sendable, Equatable {
    case declared
    case bodyInferred(depth: Int)
    case callSite(reason: String)
}

// MARK: - Visitors (internal)

/// Collects every `FunctionDeclSyntax` in a source file. Unlike SPL's
/// version, does not filter by `@lint.context` — the shared core only
/// tracks effects.
final class FunctionDeclCollector: SyntaxVisitor {

    var functions: [FunctionDeclSyntax] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(node)
        return .visitChildren
    }
}

/// Collects closure-typed property declarations that participate in the
/// pseudo-method registration path (`var search: @Sendable () -> Void`,
/// `let handler = { ... }`).
final class ClosurePropertyDeclCollector: SyntaxVisitor {

    var properties: [VariableDeclSyntax] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        properties.append(node)
        return .visitChildren
    }
}

/// `true` if `decl` lives inside a function body, initializer, deinit, or
/// accessor. Function-local closure bindings can't be called by name from
/// outside their enclosing scope, so they don't participate in the
/// pseudo-method registration path.
func isFunctionLocal(_ decl: VariableDeclSyntax) -> Bool {
    var current: Syntax? = Syntax(decl).parent
    while let node = current {
        if node.is(FunctionDeclSyntax.self) ||
           node.is(InitializerDeclSyntax.self) ||
           node.is(DeinitializerDeclSyntax.self) ||
           node.is(AccessorDeclSyntax.self) {
            return true
        }
        current = node.parent
    }
    return false
}
