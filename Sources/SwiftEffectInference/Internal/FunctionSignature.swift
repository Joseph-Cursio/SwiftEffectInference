import SwiftSyntax

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

public extension FunctionSignature {

    /// Computes the signature of a function declaration from its syntax. Uses
    /// each parameter's **external** label (Swift's `firstName`), or `"_"` when
    /// the declaration suppresses the label.
    static func from(declaration: FunctionDeclSyntax) -> FunctionSignature {
        let labels = declaration.signature.parameterClause.parameters.map { param -> String in
            // `firstName` is the external label ("_" for suppressed) or the
            // single name when the declaration uses only one name. The internal
            // `secondName`, when present, is not part of the call-site signature.
            let firstText = param.firstName.text
            return firstText.isEmpty ? "_" : firstText
        }
        return FunctionSignature(name: declaration.name.text, argumentLabels: labels)
    }

    /// Computes the signature of a closure-typed stored property, treating it
    /// as a pseudo-method declaration. Returns `nil` when the binding is not
    /// a single named identifier or the declared type is not a function type.
    ///
    /// Attribute wrappers (`@Sendable`, `@MainActor`, `@escaping`, etc.) are
    /// peeled before inspecting the type. A single optional wrapping a
    /// function type (`((Int) -> Void)?`) is not supported — Swift function
    /// types are already a nominal category, and wrapping them in `Optional`
    /// is rare enough that pattern-matching the value shape isn't
    /// worthwhile in this first slice.
    ///
    /// ## Label mapping ("Path A")
    ///
    /// Swift function types permit a `_ internalName:` parameter shape that
    /// suppresses the call-site label at the type level. Macros in the
    /// `@DependencyClient`/`@MemberwiseInit` family re-expose the var as
    /// a method whose external label is the *internal* name, so the call
    /// site written by users is `f(internalName:)`. This resolver honours
    /// that convention: when `firstName` is `_` and `secondName` is a
    /// non-empty identifier, the returned signature uses `secondName` as
    /// the label.
    ///
    /// Concretely:
    /// - `var f: (Int) -> Void`                → `f(_:)`
    /// - `var f: (_ id: Int) -> Void`          → `f(id:)`      (Path A)
    /// - `var f: (id: Int) -> Void`            → `f(id:)`
    /// - `var f: @Sendable (_ x: String) async throws -> Bool` → `f(x:)`
    ///
    /// The tradeoff: a non-macro closure property `let f: (_ x: Int) -> Void`
    /// called as `f(0)` produces an annotation-to-call-site mismatch
    /// (`f(x:)` vs `f(_:)`). The mismatch is a false negative — the user's
    /// annotation silently doesn't land — not a false positive, so the
    /// heuristic is safe. The `_ name:` shape is in practice almost
    /// exclusive to macro-wrapped declarations that re-label; the
    /// alternative of using Swift-canonical `_` as the label produces
    /// signatures that cannot match any TCA `@DependencyClient` call
    /// site and delivers zero signal.
    static func from(declaration: VariableDeclSyntax) -> FunctionSignature? {
        guard let binding = declaration.bindings.first,
              declaration.bindings.count == 1,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            return nil
        }
        let name = pattern.identifier.text

        // Primary path: explicit function-typed annotation. Preserves Path A
        // re-labelling for the macro-friendly `@DependencyClient`-style shape.
        if let typeAnnotation = binding.typeAnnotation,
           let fnType = unwrapFunctionType(typeAnnotation.type) {
            let labels = fnType.parameters.map { element -> String in
                let first = element.firstName?.text ?? ""
                let second = element.secondName?.text ?? ""
                // Path A: `_ internalName:` → re-expose the internal name.
                if first == "_" && !second.isEmpty {
                    return second
                }
                if first.isEmpty || first == "_" {
                    return "_"
                }
                return first
            }
            return FunctionSignature(name: name, argumentLabels: labels)
        }

        // Fallback: typeless binding with a closure-literal initialiser.
        // Arity comes from the closure signature's parameter clause; labels
        // are always `_` (Swift closures are positional at the call site).
        // Requires an explicit parameter list — anonymous-arg closures
        // (`{ $0 + $1 }`) can't be signed without scanning the body, so
        // they stay unregistered.
        if let closure = binding.initializer?.value.as(ClosureExprSyntax.self) {
            guard let arity = closureParameterArity(closure) else { return nil }
            return FunctionSignature(
                name: name,
                argumentLabels: Array(repeating: "_", count: arity)
            )
        }

        return nil
    }

    /// Arity of a closure literal's explicit parameter list, or `nil` when
    /// the closure has no `in`-delimited signature (anonymous-arg closures
    /// like `{ $0 + $1 }` can't be signed without body analysis).
    private static func closureParameterArity(_ closure: ClosureExprSyntax) -> Int? {
        guard let parameterClause = closure.signature?.parameterClause else {
            return nil
        }
        switch parameterClause {
        case .simpleInput(let list):
            return list.count
        case .parameterClause(let clause):
            return clause.parameters.count
        }
    }

    /// Peels `AttributedTypeSyntax` wrappers (`@Sendable`, `@MainActor`,
    /// `@escaping`) to expose the underlying `FunctionTypeSyntax`, or
    /// returns `nil` when the type isn't function-typed.
    private static func unwrapFunctionType(_ type: TypeSyntax) -> FunctionTypeSyntax? {
        if let functionType = type.as(FunctionTypeSyntax.self) {
            return functionType
        }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return unwrapFunctionType(attributed.baseType)
        }
        return nil
    }

    /// Computes the signature of a call site from its syntax. Each argument's
    /// external label is read from `LabeledExprSyntax.label`; unlabeled positional
    /// arguments become `"_"`. Trailing closures are counted as a single
    /// argument (matching how Swift encodes the call). Returns `nil` when the
    /// callee expression is not a plain identifier or member access that the
    /// Phase-1 linter can resolve.
    static func from(call: FunctionCallExprSyntax) -> FunctionSignature? {
        guard let name = calleeBaseName(of: call.calledExpression) else { return nil }

        var labels: [String] = call.arguments.map { arg in
            arg.label?.text ?? "_"
        }
        // Trailing closures are passed without a label in the `arguments`
        // clause; they appear separately on `FunctionCallExprSyntax`. Treat the
        // first trailing closure as a single unlabeled argument and additional
        // trailing closures as labeled by their own `label` token. This matches
        // the Swift compiler's own call-signature encoding.
        if call.trailingClosure != nil {
            labels.append("_")
        }
        for additional in call.additionalTrailingClosures {
            labels.append(additional.label.text)
        }

        return FunctionSignature(name: name, argumentLabels: labels)
    }

    private static func calleeBaseName(of expr: ExprSyntax) -> String? {
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
    }
}
