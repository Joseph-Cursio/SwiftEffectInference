import Foundation
import SwiftSyntax

private final class PatternNameCollector: SourceAccurateSyntaxVisitor {
    var names: Set<String> = []

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.bareName)
        return .visitChildren
    }

    override func visit(_: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }
}

/// Whether an unqualified name written in a body is declared by the code around it: a parameter, a
/// local `let`/`var` or function, a closure's parameter or capture, a loop's or a pattern's binding,
/// a `catch`'s `error`, an accessor's `newValue`, or, in a type position only, a generic parameter.
///
/// `DateInertnessChecker` asks this before it lets a free name through, so the resolution has to err
/// toward "not declared". A flat set of every name bound anywhere in the body (what
/// `BoundNameCollector` keeps, for a check that errs the other way) would let
/// `{ let mktemp = 0 }; mktemp(buffer)` through. So each binding counts only where Swift reads it:
/// - a statement's declaration, for the statements after it, and a local function for its whole
///   block;
/// - a function's or accessor's parameters, for its body, never a sibling parameter's default;
/// - a closure's parameters and captures, for its statements, never the capture list, whose
///   initializers are evaluated outside;
/// - a condition's binding, for the conditions after it and the branch it guards, never the `else`;
/// - a loop's pattern, for its `where` clause and body, never the sequence it iterates;
/// - a `case`'s bindings, for its `where` clause and statements, never the pattern itself; a
///   `catch`'s, for its body.
///
/// Names are compared without backticks. The walk stops at the enclosing type: its members are what
/// the package declares, not locals.
enum LocalNameScope {

    /// Whether `name`, written at `token`, resolves to a declaration in an enclosing local scope.
    /// A generic parameter counts only as a type, and a type only as a generic parameter: written as
    /// a value, `T()` can build a `Date`, and a local value is no type.
    ///
    /// The walk ends at `root`'s owner, the declaration whose body is being judged: a nested
    /// function judged by itself must not lean on its outer function's locals, whose initial values
    /// are not part of what is judged.
    static func declares(
        _ name: String, visibleAt token: TokenSyntax, asType: Bool = false, root: Syntax? = nil
    ) -> Bool {
        let boundary = root.flatMap(owner(of:))
        var child = Syntax(token)
        var current = token.parent
        while let node = current {
            if asType {
                if genericNames(at: node).contains(name) { return true }
            } else if introduces(name, at: node, toward: child, reference: token) {
                return true
            }
            if isTypeBoundary(node) || node.id == boundary?.id { return false }
            child = node
            current = node.parent
        }
        return false
    }

    /// The declaration or closure whose body `root` is.
    static func owner(of root: Syntax) -> Syntax? {
        var current = root.parent
        while let node = current {
            switch node.kind {
            case .functionDecl, .initializerDecl, .subscriptDecl, .accessorDecl, .closureExpr, .patternBinding,
                 .deinitializerDecl:
                return node

            default:
                current = node.parent
            }
        }
        return nil
    }

    /// Whether `items` are statements in a body, and not a file's own (which declare globals),
    /// directly or inside an `#if`.
    private static func isLocalBlock(_ items: CodeBlockItemListSyntax) -> Bool {
        var current = items.parent
        while let node = current {
            switch node.kind {
            case .codeBlock, .closureExpr, .accessorBlock, .switchCase:
                return true

            case .sourceFile:
                return false

            default:
                current = node.parent
            }
        }
        return false
    }

    private static func isTypeBoundary(_ node: Syntax) -> Bool {
        switch node.kind {
        case .structDecl, .classDecl, .enumDecl, .actorDecl, .protocolDecl, .extensionDecl, .sourceFile:
            true

        default:
            false
        }
    }

    /// Whether `node` brings `name` into scope for `child`, the ancestor of the reference just below it.
    private static func introduces(
        _ name: String, at node: Syntax, toward child: Syntax, reference: TokenSyntax
    ) -> Bool {
        if let names = signatureNames(at: node, toward: child) { return names.contains(name) }
        switch node.as(SyntaxEnum.self) {
        case .codeBlockItemList(let items) where isLocalBlock(items):
            // A file's own statements declare globals, which are the package's, not locals.
            return statementsBefore(child, in: items).contains { declares(name, statement: $0) }
                || items.contains { localTypeOrFunctionName(of: $0) == name }

        case .ifExpr(let branch):
            return conditionScopes(branch.conditions, child: child, body: branch.body, reference: reference)
                .contains(name)

        case .whileStmt(let loop):
            return conditionScopes(loop.conditions, child: child, body: loop.body, reference: reference)
                .contains(name)

        case .guardStmt(let guardStmt):
            return child.id == guardStmt.conditions.id
                && conditionNames(guardStmt.conditions, before: reference).contains(name)

        default:
            return patternScopeNames(at: node, toward: child, reference: reference).contains(name)
        }
    }

    /// What a declaration with a signature binds for `child`: its parameters, for its body only.
    /// `nil` when `node` has no signature.
    private static func signatureNames(at node: Syntax, toward child: Syntax) -> Set<String>? {
        switch node.as(SyntaxEnum.self) {
        case .closureExpr(let closure):
            child.id == closure.statements.id ? closureNames(closure) : []

        case .functionDecl(let function):
            child.id == function.body?.id ? parameterNames(function.signature.parameterClause) : []

        case .initializerDecl(let initializer):
            child.id == initializer.body?.id ? parameterNames(initializer.signature.parameterClause) : []

        case .subscriptDecl(let subscriptDecl):
            child.id == subscriptDecl.accessorBlock?.id ? parameterNames(subscriptDecl.parameterClause) : []

        case .accessorDecl(let accessor):
            child.id == accessor.body?.id ? accessorNames(accessor) : []

        default:
            nil
        }
    }

    /// What a loop's, a case's or a catch's pattern binds for `child`.
    private static func patternScopeNames(
        at node: Syntax, toward child: Syntax, reference: TokenSyntax
    ) -> Set<String> {
        switch node.as(SyntaxEnum.self) {
        case .forStmt(let loop):
            let sees = child.id == loop.body.id || child.id == loop.whereClause?.id
            return sees ? patternNames(Syntax(loop.pattern)) : []

        case .switchCase(let switchCase):
            let sees = child.id == switchCase.statements.id
                || isInWhereClause(reference, within: Syntax(switchCase.label))
            return sees ? patternNames(Syntax(switchCase.label)) : []

        case .catchClause(let clause):
            guard child.id == clause.body.id else { return [] }
            return clause.catchItems.isEmpty ? ["error"] : patternNames(Syntax(clause.catchItems))

        default:
            return []
        }
    }

    /// Whether `token` is in the `where` clause of one of `label`'s own items, which sees the items'
    /// bindings; a `for … where`, or an inner switch's `case … where`, in a closure in the pattern is
    /// still the pattern, which does not.
    private static func isInWhereClause(_ token: TokenSyntax, within label: Syntax) -> Bool {
        var current = token.parent
        while let node = current, node.id != label.id {
            // WhereClause → SwitchCaseItem → SwitchCaseItemList → SwitchCaseLabel.
            if node.is(WhereClauseSyntax.self), node.parent?.is(SwitchCaseItemSyntax.self) == true,
               node.parent?.parent?.parent?.id == label.id {
                return true
            }
            current = node.parent
        }
        return false
    }

    /// The statements of `items` written before the one holding `child`. A local `let` cannot be
    /// read before its declaration, nor by its own initializer: `let time = time(nil)` reads the
    /// global.
    private static func statementsBefore(_ child: Syntax, in items: CodeBlockItemListSyntax) -> [CodeBlockItemSyntax] {
        Array(items.prefix { $0.id != child.id })
    }

    /// A local function's or type's name, which its whole block can use.
    private static func localTypeOrFunctionName(of statement: CodeBlockItemSyntax) -> String? {
        switch Syntax(statement.item).as(SyntaxEnum.self) {
        case .functionDecl(let decl): decl.name.bareName
        case .structDecl(let decl): decl.name.bareName
        case .classDecl(let decl): decl.name.bareName
        case .enumDecl(let decl): decl.name.bareName
        case .actorDecl(let decl): decl.name.bareName
        case .typeAliasDecl(let decl): decl.name.bareName
        case .protocolDecl(let decl): decl.name.bareName
        default: nil
        }
    }

    /// Whether `name` at `token` is a local of a body around `root`'s owner: in scope, and so what
    /// Swift picks over any vocabulary or package name, but declared outside what is judged.
    ///
    /// The walk crosses a type declared in a function body (a method of a local struct still sees
    /// the function's locals), stopping only at a file's top level.
    static func isOuterLocal(_ name: String, visibleAt token: TokenSyntax, root: Syntax?) -> Bool {
        guard let root else { return false }
        if declares(name, visibleAt: token, root: root) { return false }
        var child = Syntax(token)
        var current = token.parent
        while let node = current, !node.is(SourceFileSyntax.self) {
            if introduces(name, at: node, toward: child, reference: token) { return true }
            child = node
            current = node.parent
        }
        return false
    }

    private static func declares(_ name: String, statement: CodeBlockItemSyntax) -> Bool {
        if let variable = statement.item.as(VariableDeclSyntax.self) {
            return variable.bindings.contains { patternNames(Syntax($0.pattern)).contains(name) }
        }
        if let guardStmt = statement.item.as(GuardStmtSyntax.self) {
            return conditionNames(guardStmt.conditions, before: nil).contains(name)
        }
        return false
    }

    /// What a condition list binds for `child`: every binding for the guarded body, the earlier
    /// ones for a later condition, nothing for an `else`.
    private static func conditionScopes(
        _ conditions: ConditionElementListSyntax, child: Syntax, body: CodeBlockSyntax, reference: TokenSyntax
    ) -> Set<String> {
        if child.id == body.id { return conditionNames(conditions, before: nil) }
        if child.id == conditions.id { return conditionNames(conditions, before: reference) }
        return []
    }

    /// The names `conditions` bind, only from conditions that end before `reference` when given.
    private static func conditionNames(
        _ conditions: ConditionElementListSyntax, before reference: TokenSyntax?
    ) -> Set<String> {
        var names: Set<String> = []
        for element in conditions {
            if let reference, element.endPosition > reference.position { break }
            switch element.condition {
            case .optionalBinding(let binding):
                names.formUnion(patternNames(Syntax(binding.pattern)))

            case .matchingPattern(let matching):
                names.formUnion(patternNames(Syntax(matching.pattern)))

            default:
                break
            }
        }
        return names
    }

    private static func closureNames(_ closure: ClosureExprSyntax) -> Set<String> {
        guard let signature = closure.signature else { return [] }
        var names = Set(signature.capture?.items.map(\.name.bareName) ?? [])
        switch signature.parameterClause {
        case .simpleInput(let shorthand):
            names.formUnion(shorthand.map(\.name.bareName))

        case .parameterClause(let clause):
            names.formUnion(clause.parameters.map { ($0.secondName ?? $0.firstName).bareName })

        case nil:
            break
        }
        return names
    }

    private static func parameterNames(_ clause: FunctionParameterClauseSyntax) -> Set<String> {
        Set(clause.parameters.map { ($0.secondName ?? $0.firstName).bareName })
    }

    /// The generic parameters `node` declares, when it is a declaration that can.
    private static func genericNames(at node: Syntax) -> Set<String> {
        let clause: GenericParameterClauseSyntax? = switch node.as(SyntaxEnum.self) {
        case .functionDecl(let decl): decl.genericParameterClause
        case .initializerDecl(let decl): decl.genericParameterClause
        case .subscriptDecl(let decl): decl.genericParameterClause
        case .structDecl(let decl): decl.genericParameterClause
        case .classDecl(let decl): decl.genericParameterClause
        case .enumDecl(let decl): decl.genericParameterClause
        case .actorDecl(let decl): decl.genericParameterClause
        default: nil
        }
        return Set(clause?.parameters.map(\.name.bareName) ?? [])
    }

    private static func accessorNames(_ accessor: AccessorDeclSyntax) -> Set<String> {
        if let parameter = accessor.parameters?.name { return [parameter.bareName] }
        switch accessor.accessorSpecifier.tokenKind {
        case .keyword(.set), .keyword(.willSet):
            return ["newValue"]

        case .keyword(.didSet):
            return ["oldValue"]

        default:
            return []
        }
    }

    /// Every name a pattern binds, without entering a closure an expression pattern might hold.
    private static func patternNames(_ pattern: Syntax) -> Set<String> {
        let collector = PatternNameCollector()
        collector.walk(pattern)
        return collector.names
    }
}

extension TokenSyntax {
    /// The name this token spells, without backticks: `` `time` `` and `time` are one name. A
    /// non-ASCII scalar is spelled out (`\u{212A}`): `String` compares canonically, so a Kelvin sign
    /// would otherwise equal an ASCII `K` here, and the compiler compares scalars.
    ///
    /// A raw identifier that is no plain name (`` `Locale.Language` ``, `` `a b` ``) keeps its
    /// backticks, so that it never equals a dotted path or another spelling.
    var bareName: String {
        var name = identifier?.name ?? text
        let plain = name.unicodeScalars.allSatisfy {
            $0 == "_" || $0 == "$" || CharacterSet.alphanumerics.contains($0) || !$0.isASCII
        }
        if text.hasPrefix("`"), !plain { name = "`" + name + "`" }
        guard !name.unicodeScalars.allSatisfy(\.isASCII) else { return name }
        return name.unicodeScalars.map { $0.isASCII ? String($0) : "\\u{\(String($0.value, radix: 16))}" }.joined()
    }
}
