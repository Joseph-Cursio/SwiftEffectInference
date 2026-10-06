import SwiftSyntax

/// Finds a construction of a refuted type. **Never a bare mention of a type** — a parameter type,
/// a return type, `T.self` outside a decode and a static member are not constructions.
final class ConstructionChecker: SourceAccurateSyntaxVisitor {
    private let facts: ConstructionFacts
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

// MARK: - Expected types

extension ConstructionChecker {

    /// The types an expression must produce where it is written — what a base-less `.init(…)`
    /// builds — as written components; empty when the syntax does not say.
    func expectedTypes(of node: Syntax) -> [[String]] {
        expectations(of: node).compactMap { expectation in
            switch expectation {
            case .type(let type): return TypeShapeCollector.components(of: Self.unwrappingOptional(type))
            case .selfType: return ["Self"]
            }
        }
    }

    enum Expectation {
        case type(TypeSyntax)
        case selfType
    }

    private func expectations(of node: Syntax) -> [Expectation] {
        guard let parent = node.parent else { return [] }
        if let passedThrough = transparentParent(of: node, parent) { return expectations(of: passedThrough) }
        if let list = parent.as(ExprListSyntax.self), let sequence = list.parent, sequence.is(SequenceExprSyntax.self) {
            return sequenceExpectations(of: node, in: list, sequence: sequence)
        }
        if let infix = parent.as(InfixOperatorExprSyntax.self), infix.rightOperand.id == node.id {
            if infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "??" {
                return expectations(of: parent)
            }
            if infix.operator.is(AssignmentExprSyntax.self) { return assignmentTargets(infix.leftOperand) }
            return []
        }
        if let literal = literalElementExpectations(of: node, parent) { return literal }
        if let clause = parent.as(InitializerClauseSyntax.self) {
            if let binding = clause.parent?.as(PatternBindingSyntax.self) {
                return binding.typeAnnotation.map { [.type($0.type)] } ?? []
            }
            if let parameter = clause.parent?.as(FunctionParameterSyntax.self) { return [.type(parameter.type)] }
            if let parameter = clause.parent?.as(EnumCaseParameterSyntax.self) { return [.type(parameter.type)] }
            return []
        }
        if parent.is(ReturnStmtSyntax.self) { return Self.resultType(enclosing: parent).map { [.type($0)] } ?? [] }
        if let item = parent.as(CodeBlockItemSyntax.self), let list = item.parent?.as(CodeBlockItemListSyntax.self),
           list.count == 1 {
            return soleStatementExpectations(list)
        }
        return []
    }

    /// A wrapper that hands its operand's type straight through: `try`, `await`, a ternary branch.
    private func transparentParent(of node: Syntax, _ parent: Syntax) -> Syntax? {
        if parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) { return parent }
        if let ternary = parent.as(TernaryExprSyntax.self), ternary.condition.id != node.id { return parent }
        if let ternary = parent.as(UnresolvedTernaryExprSyntax.self), ternary.thenExpression.id == node.id,
           let sequence = ternary.parent?.parent, sequence.is(SequenceExprSyntax.self) {
            return sequence
        }
        return nil
    }

    /// An unfolded sequence: what comes before decides.
    private func sequenceExpectations(of node: Syntax, in list: ExprListSyntax, sequence: Syntax) -> [Expectation] {
        let elements = Array(list)
        guard let index = elements.firstIndex(where: { $0.id == node.id }), index > 0 else { return [] }
        let preceding = elements[index - 1]
        if preceding.is(AssignmentExprSyntax.self), index >= 2 { return assignmentTargets(elements[index - 2]) }
        if preceding.is(UnresolvedTernaryExprSyntax.self) { return expectations(of: sequence) }
        if preceding.as(BinaryOperatorExprSyntax.self)?.operator.text == "??" { return expectations(of: sequence) }
        return []
    }

    /// An element of a tuple, array or dictionary literal is what the literal's type holds there.
    private func literalElementExpectations(of node: Syntax, _ parent: Syntax) -> [Expectation]? {
        if let labeled = parent.as(LabeledExprSyntax.self), let list = labeled.parent?.as(LabeledExprListSyntax.self),
           let tuple = list.parent?.as(TupleExprSyntax.self) {
            if list.count == 1 { return expectations(of: Syntax(tuple)) }
            guard let index = list.firstIndex(where: { $0.id == labeled.id }) else { return [] }
            let offset = list.distance(from: list.startIndex, to: index)
            return expectations(of: Syntax(tuple)).compactMap { expectation in
                guard case .type(let type) = expectation,
                      let tupleType = Self.unwrappingOptional(type).as(TupleTypeSyntax.self) else { return nil }
                let elements = Array(tupleType.elements)
                // A labelled element binds by label — `(b: …, a: …)` against `(a: A, b: B)` is a
                // legal shuffle — and an unlabelled one by position.
                if let label = labeled.label?.text,
                   let named = elements.first(where: { $0.firstName?.text == label }) {
                    return .type(named.type)
                }
                return offset < elements.count ? .type(elements[offset].type) : nil
            }
        }
        if let element = parent.as(ArrayElementSyntax.self),
           let array = element.parent?.parent?.as(ArrayExprSyntax.self) {
            return expectations(of: Syntax(array)).compactMap { expectation in
                guard case .type(let type) = expectation,
                      let elementType = Self.arrayElement(of: Self.unwrappingOptional(type)) else { return nil }
                return .type(elementType)
            }
        }
        if let element = parent.as(DictionaryElementSyntax.self), element.value.id == node.id,
           let dictionary = element.parent?.parent?.as(DictionaryExprSyntax.self) {
            return expectations(of: Syntax(dictionary)).compactMap { expectation in
                guard case .type(let type) = expectation,
                      let dictionaryType = Self.unwrappingOptional(type).as(DictionaryTypeSyntax.self)
                else { return nil }
                return .type(dictionaryType.value)
            }
        }
        return nil
    }

    /// The single statement of a body is its value: of a function, a computed property, or a
    /// branch of an `if` or `switch` expression. A closure's is inferred, so it says nothing.
    private func soleStatementExpectations(_ list: CodeBlockItemListSyntax) -> [Expectation] {
        guard let holder = list.parent, !holder.is(ClosureExprSyntax.self) else { return [] }
        if holder.is(AccessorBlockSyntax.self) {
            return Self.resultType(enclosing: holder).map { [.type($0)] } ?? []
        }
        if let switchCase = holder.as(SwitchCaseSyntax.self),
           let switchExpression = switchCase.parent?.parent?.as(SwitchExprSyntax.self) {
            return expectations(of: Syntax(switchExpression))
        }
        guard let block = holder.as(CodeBlockSyntax.self), let owner = block.parent else { return [] }
        if owner.is(IfExprSyntax.self) {
            // An `else if` takes its type from where the outermost `if` sits.
            var outermost = owner
            while let parent = outermost.parent, parent.is(IfExprSyntax.self) { outermost = parent }
            return expectations(of: outermost)
        }
        if owner.is(FunctionDeclSyntax.self) || owner.is(AccessorDeclSyntax.self) {
            return Self.resultType(enclosing: Syntax(block)).map { [.type($0)] } ?? []
        }
        return []
    }

    /// What an assignment's left side holds: `self` in an initializer, or a stored property of the
    /// enclosing type — unless a local binding of that name is what the left side means.
    private func assignmentTargets(_ left: ExprSyntax) -> [Expectation] {
        var name: String?
        if let reference = left.as(DeclReferenceExprSyntax.self) {
            if reference.baseName.tokenKind == .keyword(.self) { return [.selfType] }
            if Self.isLocallyBound(reference.baseName.text, at: Syntax(left)) { return [] }
            name = reference.baseName.text
        } else if let member = left.as(MemberAccessExprSyntax.self),
                  member.base?.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self) {
            name = member.declName.baseName.text
        }
        guard let name, let innermost = ConstructionFacts.enclosingTypeChain(of: Syntax(left)).last else { return [] }
        let members = facts.memberTypes[innermost.name]?[name] ?? []
        // Written inside the declaration itself, its own property is meant; in an extension, any
        // declaration of that name may be the one extended.
        let declaration = Self.enclosingTypeDeclaration(of: Syntax(left))
        let own = members.filter { $0.declaration == declaration }
        return (own.isEmpty ? members : own).map { .type($0.type) }
    }

    /// The nearest enclosing type declaration or extension.
    private static func enclosingTypeDeclaration(of node: Syntax) -> Syntax? {
        var current = node.parent
        while let ancestor = current {
            if TypeShapeCollector.declaredName(of: ancestor) != nil { return ancestor }
            current = ancestor.parent
        }
        return nil
    }

    /// Whether `name` is bound by a parameter or a local declaration between `node` and its
    /// enclosing type — in which case `name = …` does not assign the stored property. Any pattern
    /// binding `name` anywhere in an enclosing body counts, in scope at `node` or not: a local
    /// mistaken for the property would type the assignment wrongly, and one mistaken the other
    /// way only loses the context.
    private static func isLocallyBound(_ name: String, at node: Syntax) -> Bool {
        var current = node.parent
        while let ancestor = current {
            if TypeShapeCollector.declaredName(of: ancestor) != nil { return false }
            if let function = ancestor.as(FunctionDeclSyntax.self),
               Self.binds(name, function.signature.parameterClause) {
                return true
            }
            if let initializer = ancestor.as(InitializerDeclSyntax.self),
               Self.binds(name, initializer.signature.parameterClause) {
                return true
            }
            if let closure = ancestor.as(ClosureExprSyntax.self), closureParameterNames(closure).contains(name) {
                return true
            }
            if TypeShapeCollector.isFunctionLike(ancestor), bindsPattern(named: name, in: ancestor) { return true }
            current = ancestor.parent
        }
        return false
    }

    private static func binds(_ name: String, _ parameters: FunctionParameterClauseSyntax) -> Bool {
        parameters.parameters.contains { ($0.secondName ?? $0.firstName).text == name }
    }

    /// Whether a pattern anywhere in `body` binds `name`: `let`, `var`, `for`, `if let`, `case let`.
    private static func bindsPattern(named name: String, in body: Syntax) -> Bool {
        final class Finder: SyntaxVisitor {
            let name: String
            var found = false
            init(name: String) {
                self.name = name
                super.init(viewMode: .sourceAccurate)
            }
            override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
                if node.identifier.text == name { found = true }
                return .skipChildren
            }
        }
        let finder = Finder(name: name)
        finder.walk(body)
        return finder.found
    }

    private static func closureParameterNames(_ closure: ClosureExprSyntax) -> [String] {
        switch closure.signature?.parameterClause {
        case .simpleInput(let shorthand)?:
            return shorthand.map(\.name.text)
        case .parameterClause(let clause)?:
            return clause.parameters.map { ($0.secondName ?? $0.firstName).text }
        case nil:
            return []
        }
    }

    /// The declared result of the function, computed property or subscript `node` sits in; `nil`
    /// inside a closure or an initializer.
    static func resultType(enclosing node: Syntax) -> TypeSyntax? {
        var current: Syntax? = node
        while let ancestor = current {
            if ancestor.is(ClosureExprSyntax.self) || ancestor.is(InitializerDeclSyntax.self) { return nil }
            if let function = ancestor.as(FunctionDeclSyntax.self) { return function.signature.returnClause?.type }
            if let subscriptDecl = ancestor.as(SubscriptDeclSyntax.self) { return subscriptDecl.returnClause.type }
            if let binding = ancestor.as(PatternBindingSyntax.self), binding.accessorBlock != nil {
                return binding.typeAnnotation?.type
            }
            current = ancestor.parent
        }
        return nil
    }

    static func arrayElement(of type: TypeSyntax) -> TypeSyntax? {
        if let array = type.as(ArrayTypeSyntax.self) { return array.element }
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.name.text == "Array",
           let argument = identifier.genericArgumentClause?.arguments.first {
            return argument.argument.as(TypeSyntax.self)
        }
        return nil
    }
}
