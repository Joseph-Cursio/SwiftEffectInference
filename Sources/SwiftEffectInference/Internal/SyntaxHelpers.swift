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
        guard bindings.count == 1 else { return nil }
        return bindings.first?.boundName
    }
}

extension PatternBindingSyntax {
    /// The simple bound identifier of this binding (`let x = …` → `"x"`),
    /// or `nil` when the binding's pattern is not a plain identifier
    /// (tuple, wildcard, etc.). Shared by every walker that matches a
    /// binding against a target name.
    package var boundName: String? {
        pattern.as(IdentifierPatternSyntax.self)?.identifier.text
    }
}

extension ExprSyntax {
    /// The trailing identifier of a reference expression: the base name of a
    /// `DeclReferenceExprSyntax` (`foo` → `"foo"`) or the member name of a
    /// `MemberAccessExprSyntax` (`a.b.foo` → `"foo"`). Returns `nil` for any
    /// other expression kind.
    ///
    /// Shared by the call- and signature-walkers that pull a bare callee or
    /// type identifier from a called-expression leaf. Callers needing more
    /// (e.g. peeling a generic specialization) layer that on top.
    package var referenceBaseName: String? {
        if let ref = self.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text
        }
        if let member = self.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
    }
}
