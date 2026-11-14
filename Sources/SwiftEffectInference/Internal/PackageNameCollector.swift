import SwiftSyntax

/// Walks a package's declarations for `PackageNames`, never entering a function body, and recording
/// for each declaration what `PackageNames` needs to leave it out. A declaration inside an `#if`
/// clause is recorded so that it can be left out: it may not be compiled, yet it can shadow a name.
final class PackageNameCollector: SourceAccurateSyntaxVisitor {
    var entries: [PackageNameEntry] = []
    private(set) var typeParameters: Set<String> = []
    var supertypes: [String: Set<String>] = [:]
    /// What a type's initializers, subscripts and nameless calls take and return, by its path; an
    /// extension may add to a type declared in another file.
    var typeMentions: [String: Set<String>] = [:]
    private(set) var genericTypePaths: Set<String> = []
    /// The types being walked, innermost last: each one's absolute path, and whether it is a protocol.
    var containers: [(path: [String], isProtocol: Bool)] = []
    private(set) var ifConfigDepth = 0
    /// For each container being walked, whether an attribute on it (`@available(swift, obsoleted:
    /// 1)`) can hide what it declares from lookup, so that a call binds to an SDK namesake.
    var restrictions: [Bool] = []
    /// Whether a top-level `typealias StringLiteralType = …` (or another literal type) rebinds what
    /// every literal in the module builds.
    var rebindsLiterals = false
    /// Types whose construction or nameless calls (a subscript, `callAsFunction`) run code a caller
    /// cannot see: a stored default that is not inert, or a default argument of a nameless call.
    var nonInertTypePaths: Set<String> = []
    /// Whether an extension of a type that is not the package's gives its values a nameless call
    /// with a default argument, which any body could then run without naming anything.
    private(set) var hasForeignNamelessDefaults = false
    /// The containers that declare an initializer, a subscript or `callAsFunction`: on a type that
    /// is not the package's (`extension String { init(_ x: [LocalizedStringResource]) }`), these are
    /// reached by the SDK type's own name or by no name, and nothing can vouch for them.
    private(set) var extensionCallables: Set<String> = []
    /// What each container's initializers take, with `"default"` for a defaulted parameter and
    /// `"->"` for a generic one, for `PackageNames` to judge where the container is an SDK type.
    private(set) var initializerMentions: [String: Set<String>] = [:]
    /// Every name each type's initializers' default arguments spell, which run in the caller.
    private(set) var initializerDefaultNames: [String: Set<String>] = [:]
    /// Types an initializer of which has a default argument that is not inert: building one runs
    /// that default in the caller, though naming the type or reading its members does not.
    private(set) var unconstructibleTypePaths: Set<String> = []
    /// Each extension's extended path and what its inheritance clause names.
    private(set) var extensionInheritance: [(path: String, names: [String])] = []
    /// Every extension's extended path.
    private(set) var extendedPaths: Set<String> = []

    /// A freestanding declaration macro (`#_EntryDefaultValue(…)`) adds declarations no walk of the
    /// source sees, and a package's own macro can expand to anything.
    override func visit(_: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        rebindsLiterals = true
        return .skipChildren
    }

    override func visit(_: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        rebindsLiterals = true
        return .skipChildren
    }

    /// `Foundation::URL` names the SDK type whatever the package declares, and the paths here drop
    /// the selector: a package that writes one anywhere is not relaxed.
    override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
        if node.tokens(viewMode: .sourceAccurate).contains(where: { $0.tokenKind == .colonColon }) {
            rebindsLiterals = true
        }
        if Self.mayBeMisread(Syntax(node)) { rebindsLiterals = true }
        return .visitChildren
    }

    // MARK: - Where nothing is collected

    override func visit(_: CodeBlockSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_: AccessorBlockSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        ifConfigDepth += 1
        return .visitChildren
    }

    override func visitPost(_: IfConfigDeclSyntax) { ifConfigDepth -= 1 }
    override func visit(_: InitializerClauseSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    /// A `switch` case's statements, at the top level of a script, declare locals of that case.
    override func visit(_: SwitchCaseSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    // MARK: - Types

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let index = entries.count
        _ = enterType(node)
        entries[index].isClass = true
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node)
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        let index = entries.count
        _ = enterType(node)
        entries[index].isClass = true
        // A distributed actor conforms to `DistributedActor`, whose `id` its actor system assigns.
        if node.modifiers.contains(where: { $0.name.tokenKind == .keyword(.distributed) }) {
            supertypes[entries[index].path, default: []].insert("DistributedActor")
        }
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        var declared = entry(node.name, shape: .type, attributes: node.attributes)
        declared.isProtocol = true
        if Self.literalTypeAliases.contains(node.name.bareName) { rebindsLiterals = true }
        entries.append(declared)
        let path = containerPath(adding: node.name.bareName)
        // What a protocol refines, its conformers inherit: `protocol Keyed: Identifiable`.
        supertypes[path.joined(separator: "."), default: []].formUnion(Self.inheritedPaths(node.inheritanceClause))
        containers.append((path, true))
        restrictions.append(Self.restricts(node.attributes))
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let path = Self.bareComponents(of: node.extendedType) ?? ["?"]
        let inherited = Self.inheritedPaths(node.inheritanceClause)
        extendedPaths.insert(path.joined(separator: "."))
        supertypes[path.joined(separator: "."), default: []].formUnion(inherited)
        addInferredAssociatedTypes(for: node.inheritanceClause, in: path.joined(separator: "."))
        if !inherited.isEmpty { extensionInheritance.append((path.joined(separator: "."), inherited)) }
        if node.genericWhereClause != nil || Self.genericStandardTypes.contains(path.joined(separator: ".")) {
            genericTypePaths.insert(path.joined(separator: "."))
        }
        containers.append((path, false))
        restrictions.append(Self.restricts(node.attributes))
        return .visitChildren
    }

    override func visitPost(_: StructDeclSyntax) { leaveContainer() }
    override func visitPost(_: ClassDeclSyntax) { leaveContainer() }
    override func visitPost(_: EnumDeclSyntax) { leaveContainer() }
    override func visitPost(_: ActorDeclSyntax) { leaveContainer() }
    override func visitPost(_: ProtocolDeclSyntax) { leaveContainer() }
    override func visitPost(_: ExtensionDeclSyntax) { leaveContainer() }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        var alias = entry(node.name, shape: .type, attributes: node.attributes)
        alias.isAlias = true
        alias.isGeneric = node.genericParameterClause != nil
        alias.aliasTarget = Self.plainPath(of: Syntax(node.initializer.value))
        if Self.literalTypeAliases.contains(node.name.bareName) { rebindsLiterals = true }
        entries.append(alias)
        return .skipChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        typeParameters.insert(node.name.bareName)
        return .skipChildren
    }

    override func visit(_ node: GenericParameterSyntax) -> SyntaxVisitorContinueKind {
        typeParameters.insert(node.name.bareName)
        return .skipChildren
    }

    // MARK: - Members and top-level declarations

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.elements {
            let parameters = element.parameterClause.map { clause in
                clause.parameters.map {
                    PackageNameEntry.Parameter(
                        label: $0.firstName.flatMap { $0.tokenKind == .wildcard ? nil : $0.bareName },
                        hasDefault: $0.defaultValue != nil, isVariadic: false
                    )
                }
            }
            var declared = entry(element.name, shape: .enumCase(parameters), attributes: node.attributes)
            // A payload is handed back by pattern matching, so a function in it is called by the matcher.
            declared.mentions = element.parameterClause.map { Self.typeNames(in: Syntax($0), declaring: true) } ?? []
            // An associated value's default is evaluated wherever the case is built.
            let defaults = element.parameterClause?.parameters.compactMap { $0.defaultValue?.value } ?? []
            declared.isInert = declared.isInert && defaults.allSatisfy { Self.isInert(Syntax($0)) }
            declared.initializerNames = Set(defaults.flatMap { Self.identifiers(in: Syntax($0)) })
            entries.append(declared)
        }
        return .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        markAttributedRequirement(node.attributes)
        let signature = node.signature
        var declared = entry(
            node.name, shape: .function(Self.parameters(signature.parameterClause)), attributes: node.attributes
        )
        declared.isGeneric = node.genericParameterClause != nil || node.genericWhereClause != nil
            || Self.hasOpaqueParameter(signature.parameterClause)
        declared.mentions = Self.typeNames(in: Syntax(signature.parameterClause), declaring: false)
            .union(signature.returnClause.map { Self.typeNames(in: Syntax($0.type), declaring: true) } ?? [])
            .union(Self.thrownTypeNames(signature.effectSpecifiers?.throwsClause))
        // A default argument runs in the caller, wherever a call leaves it out.
        let defaults = signature.parameterClause.parameters.compactMap { $0.defaultValue?.value }
        if !defaults.allSatisfy({ Self.isInert(Syntax($0)) }) { declared.isInert = false }
        declared.initializerNames = Set(defaults.flatMap { Self.identifiers(in: Syntax($0)) })
        // A call to an `async` or throwing function must be awaited or tried; one written without
        // binds to an SDK function of that name (`gethostid()` over a package `gethostid() async`).
        if let effects = signature.effectSpecifiers, effects.asyncSpecifier != nil || effects.throwsClause != nil {
            declared.isInert = false
        }
        // A function spelled like a type (`func SortDescriptor(_:)`) can lose a call to the SDK type
        // of that name, whose initializer Swift may pick instead.
        if node.name.bareName.first?.isUppercase == true { declared.isInert = false }
        if case .binaryOperator = node.name.tokenKind { declared.isOperator = true }
        if case .prefixOperator = node.name.tokenKind { declared.isOperator = true }
        if case .postfixOperator = node.name.tokenKind { declared.isOperator = true }
        // `callAsFunction` and `dynamicallyCall` are called with no name: `value(…)`.
        if Self.hasParameterAttribute(signature.parameterClause) { declared.isInert = false }
        if ["callAsFunction", "dynamicallyCall"].contains(node.name.bareName) {
            addToContainer(declared.mentions)
            extensionCallables.insert(container)
            if signature.parameterClause.parameters.contains(where: { $0.defaultValue != nil }) {
                markNamelessDefault()
            }
        }
        entries.append(declared)
        return .skipChildren
    }

    /// An initializer's parameters are what constructing its type converts literals to; a generic
    /// one can pick its `T` from an annotation.
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let mentions = Self.typeNames(in: Syntax(node.signature.parameterClause), declaring: false)
            .union(Self.thrownTypeNames(node.signature.effectSpecifiers?.throwsClause))
        addToContainer(mentions)
        let parameters = node.signature.parameterClause.parameters
        // `Stamp()` runs whatever default it leaves out, with no label for a check to see.
        let defaults = parameters.compactMap { $0.defaultValue?.value }
        if !defaults.allSatisfy({ Self.isInert(Syntax($0)) }) { unconstructibleTypePaths.insert(container) }
        initializerDefaultNames[container, default: []].formUnion(defaults.flatMap { Self.identifiers(in: Syntax($0)) })
        var judged = mentions
        if parameters.contains(where: { $0.defaultValue != nil }) { judged.insert("default") }
        if node.genericParameterClause != nil || Self.hasOpaqueParameter(node.signature.parameterClause) {
            judged.insert("->")
        }
        initializerMentions[container, default: []].formUnion(judged)
        if Self.hasParameterAttribute(node.signature.parameterClause) { nonInertTypePaths.insert(container) }
        if node.genericParameterClause != nil || Self.hasOpaqueParameter(node.signature.parameterClause) {
            genericTypePaths.insert(container)
        }
        return .skipChildren
    }

    /// A subscript is called with no name, so what it takes and returns is its type's.
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        addToContainer(Self.typeNames(in: Syntax(node.parameterClause), declaring: false)
            .union(Self.typeNames(in: Syntax(node.returnClause.type), declaring: true))
            .union(Self.accessorThrownTypeNames(node.accessorBlock)))
        extensionCallables.insert(container)
        if node.genericParameterClause != nil { genericTypePaths.insert(container) }
        if node.parameterClause.parameters.contains(where: { $0.defaultValue != nil }) { markNamelessDefault() }
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        markAttributedRequirement(node.attributes)
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                // `static let (first, last) = (…)`: every name is left out, the initializer unjudged.
                for name in binding.pattern.tokens(viewMode: .sourceAccurate)
                where name.parent?.is(IdentifierPatternSyntax.self) == true {
                    var declared = entry(name, shape: .value, attributes: node.attributes)
                    declared.isInert = false
                    entries.append(declared)
                }
                continue
            }
            var declared = entry(identifier.identifier, shape: .value, attributes: node.attributes)
            // A wrapper synthesizes `_name` and `$name`, which an unqualified name inside the type
            // finds before any top-level one.
            if !node.attributes.isEmpty {
                for prefix in ["_", "$"] {
                    var storage = PackageNameEntry(
                        name: prefix + identifier.identifier.bareName, container: container, shape: .value
                    )
                    storage.isInert = false
                    entries.append(storage)
                }
            }
            let annotated = binding.typeAnnotation.map { Self.typeNames(in: Syntax($0.type), declaring: true) } ?? []
            declared.mentions = annotated.union(Self.accessorThrownTypeNames(binding.accessorBlock))
            let initialValueIsInert = binding.initializer.map { Self.isInert(Syntax($0.value)) } ?? true
            declared.isInert = declared.isInert && initialValueIsInert
            declared.initializerNames = binding.initializer.map { Self.identifiers(in: Syntax($0.value)) } ?? []
            // `unowned(unsafe)` reads whatever the freed memory holds.
            if node.modifiers.contains(where: { $0.detail?.detail.text == "unsafe" }) { declared.isInert = false }
            let isShared = container.isEmpty
                || node.modifiers.contains { [.keyword(.static), .keyword(.class)].contains($0.name.tokenKind) }
            if Self.isStored(binding) {
                if isShared {
                    // A global or static `var` holds whatever any code last stored, and a `let` with no
                    // initial value is set by top-level code elsewhere.
                    if node.bindingSpecifier.tokenKind == .keyword(.var) || binding.initializer == nil {
                        declared.isInert = false
                    }
                } else {
                    addToContainer(declared.mentions)
                    if !initialValueIsInert { nonInertTypePaths.insert(container) }
                }
            }
            entries.append(declared)
        }
        return .skipChildren
    }

    /// A script's top-level `guard let` declares a global, which top-level code sets.
    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        guard containers.isEmpty else { return .skipChildren }
        for token in node.conditions.tokens(viewMode: .sourceAccurate)
        where token.parent?.is(IdentifierPatternSyntax.self) == true {
            var declared = entry(token, shape: .value)
            declared.isInert = false
            entries.append(declared)
        }
        return .skipChildren
    }
}
