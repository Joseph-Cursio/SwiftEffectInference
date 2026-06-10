import SwiftSyntax

/// One result from upward inference: the effect plus a hop depth.
///
/// `depth` measures the longest chain of un-annotated functions back to a
/// declared or heuristic-downward anchor, counting the function being
/// described as one hop. So:
/// - `depth: 1` means the function's lub-contributing callees are all
///   declared or heuristic anchors (the single-pass / one-hop case).
/// - `depth: 2+` means at least one lub-contributing callee was itself
///   upward-inferred (multi-hop fixed-point).
public struct BodyInference: Sendable, Equatable {
    public let effect: Effect
    public let depth: Int

    public init(effect: Effect, depth: Int) {
        self.effect = effect
        self.depth = depth
    }
}

/// Phase-2.3 body-based effect inference ("upward inference").
///
/// Given an un-annotated function declaration, walks its body and computes
/// an inferred effect as the lattice lub of the effects of its direct
/// callees. If the body contains a non-idempotent call, the function itself
/// is inferred non-idempotent; if all calls are observational, the function
/// is observational; and so on.
///
/// ## Precedence in rule lookups
///
/// Rules consult effects in this order:
///
///   declared  >  collision-withdraw (silent)  >  upward-inferred  >  heuristic-downward  >  silent
///
/// Upward beats heuristic-downward because body analysis is a stronger
/// signal than name matching. A function named `insert` whose body only
/// calls `logMetric` is observational (upward) rather than non-idempotent
/// (downward-name).
///
/// ## Single-pass vs multi-hop
///
/// `inferEffects` itself is single-pass and order-invariant: the resolver
/// closure decides what to return for each callee, and the inferrer just
/// takes the lub. The "one-hop" or "multi-hop" policy lives in the
/// resolver — see `EffectSymbolTable.applyBodyInference(multiHop:)`.
/// In one-hop mode the resolver returns only declared and heuristic-
/// downward effects. In multi-hop mode it also returns prior-pass upward
/// results, and `EffectSymbolTable` iterates `inferEffects` to a fixed
/// point.
///
/// ## Escaping-closure policy
///
/// Same as the rule visitors: body analysis stops at `Task { }`,
/// `withTaskGroup`, `Task.detached`, SwiftUI `.task { }`. Calls inside
/// those boundaries are in a different retry context and do not propagate
/// their effects to the enclosing function.
public enum BodyEffectInferrer {

    /// Computes upward-inferred effects for every un-annotated function in
    /// `source`. Callers supply a `resolveCalleeEffect` function that maps
    /// a call-site callee to an `BodyInference` (effect + depth). The
    /// inferrer takes the lub of contributing effects and assigns the
    /// resulting function `depth = 1 + max(depth of lub-contributing
    /// callees)`. Callees whose effect is *not* the lub are still walked
    /// and counted (so an unrelated 5-hop callee doesn't inflate depth
    /// when a closer callee determines the lub).
    public static func inferEffects(
        in source: SourceFileSyntax,
        parser: EffectAnnotationParser = EffectAnnotationParser(),
        resolveCalleeEffect: (FunctionCallExprSyntax) -> BodyInference?
    ) -> [FunctionSignature: BodyInference] {
        let collector = UnannotatedFunctionCollector(parser: parser)
        collector.walk(source)

        var results: [FunctionSignature: BodyInference] = [:]
        for decl in collector.functions {
            guard let body = decl.body else { continue }
            let calleeResults = collectResults(in: Syntax(body), resolve: resolveCalleeEffect)
            guard let inference = combine(calleeResults: calleeResults) else { continue }
            let signature = FunctionSignature.from(declaration: decl)
            results[signature] = inference
        }

        // Closure-literal bindings (`let handler = { ... }`) participate
        // in upward inference on the same terms as `func` declarations.
        // Only unannotated, not-function-local bindings with a derivable
        // signature are inferred; all three filters mirror the declared-
        // effect registration path in `EffectSymbolTable.merge`.
        let bindingCollector = UnannotatedClosureBindingCollector(parser: parser)
        bindingCollector.walk(source)
        for varDecl in bindingCollector.bindings {
            guard !isFunctionLocal(varDecl),
                  let closure = varDecl.closureInitializer,
                  let signature = FunctionSignature.from(declaration: varDecl) else {
                continue
            }
            let calleeResults = collectResults(
                in: Syntax(closure.statements),
                resolve: resolveCalleeEffect
            )
            guard let inference = combine(calleeResults: calleeResults) else { continue }
            results[signature] = inference
        }

        return results
    }

    private static func combine(calleeResults: [BodyInference]) -> BodyInference? {
        // `Effect.lub(of:)` is the single source of truth for the lattice
        // ordering and its tie-break semantics (first occurrence of the
        // highest rank wins). The depth filter below reuses the same
        // `Effect.rank` so depth and lub can never disagree about ordering.
        guard let lub = Effect.lub(of: calleeResults.map { $0.effect }) else {
            return nil
        }
        let lubRank = lub.rank
        let contributingDepths = calleeResults
            .filter { $0.effect.rank == lubRank }
            .map { $0.depth }
        let depth = 1 + (contributingDepths.max() ?? 0)
        return BodyInference(effect: lub, depth: depth)
    }

    private static func collectResults(
        in syntax: Syntax,
        resolve: (FunctionCallExprSyntax) -> BodyInference?
    ) -> [BodyInference] {
        var out: [BodyInference] = []
        collect(in: syntax, resolve: resolve, accumulator: &out)
        return out
    }

    private static func collect(
        in syntax: Syntax,
        resolve: (FunctionCallExprSyntax) -> BodyInference?,
        accumulator: inout [BodyInference]
    ) {
        // Don't recurse into nested function declarations — they are their
        // own inference sites.
        if syntax.is(FunctionDeclSyntax.self) { return }
        if let closure = syntax.as(ClosureExprSyntax.self), isEscapingClosure(closure) {
            return
        }
        if let call = syntax.as(FunctionCallExprSyntax.self),
           let result = resolve(call) {
            accumulator.append(result)
        }
        for child in syntax.children(viewMode: .sourceAccurate) {
            collect(in: child, resolve: resolve, accumulator: &accumulator)
        }
    }

    private static func isEscapingClosure(_ closure: ClosureExprSyntax) -> Bool {
        var node = Syntax(closure).parent
        while let current = node {
            if let call = current.as(FunctionCallExprSyntax.self) {
                if let name = call.calledExpression.referenceBaseName,
                   escapingCalleeNames.contains(name) {
                    return true
                }
                return false
            }
            node = current.parent
        }
        return false
    }

    private static let escapingCalleeNames: Set<String> = [
        "Task",
        "detached",
        "withTaskGroup",
        "withThrowingTaskGroup",
        "withDiscardingTaskGroup",
        "withThrowingDiscardingTaskGroup",
        "task"
    ]
}

/// Shared scaffolding for the unannotated-declaration collectors below.
/// Holds the parser used to test for a declared `@lint.effect` annotation
/// and skips descent into closure expressions — the body walk for the lub
/// calculation happens separately via `collectResults`, which enforces the
/// escape-closure policy at the right granularity. Subclasses add only their
/// concrete-typed `visit(_:)` and the collection they accumulate into.
///
/// A shared base (rather than a generic collector) is required because
/// `SyntaxVisitor` dispatches to concrete-typed `visit(_:)` overrides; a
/// generic `visit(_ node: Node)` would match none of them.
class UnannotatedDeclCollector: SyntaxVisitor {
    let parser: EffectAnnotationParser

    init(parser: EffectAnnotationParser) {
        self.parser = parser
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }
}

/// Collects every `VariableDeclSyntax` with a closure-literal initialiser
/// that has no `@lint.effect` annotation. Paired with
/// `UnannotatedFunctionCollector` for upward inference: a closure binding
/// whose body calls non-idempotent work becomes itself inferred
/// non-idempotent, surfacing cross-reference violations that would
/// otherwise stay silent.
///
/// `@lint.context`-only bindings are still collected (context-only decls
/// can have their body's effect inferred); the check is specifically on
/// the presence of a declared *effect* annotation.
final class UnannotatedClosureBindingCollector: UnannotatedDeclCollector {
    var bindings: [VariableDeclSyntax] = []

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.closureInitializer != nil,
           parser.parseEffect(declaration: node) == nil {
            bindings.append(node)
        }
        return .visitChildren
    }
}

/// Collects every un-annotated `FunctionDeclSyntax` in a source file.
/// Annotated decls already have declared effects; inferring would be
/// redundant or could contradict the user's explicit choice.
final class UnannotatedFunctionCollector: UnannotatedDeclCollector {
    var functions: [FunctionDeclSyntax] = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if parser.parseEffect(declaration: node) == nil {
            functions.append(node)
        }
        return .visitChildren
    }
}
