import SwiftSyntax

/// Finds what keeps a body from letting `Date` or `UUID` named as a type go unrefuted (#30): any
/// way to read a clock, a random source, a fresh identifier or the user's settings that the
/// marker sets and the classifier do not catch on their own.
///
/// On `main` the token refuted every body that spelled the type, so it masked all of these in
/// those bodies. A body that shows any of them keeps the old verdict: the relaxation is withheld
/// from the whole body, never applied around the blocker.
///
/// Two layers. **First an allowlist** (`InertVocabulary`): every identifier must resolve to a
/// local, the standard library's inert vocabulary, or a name the package declares. Then this
/// blocklist, which refuses what is known to read ambient state **even where the package declares
/// the name**, and the shapes no name check sees:
/// - **A value conjured from a type.** An `init` called with no arguments, or not called, on
///   anything but a standard-library type that builds a constant (`let d: Date = .init()`,
///   `meta.init()`, `.map(.init)`); `Self` written as a value; a nested generic, whose `T()` can be
///   a `Date` the body never names.
/// - **Text.** String interpolation and `description`, `debugDescription`, `String(describing:)`,
///   `String(reflecting:)`, `dump`, `debugPrint`, `Text`, `localized…`: `"\(stamp)"` formats a
///   date in the user's locale on Darwin.
/// - **Settings.** `Calendar`, `TimeZone`, `Locale` and their Objective-C and Core Foundation
///   twins, `DateComponents`, every `…Formatter` and `…FormatStyle`, `dateTime`, `ISO8601Format`,
///   a base-less `.current`, `NSPredicate` and `NSExpression` (whose format strings can call
///   `now()`), SwiftUI's `Environment`, a key path to `locale`, `timeZone` or `calendar`, and an
///   argument label that picks a locale or a description (`format:`, `locale:`, `forKey:`).
/// - **Clocks, randomness, identifiers, environment:** the C time functions (`time()`, `clock()`,
///   `localtime`, `strftime`, `mktime`, …), `CACurrentMediaTime`, `ProcessInfo`, `Timer`,
///   `RunLoop`, `SystemRandomNumberGenerator`, `rand`, `SecRandomCopyBytes`, `uuid_generate`,
///   `CFUUIDCreate`, `getenv`, `Bundle`, and a member named like a clock reading
///   (`scheduler.now`, `.currentDate`).
/// - **Code the body hands to something else to write:** a custom attribute (`@AppStorage` reads
///   settings, a property wrapper runs its own initializer) and a macro expansion.
final class DateInertnessChecker: SourceAccurateSyntaxVisitor {

    /// The first thing found that blocks the relaxation, as written, or `nil` when nothing did.
    private(set) var blocker: String?

    /// What the package declares, which a callee may be and still be judged at its declaration.
    private let package: PackageNames
    /// The body being judged, where the scope of a local ends.
    private var root: Syntax?

    init(packageNames: PackageNames) {
        self.package = packageNames
        super.init()
    }

    /// What blocks relaxing `root`: first the types of the signature it is the body of, which can
    /// type a literal or an implicit member the body writes (`-> LocalizedStringResource { "Hi" }`),
    /// then the body itself.
    ///
    /// A function's parameter defaults are walked too: they are judged with the function, and the
    /// token in its body was what refuted a default that reads the clock under a parameter's name.
    func blocker(in root: Syntax) -> String? {
        self.root = root
        if package.rebindsLiterals {
            return "the package rebinds a literal type or makes an SDK type's values callable"
        }
        if let outer = Self.enclosingBody(around: root) { return outer }
        // The body's own tokens, and a syntax error anywhere in its file (a flag, not a scan). A regex
        // elsewhere in the file can invent or hide package declarations, which `PackageNameCollector`
        // answers by leaving the whole package unrelaxed; one that ran into the body would leave no
        // body to judge.
        if root.root.hasError || PackageNameCollector.mayBeMisread(root) {
            return "a file swift-syntax may read differently from the compiler"
        }
        // Inside an SDK type's extension, or a type that inherits from or conforms to an SDK type, a
        // result builder or an inherited member can rewrite or answer for what the body writes.
        // Every enclosing type counts: a package type nested in an SDK type's extension sees that
        // type's member types (`Subject` is `ProcessInfo`) before any top-level name.
        let firstToken = root.firstToken(viewMode: .sourceAccurate) ?? TokenSyntax(.wildcard, presence: .missing)
        let chain = PackageNames.enclosingTypePaths(of: firstToken)
        if let container = chain.first(where: { !package.cleanContainers.contains($0) }) {
            return "a body inside \(container), which is not wholly the package's"
        }
        if let generic = Self.genericSignature(around: root) { return generic }
        if let attribute = ownerAttribute(around: root) { return attribute }
        if let unresolved = walkSignature(around: root) { return unresolved }
        if blocker == nil { walk(root) }
        return blocker
    }

    /// Vets the types of the signature `root` is the body of, and walks its parameter defaults
    /// other than `root` itself; returns what the vetter could not resolve, before any default is
    /// walked.
    private func walkSignature(around root: Syntax) -> String? {
        guard let owner = Self.signature(around: root) else { return nil }
        let vetter = SignatureTypeVetter(package: package, root: root)
        vetter.walk(owner)
        if let unresolved = vetter.unresolved { return unresolved }
        for parameter in Self.parameters(of: owner) {
            if let value = parameter.defaultValue?.value, value.id != root.id { walk(value) }
        }
        return nil
    }

    func isInert(_ attribute: AttributeSyntax) -> Bool {
        let name = attribute.attributeName.trimmedDescription
        return Self.isInertName(name) && !package.typePaths.contains(name) && !package.refused.contains(name)
    }

    private func block(_ reason: String) -> SyntaxVisitorContinueKind {
        if blocker == nil { blocker = reason }
        return .skipChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        guard blocker == nil else { return .visitChildren }
        switch token.tokenKind {
        case .binaryOperator(let name), .prefixOperator(let name), .postfixOperator(let name):
            // A package overload of `==` that returns a key path reaches the body through `==`.
            let vouched = !package.refused.contains(name) && (Self.standardOperators.contains(name)
                || [[nil, nil], [nil]].contains { (arguments: [String?]) in
                    package.resolvesMember(name, called: arguments)
                        || package.resolvesFree(name, called: arguments, at: token)
                })
            return vouched ? .visitChildren : block("the operator `\(name)`")

        case .identifier:
            break

        case .keyword(.Self):
            // A type the body never spells, in a type position as much as a value.
            return block("Self")

        case .keyword(.self):
            // Outside a type, `self` is no instance: it is whatever the package declared as
            // `` `self` `` (`let `self` = arc4random_uniform`).
            return PackageNames.enclosingTypePaths(of: token).isEmpty ? block("self outside a type") : .visitChildren

        case .keyword(.unsafe):
            // `unowned(unsafe)` reads whatever the freed memory holds; `unsafe` waives the checks.
            return block("unsafe")

        default:
            return .visitChildren
        }
        if let blocked = Self.blocked(token.bareName) { return block(blocked) }
        if let unresolved = InertVocabulary.unresolved(token, package: package, root: root) {
            return block(unresolved)
        }
        return .visitChildren
    }

    override func visit(_: ExpressionSegmentSyntax) -> SyntaxVisitorContinueKind {
        block("string interpolation")
    }

    /// swift-syntax can read `/…/` as a regex literal where the compiler reads two divisions (after
    /// `#endif`, a keyword-spelled member, or `(`), hiding every name between them.
    override func visit(_: RegexLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        block("a regex literal")
    }

    /// `Foundation::URL` picks a module's declaration over the package's.
    override func visit(_: ModuleSelectorSyntax) -> SyntaxVisitorContinueKind {
        block("a module selector")
    }

    /// `String #if true .Comparator(…) #endif`: the member's base is outside the clause, where no
    /// receiver check sees it.
    override func visit(_: PostfixIfConfigExprSyntax) -> SyntaxVisitorContinueKind {
        block("a postfix #if")
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.declName.baseName
        if Self.blockingMemberNames.contains(name.bareName) { return block("." + name.bareName) }
        // `String.self` is a type value, whose members are statics no receiver check sees.
        if name.tokenKind == .keyword(.self) { return block(".self") }
        // `[String].Element.Comparator` is `String.Comparator`, through a type no name check reads.
        if name.bareName.first?.isUppercase == true, let base = node.base, Self.isSugaredType(base) {
            return block("\(base.trimmedDescription).\(name.bareName)")
        }
        if node.base?.as(SuperExprSyntax.self) != nil { return block("super") }
        guard name.tokenKind == .keyword(.`init`) else { return .visitChildren }
        // A base-less `.init(…)` builds whatever its context says, and the context can be a return
        // type or a callee's parameter the body never spells. `self.init(…)` in a static member of
        // an SDK type's extension builds that SDK type.
        guard let base = node.base else { return block(".init") }
        guard Self.isCalled(node), !Self.isSelf(base) else { return block("\(base.trimmedDescription).init") }
        return isConstructible(base, fromNothing: Self.constructsFromNothing(Syntax(node)))
            ? .visitChildren : block("\(base.trimmedDescription).init")
    }

    /// Whether `base.init(…)` builds a value the body can see the source of: a standard-library type
    /// (with no arguments, only one that builds a constant), or a package type, whose construction
    /// `ConstructionFacts` judges.
    private func isConstructible(_ base: ExprSyntax, fromNothing: Bool) -> Bool {
        guard let token = base.as(DeclReferenceExprSyntax.self)?.baseName
            ?? base.as(TypeExprSyntax.self)?.type.as(IdentifierTypeSyntax.self)?.name else { return false }
        if fromNothing { return InertVocabulary.constantInitializedTypes.contains(token.bareName) }
        if package.unconstructibleNames.contains(token.bareName) { return false }
        return InertVocabulary.freeNames.contains(token.bareName) || package.resolvesType(token.bareName, at: token)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let labels = node.arguments.lazy.compactMap(\.label)
        if let label = labels.first(where: { InertVocabulary.blockingLabels.contains($0.bareName) }) {
            return block(label.bareName + ":")
        }
        // `f()()`, `x[0]()` and `(clock)()` call a value no name check resolves: a function a
        // package callee handed back, or a name the parentheses hide.
        if Self.callsAnonymousValue(node.calledExpression) { return block("a call to a value no name resolves") }
        // `String(utf16CodeUnits: &unit, count: n)` reads past the one value `&unit` points at: no
        // initializer takes a pointer to a value for anything else.
        if Self.isInitializerCall(node.calledExpression),
           node.arguments.contains(where: { $0.expression.is(InOutExprSyntax.self) }) {
            return block("a pointer handed to an initializer")
        }
        // `Optional(from: decoder)` decodes whatever type the context infers: `Locale(from:)` can
        // hand back the user's current locale.
        if Self.isStandardTypeCall(node.calledExpression),
           node.arguments.contains(where: { $0.label?.bareName == "from" }) {
            return block("a standard type decoded from:")
        }
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self) else { return .visitChildren }
        if Self.blockingFreeCalls.contains(callee.baseName.bareName) { return block(callee.baseName.bareName + "()") }
        if Self.isSelf(ExprSyntax(callee)), Self.constructsFromNothing(Syntax(callee)) { return block("Self()") }
        return .visitChildren
    }

    override func visit(_ node: DeclNameArgumentSyntax) -> SyntaxVisitorContinueKind {
        InertVocabulary.blockingLabels.contains(node.name.bareName) ? block(node.name.bareName + ":") : .visitChildren
    }

    /// `Self` as a value, and a free `time`, `clock`, `rand`, `now` or `current` that no local
    /// declares, whether called, passed (`xs.map(time)`) or parenthesized (`(time)(nil)`).
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if node.baseName.tokenKind == .keyword(.Self) { return block("Self") }
        // `self` in an SDK type's extension is that type: `self == "Hi"` converts the literal to it.
        if node.baseName.tokenKind == .keyword(.self),
           let container = PackageNames.enclosingTypePaths(of: node.baseName).first,
           !package.cleanContainers.contains(container) {
            return block("self in an extension of \(container)")
        }
        let name = node.baseName.bareName
        let isFree = node.parent?.as(MemberAccessExprSyntax.self)?.declName.id != node.id
            && node.parent?.is(KeyPathPropertyComponentSyntax.self) != true
        guard isFree, Self.blockingFreeCalls.contains(name) || Self.blockingMemberNames.contains(name),
              !LocalNameScope.declares(name, visibleAt: node.baseName, root: root) else { return .visitChildren }
        return block(Self.blockingFreeCalls.contains(name) ? name + "()" : name)
    }

    /// `case "Hi":` calls `~=` (and through it `==`) with no token written, so a package overload of
    /// either that it cannot vouch for reaches the body through every expression pattern.
    override func visit(_: ExpressionPatternSyntax) -> SyntaxVisitorContinueKind {
        package.refused.contains("~=") || package.refused.contains("==")
            ? block("a pattern match against the package's `~=`") : .visitChildren
    }

    /// A metatype in a body (`x as? Int.Type`) is a type value to build or read statics from.
    override func visit(_: MetatypeTypeSyntax) -> SyntaxVisitorContinueKind {
        block("a metatype")
    }

    /// A cast to a protocol, a function type or an existential recovers what a box the package
    /// handed over holds: `error as? Sequence` iterates whatever an untyped throw carried, and
    /// `value as? () -> UUID` calls it.
    override func visit(_ node: UnresolvedAsExprSyntax) -> SyntaxVisitorContinueKind {
        castTarget(after: Syntax(node)).map(blockedCast) ?? .visitChildren
    }

    override func visit(_ node: UnresolvedIsExprSyntax) -> SyntaxVisitorContinueKind {
        castTarget(after: Syntax(node)).map(blockedCast) ?? .visitChildren
    }

    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        blockedCast(node.type)
    }

    override func visit(_ node: IsExprSyntax) -> SyntaxVisitorContinueKind {
        blockedCast(node.type)
    }

    override func visit(_ node: IsTypePatternSyntax) -> SyntaxVisitorContinueKind {
        blockedCast(node.type)
    }

    /// The type an unfolded `as` or `is` casts to: the next element of its sequence.
    private func castTarget(after node: Syntax) -> TypeSyntax? {
        guard let list = node.parent?.as(ExprListSyntax.self),
              let index = list.firstIndex(where: { $0.id == node.id }) else { return nil }
        let next = list.index(after: index)
        return next < list.endIndex ? list[next].as(TypeExprSyntax.self)?.type : nil
    }

    private func blockedCast(_ type: TypeSyntax) -> SyntaxVisitorContinueKind {
        let hidden = Syntax(type).tokens(viewMode: .sourceAccurate).contains { token in
            [.keyword(.any), .keyword(.some), .arrow].contains(token.tokenKind)
                || Self.castProtocols.contains(token.bareName)
        }
        return hidden ? block("a cast to \(type.trimmedDescription)") : .visitChildren
    }

    /// `#available` reads the running OS's version, which differs between machines.
    override func visit(_: AvailabilityConditionSyntax) -> SyntaxVisitorContinueKind {
        block("#available")
    }

    override func visit(_: SuperExprSyntax) -> SyntaxVisitorContinueKind {
        block("super")
    }

    override func visit(_ node: TypeExprSyntax) -> SyntaxVisitorContinueKind {
        node.type.trimmedDescription == "Self" ? block("Self") : .visitChildren
    }

    override func visit(_ node: KeyPathPropertyComponentSyntax) -> SyntaxVisitorContinueKind {
        let name = node.declName.baseName.bareName
        let blocks = Self.blockingKeyPathComponents.contains(name) || Self.blockingMemberNames.contains(name)
        return blocks ? block("\\." + name) : .visitChildren
    }

    override func visit(_: GenericParameterClauseSyntax) -> SyntaxVisitorContinueKind {
        block("a nested generic")
    }

    /// An inert attribute's arguments (`@available(iOS 17, *)`) are not code.
    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        isInert(node) ? .skipChildren : block("@" + node.attributeName.trimmedDescription)
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        block("#" + node.macroName.text)
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        block("#" + node.macroName.text)
    }
}
