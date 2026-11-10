import SwiftSyntax

/// Detects any `try` — the mark of a throw propagated from a callee rather than
/// raised by the function itself.
final class TryExpressionChecker: SourceAccurateSyntaxVisitor {

    private(set) var sawTry = false

    override func visit(_: TryExprSyntax) -> SyntaxVisitorContinueKind {
        sawTry = true
        return .skipChildren
    }
}
