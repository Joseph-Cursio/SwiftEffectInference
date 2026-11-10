import SwiftSyntax

/// Finds a construction of a refuted type. **Never a bare mention of a type** — a parameter type,
/// a return type, `T.self` outside a decode and a static member are not constructions.
final class ConstructionChecker: SourceAccurateSyntaxVisitor {
    let facts: ConstructionFacts
    private(set) var refutation: PurityRefutation?

    init(facts: ConstructionFacts) {
        self.facts = facts
        super.init()
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard refutation == nil else { return .skipChildren }
        if let (candidates, strict) = candidates(constructedBy: node) {
            refutation = facts.refutation(constructing: candidates, call: CallShape(node), strict: strict)
        }
        if refutation == nil, let name = Self.calleeName(of: node.calledExpression),
           name == "decode" || name == "decodeIfPresent" {
            refutation = decodeRefutation(of: node)
        }
        return .visitChildren
    }

    /// `items.map(T.init)` and `items.map(T.init(id:))` — a construction called later, as a value.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard refutation == nil, node.declName.baseName.tokenKind == .keyword(.`init`),
              let base = node.base,
              node.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id != node.id,
              let components = Self.typeComponents(of: base)
        else { return .visitChildren }
        let labels = node.declName.argumentNames.map { $0.arguments.map(\.name.text) }
        refutation = facts.declarations(named: components, from: Syntax(node))
            .lazy.compactMap { self.facts.referenceRefutation($0, labels: labels) }
            .first
        return .visitChildren
    }

    /// `@Wrapper var x = 0` in a body constructs the wrapper.
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard refutation == nil else { return .skipChildren }
        for element in node.attributes {
            guard case .attribute(let attribute) = element,
                  let components = TypeShapeCollector.components(of: attribute.attributeName) else { continue }
            let wrappers = facts.declarations(named: components, from: Syntax(node))
                .filter { facts.declarations[$0].isPropertyWrapper }
            guard !wrappers.isEmpty else { continue }
            let hasInitialValue = node.bindings.contains { $0.initializer != nil }
            refutation = facts.refutation(
                constructing: wrappers,
                call: RawDeclaration.wrapperCall(attribute, hasInitialValue: hasInitialValue)
            )
            if refutation != nil { break }
        }
        return .visitChildren
    }

    /// The declarations a call could construct, and whether the guess is only by shape; `nil`
    /// when the call is not a construction.
    private func candidates(constructedBy call: FunctionCallExprSyntax) -> ([Int], Bool)? {
        let callee = call.calledExpression
        guard let member = callee.as(MemberAccessExprSyntax.self),
              member.declName.baseName.tokenKind == .keyword(.`init`) else {
            return Self.typeComponents(of: callee).map { (facts.declarations(named: $0, from: Syntax(call)), false) }
        }
        guard let base = member.base else {
            // A base-less `.init(…)` names no type; its context may. Without one, a labelled call
            // is matched by shape against every type; an unlabelled one stays open.
            let expected = expectedTypes(of: Syntax(call))
            if !expected.isEmpty {
                return (expected.flatMap { facts.declarations(named: $0, from: Syntax(call)) }, false)
            }
            let labelled = CallShape(call).labels.contains { $0 != "_" }
            return labelled ? (Array(facts.declarations.indices), true) : nil
        }
        if base.is(SuperExprSyntax.self) {
            return (facts.superclassCandidates(enclosing: Syntax(call)), false)
        }
        if let reference = base.as(DeclReferenceExprSyntax.self), reference.baseName.tokenKind == .keyword(.self) {
            return (facts.declarations(named: ["Self"], from: Syntax(call)), false)
        }
        // `T.self.init(…)` is `T(…)`.
        if let metatype = base.as(MemberAccessExprSyntax.self), metatype.declName.baseName.tokenKind == .keyword(.self),
           let typeBase = metatype.base, let components = Self.typeComponents(of: typeBase) {
            return (facts.declarations(named: components, from: Syntax(call)), false)
        }
        return Self.typeComponents(of: base).map { (facts.declarations(named: $0, from: Syntax(call)), false) }
    }

    /// `decoder.decode(T.self, from: data)` — and `[T].self`, `T?.self`, `[K: T].self` — builds
    /// every `T` through `init(from:)`.
    private func decodeRefutation(of call: FunctionCallExprSyntax) -> PurityRefutation? {
        for argument in call.arguments {
            guard let member = argument.expression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.tokenKind == .keyword(.self),
                  let base = member.base else { continue }
            for components in Self.decodedComponents(of: base) {
                for index in facts.declarations(named: components, from: Syntax(call)) {
                    if let found = facts.decodeRefutation(index) { return found }
                }
            }
        }
        return nil
    }

    /// The types a `.self` operand names, through array, dictionary, optional and generic spellings.
    private static func decodedComponents(of base: ExprSyntax) -> [[String]] {
        if let components = typeComponents(of: base) { return [components] }
        if let array = base.as(ArrayExprSyntax.self) {
            return array.elements.flatMap { decodedComponents(of: $0.expression) }
        }
        if let dictionary = base.as(DictionaryExprSyntax.self), case .elements(let elements) = dictionary.content {
            return elements.flatMap { decodedComponents(of: $0.value) }
        }
        if let optional = base.as(OptionalChainingExprSyntax.self) { return decodedComponents(of: optional.expression) }
        if let generic = base.as(GenericSpecializationExprSyntax.self) {
            return generic.genericArgumentClause.arguments
                .compactMap { $0.argument.as(TypeSyntax.self) }
                .flatMap(ConstructionFacts.decodedComponents)
        }
        if let type = base.as(TypeExprSyntax.self) { return ConstructionFacts.decodedComponents(of: type.type) }
        return []
    }

    private static func calleeName(of callee: ExprSyntax) -> String? {
        if let member = callee.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
        if let reference = callee.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
        return nil
    }

    /// Whether `name` is spelled like a type: an uppercase letter after any leading underscores.
    static func isTypeName(_ name: String) -> Bool {
        name.drop { $0 == "_" }.first?.isUppercase == true
    }

    /// `A`, `A.B`, `A<G>.B` as an expression → their names, or `nil` for anything that is not a
    /// type spelling.
    static func typeComponents(of expression: ExprSyntax) -> [String]? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            if name == "Self" { return ["Self"] }
            return isTypeName(name) ? [name] : nil
        }
        if let generic = expression.as(GenericSpecializationExprSyntax.self) {
            return typeComponents(of: generic.expression)
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
           let prefix = typeComponents(of: base) {
            let name = member.declName.baseName.text
            return isTypeName(name) ? prefix + [name] : nil
        }
        return nil
    }

    static func unwrappingOptional(_ type: TypeSyntax) -> TypeSyntax {
        if let optional = type.as(OptionalTypeSyntax.self) { return optional.wrappedType }
        if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return unwrapped.wrappedType }
        return type
    }
}
