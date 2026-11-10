import SwiftSyntax

/// Every name a body binds — `let`/`var`, `if let`, `for … in`, `case let`, and the parameters of
/// any closure nested inside it.
///
/// Nested closures' parameters belong here for the same reason their `let`s and `var`s do: they are
/// names the region binds for itself, not state reaching in from outside it. Collecting the pattern
/// bindings while omitting the parameters gave one region two different definitions of "local", so
/// `xs.reduce(into: 0) { acc, x in acc += x }` nested inside a closure read as a captured write when
/// `acc` is as local as any `var`.
///
/// **The set is flat: scopes are not tracked.** A name bound by one nested closure counts as local
/// everywhere in the outer body, so a genuine captured write to `total` goes unrecorded if some
/// unrelated nested closure also binds a `total`. That approximation is not new — it was already
/// true of nested `let`/`var` — and it errs toward calling a closure pure, which is the direction a
/// caller can check cheaply.
private final class BoundNameCollector: SourceAccurateSyntaxVisitor {
    var names: Set<String> = []

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text)
        return .visitChildren
    }

    /// `rows.forEach { row in … }` — the shorthand parameter list.
    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    /// `rows.forEach { (row: Row) in … }` — the full parameter clause. The *second* name is the one
    /// the body refers to when both are written.
    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.secondName?.text ?? node.firstName.text)
        return .visitChildren
    }
}

/// Detects a closure assigning to something it captured rather than declared.
///
/// A capture that is only *read* becomes a parameter when the closure is lifted into a named
/// function, and the lifted function is pure. A capture that is *written* cannot be lifted into
/// anything pure — the closure's whole job is the side effect, and no signature change fixes that.
///
/// Names bound by the closure itself — its parameters, and any `let`/`var` in its body — are fair
/// game to assign to: they are locals, not state. So are the parameters of any closure nested inside
/// it, `$0` included; see `BoundNameCollector`.
final class CaptureMutationChecker: SourceAccurateSyntaxVisitor {

    private let locallyBound: Set<String>

    /// The first captured name written to, or `nil` when none is.
    private(set) var mutatedName: String?

    init(closure: ClosureExprSyntax, viewMode _: SyntaxTreeViewMode) {
        self.locallyBound = Self.namesBound(by: closure)
        super.init()
    }

    /// The folded form — present when the tree has been through an `OperatorTable`.
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard isAssignment(node.operator) else { return .visitChildren }
        refuteIfCaptured(node.leftOperand)
        return .visitChildren
    }

    /// The *unfolded* form, which is what `Parser.parse` actually produces: an operator sequence is
    /// a flat `SequenceExprSyntax` until an `OperatorTable` folds it, so a visitor that only knows
    /// `InfixOperatorExprSyntax` sees no assignments at all.
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (index, element) in elements.enumerated()
        where index > 0 && isAssignment(element) {
            refuteIfCaptured(elements[index - 1])
        }
        return .visitChildren
    }

    /// Records a mutation when `target` writes through something the closure captured rather than
    /// declared.
    private func refuteIfCaptured(_ target: ExprSyntax) {
        guard let root = rootName(of: target) else { return }
        guard !locallyBound.contains(root), !Self.isShorthandParameter(root) else { return }
        if mutatedName == nil { mutatedName = root }
    }

    /// `$0`, `$1`, … — a shorthand parameter is by construction bound by *some* enclosing closure and
    /// can never be a capture from outside every closure. Named parameters are already treated as
    /// locals, so the shorthand spelling of the same thing has to agree.
    ///
    /// The digit check matters: `$` also prefixes a property wrapper's projected value, and
    /// `$isPresented.wrappedValue = true` writes through a genuine capture. Only `$` followed by
    /// digits is a closure parameter.
    static func isShorthandParameter(_ name: String) -> Bool {
        guard name.hasPrefix("$") else { return false }
        let digits = name.dropFirst()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// `=`, and the compound forms (`+=`, `-=`, …) — all of which write to the left-hand side.
    func isAssignment(_ operatorExpr: ExprSyntax) -> Bool {
        if operatorExpr.is(AssignmentExprSyntax.self) { return true }
        guard let binary = operatorExpr.as(BinaryOperatorExprSyntax.self) else { return false }
        return binary.operator.text.hasSuffix("=")
            && !["==", "!=", "<=", ">="].contains(binary.operator.text)
    }

    /// The base identifier an assignment target ultimately writes through: `a` in `a`, `a.b`,
    /// `a[0].b`. `self.x = …` yields `self`, which is never locally bound, so it refutes.
    private func rootName(of expr: ExprSyntax) -> String? {
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            return rootName(of: base)
        }
        if let subscriptExpr = expr.as(SubscriptCallExprSyntax.self) {
            return rootName(of: subscriptExpr.calledExpression)
        }
        return nil
    }

    /// The closure's own parameters, plus every name it binds in its body.
    private static func namesBound(by closure: ClosureExprSyntax) -> Set<String> {
        var names: Set<String> = []

        if let parameterClause = closure.signature?.parameterClause {
            switch parameterClause {
            case .simpleInput(let list):
                for parameter in list { names.insert(parameter.name.text) }

            case .parameterClause(let clause):
                for parameter in clause.parameters {
                    names.insert(parameter.secondName?.text ?? parameter.firstName.text)
                }
            }
        }

        let collector = BoundNameCollector()
        collector.walk(closure.statements)
        return names.union(collector.names)
    }
}
