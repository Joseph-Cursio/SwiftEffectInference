import SwiftSyntax

// MARK: - Call parts

extension CallSiteEffectInferrer {

    /// Extracts `(calleeName, receiverName?)` from a call's called-expression.
    ///
    /// - `foo()` → `("foo", nil)`
    /// - `x.foo()` → `("foo", "x")`
    /// - `a.b.foo()` → `("foo", "b")` — the *immediate-parent* segment of
    ///   a chained member access, matching the semantic "the thing that
    ///   exposes `.foo`." Enables the observational heuristic to match
    ///   `context.logger.info(...)` where `logger` is the logger-shaped
    ///   segment even though it isn't the outermost base.
    /// - `a.b.c.foo()` → `("foo", "c")` — same rule extends to any depth.
    /// - `Foo.init(...)` → `("Foo", nil)` — normalised to the bare-identifier
    ///   form so the type-constructor whitelist fires on either spelling.
    ///   `A.B.init(...)` → `("B", nil)` (immediate type name); `Foo<T>.init(...)`
    ///   → `("Foo", nil)` (generic base peeled). `self.init(...)` and
    ///   `super.init(...)` normalise to `("self", nil)` / `("super", nil)`,
    ///   which match no whitelist — outcome unchanged.
    /// - Anything structurally more complex (subscripts, casts, function-
    ///   call bases, tuple projections) → `nil`.
    static func callParts(of expr: ExprSyntax) -> (String, String?)? {
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return (ref.baseName.text, nil)
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            let callee = member.declName.baseName.text
            guard let base = member.base else {
                return (callee, nil)
            }
            // `Type.init(...)` — treat the explicit-initializer form as
            // semantically identical to `Type(...)`. Without this normalisation
            // the type-constructor whitelist fires on `JSONDecoder()` but
            // misses `JSONDecoder.init()`, producing one stray diagnostic per
            // framework-response-builder call site that uses the explicit form.
            if callee == "init", let typeName = typeIdentifierName(of: base) {
                return (typeName, nil)
            }
            if let baseRef = base.as(DeclReferenceExprSyntax.self) {
                return (callee, baseRef.baseName.text)
            }
            if let innerMember = base.as(MemberAccessExprSyntax.self) {
                return (callee, innerMember.declName.baseName.text)
            }
            return (callee, nil)
        }
        return nil
    }

    /// Extracts the leaf type identifier from an expression used as the
    /// base of a `.init(...)` call. Returns nil when the base is not a
    /// type reference the whitelist could match (closure calls, subscripts,
    /// tuple projections, etc.).
    ///
    /// - `Foo` → `"Foo"`
    /// - `A.B` → `"B"` (nested type; immediate leaf)
    /// - `Foo<T>` → `"Foo"` (generic-specialization base peeled)
    /// - `A.B<T>` → `"B"`
    static func typeIdentifierName(of expr: ExprSyntax) -> String? {
        // Peel a generic specialization (`Foo<T>` → `Foo`) then recurse; the
        // peeled expression is normally a plain reference / member access.
        if let spec = expr.as(GenericSpecializationExprSyntax.self) {
            return typeIdentifierName(of: spec.expression)
        }
        return expr.referenceBaseName
    }
}
