import SwiftParser
import SwiftSyntax

/// One declared type, as collected — before any of it is judged.
struct RawDeclaration {
    struct StoredDefault {
        let name: String
        let isLet: Bool
        let value: ExprSyntax
        let annotation: TypeSyntax?
    }

    struct WrapperUse {
        let property: String
        let wrapper: [String]
        let attribute: AttributeSyntax
        let hasInitialValue: Bool
    }

    struct InitializerSource {
        let declaration: InitializerDeclSyntax
        let fromProtocol: Bool
    }

    let qualifiedName: String
    let bareName: String
    let kind: ConstructionKind
    let isFinal: Bool
    let isPropertyWrapper: Bool
    let site: Syntax
    var storedDefaults: [StoredDefault] = []
    /// Attribute arguments on stored properties: evaluated on every construction.
    var attributeArguments: [(property: String, arguments: Syntax)] = []
    var wrapperUses: [WrapperUse] = []
    var memberwiseParameters: [DeclarationShape.Parameter] = []
    /// An initializer in the declaration's own body suppresses the memberwise one; one in an
    /// extension does not.
    var hasInitializerInBody = false
    var initializers: [InitializerSource] = []
    var inheritedNames: [String] = []

    var unjudged: ConstructionDeclaration {
        .init(
            qualifiedName: qualifiedName, bareName: bareName, kind: kind, isFinal: isFinal,
            isPropertyWrapper: isPropertyWrapper, site: site, inheritedNames: inheritedNames,
            unconditional: nil, conditionalStoredDefault: nil, initializers: []
        )
    }

    func evaluate(with inferrer: PurityInferrer, facts: ConstructionFacts) -> ConstructionDeclaration {
        var judged = unjudged
        let stored = storedFacts(with: inferrer, facts: facts)
        judged.unconditional = stored.unconditional ?? inheritedUnconditional(facts: facts)
        judged.conditionalStoredDefault = stored.conditional
        judged.initializers = initializers.map {
            judge($0, runningStoredDefaults: stored.conditional, with: inferrer, facts: facts)
        }
        if kind == .structure, !hasInitializerInBody {
            judged.initializers.append(.init(
                parameters: memberwiseParameters,
                display: "init(" + memberwiseParameters.map { $0.label + ":" }.joined() + ")",
                origin: .memberwise, isConvenience: false,
                bodyRefutation: nil, storedDefaultRefutation: nil,
                omittedDefaultRefutations: stored.memberwiseOmitted
            ))
        }
        if kind == .classOrActor, !initializers.contains(where: { !Self.isConvenience($0.declaration) }) {
            // A class that declares no designated initializer has `init()` — implicit, or inherited.
            judged.initializers.append(.init(
                parameters: [], display: "init()", origin: .implicit, isConvenience: false,
                bodyRefutation: nil, storedDefaultRefutation: nil, omittedDefaultRefutations: []
            ))
        }
        return judged
    }

    /// What the stored properties run.
    struct StoredFacts {
        /// Run by every construction.
        var unconditional: PurityRefutation?
        /// The struct `var` defaults the memberwise initializer may skip.
        var conditional: PurityRefutation?
        /// The same, as the memberwise initializer's omittable parameters.
        var memberwiseOmitted: [OmittedDefault] = []
    }

    private func storedFacts(with inferrer: PurityInferrer, facts: ConstructionFacts) -> StoredFacts {
        var unconditional: PurityRefutation?
        var conditional: PurityRefutation?
        var omitted: [OmittedDefault] = []
        func witness(_ property: String, _ cause: PurityRefutation) -> PurityRefutation {
            .refutingConstruction(type: qualifiedName, via: .storedProperty(property), cause: cause)
        }

        for stored in storedDefaults {
            guard let cause = Self.judge(
                stored.value, declaredAs: stored.annotation, with: inferrer, facts: facts
            ) else {
                continue
            }
            // A `let` default can never be replaced; a class's or actor's defaults run in every
            // designated initializer; a struct with an initializer of its own has no memberwise one
            // to pass the value through; and an enum has no stored properties to vary. Only a
            // struct `var` behind the memberwise initializer is conditional.
            if stored.isLet || kind != .structure || hasInitializerInBody {
                unconditional = unconditional ?? witness(stored.name, cause)
            } else {
                conditional = conditional ?? witness(stored.name, cause)
                omitted.append(
                    .init(label: stored.name, unlabelledPosition: nil, refutation: witness(stored.name, cause))
                )
            }
        }
        // What every construction builds alongside: the arguments written on a property's
        // attributes, and a property wrapper this package declares.
        for (property, arguments) in attributeArguments {
            if let cause = inferrer.constructionRefutation(arguments) {
                unconditional = unconditional ?? witness(property, cause)
            }
        }
        for use in wrapperUses {
            let wrappers = facts.declarations(named: use.wrapper, from: Syntax(use.attribute))
                .filter { facts.declarations[$0].isPropertyWrapper }
            guard !wrappers.isEmpty else { continue }
            let call = Self.wrapperCall(use.attribute, hasInitialValue: use.hasInitialValue)
            if let cause = facts.refutation(constructing: wrappers, call: call) {
                unconditional = unconditional ?? witness(use.property, cause)
            }
        }
        return StoredFacts(unconditional: unconditional, conditional: conditional, memberwiseOmitted: omitted)
    }

    /// What a subclass inherits from its superclass's unconditional facts.
    private func inheritedUnconditional(facts: ConstructionFacts) -> PurityRefutation? {
        guard kind == .classOrActor else { return nil }
        for (name, supers) in facts.superclasses(of: unjudged) {
            if let cause = supers.lazy.compactMap({ facts.declarations[$0].unconditional }).first {
                return unjudged.refuted(via: .superclass(name), cause)
            }
        }
        return nil
    }

    private func judge(
        _ source: InitializerSource,
        runningStoredDefaults conditional: PurityRefutation?,
        with inferrer: PurityInferrer,
        facts: ConstructionFacts
    ) -> ConstructionInitializer {
        let declaration = source.declaration
        let parameters = DeclarationShape.from(declaration: declaration).parameters
        let display = "init(" + parameters.map { $0.label + ":" }.joined() + ")"
        let delegates = Self.calls(declaration, on: .keyword(.self))
        let isConvenience = Self.isConvenience(declaration)
        var body: PurityRefutation?
        if let block = declaration.body, let cause = inferrer.constructionRefutation(Syntax(block)) {
            body = .refutingConstruction(type: qualifiedName, via: .initializer(display), cause: cause)
        } else if kind == .classOrActor, !delegates, !isConvenience, !Self.calls(declaration, on: .keyword(.super)) {
            // A designated initializer that does not call `super.init` calls `super.init()`.
            let supers = facts.superclasses(of: unjudged).flatMap(\.candidates)
            if let cause = facts.refutation(constructing: supers, call: .empty) {
                body = .refutingConstruction(type: qualifiedName, via: .initializer(display), cause: cause)
            }
        }
        var omitted: [OmittedDefault] = []
        var unlabelled = 0
        for parameter in declaration.signature.parameterClause.parameters {
            let isUnlabelled = parameter.firstName.tokenKind == .wildcard
            defer { if isUnlabelled { unlabelled += 1 } }
            guard let value = parameter.defaultValue?.value,
                  let cause = Self.judge(value, declaredAs: parameter.type, with: inferrer, facts: facts)
            else { continue }
            let name = parameter.secondName?.text ?? parameter.firstName.text
            omitted.append(.init(
                label: isUnlabelled ? "_" : parameter.firstName.text,
                unlabelledPosition: isUnlabelled ? unlabelled : nil,
                refutation: .refutingConstruction(
                    type: qualifiedName, via: .initializer(display),
                    cause: .refutingDefaultArgument(parameter: name, cause: cause)
                )
            ))
        }
        return .init(
            parameters: parameters, display: display,
            origin: source.fromProtocol ? .protocolExtension : .declared,
            isConvenience: isConvenience,
            bodyRefutation: body,
            // Every non-delegating initializer runs the defaults; a delegating one runs them
            // through the one it delegates to.
            storedDefaultRefutation: delegates ? nil : conditional,
            omittedDefaultRefutations: omitted
        )
    }

    /// The call a property wrapper attribute makes: `init(wrappedValue:…)` with an initial value,
    /// then the attribute's own arguments.
    static func wrapperCall(_ attribute: AttributeSyntax, hasInitialValue: Bool) -> CallShape {
        var labels = hasInitialValue ? ["wrappedValue"] : []
        if case .argumentList(let arguments)? = attribute.arguments {
            labels += arguments.map { $0.label?.text ?? "_" }
        }
        return CallShape(ordinary: labels, trailing: [])
    }

    /// A default value's refutation. A base-less member — `.now`, `.init()`, `.current` — names
    /// nothing until a type is put in front of it, so it is judged that way too: `var created: Date
    /// = .now` is `Date.now`. Nested in a literal or a call (`[.init()]`, `(.now, 0)`), which type
    /// it belongs to is not worked out — it is judged in front of every type the annotation names,
    /// so `let ids: Set<UUID> = [.init()]` is `UUID.init()` among others.
    static func judge(
        _ value: ExprSyntax,
        declaredAs type: TypeSyntax?,
        with inferrer: PurityInferrer,
        facts: ConstructionFacts
    ) -> PurityRefutation? {
        if let refutation = inferrer.constructionRefutation(Syntax(value)) { return refutation }
        guard let type else { return nil }
        let members = implicitMembers(in: value)
        guard !members.isEmpty else { return nil }
        for named in namedTypes(in: type) {
            for typeText in qualifyingTexts(of: named, facts: facts) {
                for member in members {
                    guard let expression = Parser.parse(source: typeText + member).statements.first?.item else {
                        continue
                    }
                    if let refutation = inferrer.constructionRefutation(Syntax(expression)) { return refutation }
                }
            }
        }
        return nil
    }

    /// The texts that may stand in front of an implicit member of `type`: the type with `?`
    /// removed and typealiases followed — through every alias the name may mean where it is
    /// written — and for a clock's `Instant`, the clock, which is what the nondeterminism
    /// classifier knows (`ContinuousClock.Instant.now` is `ContinuousClock.now`).
    private static func qualifyingTexts(of type: TypeSyntax, facts: ConstructionFacts) -> [String] {
        let unwrapped = ConstructionChecker.unwrappingOptional(type)
        guard let components = TypeShapeCollector.components(of: unwrapped) else { return [] }
        return facts.spellings(of: components, from: Syntax(type)).map { spelling in
            var spelling = spelling
            if spelling.count > 1, spelling.last == "Instant" { spelling.removeLast() }
            return spelling.joined(separator: ".")
        }
    }

    /// Every named type in `type`, outermost first: `Set<UUID>` gives `Set<UUID>` and `UUID`.
    private static func namedTypes(in type: TypeSyntax) -> [TypeSyntax] {
        final class Finder: SyntaxVisitor {
            var found: [TypeSyntax] = []
            override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
                found.append(TypeSyntax(node))
                return .visitChildren
            }
            override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
                found.append(TypeSyntax(node))
                return .visitChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(type)
        return finder.found
    }

    /// Each base-less member in `value` as written, with its call when it is called: `.now`,
    /// `.init(title: "x")`. Not inside a closure, whose body construction does not run and whose
    /// members belong to other types.
    private static func implicitMembers(in value: ExprSyntax) -> [String] {
        final class Finder: SyntaxVisitor {
            var found: [String] = []
            override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
            override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                guard node.base == nil else { return .visitChildren }
                if let call = node.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == node.id {
                    found.append(call.trimmedDescription)
                } else {
                    found.append(node.trimmedDescription)
                }
                return .visitChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(value)
        return finder.found
    }

    static func isConvenience(_ initializer: InitializerDeclSyntax) -> Bool {
        initializer.modifiers.contains { $0.name.tokenKind == .keyword(.convenience) }
    }

    /// Whether `initializer`'s body calls `self.init` or `super.init`.
    static func calls(_ initializer: InitializerDeclSyntax, on base: TokenKind) -> Bool {
        guard let body = initializer.body else { return false }
        return body.tokens(viewMode: .sourceAccurate).contains { token in
            guard token.tokenKind == .keyword(.`init`),
                  let period = token.previousToken(viewMode: .sourceAccurate),
                  period.tokenKind == .period,
                  let receiver = period.previousToken(viewMode: .sourceAccurate) else { return false }
            return receiver.tokenKind == base
        }
    }
}

/// Walks a package once, recording every type with the parts of it that run on construction.
final class TypeShapeCollector: SyntaxVisitor {
    private(set) var raws: [RawDeclaration] = []
    private(set) var aliases: [String: [AliasDeclaration]] = [:]
    private(set) var protocolNames: Set<String> = []
    private(set) var protocolParents: [String: [String]] = [:]
    private(set) var memberTypes: [String: [String: [MemberType]]] = [:]
    /// `typealias Entity = A & B` → `["A", "B"]`.
    private var compositions: [String: [String]] = [:]
    private var pendingInitializers: [(extended: [String], initializer: InitializerDeclSyntax)] = []
    private var pendingConformances: [(extended: [String], names: [String])] = []

    /// Property wrappers whose initial value is an autoclosure, evaluated on first use rather than
    /// on construction.
    private static let autoclosureWrappers: Set<String> = ["StateObject"]

    private static let rawValueTypes: Set<String> = [
        "String", "Character", "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float"
    ]

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

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(Syntax(node), name: node.name.text, kind: .structure, isFinal: true,
               members: node.memberBlock.members, inheritance: node.inheritanceClause, attributes: node.attributes)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let isFinal = node.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
        record(Syntax(node), name: node.name.text, kind: .classOrActor, isFinal: isFinal,
               members: node.memberBlock.members, inheritance: node.inheritanceClause, attributes: node.attributes)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(Syntax(node), name: node.name.text, kind: .classOrActor, isFinal: true,
               members: node.memberBlock.members, inheritance: node.inheritanceClause, attributes: node.attributes)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(Syntax(node), name: node.name.text, kind: .enumeration, isFinal: true,
               members: node.memberBlock.members, inheritance: node.inheritanceClause, attributes: node.attributes)
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        protocolNames.insert(node.name.text)
        protocolParents[node.name.text, default: []] += Self.inheritedNames(node.inheritanceClause)
        // `protocol Fancy where Self: Seedable` refines Seedable as surely as `: Seedable` does.
        for requirement in node.genericWhereClause?.requirements ?? [] {
            guard case .conformanceRequirement(let conformance) = requirement.requirement,
                  conformance.leftType.trimmedDescription == "Self" else { continue }
            if let composition = conformance.rightType.as(CompositionTypeSyntax.self) {
                protocolParents[node.name.text, default: []] += Self.lastComponents(of: composition)
            } else if let name = Self.components(of: conformance.rightType)?.last {
                protocolParents[node.name.text, default: []].append(name)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extended = Self.components(of: node.extendedType) ?? [node.extendedType.trimmedDescription]
        for decl in Self.flattened(node.memberBlock.members) {
            if let initializer = decl.as(InitializerDeclSyntax.self) {
                pendingInitializers.append((extended, initializer))
            }
        }
        let conformances = Self.inheritedNames(node.inheritanceClause)
        if !conformances.isEmpty { pendingConformances.append((extended, conformances)) }
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        let value = node.initializer.value
        if let composition = value.as(CompositionTypeSyntax.self) {
            compositions[node.name.text, default: []] += Self.lastComponents(of: composition)
        } else if let components = Self.components(of: value) {
            aliases[node.name.text, default: []].append(
                .init(scope: Self.memberScope(of: Syntax(node)), target: components, site: Syntax(value))
            )
        }
        return .skipChildren
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

    // swiftlint:disable:next function_parameter_count
    private func record(
        _ node: Syntax,
        name: String,
        kind: ConstructionKind,
        isFinal: Bool,
        members: MemberBlockItemListSyntax,
        inheritance: InheritanceClauseSyntax?,
        attributes: AttributeListSyntax
    ) {
        guard !name.isEmpty, let qualifiedName = ConstructionFacts.lexicalChain(of: node).last?.name else { return }
        let isPropertyWrapper = attributes.contains {
            guard case .attribute(let attribute) = $0 else { return false }
            return attribute.attributeName.trimmedDescription == "propertyWrapper"
        }
        var raw = RawDeclaration(
            qualifiedName: qualifiedName, bareName: name, kind: kind, isFinal: isFinal,
            isPropertyWrapper: isPropertyWrapper, site: node
        )
        raw.inheritedNames = Self.inheritedNames(inheritance)
        if kind == .enumeration, let first = raw.inheritedNames.first, Self.rawValueTypes.contains(first) {
            // An enum with a raw type conforms to RawRepresentable without saying so.
            raw.inheritedNames.append("RawRepresentable")
        }
        for decl in Self.flattened(members) {
            if let initializer = decl.as(InitializerDeclSyntax.self) {
                raw.hasInitializerInBody = true
                raw.initializers.append(.init(declaration: initializer, fromProtocol: false))
            } else if let variable = decl.as(VariableDeclSyntax.self) {
                recordStorage(variable, of: qualifiedName, into: &raw)
            }
        }
        raws.append(raw)
    }

    private func recordStorage(_ variable: VariableDeclSyntax, of qualifiedName: String, into raw: inout RawDeclaration) {
        let modifiers = variable.modifiers.map(\.name.tokenKind)
        if modifiers.contains(.keyword(.static)) || modifiers.contains(.keyword(.class)) { return }
        let isLazy = modifiers.contains(.keyword(.lazy))
        let isLet = variable.bindingSpecifier.tokenKind == .keyword(.let)
        let attributes = variable.attributes.compactMap { element -> AttributeSyntax? in
            if case .attribute(let attribute) = element { return attribute }
            return nil
        }
        let isAutoclosure = attributes.contains {
            Self.autoclosureWrappers.contains($0.attributeName.trimmedDescription)
        }
        for binding in variable.bindings {
            // Computed: not storage. Observers (`willSet`/`didSet`) are still storage.
            if let accessors = binding.accessorBlock, !Self.isObserversOnly(accessors) { continue }
            let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                ?? binding.pattern.trimmedDescription
            let annotation = binding.typeAnnotation?.type
            if let annotation {
                memberTypes[qualifiedName, default: [:]][name, default: []]
                    .append(.init(declaration: raw.site, type: annotation))
            }
            if isLazy {
                // A lazy default runs on first access, not on construction; the memberwise
                // initializer still takes the property, optionally.
                raw.memberwiseParameters.append(.init(label: name, hasDefault: true))
                continue
            }
            for attribute in attributes {
                if let arguments = attribute.arguments { raw.attributeArguments.append((name, Syntax(arguments))) }
                if let wrapper = Self.components(of: attribute.attributeName) {
                    raw.wrapperUses.append(.init(
                        property: name, wrapper: wrapper, attribute: attribute,
                        hasInitialValue: binding.initializer != nil
                    ))
                }
            }
            if let value = binding.initializer?.value {
                if !isAutoclosure {
                    raw.storedDefaults.append(.init(name: name, isLet: isLet, value: value, annotation: annotation))
                }
                // A `let` with a default is not a memberwise parameter at all.
                if !isLet { raw.memberwiseParameters.append(.init(label: name, hasDefault: true)) }
            } else {
                // `var x: T?` and `var x: T!` default to nil in the memberwise initializer, and a
                // property wrapper may supply its own default. Omittable errs toward accepting the
                // call — and so toward refuting it.
                let optional = !isLet && (annotation?.is(OptionalTypeSyntax.self) == true
                    || annotation?.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) == true)
                raw.memberwiseParameters.append(.init(label: name, hasDefault: optional || !attributes.isEmpty))
            }
        }
    }

    private static func isObserversOnly(_ accessors: AccessorBlockSyntax) -> Bool {
        guard case .accessors(let list) = accessors.accessors else { return false }
        return list.allSatisfy {
            [.keyword(.willSet), .keyword(.didSet)].contains($0.accessorSpecifier.tokenKind)
        }
    }

    /// Attaches what extensions declared: conformances and initializers belong to every
    /// declaration the extension could name — by qualified name when one matches, through a
    /// typealias, by bare name otherwise. An extension of a protocol, the package's or not, gives
    /// its initializers to every conformer.
    func finish() -> [RawDeclaration] {
        // Compositions spelled out wherever they are named.
        for index in raws.indices {
            raws[index].inheritedNames = raws[index].inheritedNames.flatMap { compositions[$0] ?? [$0] }
        }
        for (name, parents) in protocolParents {
            protocolParents[name] = parents.flatMap { compositions[$0] ?? [$0] }
        }
        for (extended, names) in pendingConformances {
            for index in targets(extended) {
                raws[index].inheritedNames += names.flatMap { compositions[$0] ?? [$0] }
            }
        }
        var protocolInitializers: [(name: String, initializer: InitializerDeclSyntax)] = []
        for (extended, initializer) in pendingInitializers {
            let found = targets(extended)
            if found.isEmpty, let bare = extended.last {
                protocolInitializers.append((bare, initializer))
            }
            for index in found { raws[index].initializers.append(.init(declaration: initializer, fromProtocol: false)) }
        }
        if !protocolInitializers.isEmpty {
            let facts = ConstructionFacts(
                declarations: raws.map(\.unjudged), protocolNames: protocolNames, protocolParents: protocolParents
            )
            for (name, initializer) in protocolInitializers {
                for index in facts.conformers(of: name) {
                    raws[index].initializers.append(.init(declaration: initializer, fromProtocol: true))
                }
            }
        }
        return raws
    }

    private func targets(_ extended: [String]) -> [Int] {
        let written = extended.joined(separator: ".")
        let exact = raws.indices.filter { raws[$0].qualifiedName == written }
        if !exact.isEmpty { return exact }
        guard let bare = extended.last else { return [] }
        // A protocol's name: its extension is the protocol's, whatever nested type shares the name.
        if extended.count == 1, protocolNames.contains(bare) { return [] }
        let byName = raws.indices.filter { raws[$0].bareName == bare }
        if !byName.isEmpty { return byName }
        let aliased = (aliases[bare] ?? []).compactMap(\.target.last)
        return raws.indices.filter { aliased.contains(raws[$0].bareName) }
    }
}
