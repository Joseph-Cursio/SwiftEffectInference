import SwiftSyntax

/// Checks every type a signature spells against the vocabulary and the package's types, skipping
/// default arguments (judged where they are written) and attributes.
final class SignatureTypeVetter: SourceAccurateSyntaxVisitor {
    private let package: PackageNames
    private let root: Syntax
    private(set) var unresolved: String?

    init(package: PackageNames, root: Syntax) {
        self.package = package
        self.root = root
        super.init()
    }

    /// `-> Self` is a type the signature never spells.
    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if unresolved == nil, token.tokenKind == .keyword(.Self) { unresolved = "Self in the signature" }
        return .visitChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        check(node.name)
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        check(node.name)
    }

    override func visit(_: InitializerClauseSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_: AccessorBlockSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    /// A parameter's property wrapper runs its own code with the argument (`@AppStorage("k")`).
    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let name = node.attributeName.trimmedDescription
        let isPackageType = package.typePaths.contains(name) || package.refused.contains(name)
        if unresolved == nil, !DateInertnessChecker.isInertName(name) || isPackageType {
            unresolved = "@\(name) in the signature"
        }
        return .skipChildren
    }

    /// A metatype parameter hands the body a type to build or to read statics from.
    override func visit(_: MetatypeTypeSyntax) -> SyntaxVisitorContinueKind {
        if unresolved == nil { unresolved = "a metatype in the signature" }
        return .skipChildren
    }

    override func visit(_: ModuleSelectorSyntax) -> SyntaxVisitorContinueKind {
        if unresolved == nil { unresolved = "a module selector in the signature" }
        return .skipChildren
    }

    private func check(_ name: TokenSyntax) -> SyntaxVisitorContinueKind {
        if unresolved == nil, let reason = DateInertnessChecker.blocked(name.bareName)
            ?? InertVocabulary.unresolved(name, package: package, root: root) {
            unresolved = "\(reason) in the signature"
        }
        return .visitChildren
    }
}
