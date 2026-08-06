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

    /// What the chain justifying this effect bottoms out on.
    ///
    /// `depth` says how *far* an inference travelled; this says what it stood
    /// on when it got there, and the two are independent. A one-hop inference
    /// anchored on a name guess is weaker evidence than a four-hop one anchored
    /// entirely on annotations, and before this existed a consumer could not
    /// tell them apart.
    ///
    /// **Why a consumer needs it.** SwiftInferProperties' `EffectResolver` runs
    /// its own upward inference with the heuristic classifier switched off,
    /// because it *"guesses effects for unannotated callees from their NAMES —
    /// the shape of inference this repo has repeatedly measured as a precision
    /// cost — and a veto built on a name guess would suppress a true law because
    /// a callee was called `save`."* That forces a choice between one-hop
    /// declaration-anchored inference and no inference at all: SwiftProjectLint
    /// resolves multi-hop across files, but supplies `HeuristicEffectInferrer`
    /// as its anchor resolver, so its results could not be trusted wholesale.
    /// With this field the consumer can take the multi-hop reach it cannot
    /// compute for itself *and* keep the precision stance it already decided on.
    public enum Anchor: Sendable, Equatable {
        /// Every step that justifies this effect was a human annotation.
        case declared

        /// At least one step that justifies this effect came from a name or
        /// framework heuristic. Not a claim that the effect is wrong — only
        /// that a guess is load-bearing in reaching it.
        case heuristic

        /// `declared` outranks `heuristic`: if any single justification for a
        /// value rests entirely on annotations, the value is annotation-backed,
        /// and a redundant guess alongside it changes nothing.
        static func strongest(_ lhs: Anchor, _ rhs: Anchor) -> Anchor {
            lhs == .declared || rhs == .declared ? .declared : .heuristic
        }
    }

    public let effect: Effect
    public let depth: Int

    /// What this inference rests on. See `Anchor`.
    public let anchor: Anchor

    /// `anchor` defaults to `.heuristic`, which is the conservative reading and
    /// deliberately not the flattering one.
    ///
    /// A caller that constructs a `BodyInference` without saying what it stands
    /// on has not established that annotations back it, and the default must be
    /// the answer that withholds trust rather than the one that grants it. The
    /// cost of the wrong default here is asymmetric: `.declared` would let a
    /// name guess travel to a consumer wearing an annotation's authority, which
    /// is the precise failure this field exists to prevent.
    public init(effect: Effect, depth: Int, anchor: Anchor = .heuristic) {
        self.effect = effect
        self.depth = depth
        self.anchor = anchor
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
        let contributors = calleeResults.filter { $0.effect.rank == lubRank }
        let depth = 1 + (contributors.map { $0.depth }.max() ?? 0)
        // Anchor is decided by the lub's contributors alone, for the same reason
        // depth is: a callee whose effect is *below* the lub did not determine
        // the answer, so what it rested on cannot taint the answer. An
        // `idempotent` name guess sitting beside a declared `non_idempotent`
        // changes nothing about why the lub is `non_idempotent`.
        //
        // Among those contributors, `strongest` wins rather than weakest —
        // **and this is the part to check if the field ever looks wrong.** Two
        // callees both resolving `non_idempotent`, one declared and one guessed,
        // yield a lub the declaration alone fully justifies; the guess is
        // redundant, and marking the result `heuristic` because a redundant
        // guess was present would withhold trust from a conclusion annotations
        // had already earned. The guess only matters when it is the *only*
        // thing holding the lub up, which is exactly the case `strongest`
        // leaves as `.heuristic`.
        let anchor = contributors
            .map { $0.anchor }
            .reduce(BodyInference.Anchor.heuristic, BodyInference.Anchor.strongest)
        return BodyInference(effect: lub, depth: depth, anchor: anchor)
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
class UnannotatedDeclCollector: SourceAccurateSyntaxVisitor {
    let parser: EffectAnnotationParser

    init(parser: EffectAnnotationParser) {
        self.parser = parser
        super.init()
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
