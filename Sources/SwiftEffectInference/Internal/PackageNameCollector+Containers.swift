import SwiftSyntax

extension PackageNameCollector {

    var container: String { containers.last.map { $0.path.joined(separator: ".") } ?? "" }
    var isInsideProtocol: Bool { containers.contains(where: \.isProtocol) }

    func entry(
        _ name: TokenSyntax, shape: PackageNameEntry.Shape, attributes: AttributeListSyntax? = nil
    ) -> PackageNameEntry {
        if Self.meaningfulKeywords.contains(name.bareName) || Self.isNumeric(name.bareName) {
            rebindsLiterals = true
        }
        var entry = PackageNameEntry(name: name.bareName, container: container, shape: shape)
        entry.isInsideProtocol = isInsideProtocol
        entry.isInert = ifConfigDepth == 0 && name.bareName.unicodeScalars.allSatisfy(\.isASCII)
            && !restrictions.contains(true) && !Self.restricts(attributes)
        // An extension sees its extended type's members, not the types lexically around that type.
        entry.scopes = containers.map { $0.path.joined(separator: ".") }
        // An attribute inside `#if` (`#if canImport(SwiftUI) @AppStorage("k") #endif`) is unjudged.
        entry.attributes = (attributes ?? []).map {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription ?? "#if"
        }
        return entry
    }

    /// A subscript or `callAsFunction` with a default argument runs that default in its caller,
    /// with no name for a label check to see.
    func markNamelessDefault() {
        nonInertTypePaths.insert(container)
    }

    /// A protocol requirement with a result builder (`@Captions func caption()`) rewrites every
    /// conformer's body, so the protocol and its conformers are left out.
    func markAttributedRequirement(_ attributes: AttributeListSyntax) {
        guard containers.last?.isProtocol == true else { return }
        let builds = attributes.contains { attribute in
            attribute.as(AttributeSyntax.self).map {
                !DateInertnessChecker.isInertName($0.attributeName.trimmedDescription)
            } ?? true
        }
        if builds { nonInertTypePaths.insert(container) }
    }

    func addToContainer(_ mentions: Set<String>) {
        guard !container.isEmpty else { return }
        typeMentions[container, default: []].formUnion(mentions)
    }

    func leaveContainer() {
        containers.removeLast()
        restrictions.removeLast()
    }

    func containerPath(adding name: String) -> [String] {
        (containers.last?.path ?? []) + [name]
    }

    /// `enterType(_:attributes:generics:inheritance:)` for a struct, class, enum or actor.
    func enterType(
        _ node: some DeclGroupSyntax & NamedDeclSyntax & WithGenericParametersSyntax
    ) -> SyntaxVisitorContinueKind {
        enterType(
            node.name, attributes: node.attributes, generics: node.genericParameterClause,
            inheritance: node.inheritanceClause
        )
    }

    func enterType(
        _ name: TokenSyntax,
        attributes: AttributeListSyntax,
        generics: GenericParameterClauseSyntax?,
        inheritance: InheritanceClauseSyntax?
    ) -> SyntaxVisitorContinueKind {
        var declared = entry(name, shape: .type, attributes: attributes)
        declared.isGeneric = generics != nil
        // `struct StringLiteralType` is what an untyped literal builds, wherever lookup finds it.
        if Self.literalTypeAliases.contains(name.bareName) { rebindsLiterals = true }
        entries.append(declared)
        let path = containerPath(adding: name.bareName)
        supertypes[path.joined(separator: "."), default: []].formUnion(Self.inheritedPaths(inheritance))
        addInferredAssociatedTypes(for: inheritance, in: path.joined(separator: "."))
        containers.append((path, false))
        restrictions.append(Self.restricts(attributes))
        return .visitChildren
    }

    /// The member types a conformance infers without a declaration: `Identifiable`'s `ID`, a raw
    /// value's `RawValue`, `CaseIterable`'s `AllCases`. Inside the type, `ID()` is the witness
    /// (`UUID()`), found before any top-level `ID`.
    func addInferredAssociatedTypes(for clause: InheritanceClauseSyntax?, in path: String) {
        let names = Self.inheritedPaths(clause)
        var inferred: [String] = []
        if names.contains("Identifiable") { inferred.append("ID") }
        if names.contains("CaseIterable") { inferred.append("AllCases") }
        let rawTypes: Set<String> = [
            "RawRepresentable", "String", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8",
            "UInt16", "UInt32", "UInt64", "Double", "Float", "Character",
        ]
        if names.contains(where: rawTypes.contains) { inferred.append("RawValue") }
        for name in inferred {
            var member = PackageNameEntry(name: name, container: path, shape: .type)
            member.isInert = false
            entries.append(member)
        }
    }
}
