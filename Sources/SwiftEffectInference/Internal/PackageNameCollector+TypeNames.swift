import SwiftSyntax

private final class TypeNameFinder: SourceAccurateSyntaxVisitor {
    private let declaring: Bool
    var names: Set<String> = []

    init(declaring: Bool) {
        self.declaring = declaring
        super.init()
    }

    /// What a value handed over as one of these can be: `Any` holds a function value, `UUID.init`,
    /// to cast and call; a bare `Sequence` (no `any` written) a lazy map whose elements the caller
    /// computes as it iterates.
    private static let handOverTypes: Set<String> = [
        "Any", "AnyObject", "AnyHashable", "Sendable", "Sequence", "Collection", "BidirectionalCollection",
        "RandomAccessCollection", "MutableCollection", "RangeReplaceableCollection", "IteratorProtocol",
        "LazySequenceProtocol", "LazyCollectionProtocol",
        // A handed-over `Decoder` decodes with whatever strategy built it: `Array<Date>(from:)` runs
        // a `DateFormatter` in the user's time zone.
        "Decoder", "Encoder",
        // Any other standard protocol's existential holds an SDK value whose witness can read a
        // setting: an `Encodable` holding `TimeZone.autoupdatingCurrent` encodes the current zone.
        // (`Error` is left out: nothing reaches its value without a cast, which blocks.)
        "Encodable", "Decodable", "Codable", "Equatable", "Hashable", "Comparable", "Identifiable",
        "CustomStringConvertible", "CustomDebugStringConvertible", "StringProtocol", "CodingKey",
        "BinaryInteger", "FixedWidthInteger", "SignedInteger", "UnsignedInteger", "Numeric",
        "SignedNumeric", "AdditiveArithmetic", "FloatingPoint", "BinaryFloatingPoint",
    ]

    private var handsOver: Bool { declaring || functionTypeDepth > 0 }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.bareName
        names.insert(handsOver && Self.handOverTypes.contains(name) ? "->" : name)
        return .visitChildren
    }

    /// `Outer.Inner` and `Swift.KeyPath` by their whole path: the last name alone could be anything.
    /// `Swift.Sendable` is `Sendable`.
    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        let path = PackageNameCollector.bareComponents(of: TypeSyntax(node))
        if let path, path.count == 2, ["Swift", "Foundation"].contains(path[0]), handsOver,
           Self.handOverTypes.contains(path[1]) {
            names.insert("->")
        } else {
            names.insert(path?.joined(separator: ".") ?? node.name.bareName)
        }
        if let arguments = node.genericArgumentClause { walk(arguments) }
        return .skipChildren
    }

    private var functionTypeDepth = 0

    /// A function type is marked where a value of it reaches the caller to call: a declared value's
    /// type, or a function type inside a parameter's function type, which the package hands to the
    /// caller's closure (`f(_ use: (() -> UInt32) -> Void)` can pass `arc4random`).
    override func visit(_: FunctionTypeSyntax) -> SyntaxVisitorContinueKind {
        if declaring || functionTypeDepth > 0 { names.insert("->") }
        functionTypeDepth += 1
        return .visitChildren
    }

    override func visitPost(_: FunctionTypeSyntax) { functionTypeDepth -= 1 }

    /// A returned `some Sequence<Double>` can be a lazy sequence whose elements the caller computes.
    override func visit(_: SomeOrAnyTypeSyntax) -> SyntaxVisitorContinueKind {
        if declaring { names.insert("some") }
        return .visitChildren
    }

    override func visit(_: MetatypeTypeSyntax) -> SyntaxVisitorContinueKind {
        names.insert(".Type")
        return .visitChildren
    }

    /// A default argument runs in the caller and is judged there; an attribute is not a type.
    override func visit(_: InitializerClauseSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_: AttributeSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

extension PackageNameCollector {

    static func parameters(_ clause: FunctionParameterClauseSyntax) -> [PackageNameEntry.Parameter] {
        clause.parameters.map { parameter in
            let label = parameter.firstName.tokenKind == .wildcard ? nil : parameter.firstName.bareName
            var result = PackageNameEntry.Parameter(
                label: label, hasDefault: parameter.defaultValue != nil, isVariadic: parameter.ellipsis != nil
            )
            result.isInout = parameter.type.as(AttributedTypeSyntax.self)?.specifiers.contains { specifier in
                specifier.as(SimpleTypeSpecifierSyntax.self)?.specifier.tokenKind == .keyword(.inout)
            } ?? false
            return result
        }
    }

    /// A parameter's attribute other than `@escaping`, `@autoclosure` or `@Sendable`: a result
    /// builder rewrites the caller's closure into calls the caller never writes.
    static func hasParameterAttribute(_ clause: FunctionParameterClauseSyntax) -> Bool {
        let isBuilder = { (attribute: AttributeListSyntax.Element) in
            attribute.as(AttributeSyntax.self).map {
                !["escaping", "autoclosure", "Sendable"].contains($0.attributeName.trimmedDescription)
            } ?? true
        }
        return clause.parameters.contains { parameter in
            parameter.attributes.contains(where: isBuilder)
                || parameter.type.as(AttributedTypeSyntax.self)?.attributes.contains(where: isBuilder) ?? false
        }
    }

    /// A typed `throws(Stamp)` hands its caller a `Stamp` in `catch`, as a return type would.
    static func thrownTypeNames(_ clause: ThrowsClauseSyntax?) -> Set<String> {
        clause?.type.map { typeNames(in: Syntax($0), declaring: true) } ?? []
    }

    /// What a property's or subscript's accessors throw: `get throws(Fault)`.
    static func accessorThrownTypeNames(_ block: AccessorBlockSyntax?) -> Set<String> {
        guard case .accessors(let list)? = block?.accessors else { return [] }
        return list.reduce(into: []) { $0.formUnion(thrownTypeNames($1.effectSpecifiers?.throwsClause)) }
    }

    static func hasOpaqueParameter(_ clause: FunctionParameterClauseSyntax) -> Bool {
        clause.parameters.contains { parameter in
            parameter.type.tokens(viewMode: .sourceAccurate).contains {
                [.keyword(.some), .keyword(.any)].contains($0.tokenKind)
            }
        }
    }

    /// Every type name `node` spells. Where it is a declared value's type (`declaring`), a function
    /// type is marked `"->"`: calling the value runs whatever it holds. An `inout` parameter's type
    /// is a value handed back to the caller, so it is always read as declared.
    static func typeNames(in node: Syntax, declaring: Bool) -> Set<String> {
        if !declaring, let clause = node.as(FunctionParameterClauseSyntax.self) {
            return clause.parameters.reduce(into: []) { names, parameter in
                let isInout = parameter.type.as(AttributedTypeSyntax.self)?.specifiers.contains { specifier in
                    specifier.as(SimpleTypeSpecifierSyntax.self)?.specifier.tokenKind == .keyword(.inout)
                } ?? false
                names.formUnion(typeNames(in: Syntax(parameter.type), declaring: isInout))
            }
        }
        let finder = TypeNameFinder(declaring: declaring)
        finder.walk(node)
        return finder.names
    }
}
