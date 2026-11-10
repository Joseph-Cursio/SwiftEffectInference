import SwiftSyntax

/// What a lookup finds — declarations, or the scopes and superclasses it reads — each once, in
/// the order first found.
///
/// Once is all any reader needs: each takes the first candidate that answers, or skips one already
/// visited. And it bounds an answer by what there is to find. Kept with repeats, an answer through
/// `Self` held each namesake's members once per namesake, and each typealias over it multiplied
/// that again: in the compiler's tests, a lookup of `B` among 6,300 declarations found 9,800, and
/// two thousand files did not build in 8 GB.
struct FirstFound<Element: Hashable> {
    private(set) var list: [Element] = []
    private var held: Set<Element> = []

    var isEmpty: Bool { list.isEmpty }

    mutating func merge(_ more: [Element]) {
        for element in more where held.insert(element).inserted { list.append(element) }
    }
}

// MARK: - Which declarations a spelling can mean

extension ConstructionFacts {

    func indices(_ bareName: String) -> [Int] { indicesByBareName[bareName] ?? [] }

    /// `indices(bareName)` whose qualified name is `qualifiedName`, in the same order.
    func indices(_ bareName: String, qualified qualifiedName: String) -> [Int] {
        indicesByQualifiedName[bareName]?[qualifiedName] ?? []
    }

    /// The declarations `components` (as written, `["Outer", "Inner"]`) could name from `site`,
    /// the lexically preferred first. With no `site`, every declaration the spelling could mean.
    ///
    /// Asked once per scope: the answer is kept in the memo for every site that reads the same
    /// scope (`LookupKey`). A resolution that comes back to itself with the same arguments —
    /// through `Self`, whose expansion starts the depth bound afresh — would never end; that inner
    /// lookup names nothing, and the rest of the answer stands.
    ///
    /// The aliases seen are not started afresh by `Self`: an alias is never expanded inside its
    /// own expansion, as Swift never does. When `Self` dropped them, `typealias F = Self.E` in a
    /// protocol that a type named `F` conforms to read `F` as `Self.E`, `F.E` as `Self.E.E`, and so
    /// on — a new lookup every time, so nothing cut it, until the stack ran out.
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
        let settled = self.memo.settled.lookups
        if !settled.isEmpty, let known = settled[key] { return known }
        if let known = memo.lookups[key] { return known }
        guard memo.beginLookup(key) else { return [] }
        let found = resolve(components, from: site, depth: depth, aliasesSeen: aliasesSeen)
        memo.endLookup(key, found: found)
        return found
    }

    private func resolve(_ components: [String], from site: Syntax?, depth: Int, aliasesSeen: Set<String>) -> [Int] {
        guard let head = components.first, !head.isEmpty, depth < 6 else { return [] }
        if head == "Self" { return selfDeclarations(components, from: site, aliasesSeen: aliasesSeen) }
        guard let bareName = components.last, !bareName.isEmpty else { return [] }
        let written = components.joined(separator: ".")
        let meant = aliasesSeen.contains(head) ? (candidates: [], isCertain: false) : aliases(named: head, from: site)

        var found = FirstFound<Int>()
        if let site {
            let chain = Self.enclosingTypeChain(of: site)
            // Certain only in the innermost declaration, and only when nothing at the site can
            // shadow the head: there no extension context and no superclass member stands between.
            if let innermost = chain.last, !innermost.isExtension, !Self.isShadowed(head, at: site) {
                found.merge(indices(bareName, qualified: innermost.name + "." + written))
                if !found.isEmpty, !meant.isCertain { return found.list }
            }
            // An alias the innermost declaration declares shadows every outer namesake.
            if !meant.isCertain {
                for scope in reachableScopes(from: site, chain: chain) {
                    found.merge(indices(bareName, qualified: scope.isEmpty ? written : scope + "." + written))
                }
            }
        } else {
            found.merge(indices(bareName).filter {
                declarations[$0].qualifiedName == written || declarations[$0].qualifiedName.hasSuffix("." + written)
            })
        }

        // A typealias heading the spelling: what it stands for, read where the alias is written.
        for alias in meant.candidates {
            let expanded = alias.target + components.dropFirst()
            found.merge(declarations(
                named: expanded, from: alias.site, depth: depth + 1, aliasesSeen: aliasesSeen.union([head])
            ))
        }
        // A head nothing reachable names — a module, or a type this table does not record.
        if found.isEmpty, components.count > 1 {
            return declarations(
                named: Array(components.dropFirst()), from: site, depth: depth + 1, aliasesSeen: aliasesSeen
            )
        }
        return found.list
    }

    /// The scopes a name written at `site` can resolve in, innermost first: each enclosing type, the
    /// function bodies within it, its outer types when it is an extended nested type, the
    /// superclasses of a class, and the top level.
    func reachableScopes(from site: Syntax, chain: [(name: String, isExtension: Bool)]) -> [String] {
        // A class's superclasses can be many — every namesake of each — so each is kept once by a set.
        var scopes = FirstFound<String>()
        func add(_ scope: String) { scopes.merge([scope]) }
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
        return scopes.list
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
    ///
    /// Asked for every type enclosing every lookup, so it costs what it finds, not what shares a
    /// name with it: each name's direct superclasses are worked out once, with the table. Passing
    /// every namesake of each class and of each superclass it names cost the product of the two —
    /// in the compiler's tests, a thousand `class B: A` among 1,700 `class A` — for every lookup
    /// in every `B`.
    private func superclassNames(ofQualified qualifiedName: String) -> [String] {
        var result: [String] = []
        var found: Set<String> = []
        var frontier = [qualifiedName]
        while let current = frontier.popLast() {
            let bare = current.split(separator: ".").last.map(String.init) ?? current
            for name in superclassNamesByQualifiedName[bare]?[current] ?? [] where found.insert(name).inserted {
                result.append(name)
                frontier.append(name)
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
    /// each target of each alias its head can mean, and of each alias a later component names as
    /// a member of what precedes it (`Outer.Stamp`, wherever an `Outer` declares `Stamp`), read
    /// where that alias is written and followed in turn — and the spelling itself, unless an alias
    /// certainly binds its head. An alias declared in one type never takes the name from another,
    /// where it may mean a framework type.
    func spellings(of components: [String], from site: Syntax?, aliasesSeen: Set<String> = []) -> [[String]] {
        guard let head = components.first, !aliasesSeen.contains(head) else { return [components] }
        let meant = aliases(named: head, from: site)
        var result = meant.isCertain ? [] : [components]
        var expansions = meant.candidates.map { (name: head, alias: $0, rest: Array(components.dropFirst())) }
        for position in components.indices.dropFirst() where !aliasesSeen.contains(components[position]) {
            let owner = components[..<position].joined(separator: ".")
            for alias in aliases[components[position]] ?? []
            where alias.scope == owner || alias.scope.hasSuffix("." + owner) {
                expansions.append((components[position], alias, Array(components[(position + 1)...])))
            }
        }
        for (name, alias, rest) in expansions {
            for spelling in spellings(of: alias.target + rest, from: alias.site, aliasesSeen: aliasesSeen.union([name]))
            where !result.contains(spelling) {
                result.append(spelling)
            }
        }
        return result
    }

    // MARK: - Self and supertypes

    /// What `Self` can be where `site` is written: the enclosing type (through a typealias, and as
    /// a protocol's conformers when the name is also a protocol's), every subclass of a non-final
    /// class, and every conformer in a protocol extension. The lookups it asks in turn keep
    /// `aliasesSeen`, the aliases whose expansion led here.
    private func selfDeclarations(_ components: [String], from site: Syntax?, aliasesSeen: Set<String>) -> [Int] {
        guard let site, let innermost = Self.enclosingTypeChain(of: site).last else { return [] }
        let bare = innermost.name.split(separator: ".").last.map(String.init) ?? innermost.name
        var selves = FirstFound<Int>()
        selves.merge(indices(bare, qualified: innermost.name))
        if selves.isEmpty {
            for alias in aliases[bare] ?? [] {
                selves.merge(declarations(named: alias.target, from: alias.site, aliasesSeen: aliasesSeen))
            }
        }
        if selves.isEmpty, !protocolNames.contains(bare) { selves.merge(indices(bare)) }
        if protocolNames.contains(bare) { selves.merge(conformers(of: bare)) }
        // A namesake's subclasses are its namesake's: each name is widened once.
        var widened: Set<String> = []
        for index in selves.list where declarations[index].kind == .classOrActor && !declarations[index].isFinal
            && widened.insert(declarations[index].bareName).inserted {
            selves.merge(subtypes(of: [declarations[index].bareName]))
        }
        guard components.count > 1 else { return selves.list }
        // And a namesake of the same qualified name has the same members: each is asked once.
        let rest = components.dropFirst().joined(separator: ".")
        var members = FirstFound<Int>()
        var asked: Set<String> = []
        for index in selves.list where asked.insert(declarations[index].qualifiedName).inserted {
            let qualified = declarations[index].qualifiedName + "." + rest
            members.merge(declarations(
                named: qualified.split(separator: ".").map(String.init), from: nil, aliasesSeen: aliasesSeen
            ))
        }
        return members.list
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

    /// Every declaration inheriting from one of `names`, transitively — each level in the order
    /// the declarations were collected.
    ///
    /// Asked for `Self` in every class and protocol extension, so it costs what it finds: each
    /// level's declarations are read from the table by the names they inherit, where passing every
    /// declaration cost the size of the package for each `Self`.
    func subtypes(of names: Set<String>) -> [Int] {
        var found: [Int] = []
        var held: Set<Int> = []
        var frontier = names
        var seen = names
        while !frontier.isEmpty {
            var next: Set<String> = []
            let level = Set(frontier.flatMap { indicesByInheritedName[$0] ?? [] }).subtracting(held).sorted()
            for index in level {
                found.append(index)
                held.insert(index)
                let bareName = declarations[index].bareName
                if seen.insert(bareName).inserted { next.insert(bareName) }
            }
            frontier = next
        }
        return found
    }

    /// The classes `declaration` could inherit from — a struct or enum named in its inheritance
    /// clause is a protocol's namesake, never a superclass.
    ///
    /// Its own index is found once, and from the table: it is asked of each candidate a
    /// construction tries, and passing every namesake to find it, each time, cost the cube of a
    /// name's namesakes over a build — the swift compiler's tests declare `class B: A` a thousand
    /// times, among 1,700 `class A`.
    func superclasses(of declaration: ConstructionDeclaration) -> [(name: String, candidates: [Int])] {
        let own = indexOf(declaration)
        return declaration.inheritedNames.map { inherited in
            (inherited, declarations(named: [inherited], from: declaration.site)
                .filter { declarations[$0].kind == .classOrActor && $0 != own })
        }
    }

    /// The first declaration collected at `declaration`'s site — itself, in this table.
    private func indexOf(_ declaration: ConstructionDeclaration) -> Int? {
        indicesBySite[declaration.site]
    }

    /// The superclasses of the class enclosing `site` — what `super.init(…)` constructs.
    func superclassCandidates(enclosing site: Syntax) -> [Int] {
        guard let innermost = Self.enclosingTypeChain(of: site).last else { return [] }
        let bare = innermost.name.split(separator: ".").last.map(String.init) ?? innermost.name
        let owners = indices(bare, qualified: innermost.name)
        var found = FirstFound<Int>()
        for owner in owners.isEmpty ? indices(bare) : owners {
            for (_, candidates) in superclasses(of: declarations[owner]) { found.merge(candidates) }
        }
        return found.list
    }
}
