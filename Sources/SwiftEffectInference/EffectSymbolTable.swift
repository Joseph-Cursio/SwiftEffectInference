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

    /// Annotated declarations indexed by bare name, carrying which of their parameters
    /// may be omitted at a call site. Consulted only when an exact-signature lookup
    /// misses, so a call that writes every argument never pays for this.
    ///
    /// Needed because a declaration's label list names every parameter while a call
    /// site's names only the ones written: `createRequest(endpoint:method:body:queryItems:)`
    /// is called as `createRequest(endpoint:method:)` whenever the defaults suffice, and
    /// keying the lookup on equality alone silently misses it.
    private var shapesByName: [String: [(shape: DeclarationShape, effect: Effect)]] = [:]

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
            record(shape: DeclarationShape.from(declaration: funcDecl), effect: effect)
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
                  let shape = DeclarationShape.from(declaration: varDecl),
                  let effect = parser.parseEffect(declaration: varDecl) else {
                continue
            }
            record(shape: shape, effect: effect)
        }
    }

    /// Records one annotated occurrence of a function signature, with no parameter
    /// treated as omittable. Equivalent to a declaration whose parameters all lack
    /// defaults; prefer `record(shape:effect:)` when the declaration is to hand.
    public mutating func record(signature: FunctionSignature, effect: Effect) {
        record(
            shape: DeclarationShape(
                name: signature.name,
                parameters: signature.argumentLabels.map {
                    DeclarationShape.Parameter(label: $0, hasDefault: false)
                }
            ),
            effect: effect
        )
    }

    /// Records one annotated declaration, keeping both the exact-signature entry and
    /// the call-site shape that lets a caller omitting defaults still find it.
    /// Unannotated declarations are filtered out by `merge(source:parser:)` before
    /// reaching this method.
    public mutating func record(shape: DeclarationShape, effect: Effect) {
        shapesByName[shape.signature.name, default: []].append((shape, effect))

        let signature = shape.signature
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

    /// Returns the declared effect for a **call-site** `signature`, or `nil` if no
    /// annotated declaration answers to it (zero declarations, or withdrawn by collision).
    ///
    /// An exact-signature entry wins, mirroring Swift's own preference for the overload
    /// that needs no defaults. Failing that, the annotated declarations sharing this bare
    /// name are asked whether they *could* have been called this way — which is how a call
    /// that omits a defaulted argument reaches its declaration at all. If several could,
    /// and they disagree about the effect, the lookup withdraws: guessing which overload
    /// the compiler picked would be worse than staying silent.
    public func effect(for signature: FunctionSignature) -> Effect? {
        effect(for: CallSiteShape(signature: signature))
    }

    /// Returns the declared effect for a call site, or `nil` if no annotated declaration
    /// answers to it (zero declarations, or withdrawn by collision).
    ///
    /// Prefer this over the `FunctionSignature` overload wherever the call syntax is to hand.
    /// A call written with a trailing closure — `perform { }` against `func perform(action:)` —
    /// has no label for that argument at all, so it cannot be found by signature alone. Swift
    /// being made of trailing closures, looking up by bare signature is blind to a large share
    /// of real call sites.
    public func effect(for callSite: CallSiteShape) -> Effect? {
        let signature = callSite.signature

        // An exact signature wins, mirroring Swift's own preference for the overload that needs
        // no defaults. Only meaningful when nothing was sugared away.
        if callSite.trailingClosureCount == 0,
           let exact = entriesBySignature[signature]?.effect {
            return exact
        }
        // A signature withdrawn by collision stays withdrawn — do not let shape
        // matching resurrect an ambiguity the collision policy already refused.
        if isCollision(signature: signature) {
            return nil
        }
        return effectFromDeclarationShapes(callSite: callSite)
    }

    /// The single annotated declaration that `callSite` could have reached, or `nil` when none
    /// could or when several could and the choice is ambiguous.
    ///
    /// Lets a consumer ask about the *declaration* behind a call — in particular, whether a
    /// parameter the call left out was one the declaration allowed it to leave out. That is the
    /// difference between "the caller omitted a required argument" (a compile error, not our
    /// problem) and "the caller took a default" (which, for an idempotency key, is a silent
    /// correctness hole).
    public func declaration(matching callSite: CallSiteShape) -> DeclarationShape? {
        guard let candidates = shapesByName[callSite.signature.name] else { return nil }

        let matches = candidates
            .filter { $0.shape.accepts(callSite) }
            .map(\.shape)

        return matches.count == 1 ? matches.first : nil
    }

    /// The effect of the annotated declarations that could accept `callSite`, or `nil` when
    /// none could or when they disagree.
    private func effectFromDeclarationShapes(callSite: CallSiteShape) -> Effect? {
        guard let candidates = shapesByName[callSite.signature.name] else { return nil }

        var matched: Set<Effect> = []
        for candidate in candidates
        where entriesBySignature[candidate.shape.signature] != nil
            && candidate.shape.accepts(callSite) {
            matched.insert(candidate.effect)
        }

        // Ambiguous about *which* declaration but agreed about the answer is not an
        // ambiguity worth withdrawing over — whichever the compiler picked, the effect
        // is the same.
        return matched.count == 1 ? matched.first : nil
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

    /// Body inference whose heuristic resolver does not need the enclosing file.
    ///
    /// The import-aware form exists because some heuristics are gated on what a file imports
    /// (Fluent's `save`/`delete` only mean what they look like when `FluentKit` is in scope).
    /// A resolver that consults no imports has no use for the second parameter, and saying so
    /// is clearer than threading an ignored argument through every call site.
    public mutating func applyBodyInference(
        to sources: [SourceFileSyntax],
        multiHop: Bool = false,
        maxHops: Int = 5,
        wallClockBudget: Duration = .seconds(30),
        heuristicEffectForCall: @escaping (FunctionCallExprSyntax) -> Effect?
    ) {
        applyBodyInference(
            to: sources,
            multiHop: multiHop,
            maxHops: maxHops,
            wallClockBudget: wallClockBudget
        ) { call, _ in
            heuristicEffectForCall(call)
        }
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

/// Collects every `FunctionDeclSyntax` in a source file. The shared core only
/// tracks effects; the execution-context axis (`@lint.context`) is a linting
/// concern and lives in its consumer.
///
/// Descent stops at closure expressions. A declaration written inside a closure
/// body cannot be called by name from outside it, so registering it would put a
/// signature in the table that no call site can legitimately resolve to — and,
/// worse, could collide with a real top-level declaration of the same shape.
/// `BodyEffectInferrer`'s collectors already stop at closures; these now agree.
final class FunctionDeclCollector: SourceAccurateSyntaxVisitor {

    var functions: [FunctionDeclSyntax] = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(node)
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }
}

/// Collects closure-typed property declarations that participate in the
/// pseudo-method registration path (`var search: @Sendable () -> Void`,
/// `let handler = { ... }`). Stops at closure expressions for the same reason
/// as `FunctionDeclCollector`.
final class ClosurePropertyDeclCollector: SourceAccurateSyntaxVisitor {

    var properties: [VariableDeclSyntax] = []

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        properties.append(node)
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }
}

/// `true` if `decl` lives inside a function body, initializer, deinit, or
/// accessor. Function-local closure bindings can't be called by name from
/// outside their enclosing scope, so they don't participate in the
/// pseudo-method registration path.
///
/// Public because consumers building their own inference passes over the same
/// declarations need to apply the identical exclusion — `SwiftProjectLint`'s
/// upward inferrer being the motivating case.
public func isFunctionLocal(_ decl: VariableDeclSyntax) -> Bool {
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
