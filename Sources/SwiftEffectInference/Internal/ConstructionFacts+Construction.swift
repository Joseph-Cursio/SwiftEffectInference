import SwiftSyntax

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
            if let inherited = inheritedRefutation(
                of: declaration, accepting: accepting, call: call, visited: &visited
            ) {
                return inherited
            }
            guard accepting.isEmpty, !strict else { continue }
            if declaration.kind == .enumeration, call.labels == ["rawValue"] { continue }
            if let any = declaration.anyRefutation { return any }
        }
        return nil
    }

    /// The refutation a call incurs through the designated initializers a class inherits — all of
    /// them when none of its own accepts the call — or `nil`.
    private func inheritedRefutation(
        of declaration: ConstructionDeclaration,
        accepting: [ConstructionInitializer],
        call: CallShape,
        visited: inout Set<Int>
    ) -> PurityRefutation? {
        if declaration.kind == .classOrActor, declaration.inheritsDesignatedInitializers || accepting.isEmpty {
            for (name, supers) in superclasses(of: declaration) {
                if let cause = refutation(constructing: supers, call: call, strict: false, visited: &visited) {
                    return declaration.refuted(via: .superclass(name), cause)
                }
            }
        }
        return nil
    }

    /// Whether `call` could be a construction of the declaration at `index`: one of its own
    /// initializers fits, or it inherits one that may — from a superclass in the package, or from
    /// one outside it, which could take anything.
    ///
    /// Answered once per declaration and depth for a call shape: with a namesake at every level,
    /// the paths up the superclasses double at each one, and the declarations on them do not.
    /// The depth bound is what ends a cycle of superclasses, so it is part of the question.
    private func mayFit(_ call: CallShape, _ index: Int, depth: Int = 0) -> Bool {
        guard let memo = memo.instance else { return memoised().mayFit(call, index, depth: depth) }
        let key = FitKey(call: call, index: index, depth: depth)
        if let known = memo.fits[key] { return known }
        let fits = fitsUnmemoised(call, index, depth: depth)
        memo.fits[key] = fits
        return fits
    }

    private func fitsUnmemoised(_ call: CallShape, _ index: Int, depth: Int) -> Bool {
        let declaration = declarations[index]
        if !declaration.accepting(call).isEmpty { return true }
        guard declaration.inheritsDesignatedInitializers, depth < 8 else { return false }
        let supers = superclasses(of: declaration).flatMap(\.candidates)
        if supers.isEmpty { return !declaration.inheritedNames.isEmpty }
        return supers.contains { mayFit(call, $0, depth: depth + 1) }
    }

    /// What `T.init` — or `T.init(label:…)`, when `labels` is given — runs called as a function
    /// value, following the initializers a class inherits.
    ///
    /// Answered once per declaration and depth, for the reason `mayFit` is.
    func referenceRefutation(_ index: Int, labels: [String]?, depth: Int = 0) -> PurityRefutation? {
        guard let memo = memo.instance else {
            return memoised().referenceRefutation(index, labels: labels, depth: depth)
        }
        let key = ReferenceKey(index: index, labels: labels, depth: depth)
        if let known = memo.references[key] { return known }
        let found = referenceUnmemoised(index, labels: labels, depth: depth)
        memo.references.updateValue(found, forKey: key)
        return found
    }

    private func referenceUnmemoised(_ index: Int, labels: [String]?, depth: Int) -> PurityRefutation? {
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
    ///
    /// Searched depth first through its superclasses and then its stored properties, each
    /// declaration once, and the first refutation found is the witness. Answered once per
    /// declaration in a pass: every decode site of a type asks the same question, and only a new
    /// pass can change the answer.
    func decodeRefutation(_ index: Int) -> PurityRefutation? {
        guard let memo = memo.instance else { return memoised().decodeRefutation(index) }
        if let known = memo.decodes[index] { return known }
        var visited: Set<Int> = []
        let found = decodeSearch(index, visited: &visited, memo: memo).refutation
        // A search from one declaration that finds nothing went everywhere its decoding reaches.
        if found == nil { memo.undecodable.formUnion(visited) }
        memo.decodes.updateValue(found, forKey: index)
        return found
    }

    /// The search under `decodeRefutation(_:)`, and whether it proved `index` reaches no refutation
    /// by any path. A declaration skipped as visited may yet reach one — it is still being
    /// searched, above — so a search that skipped one proves nothing. One that skipped only
    /// declarations already proved undecodable does, and those are skipped without searching:
    /// whatever they would mark visited reaches nothing either, so no later step can tell.
    private func decodeSearch(
        _ index: Int,
        visited: inout Set<Int>,
        memo: ConstructionMemo
    ) -> (refutation: PurityRefutation?, reachesNothing: Bool) {
        if memo.undecodable.contains(index) { return (nil, true) }
        guard visited.insert(index).inserted else { return (nil, false) }
        memo.decodeSteps += 1
        let declaration = declarations[index]
        if let own = declaration.unconditional ?? declaration.conditionalStoredDefault { return (own, false) }
        // Every one: `#if` branches may each declare their own.
        let decoders = declaration.initializers.filter { $0.parameters.map(\.label) == ["from"] }
        if let body = decoders.lazy.compactMap(\.bodyRefutation).first {
            return (body, false)
        }
        var reachesNothing = true
        for edge in decodeEdges(of: index, memo: memo) {
            let held = decodeSearch(edge.held, visited: &visited, memo: memo)
            if let cause = held.refutation { return (declaration.refuted(via: edge.step, cause), false) }
            reachesNothing = reachesNothing && held.reachesNothing
        }
        if reachesNothing { memo.undecodable.insert(index) }
        return (nil, reachesNothing)
    }

    /// The declarations decoding the one at `index` decodes in turn, in the order they are
    /// searched: its superclasses, then each stored property's types, by property name. Read from
    /// names and stored-property types alone, so kept for the whole build.
    private func decodeEdges(of index: Int, memo: ConstructionMemo) -> [DecodeEdge] {
        if let known = self.memo.settled.decodeEdges[index] ?? memo.decodeEdges[index] { return known }
        let declaration = declarations[index]
        var edges: [DecodeEdge] = []
        if declaration.kind == .classOrActor {
            for (name, supers) in superclasses(of: declaration) {
                edges += supers.map { DecodeEdge(step: .superclass(name), held: $0) }
            }
        }
        for (property, types) in (memberTypes[declaration.qualifiedName] ?? [:]).sorted(by: { $0.key < $1.key }) {
            for member in types where member.declaration == declaration.site {
                for components in Self.decodedComponents(of: member.type) {
                    let held = declarations(named: components, from: Self.memberSite(of: declaration.site))
                    edges += held.map { DecodeEdge(step: .storedProperty(property), held: $0) }
                }
            }
        }
        memo.decodeEdges[index] = edges
        return edges
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
