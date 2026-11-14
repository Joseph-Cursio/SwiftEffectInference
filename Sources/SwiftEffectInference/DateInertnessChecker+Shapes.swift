import SwiftSyntax

extension DateInertnessChecker {

    /// `[String]`, `[Int: String]` or `Array<String>` written as a value, in parentheses or not.
    static func isSugaredType(_ expression: ExprSyntax) -> Bool {
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return isSugaredType(only.expression)
        }
        return expression.is(ArrayExprSyntax.self) || expression.is(DictionaryExprSyntax.self)
            || expression.is(GenericSpecializationExprSyntax.self)
    }

    static func callsAnonymousValue(_ callee: ExprSyntax) -> Bool {
        var expression = callee
        while true {
            if let chained = expression.as(OptionalChainingExprSyntax.self) {
                expression = chained.expression
            } else if let forced = expression.as(ForceUnwrapExprSyntax.self) {
                expression = forced.expression
            } else {
                break
            }
        }
        return expression.is(FunctionCallExprSyntax.self) || expression.is(SubscriptCallExprSyntax.self)
            || expression.is(TupleExprSyntax.self)
    }

    /// A standard-library type called, whose generic arguments the context can infer.
    static func isStandardTypeCall(_ callee: ExprSyntax) -> Bool {
        var expression = callee
        if let member = expression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.tokenKind == .keyword(.`init`), let base = member.base {
            expression = base
        }
        if let specialized = expression.as(GenericSpecializationExprSyntax.self) { expression = specialized.expression }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return InertVocabulary.freeNames.contains(reference.baseName.bareName)
                && reference.baseName.bareName.first?.isUppercase == true
        }
        return isSugaredType(expression)
    }

    /// `String(…)`, `Swift.String(…)` or `String.init(…)`: a type name called.
    static func isInitializerCall(_ callee: ExprSyntax) -> Bool {
        if let member = callee.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.tokenKind == .keyword(.`init`)
                || member.declName.baseName.bareName.first?.isUppercase == true
        }
        if let reference = callee.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.bareName.first?.isUppercase == true
        }
        return callee.is(GenericSpecializationExprSyntax.self) || isSugaredType(callee)
    }

    static func isCalled(_ node: MemberAccessExprSyntax) -> Bool {
        guard let call = node.parent?.as(FunctionCallExprSyntax.self) else { return false }
        return call.calledExpression.id == node.id
    }

    /// Whether the `init` member `node` names builds a value from no input: called with no
    /// arguments and no closure, or not called at all, so whatever it is handed stays unseen.
    static func constructsFromNothing(_ node: Syntax) -> Bool {
        guard let call = node.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == node.id else {
            return true
        }
        return call.arguments.isEmpty && call.trailingClosure == nil && call.additionalTrailingClosures.isEmpty
    }

    static func isSelf(_ expression: ExprSyntax) -> Bool {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.tokenKind == .keyword(.Self) || reference.baseName.tokenKind == .keyword(.self)
        }
        return expression.is(TypeExprSyntax.self) && expression.trimmedDescription == "Self"
    }
}
