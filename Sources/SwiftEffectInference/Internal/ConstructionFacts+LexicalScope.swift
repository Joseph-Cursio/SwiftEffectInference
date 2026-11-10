import SwiftSyntax

// MARK: - Lexical scope

extension ConstructionFacts {

    /// A position inside a type declaration's body, where its own nested types are in scope.
    static func memberSite(of declaration: Syntax) -> Syntax {
        if let decl = declaration.as(StructDeclSyntax.self) { return Syntax(decl.memberBlock) }
        if let decl = declaration.as(ClassDeclSyntax.self) { return Syntax(decl.memberBlock) }
        if let decl = declaration.as(ActorDeclSyntax.self) { return Syntax(decl.memberBlock) }
        if let decl = declaration.as(EnumDeclSyntax.self) { return Syntax(decl.memberBlock) }
        return declaration
    }

    /// The types enclosing `node`, outermost first, each qualified the way the collector qualified
    /// it — `<local>` marking a type declared inside a function — and whether it is an extension.
    static func enclosingTypeChain(of node: Syntax) -> [(name: String, isExtension: Bool)] {
        node.parent.map { lexicalChain(of: $0) } ?? []
    }

    /// `enclosingTypeChain(of:)` including `node` itself when it is a type declaration.
    static func lexicalChain(of node: Syntax) -> [(name: String, isExtension: Bool)] {
        // Innermost first: a type's name, or `nil` for a function-like boundary.
        var walked: [(name: String?, isExtension: Bool)] = []
        var current: Syntax? = node
        while let ancestor = current {
            if let name = TypeShapeCollector.declaredName(of: ancestor) {
                walked.append((name, ancestor.is(ExtensionDeclSyntax.self)))
            } else if TypeShapeCollector.isFunctionLike(ancestor) {
                walked.append((nil, false))
            }
            current = ancestor.parent
        }
        var chain: [(name: String, isExtension: Bool)] = []
        var prefix: [String] = []
        var crossedBody = false
        for entry in walked.reversed() {
            guard let name = entry.name else {
                crossedBody = true
                continue
            }
            if entry.isExtension {
                // An extension names its type in full, so it restarts the qualification.
                prefix = [name]
            } else {
                if crossedBody { prefix.append("<local>") }
                prefix.append(name)
            }
            crossedBody = false
            chain.append((prefix.joined(separator: "."), entry.isExtension))
        }
        return chain
    }
}
