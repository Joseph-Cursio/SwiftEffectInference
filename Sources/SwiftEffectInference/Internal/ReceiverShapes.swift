import SwiftSyntax

/// The resolved type of a method-call receiver, expressed as a type-name
/// classification rather than a full Swift type. This is **syntactic**
/// inference — it reads what the source literally says (parameter
/// annotations, pattern-binding annotations, literal shapes) and does not
/// perform semantic resolution. Cases the resolver cannot classify
/// lexically return `.unresolved`.
public enum ResolvedReceiverType: Equatable, Sendable {
    /// A well-known stdlib collection or wrapper type. The `String` payload
    /// is the bare type name (`"Array"`, `"Set"`, `"Dictionary"`, `"String"`,
    /// `"Optional"`). Used by `StdlibIdempotentMutations` to suppress bare-name
    /// inference matches on stdlib operations.
    case stdlibCollection(String)

    /// A user-defined or non-excluded type, identified by name only.
    case named(String)

    /// The receiver's type cannot be determined from syntax alone.
    /// Typical causes: chained access (`x.y.z.w()`), generic-parameter
    /// receivers, return-type-inferred receivers, computed properties
    /// without explicit type annotation.
    case unresolved
}

/// Phase-2 second-slice receiver-type resolver.
///
/// Given a method call `receiver.method(...)`, attempts to identify the
/// `receiver`'s declared type name using **source-local evidence only**.
/// Resolution sources, in precedence order:
///
/// 1. **Literal shape.** `[1, 2].append(...)` — receiver is an Array literal.
/// 2. **Constructor call.** `Queue().enqueue(...)` — receiver is a
///    direct constructor invocation with a type-name callee.
/// 3. **`self.<name>` member access.** Walks to the enclosing type decl
///    and reads the stored property's type annotation.
/// 4. **Bare-identifier receiver.** Walks the parent chain looking for:
///    - a matching function / initializer parameter's type annotation;
///    - a matching local `let`/`var` binding earlier in the enclosing
///      block (its type annotation, or if untyped its initializer shape);
///    - a matching stored property of the enclosing type decl.
/// 5. **Anything else** → `.unresolved`.
///
/// The resolver never guesses. When any resolution source produces an
/// ambiguous result (chained expression, generic parameter type, member
/// access on a computed property), `.unresolved` is returned and the
/// bare-name heuristic proceeds unchanged. This is round-5 baseline
/// behaviour, so the resolver cannot regress existing tests.
///
/// ## Shadowing
///
/// The optional `localTypes` parameter protects against a project redefining
/// a stdlib name (e.g. declaring its own `Array` type). If the type name
/// resolves to one of the stdlib names *and* `localTypes` contains that
/// name, the result is downgraded to `.named` — the stdlib exclusion table
/// won't fire on a user-defined shadow.
public enum ReceiverShapes {

    /// Convenience wrapper that extracts the receiver expression from a
    /// method call. For `x.foo(y)` returns the resolution of `x`. For
    /// `foo(y)` (no receiver) returns `.unresolved`.
    public static func resolve(
        receiverOf call: FunctionCallExprSyntax,
        localTypes: Set<String> = []
    ) -> ResolvedReceiverType {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              let base = member.base else {
            return .unresolved
        }
        return resolve(base, localTypes: localTypes)
    }

    /// Resolves a single receiver expression. Public so that the inferrer
    /// (and future callers) can operate on arbitrary expressions without
    /// routing through a `FunctionCallExprSyntax`.
    public static func resolve(
        _ expr: ExprSyntax,
        localTypes: Set<String> = []
    ) -> ResolvedReceiverType {
        // Layer 1: literal shapes.
        if expr.is(ArrayExprSyntax.self) {
            return classifyTypeName("Array", localTypes: localTypes)
        }
        if expr.is(DictionaryExprSyntax.self) {
            return classifyTypeName("Dictionary", localTypes: localTypes)
        }
        if expr.is(StringLiteralExprSyntax.self) {
            return classifyTypeName("String", localTypes: localTypes)
        }
        if expr.is(NilLiteralExprSyntax.self) {
            return classifyTypeName("Optional", localTypes: localTypes)
        }

        // Layer 2: constructor call. `Queue()`, `Array<Int>()`, `UUID()`.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let typeName = constructorTypeName(of: call) {
            return classifyTypeName(typeName, localTypes: localTypes)
        }

        // Layer 3: `self.<name>` member access. Look up the stored property
        // on the enclosing type.
        if let member = expr.as(MemberAccessExprSyntax.self),
           let baseRef = member.base?.as(DeclReferenceExprSyntax.self),
           baseRef.baseName.text == "self" {
            let propertyName = member.declName.baseName.text
            if let typeSyntax = storedPropertyType(named: propertyName, around: Syntax(expr)) {
                return classifyTypeSyntax(typeSyntax, localTypes: localTypes)
            }
            return .unresolved
        }

        // Layer 4: bare identifier — walk for param / local / self-property.
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if let result = resolveIdentifier(name, from: Syntax(expr), localTypes: localTypes) {
                return result
            }
            return .unresolved
        }

        return .unresolved
    }

    // MARK: - Constructor detection

    /// Returns the type-name for constructor-shaped call expressions.
    /// `Queue()` → `"Queue"`, `Array<Int>()` → `"Array"`, `UUID()` → `"UUID"`.
    /// Returns nil for non-constructor calls (e.g. `foo.bar()`, `doThing()`).
    private static func constructorTypeName(of call: FunctionCallExprSyntax) -> String? {
        // `TypeName()` — direct identifier callee, type names start uppercase.
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            return name.first?.isUppercase == true ? name : nil
        }
        // `TypeName<Generics>()` — generic-specialization wraps an identifier.
        if let gen = call.calledExpression.as(GenericSpecializationExprSyntax.self),
           let ref = gen.expression.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            return name.first?.isUppercase == true ? name : nil
        }
        return nil
    }

    // MARK: - Identifier resolution (parameter / local binding / stored property)

    /// Walks up the parent chain from `startNode` looking for the first
    /// declaration of `name`. Returns `nil` when no declaration is found
    /// along the lexical path.
    private static func resolveIdentifier(
        _ name: String,
        from startNode: Syntax,
        localTypes: Set<String>
    ) -> ResolvedReceiverType? {
        let usagePosition = startNode.position
        var current: Syntax? = startNode.parent

        while let node = current {
            // Function / initializer parameters.
            if let funcDecl = node.as(FunctionDeclSyntax.self),
               let param = parameter(named: name, in: funcDecl.parameterList) {
                return classifyTypeSyntax(param.type, localTypes: localTypes)
            }
            if let initz = node.as(InitializerDeclSyntax.self),
               let param = parameter(named: name, in: initz.parameterList) {
                return classifyTypeSyntax(param.type, localTypes: localTypes)
            }

            // Local bindings inside an enclosing code block.
            if let block = node.as(CodeBlockSyntax.self),
               let result = localBinding(
                   named: name,
                   in: block.statements,
                   before: usagePosition,
                   localTypes: localTypes
               ) {
                return result
            }

            // Local bindings inside an enclosing closure body. Closure
            // bodies hold `CodeBlockItemListSyntax` directly — there's no
            // `CodeBlockSyntax` wrapper, so the `.as(CodeBlockSyntax.self)`
            // check above doesn't hit.
            if let closure = node.as(ClosureExprSyntax.self),
               let result = localBinding(
                   named: name,
                   in: closure.statements,
                   before: usagePosition,
                   localTypes: localTypes
               ) {
                return result
            }

            // Stored properties of enclosing type decls.
            if let cls = node.as(ClassDeclSyntax.self),
               let typeSyntax = storedPropertyType(named: name, in: cls.memberBlock.members) {
                return classifyTypeSyntax(typeSyntax, localTypes: localTypes)
            }
            if let str = node.as(StructDeclSyntax.self),
               let typeSyntax = storedPropertyType(named: name, in: str.memberBlock.members) {
                return classifyTypeSyntax(typeSyntax, localTypes: localTypes)
            }
            if let act = node.as(ActorDeclSyntax.self),
               let typeSyntax = storedPropertyType(named: name, in: act.memberBlock.members) {
                return classifyTypeSyntax(typeSyntax, localTypes: localTypes)
            }
            if let ext = node.as(ExtensionDeclSyntax.self),
               let typeSyntax = storedPropertyType(named: name, in: ext.memberBlock.members) {
                return classifyTypeSyntax(typeSyntax, localTypes: localTypes)
            }

            current = node.parent
        }
        return nil
    }

    private static func parameter(named name: String, in parameters: FunctionParameterListSyntax) -> FunctionParameterSyntax? {
        for param in parameters {
            let localName = param.secondName?.text ?? param.firstName.text
            if localName == name { return param }
        }
        return nil
    }

    /// Looks through `statements` for a `let` / `var` binding of `name`
    /// that appears lexically before the usage site. Returns a resolution
    /// derived from the binding's type annotation (preferred) or its
    /// initializer expression (fallback).
    private static func localBinding(
        named name: String,
        in statements: CodeBlockItemListSyntax,
        before position: AbsolutePosition,
        localTypes: Set<String>
    ) -> ResolvedReceiverType? {
        for statement in statements {
            // Only consider statements that start before the usage site.
            if statement.position.utf8Offset >= position.utf8Offset { break }
            guard let varDecl = statement.item.as(VariableDeclSyntax.self) else { continue }
            for binding in varDecl.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                      pattern.identifier.text == name else { continue }
                // Typed binding: the annotation is authoritative.
                if let annotation = binding.typeAnnotation {
                    return classifyTypeSyntax(annotation.type, localTypes: localTypes)
                }
                // Untyped binding: classify the initializer's surface shape.
                if let initExpr = binding.initializer?.value {
                    if let shape = initializerShape(initExpr, localTypes: localTypes) {
                        return shape
                    }
                }
                // Binding found but unresolvable — `.unresolved`, don't keep
                // searching (the binding shadows any outer declaration).
                return .unresolved
            }
        }
        return nil
    }

    /// Classifies an initializer expression at face value. Literals and
    /// constructor calls resolve directly; anything else is unresolvable
    /// without chasing further, which this layer deliberately doesn't do.
    private static func initializerShape(_ expr: ExprSyntax, localTypes: Set<String>) -> ResolvedReceiverType? {
        if expr.is(ArrayExprSyntax.self) { return classifyTypeName("Array", localTypes: localTypes) }
        if expr.is(DictionaryExprSyntax.self) { return classifyTypeName("Dictionary", localTypes: localTypes) }
        if expr.is(StringLiteralExprSyntax.self) { return classifyTypeName("String", localTypes: localTypes) }
        if expr.is(NilLiteralExprSyntax.self) { return classifyTypeName("Optional", localTypes: localTypes) }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let typeName = constructorTypeName(of: call) {
            return classifyTypeName(typeName, localTypes: localTypes)
        }
        return nil
    }

    // MARK: - Stored-property lookup

    private static func storedPropertyType(
        named name: String,
        around startNode: Syntax
    ) -> TypeSyntax? {
        var current: Syntax? = startNode.parent
        while let node = current {
            if let cls = node.as(ClassDeclSyntax.self),
               let typeSyntax = storedPropertyType(named: name, in: cls.memberBlock.members) {
                return typeSyntax
            }
            if let str = node.as(StructDeclSyntax.self),
               let typeSyntax = storedPropertyType(named: name, in: str.memberBlock.members) {
                return typeSyntax
            }
            if let act = node.as(ActorDeclSyntax.self),
               let typeSyntax = storedPropertyType(named: name, in: act.memberBlock.members) {
                return typeSyntax
            }
            if let ext = node.as(ExtensionDeclSyntax.self),
               let typeSyntax = storedPropertyType(named: name, in: ext.memberBlock.members) {
                return typeSyntax
            }
            current = node.parent
        }
        return nil
    }

    private static func storedPropertyType(
        named name: String,
        in members: MemberBlockItemListSyntax
    ) -> TypeSyntax? {
        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in varDecl.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                      pattern.identifier.text == name,
                      let typeAnnotation = binding.typeAnnotation else { continue }
                return typeAnnotation.type
            }
        }
        return nil
    }

    // MARK: - Type-syntax classification

    private static func classifyTypeSyntax(
        _ type: TypeSyntax,
        localTypes: Set<String>
    ) -> ResolvedReceiverType {
        if type.is(ArrayTypeSyntax.self) {
            return classifyTypeName("Array", localTypes: localTypes)
        }
        if type.is(DictionaryTypeSyntax.self) {
            return classifyTypeName("Dictionary", localTypes: localTypes)
        }
        if type.is(OptionalTypeSyntax.self) {
            return classifyTypeName("Optional", localTypes: localTypes)
        }
        if let ident = type.as(IdentifierTypeSyntax.self) {
            return classifyTypeName(ident.name.text, localTypes: localTypes)
        }
        // MemberTypeSyntax, TupleTypeSyntax, SomeOrAnyTypeSyntax, etc.
        return .unresolved
    }

    private static func classifyTypeName(
        _ name: String,
        localTypes: Set<String>
    ) -> ResolvedReceiverType {
        if localTypes.contains(name) {
            return .named(name)
        }
        if stdlibCollectionNames.contains(name) {
            return .stdlibCollection(name)
        }
        return .named(name)
    }

    private static let stdlibCollectionNames: Set<String> = [
        "Array", "Set", "Dictionary", "String", "Optional"
    ]
}
