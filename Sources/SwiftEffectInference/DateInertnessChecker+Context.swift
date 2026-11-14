import SwiftSyntax

extension DateInertnessChecker {

    /// A body declared inside another body, a local function's or a local type's member's: the
    /// outer body's locals, `#if` clauses and later declarations can take any name it spells, and a
    /// local type's path can be a package type's.
    static func enclosingBody(around root: Syntax) -> String? {
        guard let owner = LocalNameScope.owner(of: root) else { return nil }
        var child = owner
        var current = owner.parent
        while let node = current, !node.is(SourceFileSyntax.self) {
            switch node.kind {
            case .codeBlock, .closureExpr, .switchCase:
                return "a body declared inside another body"

            // A property's own accessors are its body; an implicit getter's statements hold locals.
            case .accessorBlock where !child.is(AccessorDeclListSyntax.self):
                return "a body declared inside another body"

            default:
                break
            }
            child = node
            current = node.parent
        }
        return nil
    }

    static func parameters(of owner: Syntax) -> [FunctionParameterSyntax] {
        if let signature = owner.as(FunctionSignatureSyntax.self) {
            return Array(signature.parameterClause.parameters)
        }
        if let subscriptDecl = owner.as(SubscriptDeclSyntax.self) {
            return Array(subscriptDecl.parameterClause.parameters)
        }
        return []
    }

    /// A generic signature or context around `root`: the caller picks its `T` (or the conformer
    /// its `Self`), and a literal or `T(…)` in the body then builds whatever that is. Enclosing
    /// generic types, constrained extensions and protocol extensions count, as well as the
    /// declaration's own clause.
    static func genericSignature(around root: Syntax) -> String? {
        var current: Syntax? = root
        while let node = current {
            if isGeneric(node) { return "a generic signature" }
            current = node.parent
        }
        return nil
    }

    private static func isGeneric(_ node: Syntax) -> Bool {
        switch node.as(SyntaxEnum.self) {
        case .functionDecl(let decl):
            let opaque = decl.signature.parameterClause.parameters.contains { parameter in
                parameter.type.tokens(viewMode: .sourceAccurate).contains { $0.tokenKind == .keyword(.some) }
            }
            return decl.genericParameterClause != nil || decl.genericWhereClause != nil || opaque

        case .initializerDecl(let decl):
            return decl.genericParameterClause != nil || decl.genericWhereClause != nil

        case .subscriptDecl(let decl):
            return decl.genericParameterClause != nil || decl.genericWhereClause != nil

        case .structDecl(let decl):
            return decl.genericParameterClause != nil || decl.genericWhereClause != nil

        case .classDecl(let decl):
            return decl.genericParameterClause != nil || decl.genericWhereClause != nil

        case .enumDecl(let decl):
            return decl.genericParameterClause != nil || decl.genericWhereClause != nil

        case .actorDecl(let decl):
            return decl.genericParameterClause != nil || decl.genericWhereClause != nil

        case .protocolDecl:
            return true

        case .extensionDecl(let decl):
            return decl.genericWhereClause != nil
                || PackageNameCollector.isGenericStandardType(TypeShapeCollector.components(of: decl.extendedType))

        default:
            return false
        }
    }

    /// A non-inert attribute on the declaration whose body `root` is: a result builder
    /// (`@Captions var greeting: String { "Hi" }`) rewrites the body into calls it never writes.
    func ownerAttribute(around root: Syntax) -> String? {
        var current: Syntax? = root
        while let node = current {
            if let attributes = Self.attributes(of: node) {
                for element in attributes {
                    guard let attribute = element.as(AttributeSyntax.self) else {
                        return "an attribute inside #if on the declaration"
                    }
                    if !isInert(attribute) {
                        return "@\(attribute.attributeName.trimmedDescription) on the declaration"
                    }
                }
                if !node.is(AccessorDeclSyntax.self) { return nil }
            }
            if node.is(ClosureExprSyntax.self) { return nil }
            current = node.parent
        }
        return nil
    }

    /// The attributes written on `node`, when it is a declaration that can own a body: a function,
    /// an initializer, a subscript, a variable or an accessor.
    private static func attributes(of node: Syntax) -> AttributeListSyntax? {
        switch node.as(SyntaxEnum.self) {
        case .functionDecl(let decl): decl.attributes
        case .initializerDecl(let decl): decl.attributes
        case .subscriptDecl(let decl): decl.attributes
        case .variableDecl(let decl): decl.attributes
        case .accessorDecl(let decl): decl.attributes
        default: nil
        }
    }

    /// The declared types around `root`: the signature or the binding whose body it is.
    static func signature(around root: Syntax) -> Syntax? {
        var current: Syntax? = root
        while let node = current {
            switch node.as(SyntaxEnum.self) {
            case .functionDecl(let decl): return Syntax(decl.signature)
            case .initializerDecl(let decl): return Syntax(decl.signature)
            case .accessorDecl, .accessorBlock: current = node.parent
            case .subscriptDecl(let decl): return Syntax(decl)
            case .patternBinding(let binding): return binding.typeAnnotation.map(Syntax.init)
            case .closureExpr(let closure): return closure.signature.map(Syntax.init)
            default: current = node.parent
            }
        }
        return nil
    }
}
