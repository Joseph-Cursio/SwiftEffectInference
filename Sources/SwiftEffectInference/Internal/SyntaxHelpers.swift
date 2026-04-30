import SwiftSyntax

// MARK: - SwiftSyntax Convenience Extensions

extension FunctionDeclSyntax {
    /// Direct accessor for the parameter list, avoiding deep signature navigation.
    package var parameterList: FunctionParameterListSyntax {
        signature.parameterClause.parameters
    }
}

extension InitializerDeclSyntax {
    /// Direct accessor for the parameter list, avoiding deep signature navigation.
    package var parameterList: FunctionParameterListSyntax {
        signature.parameterClause.parameters
    }
}

extension VariableDeclSyntax {
    /// Returns the initialiser closure for a single-binding decl whose
    /// initialiser is a closure literal. Returns `nil` when:
    /// - the decl has more than one binding (`let a = {}, b = {}`)
    /// - the sole binding has no initialiser
    /// - the initialiser is some other expression (`let x = 42`)
    ///
    /// Closure-handler annotation (Phase 2 third slice) uses this as the
    /// anchor for the closure's body when `/// @lint.context` is declared
    /// on the variable decl.
    package var closureInitializer: ClosureExprSyntax? {
        guard bindings.count == 1,
              let binding = bindings.first,
              let initialiser = binding.initializer?.value.as(ClosureExprSyntax.self)
        else { return nil }
        return initialiser
    }

    /// The simple identifier of the single binding, if any. Returns `nil`
    /// for multi-binding decls or non-identifier patterns (tuple patterns,
    /// wildcards, etc.).
    package var firstBindingName: String? {
        guard bindings.count == 1,
              let pattern = bindings.first?.pattern.as(IdentifierPatternSyntax.self)
        else { return nil }
        return pattern.identifier.text
    }
}
