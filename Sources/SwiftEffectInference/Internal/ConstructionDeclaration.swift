import SwiftSyntax

/// A stored property's declared type, with the declaration it belongs to — so two declarations of
/// one qualified name (`#if` branches, several targets) keep their own.
struct MemberType: Sendable, Equatable {
    let declaration: Syntax
    let type: TypeSyntax
}

/// What kind of type a declaration is, as far as constructing it goes.
enum ConstructionKind: Sendable, Equatable {
    case structure
    case classOrActor
    case enumeration
}

/// A defaulted initializer parameter whose default refutes — incurred only by the calls that
/// omit it.
struct OmittedDefault: Sendable, Equatable {
    /// The external label, `_` when there is none.
    let label: String
    /// For an unlabelled parameter, which unlabelled parameter it is: a call that writes more
    /// unlabelled arguments than that supplied it.
    let unlabelledPosition: Int?
    let refutation: PurityRefutation
}

/// One initializer a call may reach, with what reaching it runs.
struct ConstructionInitializer: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        /// Written in the type or one of its extensions.
        case declared
        /// A struct's synthesized memberwise initializer.
        case memberwise
        /// A root class's implicit `init()`.
        case implicit
        /// Written in an extension of a protocol the type conforms to.
        case protocolExtension
    }

    let parameters: [DeclarationShape.Parameter]
    /// `init(title:)` as a reader would write it.
    let display: String
    let origin: Origin
    let isConvenience: Bool
    /// The body refutes — every call this initializer accepts. A delegating body refutes when the
    /// initializer it delegates to does.
    var bodyRefutation: PurityRefutation?
    /// The struct `var` defaults this initializer runs. Every initializer but the memberwise one
    /// and the delegating ones runs them before its body.
    var storedDefaultRefutation: PurityRefutation?
    var omittedDefaultRefutations: [OmittedDefault]

    /// What a call with `call`'s arguments incurs here.
    func refutation(for call: CallShape) -> PurityRefutation? {
        if let bodyRefutation { return bodyRefutation }
        if let storedDefaultRefutation { return storedDefaultRefutation }
        let written = Set(call.labels)
        let unlabelledWritten = call.ordinary.filter { $0 == "_" }.count
        for omitted in omittedDefaultRefutations {
            if let position = omitted.unlabelledPosition {
                if unlabelledWritten <= position { return omitted.refutation }
            } else if !written.contains(omitted.label) {
                return omitted.refutation
            }
        }
        return nil
    }

    /// Anything a call reaching it can incur.
    var anyRefutation: PurityRefutation? {
        bodyRefutation ?? storedDefaultRefutation ?? omittedDefaultRefutations.first?.refutation
    }

    /// What it runs called as a function value, which evaluates no default argument — except
    /// that a memberwise initializer whose every parameter has a default is also `init()`.
    func referenceRefutation(labels: [String]?) -> PurityRefutation? {
        if let bodyRefutation { return bodyRefutation }
        if let storedDefaultRefutation { return storedDefaultRefutation }
        if origin == .memberwise, labels?.isEmpty ?? true, parameters.allSatisfy(\.isOmittable) {
            return omittedDefaultRefutations.first?.refutation
        }
        return nil
    }
}

/// One declared type and the facts about constructing it.
struct ConstructionDeclaration: Sendable, Equatable {
    let qualifiedName: String
    let bareName: String
    let kind: ConstructionKind
    /// A class nothing may subclass — `final`, or an actor.
    let isFinal: Bool
    let isPropertyWrapper: Bool
    /// The declaration itself, so its inheritance clause resolves from where it is written.
    let site: Syntax
    /// Every type named in an inheritance clause, its own and its extensions', with protocol
    /// compositions spelled out.
    var inheritedNames: [String]
    /// Refutes every construction, whatever initializer it reaches.
    var unconditional: PurityRefutation?
    /// The struct `var` defaults — conditional, because the memberwise initializer takes them as
    /// arguments.
    var conditionalStoredDefault: PurityRefutation?
    var initializers: [ConstructionInitializer]

    /// The witness for constructing it, reaching `cause` through `step`.
    func refuted(via step: PurityRefutation.ConstructionStep, _ cause: PurityRefutation) -> PurityRefutation {
        .refutingConstruction(type: qualifiedName, via: step, cause: cause)
    }

    /// The scope it is declared in: `A.B` for `A.B.C`, `""` at the top level.
    var parentScope: String {
        qualifiedName.split(separator: ".").dropLast().joined(separator: ".")
    }

    /// A class that declares no designated initializer of its own inherits its superclass's.
    var inheritsDesignatedInitializers: Bool {
        kind == .classOrActor && !initializers.contains { $0.origin == .declared && !$0.isConvenience }
    }

    /// The initializers `call` fits. Swift prefers a type's own initializer to a protocol
    /// extension's with the same labels, so that one is set aside.
    func accepting(_ call: CallShape) -> [ConstructionInitializer] {
        let fitting = initializers.filter { call.reaches($0.parameters) }
        let own = fitting.filter { $0.origin != .protocolExtension }
        let ownLabels = Set(own.map { $0.parameters.map(\.label) })
        return own + fitting.filter {
            $0.origin == .protocolExtension && !ownLabels.contains($0.parameters.map(\.label))
        }
    }

    /// Anything any construction path can run — the answer when the path is unknown.
    var anyRefutation: PurityRefutation? {
        unconditional ?? conditionalStoredDefault ?? initializers.lazy.compactMap(\.anyRefutation).first
    }

    /// How many places a refutation can land — what bounds the fixpoint.
    var slotCount: Int {
        2 + initializers.reduce(0) { $0 + 2 + $1.omittedDefaultRefutations.count }
    }

    /// How many of them have one.
    var refutedSlotCount: Int {
        [unconditional, conditionalStoredDefault].compactMap { $0 }.count
            + initializers.reduce(0) {
                $0 + [$1.bodyRefutation, $1.storedDefaultRefutation].compactMap { $0 }.count
                    + $1.omittedDefaultRefutations.count
            }
    }

    /// `self`, keeping every witness `earlier` already found — so a witness, once assigned, never
    /// changes, and a recursive construction converges instead of nesting one level deeper on
    /// every pass.
    func keeping(_ earlier: ConstructionDeclaration) -> ConstructionDeclaration {
        var merged = self
        merged.unconditional = earlier.unconditional ?? unconditional
        merged.conditionalStoredDefault = earlier.conditionalStoredDefault ?? conditionalStoredDefault
        for index in merged.initializers.indices where index < earlier.initializers.count {
            let old = earlier.initializers[index]
            merged.initializers[index].bodyRefutation = old.bodyRefutation ?? merged.initializers[index].bodyRefutation
            merged.initializers[index].storedDefaultRefutation =
                old.storedDefaultRefutation ?? merged.initializers[index].storedDefaultRefutation
            let kept = Dictionary(
                old.omittedDefaultRefutations.map { ($0.label, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            merged.initializers[index].omittedDefaultRefutations =
                merged.initializers[index].omittedDefaultRefutations.map { kept[$0.label] ?? $0 }
        }
        return merged
    }
}

/// The arguments a construction call writes, split the way Swift binds them.
struct CallShape: Equatable {
    /// The labels of the parenthesized arguments, `_` for an unlabelled one.
    let ordinary: [String]
    /// The trailing closures: `_` for the first, then the labels of any more.
    let trailing: [String]

    static let empty = CallShape(ordinary: [], trailing: [])

    init(ordinary: [String], trailing: [String]) {
        self.ordinary = ordinary
        self.trailing = trailing
    }

    /// Built from the arguments alone, so the callee's spelling — `T<G>(…)`, `Outer.T(…)` — never
    /// costs the shape.
    init(_ call: FunctionCallExprSyntax) {
        ordinary = call.arguments.map { $0.label?.text ?? "_" }
        var trailing: [String] = []
        if call.trailingClosure != nil {
            trailing.append("_")
            trailing += call.additionalTrailingClosures.map(\.label.text)
        }
        self.trailing = trailing
    }

    /// Every label written, for deciding which defaults the call omitted.
    var labels: [String] { ordinary + trailing }

    /// Whether this call could have reached an initializer with `parameters`.
    ///
    /// The parenthesized arguments match in order, skipping only omittable parameters. The first
    /// trailing closure is matched by forward scan (SE-0286): it may bind to any later parameter
    /// with only omittable ones before it, and any further, labelled ones follow in order. This is
    /// looser than the compiler — it does not know which parameters take a function — and looser
    /// is the safe direction: a call accepted by more initializers refutes if any of them does.
    func reaches(_ parameters: [DeclarationShape.Parameter]) -> Bool {
        guard let afterOrdinary = Self.scan(parameters, from: 0, labels: ordinary) else { return false }
        guard !trailing.isEmpty else {
            return parameters[afterOrdinary...].allSatisfy(\.isOmittable)
        }
        var first = afterOrdinary
        while first < parameters.count {
            if let end = Self.scan(parameters, from: first + 1, labels: Array(trailing.dropFirst())),
               parameters[end...].allSatisfy(\.isOmittable) {
                return true
            }
            guard parameters[first].isOmittable else { break }
            first += 1
        }
        return false
    }

    /// Matches `labels` against `parameters` from `start`; the index after the last one matched,
    /// or `nil`.
    private static func scan(
        _ parameters: [DeclarationShape.Parameter],
        from start: Int,
        labels: [String]
    ) -> Int? {
        var declared = start
        var written = 0
        while written < labels.count {
            while declared < parameters.count,
                  parameters[declared].label != labels[written],
                  parameters[declared].isOmittable {
                declared += 1
            }
            guard declared < parameters.count, parameters[declared].label == labels[written] else { return nil }
            written += 1
            if parameters[declared].isVariadic {
                while written < labels.count, labels[written] == "_" { written += 1 }
            }
            declared += 1
        }
        return declared
    }
}

extension DeclarationShape {
    /// The shape of an initializer, named `init`.
    static func from(declaration: InitializerDeclSyntax) -> DeclarationShape {
        DeclarationShape(
            name: "init",
            parameters: declaration.signature.parameterClause.parameters.map { param in
                Parameter(
                    label: param.firstName.text.isEmpty ? "_" : param.firstName.text,
                    hasDefault: param.defaultValue != nil,
                    isVariadic: param.ellipsis != nil
                )
            }
        )
    }
}
