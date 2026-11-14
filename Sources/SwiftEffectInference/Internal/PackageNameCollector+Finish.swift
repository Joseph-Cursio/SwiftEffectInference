extension PackageNameCollector {

    func finish() -> PackageNames {
        for index in entries.indices where entries[index].isType && !entries[index].isAlias {
            let path = entries[index].path
            entries[index].mentions.formUnion(typeMentions[path] ?? [])
            if genericTypePaths.contains(path) { entries[index].isGeneric = true }
            if nonInertTypePaths.contains(path) { entries[index].isInert = false }
        }
        let declaredTypes = Set(entries.lazy.filter { $0.isType && !$0.isAlias }.map(\.path))
        let foreignNameless = hasForeignNamelessDefaults || !nonInertTypePaths.subtracting(declaredTypes).isEmpty
            || extensionCallables.contains { !$0.isEmpty && !declaredTypes.contains($0) }
            || addsForeignConformance(declaredTypes: declaredTypes)
            || extendsThroughAnotherPath(declaredTypes: declaredTypes)
            || addsForeignInitializer(declaredTypes: declaredTypes)
        return PackageNames(
            entries: entries, typeParameters: typeParameters, supertypes: supertypes,
            openContainers: genericTypePaths, rebindsLiterals: rebindsLiterals || foreignNameless,
            extensionInitializers: initializerMentions,
            construction: .init(unconstructible: unconstructibleTypePaths, defaultNames: initializerDefaultNames)
        )
    }

    /// Whether an extension gives a type that is not plainly one the package declares (an SDK type,
    /// an alias, a module-qualified path) a conformance that can bring members no body names: a
    /// protocol extension's `callAsFunction` makes `Date()()` or the literal `7()` callable, and a
    /// `Sequence` conformance makes `for x in date` run whatever its iterator does.
    private func addsForeignConformance(declaredTypes: Set<String>) -> Bool {
        let declaredNames = Set(entries.lazy.filter(\.isType).map(\.name))
        return extensionInheritance.contains { path, names in
            !declaredTypes.contains(path) && names.contains { name in
                declaredNames.contains(name) || !PackageNames.inertConformances.contains(name)
            }
        }
    }

    /// Whether an initializer added to a type the package does not declare takes a default, a generic
    /// or a foreign parameter: it is reached by spellings no name check ties to it (`[Int](slots:)`,
    /// `Int?(seeded:)`, `TimeInterval(jitter:)` for `Double`, `Int(seeded:)` from `BinaryInteger`).
    private func addsForeignInitializer(declaredTypes: Set<String>) -> Bool {
        initializerMentions.contains { container, mentions in
            !declaredTypes.contains(container) && mentions.contains { mention in
                mention == "default" || mention == "->" || !InertVocabulary.typeNames.contains(mention)
            }
        }
    }

    /// Whether an extension reaches a package type by another path (an alias, `Module.Shelf`), so that
    /// what it declares (`init`, a member alias) is recorded where no lookup from the type finds it.
    private func extendsThroughAnotherPath(declaredTypes: Set<String>) -> Bool {
        let aliases = Set(entries.lazy.filter(\.isAlias).map(\.path))
        let typeNames = Set(entries.lazy.filter(\.isType).map(\.name))
        return extendedPaths.contains { path in
            aliases.contains(path)
                || (!declaredTypes.contains(path) && path.contains(".")
                    && typeNames.contains(String(path.split(separator: ".").last ?? "")))
        }
    }
}
