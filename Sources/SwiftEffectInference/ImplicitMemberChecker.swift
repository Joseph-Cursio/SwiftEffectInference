import SwiftSyntax

/// Detects a base-less member — `.now`, `.init()`, `.standardError` — which takes its type from
/// whatever the code around it declares.
final class ImplicitMemberChecker: SourceAccurateSyntaxVisitor {

    private(set) var found = false

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.base == nil { found = true }
        return found ? .skipChildren : .visitChildren
    }
}
