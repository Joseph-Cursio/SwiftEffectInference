import SwiftSyntax

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
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float",
    ]

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, name: node.name.text, kind: .structure, isFinal: true)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let isFinal = node.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
        record(node, name: node.name.text, kind: .classOrActor, isFinal: isFinal)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, name: node.name.text, kind: .classOrActor, isFinal: true)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, name: node.name.text, kind: .enumeration, isFinal: true)
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

    private func record(_ decl: some DeclGroupSyntax, name: String, kind: ConstructionKind, isFinal: Bool) {
        let node = Syntax(decl)
        guard !name.isEmpty, let qualifiedName = ConstructionFacts.lexicalChain(of: node).last?.name else { return }
        let isPropertyWrapper = decl.attributes.contains {
            guard case .attribute(let attribute) = $0 else { return false }
            return attribute.attributeName.trimmedDescription == "propertyWrapper"
        }
        var raw = RawDeclaration(
            qualifiedName: qualifiedName, bareName: name, kind: kind, isFinal: isFinal,
            isPropertyWrapper: isPropertyWrapper, site: node
        )
        raw.inheritedNames = Self.inheritedNames(decl.inheritanceClause)
        if kind == .enumeration, let first = raw.inheritedNames.first, Self.rawValueTypes.contains(first) {
            // An enum with a raw type conforms to RawRepresentable without saying so.
            raw.inheritedNames.append("RawRepresentable")
        }
        for member in Self.flattened(decl.memberBlock.members) {
            if let initializer = member.as(InitializerDeclSyntax.self) {
                raw.hasInitializerInBody = true
                raw.initializers.append(.init(declaration: initializer, fromProtocol: false))
            } else if let variable = member.as(VariableDeclSyntax.self) {
                recordStorage(variable, of: qualifiedName, into: &raw)
            }
        }
        raws.append(raw)
    }

    private func recordStorage(
        _ variable: VariableDeclSyntax,
        of qualifiedName: String,
        into raw: inout RawDeclaration
    ) {
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
            Self.recordAttributes(attributes, of: name, hasInitialValue: binding.initializer != nil, into: &raw)
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

    /// What a stored property's attributes add: their arguments, and the property wrapper each
    /// may name.
    private static func recordAttributes(
        _ attributes: [AttributeSyntax],
        of name: String,
        hasInitialValue: Bool,
        into raw: inout RawDeclaration
    ) {
        for attribute in attributes {
            if let arguments = attribute.arguments { raw.attributeArguments.append((name, Syntax(arguments))) }
            if let wrapper = Self.components(of: attribute.attributeName) {
                raw.wrapperUses.append(.init(
                    property: name, wrapper: wrapper, attribute: attribute,
                    hasInitialValue: hasInitialValue
                ))
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
