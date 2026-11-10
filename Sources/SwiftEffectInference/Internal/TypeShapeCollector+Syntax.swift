import SwiftSyntax

// MARK: - Syntax helpers

extension TypeShapeCollector {

    /// The bare name of each member of `A & B.C`: `["A", "C"]`.
    static func lastComponents(of composition: CompositionTypeSyntax) -> [String] {
        composition.elements.compactMap { components(of: $0.type)?.last }
    }

    static func declaredName(of node: Syntax) -> String? {
        if let decl = node.as(StructDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ClassDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ActorDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(EnumDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ProtocolDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ExtensionDeclSyntax.self) {
            return components(of: decl.extendedType)?.joined(separator: ".") ?? decl.extendedType.trimmedDescription
        }
        return nil
    }

    static func isFunctionLike(_ node: Syntax) -> Bool {
        node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self)
            || node.is(DeinitializerDeclSyntax.self) || node.is(AccessorBlockSyntax.self)
            || node.is(SubscriptDeclSyntax.self) || node.is(ClosureExprSyntax.self)
    }

    /// The scope a declaration at `node` belongs to: the qualified name of its innermost enclosing
    /// type, with `.<local>` appended when a function body lies between — `<local>` alone at the top
    /// level — and empty for a top-level declaration. `reachableScopes(from:chain:)` spells them so.
    static func memberScope(of node: Syntax) -> String {
        let enclosing = ConstructionFacts.enclosingTypeChain(of: node).last?.name ?? ""
        guard ConstructionFacts.bodiesCrossed(from: node).first == true else { return enclosing }
        return enclosing.isEmpty ? "<local>" : enclosing + ".<local>"
    }

    /// `A`, `A.B`, `A<G>` as a type → their names, generic arguments dropped; `nil` for any other
    /// type spelling.
    static func components(of type: TypeSyntax) -> [String]? {
        if let identifier = type.as(IdentifierTypeSyntax.self) { return [identifier.name.text] }
        if let member = type.as(MemberTypeSyntax.self), let base = components(of: member.baseType) {
            return base + [member.name.text]
        }
        if let attributed = type.as(AttributedTypeSyntax.self) { return components(of: attributed.baseType) }
        return nil
    }

    /// The bare names an inheritance clause names, with a composition (`A & B`) spelled out.
    static func inheritedNames(_ clause: InheritanceClauseSyntax?) -> [String] {
        clause?.inheritedTypes.flatMap { inherited -> [String] in
            if let composition = inherited.type.as(CompositionTypeSyntax.self) {
                return composition.elements.compactMap { components(of: $0.type)?.last }
            }
            return components(of: inherited.type)?.last.map { [$0] } ?? []
        } ?? []
    }

    /// A member block's declarations, with every `#if` clause's members spliced in — any doubt
    /// about the build configuration refutes.
    static func flattened(_ members: MemberBlockItemListSyntax) -> [DeclSyntax] {
        members.flatMap { item -> [DeclSyntax] in
            guard let ifConfig = item.decl.as(IfConfigDeclSyntax.self) else { return [item.decl] }
            return ifConfig.clauses.flatMap { clause -> [DeclSyntax] in
                if case .decls(let nested)? = clause.elements { return flattened(nested) }
                return []
            }
        }
    }
}
