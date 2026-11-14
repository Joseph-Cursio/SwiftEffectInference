import SwiftSyntax

// MARK: - Resolution

extension PackageNames {

    /// Whether a free `name` at `token`, called with `labels` (or not called, `nil`), resolves to the
    /// package.
    func resolvesFree(_ name: String, called labels: [String?]?, at token: TokenSyntax) -> Bool {
        let chain = Self.enclosingTypePaths(of: token)
        guard chain.allSatisfy(cleanContainers.contains) else { return false }
        for path in chain + [""] {
            if let shapes = byContainer[path]?[name] { return Self.accepts(shapes, called: labels) }
        }
        return false
    }

    /// Whether an enclosing type at `token` leaves out a member spelled `name`, which Swift would find
    /// before any vocabulary or top-level name.
    func shadowsFree(_ name: String, at token: TokenSyntax) -> Bool {
        var seen: Set<String> = []
        var pending = Self.enclosingTypePaths(of: token) + [""]
        while let path = pending.popLast() {
            guard seen.insert(path).inserted else { continue }
            if excludedByContainer[path]?.contains(name) == true { return true }
            // A superclass's or a protocol's left-out member is inherited, and found first too.
            pending.append(contentsOf: supertypes[path] ?? [])
        }
        return false
    }

    /// Whether a member spelled `name`, called with `labels` (or not, `nil`), may be one the package
    /// left out, which the vocabulary must then not vouch for.
    func mayBeExcludedMember(_ name: String, called labels: [String?]?) -> Bool {
        guard let shapes = excludedMembers[name] else { return false }
        guard let labels else {
            // Written as a value, `s.first` can be a left-out method taken unapplied.
            return shapes.contains { if case .function = $0 { true } else { false } }
        }
        // Loosely: `first()` may be a left-out `first(_ skip: Int = 0)`.
        return shapes.contains { shape in
            switch shape {
            case .function(let parameters), .enumCase(let parameters?):
                PackageNameEntry.Parameter.mayMatch(parameters, labels: labels)

            case .type, .value, .enumCase(nil):
                true
            }
        }
    }

    /// Whether a member `name`, called with `labels` (or not, `nil`), is one a package type declares.
    func resolvesMember(_ name: String, called labels: [String?]?) -> Bool {
        members[name].map { Self.accepts($0, called: labels) } ?? false
    }

    /// Whether `name`, called with `labels` (or not, `nil`), is a member the package declares on the
    /// type at `container`: for a receiver whose type the source spells, `self` or `String`.
    func resolvesMember(_ name: String, in container: String, called labels: [String?]?) -> Bool {
        byContainer[container]?[name].map { Self.accepts($0, called: labels) } ?? false
    }

    /// Whether a type name at `token` resolves to a package type: top-level, or nested in a type
    /// enclosing `token`.
    func resolvesType(_ name: String, at token: TokenSyntax) -> Bool {
        (Self.enclosingTypePaths(of: token) + [""]).contains { path in
            typePaths.contains(path.isEmpty ? name : path + "." + name)
        }
    }

    /// The path of the package type a type name at `token` names: nested in an enclosing type, or
    /// top-level.
    ///
    /// Innermost first, and a scope that declares the name as anything but a type ends the search:
    /// a `static let Anchor: [Int]` in an enclosing type is what `Anchor` is there, not a type.
    func typePath(of name: String, at token: TokenSyntax) -> String? {
        for scope in Self.enclosingTypePaths(of: token) + [""] {
            let path = scope.isEmpty ? name : scope + "." + name
            if typePaths.contains(path) { return path }
            if declaresNonType(name, in: scope) { return nil }
        }
        return nil
    }

    /// Whether `scope`, or a supertype it inherits members from, declares `name` as anything but a
    /// type, or leaves it out.
    private func declaresNonType(_ name: String, in scope: String) -> Bool {
        var seen: Set<String> = []
        var pending = [scope]
        while let path = pending.popLast() {
            guard seen.insert(path).inserted else { continue }
            if (byContainer[path]?[name] ?? []).contains(where: { $0 != .type })
                || excludedByContainer[path]?.contains(name) == true {
                return true
            }
            if !path.isEmpty { pending.append(contentsOf: supertypes[path] ?? []) }
        }
        return false
    }

    /// Whether `path` (`Outer.Inner`) is a package type.
    func resolvesTypePath(_ path: [String]) -> Bool {
        typePaths.contains(path.joined(separator: "."))
    }

    private static func accepts(_ shapes: [PackageNameEntry.Shape], called labels: [String?]?) -> Bool {
        shapes.contains { shape in
            switch shape {
            case .type:
                true

            case .value:
                labels == nil

            case .function(let parameters):
                labels.map { PackageNameEntry.Parameter.match(parameters, labels: $0) } ?? false

            case .enumCase(let parameters):
                labels.map { PackageNameEntry.Parameter.match(parameters ?? [], labels: $0) } ?? (parameters == nil)
            }
        }
    }

    /// The qualified paths of the types enclosing `token`, innermost first.
    static func enclosingTypePaths(of token: TokenSyntax) -> [String] {
        var walked: [(path: [String], isExtension: Bool)] = []
        var current = token.parent
        while let node = current {
            if let path = PackageNameCollector.containerPath(of: node) {
                walked.append((path, node.is(ExtensionDeclSyntax.self)))
            }
            current = node.parent
        }
        // An extension's path is absolute; a nested type's is its outer type's plus its own name.
        var paths: [String] = []
        var prefix: [String] = []
        for entry in walked.reversed() {
            prefix = entry.isExtension ? entry.path : prefix + entry.path
            paths.insert(prefix.joined(separator: "."), at: 0)
        }
        return paths
    }
}
