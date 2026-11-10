import SwiftSyntax

/// How a call site was actually *written*, as opposed to what it means.
///
/// The written argument list is not the declared parameter list, and the gap between them is
/// where declared effects go to die. Two distinct sugars open that gap:
///
/// - **Defaulted and variadic parameters** may simply be absent from the call.
/// - **Trailing closures** are written *without their label*. Swift drops the first trailing
///   closure's argument label entirely, so `perform(action:)` written as `perform { }` yields
///   the label list `["_"]` — which matches no declaration by name. Since Swift is made of
///   trailing closures, a matcher that ignores this is blind to a large fraction of all calls.
///
/// `CallSiteShape` records the labels *and* how many of the trailing ones were closures, so the
/// declaration side can reconstruct which parameter each argument was actually for.
public struct CallSiteShape: Sendable, Hashable {
    public let signature: FunctionSignature

    /// How many arguments at the *end* of `signature.argumentLabels` were written as trailing
    /// closures. The first of them carries no label at the call site (Swift drops it), so it
    /// can only be matched positionally; any further ones do carry theirs.
    public let trailingClosureCount: Int

    public init(signature: FunctionSignature, trailingClosureCount: Int = 0) {
        self.signature = signature
        self.trailingClosureCount = trailingClosureCount
    }

    /// The shape of a call as written. Returns `nil` when the callee is not a plain identifier
    /// or member access.
    public static func from(call: FunctionCallExprSyntax) -> Self? {
        guard let callee = FunctionSignature.from(call: call) else { return nil }

        var trailing = 0
        if call.trailingClosure != nil {
            trailing = 1 + call.additionalTrailingClosures.count
        }
        return Self(signature: callee, trailingClosureCount: trailing)
    }
}

/// A declaration's parameters, in enough detail to say which call sites could have reached it.
///
/// `FunctionSignature` alone cannot answer "could this call have been this declaration?",
/// because a declaration's label list names *every* parameter while a call site's names only
/// what was written. Matching the two lists for equality misses every call that omits a default,
/// passes a trailing closure, or spreads a variadic — and the miss is *silent*: the declared
/// effect never lands and the caller falls back to name-based inference.
public struct DeclarationShape: Sendable, Hashable {

    /// One declared parameter, with the two properties that decide whether a written argument
    /// list could have reached it.
    public struct Parameter: Sendable, Hashable {
        /// The external label, or `"_"` when the declaration suppresses it.
        public let label: String

        /// Whether the parameter carries a default value, and so may be absent from the call.
        public let hasDefault: Bool

        /// Whether the parameter is variadic. A variadic may be given nothing, or several
        /// arguments — only the first of which carries the label.
        public let isVariadic: Bool

        public init(label: String, hasDefault: Bool, isVariadic: Bool = false) {
            self.label = label
            self.hasDefault = hasDefault
            self.isVariadic = isVariadic
        }

        /// Whether the call site may leave this parameter out entirely.
        public var isOmittable: Bool { hasDefault || isVariadic }
    }

    public let name: String
    public let parameters: [Parameter]

    public init(name: String, parameters: [Parameter]) {
        self.name = name
        self.parameters = parameters
    }

    /// The declaration's own signature — every parameter, labelled.
    public var signature: FunctionSignature {
        FunctionSignature(name: name, argumentLabels: parameters.map(\.label))
    }

    /// Whether `callSite` could have resolved to this declaration.
    ///
    /// Trailing closures bind to the *last* parameters, so they are matched from the tail
    /// inwards and the ordinary arguments are matched against what remains. Within the ordinary
    /// arguments the rule is Swift's own: they appear in declaration order, and only omittable
    /// parameters may be skipped. So argument order still matters, an unknown label still fails,
    /// and a missing *required* parameter still fails — the match is looser than string
    /// equality, but no looser than the compiler.
    public func accepts(_ callSite: CallSiteShape) -> Bool {
        guard callSite.signature.name == name else { return false }

        let callLabels = callSite.signature.argumentLabels
        let trailing = callSite.trailingClosureCount

        // Trailing closures occupy the final parameters, one for one. More trailing closures
        // than parameters is not this declaration.
        guard trailing <= parameters.count, trailing <= callLabels.count else { return false }

        let boundary = parameters.count - trailing
        let trailingParameters = parameters[boundary...]
        let trailingLabels = callLabels[(callLabels.count - trailing)...]

        // The first trailing closure's label is dropped by Swift, so it matches whatever the
        // declaration calls that parameter. Any further trailing closures do carry their labels.
        for (offset, (parameter, label)) in zip(trailingParameters, trailingLabels).enumerated()
        where offset > 0 && parameter.label != label {
            return false
        }

        return acceptsOrdinaryArguments(
            Array(callLabels.prefix(callLabels.count - trailing)),
            against: Array(parameters.prefix(boundary))
        )
    }

    /// Whether the non-trailing-closure arguments could have filled `declared`.
    func acceptsOrdinaryArguments(
        _ callLabels: [String],
        against declared: [Parameter]
    ) -> Bool {
        var declaredIndex = 0
        var callIndex = 0

        while callIndex < callLabels.count {
            let callLabel = callLabels[callIndex]

            // Step over parameters the call chose not to supply. Only omittable ones may be
            // skipped; reaching a required parameter that does not match means no match.
            while declaredIndex < declared.count,
                  declared[declaredIndex].label != callLabel,
                  declared[declaredIndex].isOmittable {
                declaredIndex += 1
            }
            guard declaredIndex < declared.count,
                  declared[declaredIndex].label == callLabel else {
                return false
            }

            if declared[declaredIndex].isVariadic {
                // A variadic swallows its labelled argument plus every unlabelled one that
                // immediately follows: `publish(events: "a", "b")` is one parameter, two args.
                callIndex += 1
                while callIndex < callLabels.count, callLabels[callIndex] == "_" {
                    callIndex += 1
                }
            } else {
                callIndex += 1
            }
            declaredIndex += 1
        }

        // Whatever the call never reached must be omittable.
        return declared[declaredIndex...].allSatisfy(\.isOmittable)
    }
}

/// Canonical bare-receiver function signature: base name plus the ordered list
/// of argument labels (external labels, not internal parameter names). Unlabeled
/// positional arguments are represented as `"_"`, matching Swift's own rendering
/// convention (`foo(_:bar:)`).
///
/// Two declarations share a signature iff a single call site could match either
/// without further type information. The linter has no type checker, so this is
/// the strongest disambiguator available on pure syntax.
///
/// ## Examples
/// - `func upsert(_ id: Int)` → `upsert(_:)`
/// - `func create(key: String, value: some Codable, expires: Duration?)` → `create(key:value:expires:)`
/// - `func create(key: String, value: some Codable)` → `create(key:value:)` (distinct from above)
/// - `func send(to email: String)` → `send(to:)`  — external label wins over internal name
public struct FunctionSignature: Sendable, Hashable {
    public let name: String
    public let argumentLabels: [String]

    public init(name: String, argumentLabels: [String]) {
        self.name = name
        self.argumentLabels = argumentLabels
    }

    /// Canonical textual rendering, matching Swift's documentation form:
    /// `name(label1:label2:…)`. Used in diagnostics and debug output.
    public var description: String {
        let labels = argumentLabels.map { "\($0):" }.joined()
        return "\(name)(\(labels))"
    }
}
