import SwiftSyntax

/// Infers whether a function is `Effect.pure` — referentially transparent:
/// no side effects, deterministic, and total (a function of its inputs alone).
///
/// This is the **canonical** purity oracle for the ecosystem. Purity is a
/// *conjunctive* property — a function is `.pure` only when **none** of the
/// impurity / nondeterminism / partiality refuters fire — so a single narrow
/// analyzer can never establish it soundly; it can only *refute* it. This type
/// owns the I/O / nondeterminism / totality refuters. Callers that also need to
/// rule out a domain-specific effect surface (e.g. SwiftInferProperties' TCA
/// `ReducerPurity`, which refutes on `Effect`/`Task`/`await` and hidden
/// mutation) take the **meet** of their refutation with this one: claim `.pure`
/// only when both agree.
///
/// ## Soundness
///
/// On the effect lattice `pure ≤ observational ≤ … ≤ nonIdempotent`, a sound
/// inference only ever *over-approximates* — it never claims an effect below
/// the true one. `.pure` is the lattice bottom and the most dangerous place to
/// land wrongly (every downstream consumer *trusts* it: a generated property
/// test runs a `.pure` function in-process and asserts a law over random
/// inputs). So this inferrer is conservative by construction: any doubt refutes
/// purity. A missed refuter would be unsound, so the marker sets err toward
/// flagging.
///
/// ## History
///
/// Lifted from SwiftProjectLint's testability rule (`PureFunctionCandidateVisitor`)
/// during Idea #4 so the purity *inference*, not just the `Effect` *type*, lives
/// in the shared leaf. SwiftProjectLint and SwiftInferProperties now consume one
/// oracle instead of carrying parallel copies.
public struct PurityInferrer: Sendable {

    public init() {
        // Stateless — the inferrer holds no configuration.
    }

    /// Strong impurity markers — any reference in the body refutes purity.
    /// I/O, logging, persistence, and the nondeterministic randomness family
    /// each introduce an effect or a non-reproducible result.
    private static let impureMarkers: Set<String> = [
        "print", "NSLog", "FileManager", "URLSession", "UserDefaults",
        "NotificationCenter", "DispatchQueue",
        "arc4random", "arc4random_uniform", "drand48",
        "random", "randomElement", "shuffled"
    ]

    /// Returns `.pure` when `function` is referentially transparent — its
    /// signature is synchronous and non-throwing, its body references no
    /// impurity marker, and nothing in it can trap — and `nil` (purity
    /// refuted) otherwise.
    ///
    /// `async` and `throws` both refute purity: an `async` body awaits some
    /// effect, and a `throws` function has no return value for the inputs that
    /// throw, so it is not total over its domain. A body-less declaration (a
    /// protocol requirement) is refuted — there is nothing to inspect.
    public func inferredEffect(for function: FunctionDeclSyntax) -> Effect? {
        guard let body = function.body else { return nil }
        guard isSynchronousAndNonThrowing(function.signature) else { return nil }
        guard !bodyLooksImpure(body), bodyIsTotal(body) else { return nil }
        return .pure
    }

    /// Convenience boolean form of `inferredEffect(for:)`.
    public func isPure(_ function: FunctionDeclSyntax) -> Bool {
        inferredEffect(for: function) == .pure
    }

    // MARK: - Refutation predicates

    private func isSynchronousAndNonThrowing(_ signature: FunctionSignatureSyntax) -> Bool {
        signature.effectSpecifiers?.asyncSpecifier == nil
            && signature.effectSpecifiers?.throwsClause == nil
    }

    private func bodyLooksImpure(_ body: CodeBlockSyntax) -> Bool {
        body.tokens(viewMode: .sourceAccurate).contains { Self.impureMarkers.contains($0.text) }
    }

    /// True when nothing in the body can trap (crash) at runtime — the property
    /// that lets us treat the function as total. Force-unwrap (`!`), `try!`,
    /// `as!`, and the `fatalError` / `precondition` / `assert` family all
    /// introduce inputs for which there is no return value, so a property test
    /// over generated inputs would hit a crash rather than a falsified law.
    private func bodyIsTotal(_ body: CodeBlockSyntax) -> Bool {
        let checker = TotalityChecker()
        checker.walk(body)
        return checker.isTotal
    }
}

/// Walks a function body looking for any runtime trap that breaks totality.
private final class TotalityChecker: SourceAccurateSyntaxVisitor {

    private(set) var isTotal = true

    /// Standard-library trap functions: reaching them means the function has no
    /// return value for some inputs.
    private static let trapFunctions: Set<String> = [
        "fatalError", "preconditionFailure", "precondition",
        "assert", "assertionFailure"
    ]

    override func visit(_ node: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
        _ = node
        isTotal = false
        return .skipChildren
    }

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" { isTotal = false }
        return .visitChildren
    }

    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" { isTotal = false }
        return .visitChildren
    }

    // Raw (unfolded) parse trees represent `x as! T` as an `UnresolvedAsExprSyntax`
    // inside a `SequenceExprSyntax`; the folded `AsExprSyntax` form only appears
    // after operator-precedence folding, which the linter doesn't run.
    override func visit(_ node: UnresolvedAsExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" { isTotal = false }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
           Self.trapFunctions.contains(callee) {
            isTotal = false
        }
        return .visitChildren
    }
}
