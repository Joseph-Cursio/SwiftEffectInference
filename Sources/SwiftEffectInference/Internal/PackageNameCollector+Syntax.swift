import SwiftSyntax

extension PackageNameCollector {

    /// Standard-library types whose extensions' members are generic over `Element`, `Wrapped` or
    /// `Self`, and protocols whose extensions' members are.
    static let genericStandardTypes: Set<String> = [
        "Array", "ContiguousArray", "ArraySlice", "Dictionary", "Set", "Optional", "Result", "Range",
        "ClosedRange", "Slice", "Sequence", "Collection", "BidirectionalCollection", "RandomAccessCollection",
        "MutableCollection", "RangeReplaceableCollection", "LazySequenceProtocol", "IteratorProtocol",
        "StringProtocol", "BinaryInteger", "FixedWidthInteger", "Numeric", "FloatingPoint",
        "BinaryFloatingPoint", "Equatable", "Hashable", "Comparable", "Encodable", "Decodable",
        "KeyPath", "WritableKeyPath", "PartialKeyPath",
    ]

    static func isGenericStandardType(_ path: [String]?) -> Bool {
        path.map { genericStandardTypes.contains($0.joined(separator: ".")) } ?? false
    }

    static let literalTypeAliases: Set<String> = [
        "StringLiteralType", "IntegerLiteralType", "FloatLiteralType", "BooleanLiteralType",
        "ExtendedGraphemeClusterType", "UnicodeScalarType",
    ]

    /// Whether swift-syntax and the compiler may read `node`'s file differently: a syntax error, or
    /// a regex literal, which swift-syntax can lex where the compiler reads two divisions (after
    /// `#endif` or `.default`), hiding declarations or inventing them from string literals.
    static func mayBeMisread(_ node: Syntax) -> Bool {
        node.hasError || node.tokens(viewMode: .sourceAccurate).contains { token in
            switch token.tokenKind {
            case .regexSlash, .regexPoundDelimiter, .regexLiteralPattern: true
            default: false
            }
        }
    }

    /// An `@available` attribute can hide a declaration from lookup (`obsoleted:`, `unavailable`,
    /// a version not yet reached), and a call then binds to an SDK function spelled the same.
    static func restricts(_ attributes: AttributeListSyntax?) -> Bool {
        (attributes ?? []).contains { element in
            element.as(AttributeSyntax.self).map { $0.attributeName.trimmedDescription == "available" } ?? true
        }
    }

    /// `Outer.Inner` (backticks stripped) as `["Outer", "Inner"]`, or `nil` for anything that is not
    /// a plain path of names.
    static func bareComponents(of type: TypeSyntax) -> [String]? {
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil {
            return [identifier.name.bareName]
        }
        if let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil,
           let base = bareComponents(of: member.baseType) {
            return base + [member.name.bareName]
        }
        if let attributed = type.as(AttributedTypeSyntax.self) { return bareComponents(of: attributed.baseType) }
        return nil
    }

    /// What an inheritance clause names, each by its whole path as spelled (`Outer.Codable`, never
    /// just `Codable`), with a composition spelled out and `"?"` for anything else.
    static func inheritedPaths(_ clause: InheritanceClauseSyntax?) -> [String] {
        clause?.inheritedTypes
            .flatMap { inherited -> [TypeSyntax] in
                inherited.type.as(CompositionTypeSyntax.self).map { $0.elements.map(\.type) } ?? [inherited.type]
            }
            .map { bareComponents(of: $0)?.joined(separator: ".") ?? "?" } ?? []
    }

    /// The path `node` adds when it declares or extends a type: its name, or an extension's whole
    /// extended type (`["Outer", "Inner"]`).
    static func containerPath(of node: Syntax) -> [String]? {
        switch node.as(SyntaxEnum.self) {
        case .structDecl(let decl): [decl.name.bareName]
        case .classDecl(let decl): [decl.name.bareName]
        case .enumDecl(let decl): [decl.name.bareName]
        case .actorDecl(let decl): [decl.name.bareName]
        case .protocolDecl(let decl): [decl.name.bareName]
        case .extensionDecl(let decl): bareComponents(of: decl.extendedType) ?? ["?"]
        default: nil
        }
    }

    /// Keywords with a meaning of their own, which a backticked declaration (`` let `self` = … ``)
    /// can give to every body that writes them.
    static let meaningfulKeywords: Set<String> = [
        "self", "Self", "super", "init", "deinit", "subscript", "Type", "Protocol", "Any",
    ]

    /// Whether `name` is a raw identifier that starts with a digit (`` `1` ``, `` `0x1` ``). A member
    /// access spells it as a number (`Kinds.1()`, `self.0()`), which reads like a tuple element and
    /// is a literal token, not a name, so no resolution sees it.
    static func isNumeric(_ name: String) -> Bool {
        name.drop { $0 == "`" }.first?.isNumber ?? false
    }

    /// `Outer.Inner` as `["Outer", "Inner"]`, or `nil` for anything with generic arguments or that
    /// is not a plain name.
    static func plainPath(of type: Syntax) -> [String]? {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return identifier.genericArgumentClause == nil ? [identifier.name.bareName] : nil
        }
        if let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil {
            return plainPath(of: Syntax(member.baseType)).map { $0 + [member.name.bareName] }
        }
        return nil
    }

    static func isStored(_ binding: PatternBindingSyntax) -> Bool {
        switch binding.accessorBlock?.accessors {
        case nil:
            return true

        case .getter:
            return false

        case .accessors(let list):
            return list.allSatisfy { [.keyword(.willSet), .keyword(.didSet)].contains($0.accessorSpecifier.tokenKind) }
        }
    }

    /// Whether a stored property's initial value is inert by the same rules a relaxed body meets,
    /// with no package names to lean on.
    static func isInert(_ value: Syntax) -> Bool {
        let checker = DateInertnessChecker(packageNames: .empty)
        checker.walk(value)
        return checker.blocker == nil && PurityInferrer().refutingMarker(in: value) == nil
    }

    /// Every name an initial value spells, which `PackageNames` checks against what it leaves out:
    /// the vocabulary vouched for them here, before the package's own spellings were known.
    static func identifiers(in value: Syntax) -> Set<String> {
        Set(value.tokens(viewMode: .sourceAccurate).compactMap { token in
            switch token.tokenKind {
            case .identifier, .binaryOperator, .prefixOperator, .postfixOperator: token.bareName
            default: nil
            }
        })
    }
}
