import SwiftSyntax

/// The names a package declares that a body elsewhere can reach, arranged the way Swift reaches
/// them: `InertVocabulary` lets a body that names `Date` only as a type relax when what it calls is
/// the package's own, since a callee in the package is judged at its own declaration (#30).
///
/// - **A free name** resolves to a top-level declaration, or to a member of a type enclosing the
///   reference, and only through enclosing types that are wholly the package's: inside an extension
///   of an SDK type, or a type that inherits from or conforms to one, an unqualified name may be an
///   inherited SDK member, which Swift finds before any top-level declaration.
/// - **A call** resolves only to a function whose every parameter it writes, with matching labels
///   (an omitted default or a variadic would let an SDK overload of that arity win), or to a package
///   type: a package `func getuid(_: Int = 0)` does not make Darwin's `getuid()` the package's. A
///   function written as a value resolves only with its labels spelled. A type whose initializer
///   has a default that is not inert can be named but not called (`unconstructibleNames`).
/// - **A member** (`x.name`, `.name`) resolves to a member of any package type, since the receiver's
///   type is not known here; a call to it must match one's labels. A member spelled like an SDK one,
///   on a value of an SDK type, is let through: the documented residual. `DateInertnessChecker`'s
///   blocklist refuses the known ambient ones wherever they are declared.
/// - **A type name** resolves to a top-level package type or one nested in an enclosing type;
///   `A.B` to the type at that path.
///
/// A name is left out, everywhere it is spelled, when any declaration of it is one of these:
/// - inside a function body, or inside an `#if` clause, which may not be compiled;
/// - a protocol's requirement or a protocol extension's member, which has no one body to judge;
/// - generic, or a member of a generic type, or a type parameter's name anywhere: an annotation
///   can pick `T` to be `Date` and the callee's `T()` then builds one, which no oracle sees;
/// - a typealias, unless its target is a package type (`typealias Instant = Date` makes `Instant()`
///   a clock read);
/// - a stored property, an enum case's associated-value default, or a function's default argument,
///   whose value is not itself inert, or a declaration a custom attribute wraps: a global's
///   initializer runs on first read, and a default runs in whichever body leaves it out;
/// - a declaration whose types name a type that is neither the package's nor in the vocabulary, or
///   a function type or a metatype it returns or stores: a literal converts to it in the caller's
///   body (`LocalizedStringResource` records the user's locale), a returned `Date.init` is called
///   there (`stamper()()`), and a returned format style is used there;
/// - a declaration that throws such a type (`throws(Stamp)` hands the caller a `Stamp`);
/// - a type whose subscripts, `callAsFunction` or `@dynamicCallable` calls (which spell no name)
///   take or return such a type, or that inherits from a type that is not the package's, resolved
///   by its whole path (`Outer.Codable` is not `Codable`, nor is a package `protocol Equatable`).
///
/// An extension that gives a type the package does not plainly declare a conformance (an SDK type,
/// an alias, a module-qualified path) leaves the whole package unrelaxed: a protocol extension can
/// make `Date()()` callable or `for x in date` iterate, with no name written.
struct PackageNames: Sendable, Equatable {

    static let empty = Self()

    /// The protocols whose conformance brings no member a body could mistake for the package's.
    static let inertConformances: Set<String> = [
        // `Identifiable` only for a value type: a class's default `id` is `ObjectIdentifier(self)`, a
        // fresh identity (see `init`).
        "Equatable", "Hashable", "Comparable", "Codable", "Encodable", "Decodable", "Sendable",
        "Error", "CaseIterable", "RawRepresentable", "AnyObject",
        "String", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32",
        "UInt64", "Double", "Float", "Character",
    ]

    /// Every declaration by its container's qualified path (`""` for the top level), then by name.
    private(set) var byContainer: [String: [String: [PackageNameEntry.Shape]]] = [:]
    /// Every member declaration, of any container, by name.
    private(set) var members: [String: [PackageNameEntry.Shape]] = [:]
    /// The qualified path of every package type a body may name.
    private(set) var typePaths: Set<String> = []
    /// The qualified paths of the types an unqualified name may be looked up in.
    private(set) var cleanContainers: Set<String> = []
    /// Every name a type parameter, or a left-out declaration that could hand the body something
    /// (`refuses(_:)`), spells. It refuses even a name the vocabulary admits, since a body can reach
    /// one by that name and the receiver is not known: `struct Box { typealias first = Date }` makes
    /// `Box.first()` a clock read, and a left-out `var first: AnyIterator<UInt64>` makes
    /// `ticker.first` a clock the body iterates.
    private(set) var refused: Set<String> = []
    /// The names left out of each container, which an unqualified name inside it finds before any
    /// top-level or vocabulary name.
    private(set) var excludedByContainer: [String: Set<String>] = [:]
    /// The shapes of every left-out member, by name: a call shaped like one of them may be it, and
    /// the vocabulary cannot vouch for that call (`stamper.first()()` with a package `first()` that
    /// returns `Date.init`).
    private(set) var excludedMembers: [String: [PackageNameEntry.Shape]] = [:]
    /// Whether the package rebinds a literal type (`typealias StringLiteralType = …`), so that a
    /// literal in any body may build an SDK value, or gives an SDK type's values a nameless call with
    /// a default argument, which any body could run without naming anything.
    private(set) var rebindsLiterals = false
    /// Each type's (and extension's) inheritance clause, by path, resolved to package paths where
    /// they reach one.
    private(set) var supertypes: [String: Set<String>] = [:]
    /// The names of the types whose construction runs an initializer default the caller cannot see
    /// (`init(id: UUID = UUID())`), with their subclasses and aliases. A body may name one as a type
    /// and read its members, but a call to the name, or `.init` on it, is refused.
    private(set) var unconstructibleNames: Set<String> = []

    /// What `PackageNameCollector` saw of the package's initializers' default arguments.
    struct Construction: Sendable {
        /// The types an initializer of which has a default that is not inert.
        var unconstructible: Set<String> = []
        /// Every name each type's initializer defaults spell, by the type's path.
        var defaultNames: [String: Set<String>] = [:]
    }

    static func build(from sources: [SourceFileSyntax]) -> Self {
        let collector = PackageNameCollector()
        for source in sources { collector.walk(source) }
        return collector.finish()
    }

    init() { /* empty */ }

    init(
        entries: [PackageNameEntry],
        typeParameters: Set<String>,
        supertypes: [String: Set<String>],
        openContainers: Set<String> = [],
        rebindsLiterals: Bool = false,
        extensionInitializers: [String: Set<String>] = [:],
        construction: Construction = .init()
    ) {
        self.rebindsLiterals = rebindsLiterals
        let declaredPaths = Set(entries.lazy.map(\.path))
        self.supertypes = Self.resolve(supertypes, entries: entries, declared: declaredPaths)
        let admission = Admission(entries: entries, openContainers: openContainers)
        var types = Self.resolveAliases(entries.filter { !admission.isOpen($0) }, declared: declaredPaths)
        // Decide the types first, so that a left-out type's members are left out with it; and to a
        // fixpoint, since a type inheriting from a left-out one (a protocol whose requirement carries
        // a result builder) inherits what left it out.
        var refusedNames = typeParameters
        var excluded = typeParameters
        let outcasts = excludeTypes(
            entries,
            types: &types,
            refusedNames: &refusedNames,
            excluded: &excluded,
            admission: admission
        )
        // Then the rest, to a fixpoint: an initial value the vocabulary vouched for may spell a name
        // the package turned out to leave out.
        var clean = entries.filter { !$0.isType || !outcasts.contains($0.path) }
        let shadowing = Self.shadowingNames(anyType: admission.anyType, types: types)
        var changed = true
        while changed {
            changed = false
            clean.removeAll { entry in
                let insideOutcast = Self.prefixes(of: entry.container).contains { outcasts.contains($0) }
                let spellsRefused = !entry.initializerNames.isDisjoint(with: refusedNames)
                let admitted = Self.admits(entry, types: types, shadowing: shadowing, admission: admission)
                guard insideOutcast || spellsRefused || !admitted else {
                    return false
                }
                excluded.insert(entry.name)
                excludedByContainer[entry.container, default: []].insert(entry.name)
                excludedMembers[entry.name, default: []].append(entry.shape)
                if spellsRefused || Self.refuses(entry), refusedNames.insert(entry.name).inserted { changed = true }
                return true
            }
        }
        for entry in clean where !excluded.contains(entry.name) {
            byContainer[entry.container, default: [:]][entry.name, default: []].append(entry.shape)
            if !entry.container.isEmpty { members[entry.name, default: []].append(entry.shape) }
            if entry.isType { typePaths.insert(entry.path) }
        }
        refusedNames.formUnion(
            Self.sdkTypesWithForeignInitializers(extensionInitializers, declared: declaredPaths, types: types)
        )
        refused = refusedNames
        unconstructibleNames = Self.unconstructible(
            construction, refused: refusedNames, entries: entries, supertypes: self.supertypes
        )
        // A protocol's extension sees `Self`, which the protocol's own `where` clause or inheritance can
        // pin to an SDK type (`RawValue == LocalizedStringResource`, `Self: NSLocale`).
        let declaredTypes = Set(entries.lazy.filter { $0.isType && !$0.isAlias && !$0.isProtocol }.map(\.path))
        cleanContainers = typePaths.intersection(declaredTypes)
    }

    /// Leaves out, to a fixpoint, every type that inherits from an SDK type, that `admits` refuses,
    /// or that is no longer nameable, recording its name in `refusedNames`, `excluded` and
    /// `excludedByContainer`, and returns the paths of the types it left out.
    private mutating func excludeTypes(
        _ entries: [PackageNameEntry],
        types: inout Set<String>,
        refusedNames: inout Set<String>,
        excluded: inout Set<String>,
        admission: Admission
    ) -> Set<String> {
        var outcasts: Set<String> = []
        var changed = true
        while changed {
            types.subtract(Self.inheritingForeign(types, entries: entries, supertypes: supertypes))
            let nameable = types
            let shadowing = Self.shadowingNames(anyType: admission.anyType, types: types)
            let more = entries.filter { entry in
                entry.isType && !outcasts.contains(entry.path)
                    && (!Self.admits(entry, types: types, shadowing: shadowing, admission: admission)
                        || !nameable.contains(entry.path))
            }
            for entry in more {
                excluded.insert(entry.name)
                excludedByContainer[entry.container, default: []].insert(entry.name)
                refusedNames.insert(entry.name)
                outcasts.insert(entry.path)
            }
            types.subtract(outcasts)
            changed = !more.isEmpty
        }
        return outcasts
    }
}
