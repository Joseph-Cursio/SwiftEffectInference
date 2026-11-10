import SwiftSyntax

/// Walks a function body looking for any runtime trap that breaks totality.
final class TotalityChecker: SourceAccurateSyntaxVisitor {

    /// The first trap seen, or `nil` when the body is total. Which trap it is, not
    /// merely that there is one: `x!` and `fatalError("unreachable")` call for
    /// different advice, and the second names its own callee.
    private(set) var trap: PurityRefutation.Partiality?

    /// Standard-library trap functions: reaching them means the function has no
    /// return value for some inputs.
    private static let trapFunctions: Set<String> = [
        "fatalError", "preconditionFailure", "precondition",
        "assert", "assertionFailure",
    ]

    private func record(_ partiality: PurityRefutation.Partiality) {
        if trap == nil { trap = partiality }
    }

    override func visit(_ node: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
        _ = node
        record(.forceUnwrap)
        return .skipChildren
    }

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" { record(.forcedTry) }
        return .visitChildren
    }

    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" { record(.forcedCast) }
        return .visitChildren
    }

    // Raw (unfolded) parse trees represent `x as! T` as an `UnresolvedAsExprSyntax`
    // inside a `SequenceExprSyntax`; the folded `AsExprSyntax` form only appears
    // after operator-precedence folding, which the linter doesn't run.
    override func visit(_ node: UnresolvedAsExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" { record(.forcedCast) }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
           Self.trapFunctions.contains(callee) {
            record(.trap(callee))
        }
        return .visitChildren
    }
}
