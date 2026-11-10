import SwiftParser
import SwiftSyntax

/// One declared type, as collected — before any of it is judged.
struct RawDeclaration {
    struct StoredDefault {
        let name: String
        let isLet: Bool
        let value: ExprSyntax
        let annotation: TypeSyntax?
    }

    struct WrapperUse {
        let property: String
        let wrapper: [String]
        let attribute: AttributeSyntax
        let hasInitialValue: Bool
    }

    struct InitializerSource {
        let declaration: InitializerDeclSyntax
        let fromProtocol: Bool
    }

    let qualifiedName: String
    let bareName: String
    let kind: ConstructionKind
    let isFinal: Bool
    let isPropertyWrapper: Bool
    let site: Syntax
    var storedDefaults: [StoredDefault] = []
    /// Attribute arguments on stored properties: evaluated on every construction.
    var attributeArguments: [(property: String, arguments: Syntax)] = []
    var wrapperUses: [WrapperUse] = []
    var memberwiseParameters: [DeclarationShape.Parameter] = []
    /// An initializer in the declaration's own body suppresses the memberwise one; one in an
    /// extension does not.
    var hasInitializerInBody = false
    var initializers: [InitializerSource] = []
    var inheritedNames: [String] = []

    var unjudged: ConstructionDeclaration {
        .init(
            qualifiedName: qualifiedName, bareName: bareName, kind: kind, isFinal: isFinal,
            isPropertyWrapper: isPropertyWrapper, site: site, inheritedNames: inheritedNames,
            unconditional: nil, conditionalStoredDefault: nil, initializers: []
        )
    }

    func evaluate(with inferrer: PurityInferrer, facts: ConstructionFacts) -> ConstructionDeclaration {
        var judged = unjudged
        let stored = storedFacts(with: inferrer, facts: facts)
        judged.unconditional = stored.unconditional ?? inheritedUnconditional(facts: facts)
        judged.conditionalStoredDefault = stored.conditional
        judged.initializers = initializers.map {
            judge($0, runningStoredDefaults: stored.conditional, with: inferrer, facts: facts)
        }
        if kind == .structure, !hasInitializerInBody {
            judged.initializers.append(.init(
                parameters: memberwiseParameters,
                display: "init(" + memberwiseParameters.map { $0.label + ":" }.joined() + ")",
                origin: .memberwise, isConvenience: false,
                bodyRefutation: nil, storedDefaultRefutation: nil,
                omittedDefaultRefutations: stored.memberwiseOmitted
            ))
        }
        if kind == .classOrActor, !initializers.contains(where: { !Self.isConvenience($0.declaration) }) {
            // A class that declares no designated initializer has `init()` — implicit, or inherited.
            judged.initializers.append(.init(
                parameters: [], display: "init()", origin: .implicit, isConvenience: false,
                bodyRefutation: nil, storedDefaultRefutation: nil, omittedDefaultRefutations: []
            ))
        }
        return judged
    }

    /// What the stored properties run.
    struct StoredFacts {
        /// Run by every construction.
        var unconditional: PurityRefutation?
        /// The struct `var` defaults the memberwise initializer may skip.
        var conditional: PurityRefutation?
        /// The same, as the memberwise initializer's omittable parameters.
        var memberwiseOmitted: [OmittedDefault] = []
    }

    private func storedFacts(with inferrer: PurityInferrer, facts: ConstructionFacts) -> StoredFacts {
        var unconditional: PurityRefutation?
        var conditional: PurityRefutation?
        var omitted: [OmittedDefault] = []
        func witness(_ property: String, _ cause: PurityRefutation) -> PurityRefutation {
            .refutingConstruction(type: qualifiedName, via: .storedProperty(property), cause: cause)
        }

        for stored in storedDefaults {
            guard let cause = Self.judge(
                stored.value, declaredAs: stored.annotation, with: inferrer, facts: facts
            ) else {
                continue
            }
            // A `let` default can never be replaced; a class's or actor's defaults run in every
            // designated initializer; a struct with an initializer of its own has no memberwise one
            // to pass the value through; and an enum has no stored properties to vary. Only a
            // struct `var` behind the memberwise initializer is conditional.
            if stored.isLet || kind != .structure || hasInitializerInBody {
                unconditional = unconditional ?? witness(stored.name, cause)
            } else {
                conditional = conditional ?? witness(stored.name, cause)
                omitted.append(
                    .init(label: stored.name, unlabelledPosition: nil, refutation: witness(stored.name, cause))
                )
            }
        }
        // What every construction builds alongside: the arguments written on a property's
        // attributes, and a property wrapper this package declares.
        for (property, arguments) in attributeArguments {
            if let cause = inferrer.constructionRefutation(arguments) {
                unconditional = unconditional ?? witness(property, cause)
            }
        }
        for use in wrapperUses {
            let wrappers = facts.declarations(named: use.wrapper, from: Syntax(use.attribute))
                .filter { facts.declarations[$0].isPropertyWrapper }
            guard !wrappers.isEmpty else { continue }
            let call = Self.wrapperCall(use.attribute, hasInitialValue: use.hasInitialValue)
            if let cause = facts.refutation(constructing: wrappers, call: call) {
                unconditional = unconditional ?? witness(use.property, cause)
            }
        }
        return StoredFacts(unconditional: unconditional, conditional: conditional, memberwiseOmitted: omitted)
    }

    /// What a subclass inherits from its superclass's unconditional facts.
    private func inheritedUnconditional(facts: ConstructionFacts) -> PurityRefutation? {
        guard kind == .classOrActor else { return nil }
        for (name, supers) in facts.superclasses(of: unjudged) {
            if let cause = supers.lazy.compactMap({ facts.declarations[$0].unconditional }).first {
                return unjudged.refuted(via: .superclass(name), cause)
            }
        }
        return nil
    }

    private func judge(
        _ source: InitializerSource,
        runningStoredDefaults conditional: PurityRefutation?,
        with inferrer: PurityInferrer,
        facts: ConstructionFacts
    ) -> ConstructionInitializer {
        let declaration = source.declaration
        let parameters = DeclarationShape.from(declaration: declaration).parameters
        let display = "init(" + parameters.map { $0.label + ":" }.joined() + ")"
        let delegates = Self.calls(declaration, on: .keyword(.self))
        let isConvenience = Self.isConvenience(declaration)
        var body: PurityRefutation?
        if let block = declaration.body, let cause = inferrer.constructionRefutation(Syntax(block)) {
            body = .refutingConstruction(type: qualifiedName, via: .initializer(display), cause: cause)
        } else if kind == .classOrActor, !delegates, !isConvenience, !Self.calls(declaration, on: .keyword(.super)) {
            // A designated initializer that does not call `super.init` calls `super.init()`.
            let supers = facts.superclasses(of: unjudged).flatMap(\.candidates)
            if let cause = facts.refutation(constructing: supers, call: .empty) {
                body = .refutingConstruction(type: qualifiedName, via: .initializer(display), cause: cause)
            }
        }
        var omitted: [OmittedDefault] = []
        var unlabelled = 0
        for parameter in declaration.signature.parameterClause.parameters {
            let isUnlabelled = parameter.firstName.tokenKind == .wildcard
            defer { if isUnlabelled { unlabelled += 1 } }
            guard let value = parameter.defaultValue?.value,
                  let cause = Self.judge(value, declaredAs: parameter.type, with: inferrer, facts: facts)
            else { continue }
            let name = parameter.secondName?.text ?? parameter.firstName.text
            omitted.append(.init(
                label: isUnlabelled ? "_" : parameter.firstName.text,
                unlabelledPosition: isUnlabelled ? unlabelled : nil,
                refutation: .refutingConstruction(
                    type: qualifiedName, via: .initializer(display),
                    cause: .refutingDefaultArgument(parameter: name, cause: cause)
                )
            ))
        }
        return .init(
            parameters: parameters, display: display,
            origin: source.fromProtocol ? .protocolExtension : .declared,
            isConvenience: isConvenience,
            bodyRefutation: body,
            // Every non-delegating initializer runs the defaults; a delegating one runs them
            // through the one it delegates to.
            storedDefaultRefutation: delegates ? nil : conditional,
            omittedDefaultRefutations: omitted
        )
    }

    /// The call a property wrapper attribute makes: `init(wrappedValue:…)` with an initial value,
    /// then the attribute's own arguments.
    static func wrapperCall(_ attribute: AttributeSyntax, hasInitialValue: Bool) -> CallShape {
        var labels = hasInitialValue ? ["wrappedValue"] : []
        if case .argumentList(let arguments)? = attribute.arguments {
            labels += arguments.map { $0.label?.text ?? "_" }
        }
        return CallShape(ordinary: labels, trailing: [])
    }

    /// A default value's refutation. A base-less member — `.now`, `.init()`, `.current` — names
    /// nothing until a type is put in front of it, so it is judged that way too: `var created: Date
    /// = .now` is `Date.now`. Nested in a literal or a call (`[.init()]`, `(.now, 0)`), which type
    /// it belongs to is not worked out — it is judged in front of every type the annotation names,
    /// so `let ids: Set<UUID> = [.init()]` is `UUID.init()` among others.
    static func judge(
        _ value: ExprSyntax,
        declaredAs type: TypeSyntax?,
        with inferrer: PurityInferrer,
        facts: ConstructionFacts
    ) -> PurityRefutation? {
        if let refutation = inferrer.constructionRefutation(Syntax(value)) { return refutation }
        guard let type else { return nil }
        let members = implicitMembers(in: value)
        guard !members.isEmpty else { return nil }
        for named in namedTypes(in: type) {
            for typeText in qualifyingTexts(of: named, facts: facts) {
                for member in members {
                    guard let expression = Parser.parse(source: typeText + member).statements.first?.item else {
                        continue
                    }
                    if let refutation = inferrer.constructionRefutation(Syntax(expression)) { return refutation }
                }
            }
        }
        return nil
    }

    /// The texts that may stand in front of an implicit member of `type`: the type with `?`
    /// removed and typealiases followed — through every alias the name may mean where it is
    /// written — and for a clock's `Instant`, the clock, which is what the nondeterminism
    /// classifier knows (`ContinuousClock.Instant.now` is `ContinuousClock.now`).
    private static func qualifyingTexts(of type: TypeSyntax, facts: ConstructionFacts) -> [String] {
        let unwrapped = ConstructionChecker.unwrappingOptional(type)
        guard let components = TypeShapeCollector.components(of: unwrapped) else { return [] }
        return facts.spellings(of: components, from: Syntax(type)).map { spelling in
            var spelling = spelling
            if spelling.count > 1, spelling.last == "Instant" { spelling.removeLast() }
            return spelling.joined(separator: ".")
        }
    }

    /// Every named type in `type`, outermost first: `Set<UUID>` gives `Set<UUID>` and `UUID`.
    private static func namedTypes(in type: TypeSyntax) -> [TypeSyntax] {
        final class Finder: SyntaxVisitor {
            var found: [TypeSyntax] = []

            override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
                found.append(TypeSyntax(node))
                return .visitChildren
            }
            override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
                found.append(TypeSyntax(node))
                return .visitChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(type)
        return finder.found
    }

    /// Each base-less member in `value` as written, with its call when it is called: `.now`,
    /// `.init(title: "x")`. Not inside a closure, whose body construction does not run and whose
    /// members belong to other types.
    private static func implicitMembers(in value: ExprSyntax) -> [String] {
        final class Finder: SyntaxVisitor {
            var found: [String] = []

            override func visit(_: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
            override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                guard node.base == nil else { return .visitChildren }
                if let call = node.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == node.id {
                    found.append(call.trimmedDescription)
                } else {
                    found.append(node.trimmedDescription)
                }
                return .visitChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(value)
        return finder.found
    }

    static func isConvenience(_ initializer: InitializerDeclSyntax) -> Bool {
        initializer.modifiers.contains { $0.name.tokenKind == .keyword(.convenience) }
    }

    /// Whether `initializer`'s body calls `self.init` or `super.init`.
    static func calls(_ initializer: InitializerDeclSyntax, on base: TokenKind) -> Bool {
        guard let body = initializer.body else { return false }
        return body.tokens(viewMode: .sourceAccurate).contains { token in
            guard token.tokenKind == .keyword(.`init`),
                  let period = token.previousToken(viewMode: .sourceAccurate),
                  period.tokenKind == .period,
                  let receiver = period.previousToken(viewMode: .sourceAccurate) else { return false }
            return receiver.tokenKind == base
        }
    }
}
