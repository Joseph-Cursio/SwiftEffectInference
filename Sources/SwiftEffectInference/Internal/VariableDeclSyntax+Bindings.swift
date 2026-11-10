import SwiftSyntax

package extension VariableDeclSyntax {
    /// Returns the initialiser closure for a single-binding decl whose
    /// initialiser is a closure literal. Returns `nil` when:
    /// - the decl has more than one binding (`let a = {}, b = {}`)
    /// - the sole binding has no initialiser
    /// - the initialiser is some other expression (`let x = 42`)
    ///
    /// Closure-handler annotation (Phase 2 third slice) uses this as the
    /// anchor for the closure's body when `/// @lint.context` is declared
    /// on the variable decl.
    var closureInitializer: ClosureExprSyntax? {
        guard bindings.count == 1,
              let binding = bindings.first,
              let initialiser = binding.initializer?.value.as(ClosureExprSyntax.self)
        else { return nil }
        return initialiser
    }

    /// The simple identifier of the single binding, if any. Returns `nil`
    /// for multi-binding decls or non-identifier patterns (tuple patterns,
    /// wildcards, etc.).
    var firstBindingName: String? {
        guard bindings.count == 1 else { return nil }
        return bindings.first?.boundName
    }
}

package extension PatternBindingSyntax {
    /// The simple bound identifier of this binding (`let x = …` → `"x"`),
    /// or `nil` when the binding's pattern is not a plain identifier
    /// (tuple, wildcard, etc.). Shared by every walker that matches a
    /// binding against a target name.
    var boundName: String? {
        pattern.as(IdentifierPatternSyntax.self)?.identifier.text
    }
}
