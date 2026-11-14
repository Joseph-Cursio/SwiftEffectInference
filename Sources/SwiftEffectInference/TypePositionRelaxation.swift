import SwiftSyntax

/// Where a `Date` or `UUID` written in a body only names the type, so the token reads no clock and
/// makes no identifier (#30).
///
/// `let d: [Date: Int] = [:]` and a nested helper's `-> Date` run nothing, and a function that takes
/// its instant as a parameter is the shape this module recommends. The token used to refute them
/// anyway. It cannot simply stop: the token was also standing in for "this body handles dates",
/// and it masked every ambient read made through a date value in the same body (see
/// `DateInertnessChecker`, which a body must pass before any position here relaxes).
///
/// A position relaxes only where the type cannot make a value appear without the token being
/// written as an expression:
/// - a local binding's annotation, `let d: Date? = nil`;
/// - a nested function's or closure's signature, `func daysAgo(_ n: Int) -> Date`;
/// - a conditional cast, `x as? Date`, `x is UUID`;
/// - an empty collection named as an expression, `[Date: Int]()`, `[UUID]()`.
///
/// It never relaxes where the type can supply a value by itself:
/// - inside a nested type, typealias, generic clause, attribute or macro, where a declaration can
///   hand the type to code the body never spells (a protocol default that builds `Self.Value()`);
/// - an explicit specialization, `make<Date>()`, `Array<Date>(repeating: .init(), count: 2)`;
/// - an `as` coercion, `make() as Date`, which picks a generic's type the way a specialization does;
/// - a metatype, `UUID.Type`, whose value builds one with `.init()`.
enum TypePositionRelaxation {

    /// The markers this relaxes. Every other marker keeps refuting wherever it is written.
    static let relaxableMarkers: Set<String> = ["Date", "UUID"]

    /// Whether `token`, inside `root`, only names one of the `relaxableMarkers` as a type.
    static func onlyNamesType(_ token: TokenSyntax, within root: Syntax) -> Bool {
        guard relaxableMarkers.contains(token.text), let parent = token.parent else { return false }
        if let type = parent.as(IdentifierTypeSyntax.self), type.name.id == token.id {
            return admitsType(at: Syntax(type), within: root)
        }
        if let member = parent.as(MemberTypeSyntax.self), member.name.id == token.id,
           member.baseType.as(IdentifierTypeSyntax.self)?.name.text == "Foundation" {
            return admitsType(at: Syntax(member), within: root)
        }
        if let reference = parent.as(DeclReferenceExprSyntax.self), reference.baseName.id == token.id,
           let collection = emptyCollectionConstruction(around: reference) {
            return admitsType(at: collection, within: root)
        }
        return false
    }

    /// The collection literal `reference` is the only type of, when that literal is called with no
    /// arguments: the `[Date: Int]` of `[Date: Int]()`.
    private static func emptyCollectionConstruction(around reference: DeclReferenceExprSyntax) -> Syntax? {
        guard reference.argumentNames == nil, let element = reference.parent else { return nil }
        let literal: Syntax?
        if let item = element.as(ArrayElementSyntax.self), item.expression.id == reference.id,
           let list = item.parent?.as(ArrayElementListSyntax.self), list.count == 1 {
            literal = list.parent
        } else if let pair = element.as(DictionaryElementSyntax.self),
                  pair.key.id == reference.id || pair.value.id == reference.id,
                  let list = pair.parent?.as(DictionaryElementListSyntax.self), list.count == 1 {
            literal = list.parent
        } else {
            literal = nil
        }
        guard let literal, literal.is(ArrayExprSyntax.self) || literal.is(DictionaryExprSyntax.self),
              let call = literal.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == literal.id,
              call.arguments.isEmpty, call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty else {
            return nil
        }
        return literal
    }

    /// Whether nothing between `node` and `root` lets the type supply a value the body never spells.
    private static func admitsType(at node: Syntax, within root: Syntax) -> Bool {
        var current = node.parent
        while let ancestor = current, ancestor.id != root.id {
            if closesOver(ancestor) { return false }
            current = ancestor.parent
        }
        return true
    }

    /// Whether `node` is a context where a type can supply a value by itself.
    private static func closesOver(_ node: Syntax) -> Bool {
        switch node.kind {
        case .structDecl, .classDecl, .enumDecl, .actorDecl, .protocolDecl, .extensionDecl,
             .typeAliasDecl, .associatedTypeDecl, .genericParameterClause, .genericWhereClause,
             .attribute, .macroExpansionExpr, .macroExpansionDecl, .genericSpecializationExpr,
             .metatypeType:
            return true

        case .asExpr:
            return node.as(AsExprSyntax.self)?.questionOrExclamationMark == nil

        case .typeExpr:
            return isCoercedTo(node)

        default:
            return false
        }
    }

    /// Whether `type` is the target of an `as` coercion in an unfolded sequence, `make() as Date`:
    /// the parser leaves the `as` and the type as neighbours, with no `AsExprSyntax` around them.
    private static func isCoercedTo(_ type: Syntax) -> Bool {
        guard let list = type.parent?.as(ExprListSyntax.self),
              let index = list.firstIndex(where: { $0.id == type.id }), index != list.startIndex,
              let cast = list[list.index(before: index)].as(UnresolvedAsExprSyntax.self) else { return false }
        return cast.questionOrExclamationMark == nil
    }
}
