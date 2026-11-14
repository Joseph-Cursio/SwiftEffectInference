extension PackageNames {

    /// What stays fixed while `init` decides which declarations to leave out: the containers whose
    /// members are open, the path of every declared type or alias, and the scopes that are no type
    /// the package declares (an SDK type's extension).
    struct Admission {
        let openPaths: Set<String>
        let anyType: Set<String>
        let sdkScopes: Set<String>

        init(entries: [PackageNameEntry], openContainers: Set<String>) {
            openPaths = openContainers.union(
                entries.lazy.filter { $0.isType && ($0.isGeneric || $0.isProtocol) }.map(\.path)
            )
            anyType = Set(entries.lazy.filter(\.isType).map(\.path))
            sdkScopes = Set(entries.lazy.flatMap(\.scopes))
                .subtracting(entries.lazy.filter { $0.isType && !$0.isAlias }.map(\.path))
        }

        /// Whether `entry` is generic, inside a protocol, or inside an open container.
        func isOpen(_ entry: PackageNameEntry) -> Bool {
            entry.isGeneric || entry.isInsideProtocol
                || PackageNames.prefixes(of: entry.container).contains { openPaths.contains($0) }
        }
    }

    /// An initializer added to an SDK type, taking a foreign or defaulted or generic parameter, is
    /// reached by that type's own name: `String(caption: "Hi")`. The names of those SDK types.
    static func sdkTypesWithForeignInitializers(
        _ extensionInitializers: [String: Set<String>], declared declaredPaths: Set<String>, types: Set<String>
    ) -> Set<String> {
        var names: Set<String> = []
        for (container, mentions) in extensionInitializers where !declaredPaths.contains(container) {
            let foreign = mentions.contains {
                !InertVocabulary.typeNames.contains(Self.unqualified($0)) && !types.contains($0)
            }
            if foreign, let name = container.split(separator: ".").last { names.insert(String(name)) }
        }
        return names
    }

    /// Whether a left-out `entry`, reached by a spelling the vocabulary vouches for, could hand the
    /// body something it cannot see: anything that builds (a type, an alias, a case), an operator, a
    /// value or a call that is not inert, generic or wrapped, a call that can leave out a default
    /// or fill a variadic, or anything typed beyond the vocabulary (a function, an iterator, a key
    /// path, a package type). A plain `let value: String` of a `View` only reads.
    static func refuses(_ entry: PackageNameEntry) -> Bool {
        switch entry.shape {
        case .type, .enumCase:
            return true

        case .function(let parameters):
            if entry.isOperator || parameters.contains(where: { $0.hasDefault || $0.isVariadic }) { return true }

        case .value:
            break
        }
        let typed = entry.mentions.allSatisfy { InertVocabulary.typeNames.contains(unqualified($0)) }
        return !entry.isInert || entry.isGeneric || !entry.attributes.isEmpty || !typed
    }

    /// The names of the types whose construction runs a default that is not inert, or that spells a
    /// name the package left out: and to a fixpoint, their subclasses (which inherit the
    /// initializers) and the aliases to any of them.
    static func unconstructible(
        _ construction: Construction,
        refused: Set<String>,
        entries: [PackageNameEntry],
        supertypes: [String: Set<String>]
    ) -> Set<String> {
        let declared = Set(entries.lazy.map(\.path))
        var paths = construction.unconstructible.union(
            construction.defaultNames.filter { !$0.value.isDisjoint(with: refused) }.keys
        )
        var changed = !paths.isEmpty
        while changed {
            changed = false
            for (path, inherited) in supertypes where !paths.contains(path) && !inherited.isDisjoint(with: paths) {
                paths.insert(path)
                changed = true
            }
            for alias in entries where alias.isAlias && !paths.contains(alias.path) {
                guard let target = alias.aliasTarget?.joined(separator: ".") else { continue }
                let candidates = alias.scopes.reversed().map { $0 + "." + target } + [target]
                if candidates.contains(where: { declared.contains($0) && paths.contains($0) }) {
                    paths.insert(alias.path)
                    changed = true
                }
            }
        }
        return Set(paths.compactMap { $0.split(separator: ".").last.map(String.init) })
    }

    /// Whether nothing about `entry` itself leaves it out: open, not inert, foreign, wrapped, or an
    /// alias to a type that is not the package's.
    static func admits(
        _ entry: PackageNameEntry, types: Set<String>, shadowing: Set<String>, admission: Admission
    ) -> Bool {
        // What a type's members spell is resolved from inside it, where its nested types are.
        let scopes = entry.isType ? entry.scopes + [entry.path] : entry.scopes
        // Inside an SDK type's extension, a name may be one of its member types (`String.Comparator`),
        // which Swift finds first; and a type declared there is reached through them.
        let underSDK = entry.scopes.contains(where: admission.sdkScopes.contains)
        if underSDK, entry.isType { return false }
        let foreign = entry.mentions.contains { mention in
            // A name a left-out type or alias spells anywhere may be what Swift finds, through a
            // superclass's member types or an extension the lookup cannot place.
            if shadowing.contains(String(mention.split(separator: ".").first ?? "")) { return true }
            // The innermost declaration of the name decides, an alias or a left-out type among them:
            // `typealias Error = String.Comparator` inside a type is not the vocabulary's `Error`.
            if let picked = innermost(mention, from: scopes, in: admission.anyType) { return !types.contains(picked) }
            if underSDK {
                return !InertVocabulary.typeNames.contains(Self.unqualified(mention)) || mention.contains(".")
            }
            return !InertVocabulary.typeNames.contains(Self.unqualified(mention))
                && !reaches(mention, from: scopes, in: types)
        }
        // An attribute spelled like any package type, left out or not, is that type's code.
        let wrapped = entry.attributes.contains {
            !DateInertnessChecker.isInertName($0) || reaches($0, from: entry.scopes, in: admission.anyType)
        }
        let unresolvedAlias = entry.isAlias && !types.contains(entry.path)
        return !admission.isOpen(entry) && entry.isInert && !foreign && !wrapped && !unresolvedAlias
    }

    /// `Swift.Int` and `Foundation.Date` as `Int` and `Date`; any other path unchanged.
    private static func unqualified(_ mention: String) -> String {
        for module in ["Swift.", "Foundation."] where mention.hasPrefix(module) {
            return String(mention.dropFirst(module.count))
        }
        return mention
    }

    /// The types that inherit from or conform to an SDK type, and so inherit SDK initializers and
    /// members, to a fixpoint (a subclass of one inherits them too). `supertypes` are resolved: a
    /// package type by its path, anything else as spelled.
    static func inheritingForeign(
        _ types: Set<String>, entries: [PackageNameEntry], supertypes: [String: Set<String>]
    ) -> Set<String> {
        // `Identifiable` brings a class its `ObjectIdentifier(self)` default `id`, an address; and a
        // protocol refining it can be adopted by a class.
        let classes = Set(entries.lazy.filter { $0.isClass || $0.isProtocol }.map(\.path))
        let declared = Set(entries.lazy.map(\.path))
        // A conformance spelled like an inert protocol is that protocol only where the package
        // declares nothing of that name: a package `protocol Equatable` is not `Swift.Equatable`.
        let typeNames = Set(entries.lazy.filter(\.isType).map(\.name))
        var remaining = types
        var inheriting: Set<String> = []
        var changed = true
        while changed {
            let more = remaining.filter { path in
                (supertypes[path] ?? []).contains { supertype in
                    if declared.contains(supertype) { return !remaining.contains(supertype) }
                    let isStandard = inertConformances.contains(supertype)
                        || (supertype == "Identifiable" && !classes.contains(path))
                    return !isStandard || typeNames.contains(supertype)
                }
            }
            changed = !more.isEmpty
            remaining.subtract(more)
            inheriting.formUnion(more)
        }
        return inheriting
    }

    /// Each inheritance clause's names as the package paths they reach from the type's scopes,
    /// innermost first (`Outer.Base` inside `Outer` is never the top-level `Base`). A name more than
    /// one scope declares, the type's own nested types among them, is kept as every path it may be,
    /// so that each must pass. A name no scope declares is kept as spelled.
    static func resolve(
        _ supertypes: [String: Set<String>], entries: [PackageNameEntry], declared: Set<String>
    ) -> [String: Set<String>] {
        let scopes = Dictionary(entries.lazy.filter(\.isType).map { ($0.path, $0.scopes) }) { first, _ in first }
        return supertypes.reduce(into: [:]) { resolved, item in
            let (path, names) = item
            resolved[path] = Set(names.flatMap { name -> [String] in
                let candidates = ([path] + (scopes[path] ?? []).reversed()).map { $0 + "." + name } + [name]
                let reached = candidates.filter(declared.contains)
                return reached.isEmpty ? [name] : reached
            })
        }
    }

    /// Whether the type name `name`, spelled in a declaration whose lexical scopes are `scopes`, is
    /// one of `types`. Swift looks innermost first, so the first scope that declares the name decides.
    /// A nested `Box.Locale` does not make a bare `Locale` elsewhere the package's.
    private static func reaches(_ name: String, from scopes: [String], in types: Set<String>) -> Bool {
        types.contains(name) || scopes.contains { types.contains($0 + "." + name) }
    }

    /// The names of every declared type or alias the package leaves out.
    static func shadowingNames(anyType: Set<String>, types: Set<String>) -> Set<String> {
        Set(anyType.subtracting(types).compactMap { $0.split(separator: ".").last.map(String.init) })
    }

    /// The path of the innermost declaration of the type name `name` from `scopes`, or `nil`.
    private static func innermost(_ name: String, from scopes: [String], in declared: Set<String>) -> String? {
        (scopes.reversed().map { $0 + "." + name } + [name]).first(where: declared.contains)
    }

    /// `"A.B.C"` as `["A", "A.B", "A.B.C"]`; nothing for the top level.
    static func prefixes(of path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        for component in path.split(separator: ".") {
            current = current.isEmpty ? String(component) : current + "." + component
            result.append(current)
        }
        return result
    }

    /// The paths of the package's types, with each alias whose target is a package type, to a
    /// fixpoint. An alias with generic arguments has no target here: `Box<UUID>()` can build the
    /// `UUID`.
    static func resolveAliases(_ entries: [PackageNameEntry], declared: Set<String>) -> Set<String> {
        var types = Set(entries.lazy.filter { $0.isType && !$0.isAlias }.map(\.path))
        let aliases = entries.filter(\.isAlias)
        var changed = true
        while changed {
            changed = false
            for alias in aliases where !types.contains(alias.path) {
                guard let target = alias.aliasTarget?.joined(separator: ".") else { continue }
                // The innermost declaration of the name is the one Swift picks, resolved or not.
                let candidates = alias.scopes.reversed().map { $0 + "." + target } + [target]
                if let picked = candidates.first(where: declared.contains), types.contains(picked) {
                    types.insert(alias.path)
                    changed = true
                }
            }
        }
        return types
    }
}
