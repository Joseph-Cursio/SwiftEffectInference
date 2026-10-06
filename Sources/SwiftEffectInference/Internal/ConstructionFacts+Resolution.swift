import SwiftSyntax

// MARK: - Which declarations a spelling can mean

extension ConstructionFacts {

    func indices(_ bareName: String) -> [Int] { indicesByBareName[bareName] ?? [] }

    /// The declarations `components` (as written, `["Outer", "Inner"]`) could name from `site`,
    /// the lexically preferred first. With no `site`, every declaration the spelling could mean.
    ///
    /// Asked once per scope: the answer is kept in the memo for every site that reads the same
    /// scope (`LookupKey`).
    func declarations(
        named components: [String],
        from site: Syntax?,
        depth: Int = 0,
        aliasesSeen: Set<String> = []
    ) -> [Int] {
        guard let memo = memo.instance else {
            return memoised().declarations(named: components, from: site, depth: depth, aliasesSeen: aliasesSeen)
        }
        let key = LookupKey(components: components, site: site, depth: depth, aliasesSeen: aliasesSeen)
        if let known = memo.lookups[key] { return known }
        let found = resolve(components, from: site, depth: depth, aliasesSeen: aliasesSeen)
        memo.lookups[key] = found
        return found
    }

    private func resolve(_ components: [String], from site: Syntax?, depth: Int, aliasesSeen: Set<String>) -> [Int] {
        guard let head = components.first, !head.isEmpty, depth < 6 else { return [] }
        if head == "Self" { return selfDeclarations(components, from: site) }
        guard let bareName = components.last, !bareName.isEmpty else { return [] }
        let written = components.joined(separator: ".")
        let meant = aliasesSeen.contains(head) ? (candidates: [], isCertain: false) : aliases(named: head, from: site)

        var found: [Int] = []
        if let site {
            let chain = Self.enclosingTypeChain(of: site)
            // Certain only in the innermost declaration, and only when nothing at the site can
            // shadow the head: there no extension context and no superclass member stands between.
            if let innermost = chain.last, !innermost.isExtension, !Self.isShadowed(head, at: site) {
                found = indices(bareName).filter {
                    declarations[$0].qualifiedName == innermost.name + "." + written
                }
                if !found.isEmpty, !meant.isCertain { return found }
            }
            // An alias the innermost declaration declares shadows every outer namesake.
            if !meant.isCertain {
                for scope in reachableScopes(from: site, chain: chain) {
                    let qualified = scope.isEmpty ? written : scope + "." + written
                    found += indices(bareName).filter {
                        declarations[$0].qualifiedName == qualified && !found.contains($0)
                    }
                }
            }
        } else {
            found = indices(bareName).filter {
                declarations[$0].qualifiedName == written || declarations[$0].qualifiedName.hasSuffix("." + written)
            }
        }

        // A typealias heading the spelling: what it stands for, read where the alias is written.
        for alias in meant.candidates {
            let expanded = alias.target + components.dropFirst()
            found += declarations(
                named: expanded, from: alias.site, depth: depth + 1, aliasesSeen: aliasesSeen.union([head])
            )
                .filter { !found.contains($0) }
        }
        // A head nothing reachable names — a module, or a type this table does not record.
        if found.isEmpty, components.count > 1 {
            return declarations(
                named: Array(components.dropFirst()), from: site, depth: depth + 1, aliasesSeen: aliasesSeen
            )
        }
        return found
    }

    /// The scopes a name written at `site` can resolve in, innermost first: each enclosing type, the
    /// function bodies within it, its outer types when it is an extended nested type, the
    /// superclasses of a class, and the top level.
    func reachableScopes(from site: Syntax, chain: [(name: String, isExtension: Bool)]) -> [String] {
        var scopes: [String] = []
        func add(_ scope: String) { if !scopes.contains(scope) { scopes.append(scope) } }
        let bodies = Self.bodiesCrossed(from: site)
        for (level, entry) in chain.reversed().enumerated() {
            add(entry.name)
            // A function's local types are reachable only from inside that function's body.
            if level < bodies.count, bodies[level] { add(entry.name + ".<local>") }
            if entry.isExtension {
                var parts = entry.name.split(separator: ".").map(String.init)
                while parts.count > 1 {
                    parts.removeLast()
                    add(parts.joined(separator: "."))
                }
            }
            for supertype in superclassNames(ofQualified: entry.name) { add(supertype) }
        }
        if bodies.count > chain.count, bodies[chain.count] { add("<local>") }
        add("")
        return scopes
    }

    /// For each type enclosing `site`, innermost first, and then the top level: whether a function
    /// body lies between it and `site` — where that scope's local types are in reach.
    static func bodiesCrossed(from site: Syntax) -> [Bool] {
        var result: [Bool] = []
        var crossed = false
        var current = site.parent
        while let ancestor = current {
            if TypeShapeCollector.declaredName(of: ancestor) != nil {
                result.append(crossed)
                crossed = false
            } else if TypeShapeCollector.isFunctionLike(ancestor) {
                crossed = true
            }
            current = ancestor.parent
        }
        result.append(crossed)
        return result
    }

    /// The qualified names of every class `qualifiedName` inherits from, transitively.
    private func superclassNames(ofQualified qualifiedName: String) -> [String] {
        var result: [String] = []
        var frontier = [qualifiedName]
        while let current = frontier.popLast() {
            let bare = current.split(separator: ".").last.map(String.init) ?? current
            for index in indices(bare) where declarations[index].qualifiedName == current {
                for inherited in declarations[index].inheritedNames {
                    for parent in indices(inherited) where declarations[parent].kind == .classOrActor {
                        let name = declarations[parent].qualifiedName
                        if !result.contains(name) {
                            result.append(name)
                            frontier.append(name)
                        }
                    }
                }
            }
        }
        return result
    }

    /// Whether something declared at `site` — a generic parameter, or a type or typealias local to
    /// an enclosing body — binds `name` ahead of a member type.
    static func isShadowed(_ name: String, at site: Syntax) -> Bool {
        var current: Syntax? = site
        while let ancestor = current {
            if let clause = genericParameters(of: ancestor),
               clause.parameters.contains(where: { $0.name.text == name }) {
                return true
            }
            if let items = ancestor.as(CodeBlockItemListSyntax.self) {
                for item in items {
                    guard case .decl(let decl) = item.item else { continue }
                    if localTypeName(of: decl) == name { return true }
                }
            }
            current = ancestor.parent
        }
        return false
    }

    private static func genericParameters(of node: Syntax) -> GenericParameterClauseSyntax? {
        if let decl = node.as(FunctionDeclSyntax.self) { return decl.genericParameterClause }
        if let decl = node.as(InitializerDeclSyntax.self) { return decl.genericParameterClause }
        if let decl = node.as(SubscriptDeclSyntax.self) { return decl.genericParameterClause }
        if let decl = node.as(StructDeclSyntax.self) { return decl.genericParameterClause }
        if let decl = node.as(ClassDeclSyntax.self) { return decl.genericParameterClause }
        if let decl = node.as(EnumDeclSyntax.self) { return decl.genericParameterClause }
        if let decl = node.as(ActorDeclSyntax.self) { return decl.genericParameterClause }
        return nil
    }

    private static func localTypeName(of decl: DeclSyntax) -> String? {
        if let alias = decl.as(TypeAliasDeclSyntax.self) { return alias.name.text }
        if let type = decl.as(StructDeclSyntax.self) { return type.name.text }
        if let type = decl.as(ClassDeclSyntax.self) { return type.name.text }
        if let type = decl.as(EnumDeclSyntax.self) { return type.name.text }
        if let type = decl.as(ActorDeclSyntax.self) { return type.name.text }
        return nil
    }

    // MARK: - Typealiases

    /// The typealiases `name` written at `site` can mean, the lexically nearest first. Certain —
    /// the aliases the innermost enclosing *declaration* (not an extension) declares, and nothing
    /// else — under the rule that makes a type name certain; otherwise every alias of that name,
    /// wherever it is declared, since which one Swift picks can turn on a conformance, a
    /// superclass or a module. Collection order never decides. With no `site`, every alias.
    func aliases(named name: String, from site: Syntax?) -> (candidates: [AliasDeclaration], isCertain: Bool) {
        let all = aliases[name] ?? []
        guard let site, !all.isEmpty else { return (all, false) }
        let chain = Self.enclosingTypeChain(of: site)
        if let innermost = chain.last, !innermost.isExtension, !Self.isShadowed(name, at: site) {
            let own = all.filter { $0.scope == innermost.name }
            if !own.isEmpty { return (own, true) }
        }
        let scopes = reachableScopes(from: site, chain: chain)
        let rank = { (alias: AliasDeclaration) in scopes.firstIndex(of: alias.scope) ?? scopes.count }
        let nearestFirst = all.enumerated().sorted { lhs, rhs in
            (rank(lhs.element), lhs.offset) < (rank(rhs.element), rhs.offset)
        }
        return (nearestFirst.map(\.element), false)
    }

    /// Every spelling `components` written at `site` may stand for once typealiases are followed:
    /// each target of each alias its head can mean, read where that alias is written and followed
    /// in turn — and the spelling itself, unless an alias certainly binds its head. An alias
    /// declared in one type never takes the name from another, where it may mean a framework type.
    func spellings(of components: [String], from site: Syntax?, aliasesSeen: Set<String> = []) -> [[String]] {
        guard let head = components.first, !aliasesSeen.contains(head) else { return [components] }
        let meant = aliases(named: head, from: site)
        var result = meant.isCertain ? [] : [components]
        for alias in meant.candidates {
            let expanded = alias.target + components.dropFirst()
            for spelling in spellings(of: expanded, from: alias.site, aliasesSeen: aliasesSeen.union([head]))
            where !result.contains(spelling) {
                result.append(spelling)
            }
        }
        return result
    }

    // MARK: - Self and supertypes

    /// What `Self` can be where `site` is written: the enclosing type (through a typealias, and as
    /// a protocol's conformers when the name is also a protocol's), every subclass of a non-final
    /// class, and every conformer in a protocol extension.
    private func selfDeclarations(_ components: [String], from site: Syntax?) -> [Int] {
        guard let site, let innermost = Self.enclosingTypeChain(of: site).last else { return [] }
        let bare = innermost.name.split(separator: ".").last.map(String.init) ?? innermost.name
        var selves = indices(bare).filter { declarations[$0].qualifiedName == innermost.name }
        if selves.isEmpty {
            selves = (aliases[bare] ?? []).flatMap { declarations(named: $0.target, from: $0.site) }
        }
        if selves.isEmpty, !protocolNames.contains(bare) { selves = indices(bare) }
        if protocolNames.contains(bare) {
            selves += conformers(of: bare).filter { !selves.contains($0) }
        }
        for index in selves where declarations[index].kind == .classOrActor && !declarations[index].isFinal {
            selves += subtypes(of: [declarations[index].bareName]).filter { !selves.contains($0) }
        }
        guard components.count > 1 else { return selves }
        let rest = components.dropFirst().joined(separator: ".")
        return selves.flatMap { index in
            let qualified = declarations[index].qualifiedName + "." + rest
            return declarations(named: qualified.split(separator: ".").map(String.init), from: nil)
        }
    }

    /// Every declaration conforming to `protocolName`, directly or through a protocol that
    /// inherits it. Works for a protocol the package does not declare too: whoever names it in an
    /// inheritance clause conforms.
    func conformers(of protocolName: String) -> [Int] {
        var protocols: Set<String> = [protocolName]
        var grew = true
        while grew {
            grew = false
            for (name, parents) in protocolParents
            where !protocols.contains(name) && parents.contains(where: protocols.contains) {
                protocols.insert(name)
                grew = true
            }
        }
        return subtypes(of: protocols)
    }

    /// Every declaration inheriting from one of `names`, transitively.
    func subtypes(of names: Set<String>) -> [Int] {
        var found: [Int] = []
        var frontier = names
        var seen = names
        while !frontier.isEmpty {
            var next: Set<String> = []
            for (index, declaration) in declarations.enumerated()
            where declaration.inheritedNames.contains(where: frontier.contains) && !found.contains(index) {
                found.append(index)
                if seen.insert(declaration.bareName).inserted { next.insert(declaration.bareName) }
            }
            frontier = next
        }
        return found
    }

    /// The classes `declaration` could inherit from — a struct or enum named in its inheritance
    /// clause is a protocol's namesake, never a superclass.
    func superclasses(of declaration: ConstructionDeclaration) -> [(name: String, candidates: [Int])] {
        declaration.inheritedNames.map { inherited in
            (inherited, declarations(named: [inherited], from: declaration.site)
                .filter { declarations[$0].kind == .classOrActor && $0 != indexOf(declaration) })
        }
    }

    private func indexOf(_ declaration: ConstructionDeclaration) -> Int? {
        indices(declaration.bareName).first { declarations[$0].site == declaration.site }
    }

    /// The superclasses of the class enclosing `site` — what `super.init(…)` constructs.
    func superclassCandidates(enclosing site: Syntax) -> [Int] {
        guard let innermost = Self.enclosingTypeChain(of: site).last else { return [] }
        let bare = innermost.name.split(separator: ".").last.map(String.init) ?? innermost.name
        let owners = indices(bare).filter { declarations[$0].qualifiedName == innermost.name }
        return (owners.isEmpty ? indices(bare) : owners).flatMap { owner in
            superclasses(of: declarations[owner]).flatMap(\.candidates)
        }
    }
}

// MARK: - What a construction incurs

extension ConstructionFacts {

    /// The refutation a call incurs on any of `candidates`, or `nil`.
    ///
    /// A class also reaches the designated initializers it inherits — all of them when it declares
    /// none of its own. When no initializer a candidate has accepts the call, it reached one this
    /// table cannot see, and any doubt refutes: the candidate answers with anything constructing
    /// it can run — except an enum's synthesized `init(rawValue:)`. `strict` is for a guess at the
    /// type by shape alone: it judges only candidates the call can fit.
    func refutation(constructing candidates: [Int], call: CallShape, strict: Bool = false) -> PurityRefutation? {
        var visited: Set<Int> = []
        return refutation(constructing: candidates, call: call, strict: strict, visited: &visited)
    }

    private func refutation(
        constructing candidates: [Int],
        call: CallShape,
        strict: Bool,
        visited: inout Set<Int>
    ) -> PurityRefutation? {
        for index in candidates where visited.insert(index).inserted {
            let declaration = declarations[index]
            if strict, !mayFit(call, index) { continue }
            if let unconditional = declaration.unconditional { return unconditional }
            let accepting = declaration.accepting(call)
            for initializer in accepting {
                if let found = initializer.refutation(for: call) { return found }
            }
            if declaration.kind == .classOrActor, declaration.inheritsDesignatedInitializers || accepting.isEmpty {
                for (name, supers) in superclasses(of: declaration) {
                    if let cause = refutation(constructing: supers, call: call, strict: false, visited: &visited) {
                        return declaration.refuted(via: .superclass(name), cause)
                    }
                }
            }
            guard accepting.isEmpty, !strict else { continue }
            if declaration.kind == .enumeration, call.labels == ["rawValue"] { continue }
            if let any = declaration.anyRefutation { return any }
        }
        return nil
    }

    /// Whether `call` could be a construction of the declaration at `index`: one of its own
    /// initializers fits, or it inherits one that may — from a superclass in the package, or from
    /// one outside it, which could take anything.
    private func mayFit(_ call: CallShape, _ index: Int, depth: Int = 0) -> Bool {
        let declaration = declarations[index]
        if !declaration.accepting(call).isEmpty { return true }
        guard declaration.inheritsDesignatedInitializers, depth < 8 else { return false }
        let supers = superclasses(of: declaration).flatMap(\.candidates)
        if supers.isEmpty { return !declaration.inheritedNames.isEmpty }
        return supers.contains { mayFit(call, $0, depth: depth + 1) }
    }

    /// What `T.init` — or `T.init(label:…)`, when `labels` is given — runs called as a function
    /// value, following the initializers a class inherits.
    func referenceRefutation(_ index: Int, labels: [String]?, depth: Int = 0) -> PurityRefutation? {
        let declaration = declarations[index]
        if let unconditional = declaration.unconditional { return unconditional }
        let matching = declaration.initializers.filter { labels == nil || $0.parameters.map(\.label) == labels }
        if let found = matching.lazy.compactMap({ $0.referenceRefutation(labels: labels) }).first { return found }
        if declaration.kind == .classOrActor, depth < 8,
           declaration.inheritsDesignatedInitializers || matching.isEmpty {
            for (name, supers) in superclasses(of: declaration) {
                let causes = supers.lazy.compactMap { self.referenceRefutation($0, labels: labels, depth: depth + 1) }
                if let cause = causes.first {
                    return declaration.refuted(via: .superclass(name), cause)
                }
            }
        }
        if labels != nil, matching.isEmpty { return declaration.anyRefutation }
        return nil
    }

    /// What decoding the declaration at `index` runs: `init(from:)`, its own, inherited or the
    /// synthesized one — which like any non-memberwise initializer runs the stored defaults first —
    /// and the decoding of every type its stored properties hold.
    func decodeRefutation(_ index: Int, visited: inout Set<Int>) -> PurityRefutation? {
        guard visited.insert(index).inserted else { return nil }
        let declaration = declarations[index]
        if let own = declaration.unconditional ?? declaration.conditionalStoredDefault { return own }
        // Every one: `#if` branches may each declare their own.
        let decoders = declaration.initializers.filter { $0.parameters.map(\.label) == ["from"] }
        if let body = decoders.lazy.compactMap(\.bodyRefutation).first {
            return body
        }
        if declaration.kind == .classOrActor {
            for (name, supers) in superclasses(of: declaration) {
                for parent in supers {
                    if let cause = decodeRefutation(parent, visited: &visited) {
                        return declaration.refuted(via: .superclass(name), cause)
                    }
                }
            }
        }
        for (property, types) in (memberTypes[declaration.qualifiedName] ?? [:]).sorted(by: { $0.key < $1.key }) {
            for member in types where member.declaration == declaration.site {
                for components in Self.decodedComponents(of: member.type) {
                    for held in declarations(named: components, from: Self.memberSite(of: declaration.site)) {
                        if let cause = decodeRefutation(held, visited: &visited) {
                            return declaration.refuted(via: .storedProperty(property), cause)
                        }
                    }
                }
            }
        }
        return nil
    }

    /// The types a decoded value of `type` is built from: the type itself, or the elements of an
    /// optional, array, dictionary or other generic container.
    static func decodedComponents(of type: TypeSyntax) -> [[String]] {
        if let optional = type.as(OptionalTypeSyntax.self) { return decodedComponents(of: optional.wrappedType) }
        if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return decodedComponents(of: unwrapped.wrappedType)
        }
        if let array = type.as(ArrayTypeSyntax.self) { return decodedComponents(of: array.element) }
        if let dictionary = type.as(DictionaryTypeSyntax.self) { return decodedComponents(of: dictionary.value) }
        if let identifier = type.as(IdentifierTypeSyntax.self), let generics = identifier.genericArgumentClause {
            let arguments = generics.arguments.compactMap { $0.argument.as(TypeSyntax.self) }
            return [[identifier.name.text]] + arguments.flatMap(decodedComponents)
        }
        return TypeShapeCollector.components(of: type).map { [$0] } ?? []
    }
}

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
