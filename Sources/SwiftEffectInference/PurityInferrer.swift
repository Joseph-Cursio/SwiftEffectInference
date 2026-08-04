import SwiftSyntax

/// How far a function gets toward `Effect.pure` — the two clauses separated,
/// because two consumers need different halves and answering with one `Bool`
/// made them disagree.
///
/// `.pure` is a *conjunction*: referentially transparent **and** total. Those
/// are different properties, and `throws` refutes only the second one. Collapse
/// them and a throwing-but-otherwise-transparent function is indistinguishable
/// from one that reads the clock — which is exactly the confusion that cost the
/// SwiftLintRuleStudio road test its highest-value law. `serialize(_:) throws ->
/// String` is a deterministic function of its argument; the linter's seed rule
/// refused to name it, so SwiftInferProperties — which vouches for purity *via
/// the seed* and only checks shape itself — never got the chance to propose the
/// law it already knew how to write.
///
/// So the verdict says which clause failed, and each consumer decides what it
/// can live with:
///
/// - **A law that must hold on every input** (an `@lint.effect pure` claim, a
///   `couldBePrivateMember` narrowing) needs `.pure`.
/// - **A law whose domain can be narrowed to the success set** — determinism as
///   `(try? f(x)) == (try? f(x))`, a round trip caveated to inputs that parse —
///   is satisfied by `.pureButPartial` too.
///
/// The distinction is *only* about partiality. A `.pureButPartial` function has
/// passed every impurity and nondeterminism refuter; it simply has no answer for
/// part of its domain.
public enum PurityVerdict: Sendable, Equatable {
    /// Referentially transparent and total: `.pure` on the effect lattice.
    case pure

    /// Referentially transparent but **partial** — it `throws`, so it is
    /// undefined on some inputs. Deterministic where it is defined.
    case pureButPartial

    /// Not referentially transparent: an impurity or nondeterminism refuter
    /// fired, or the shape could not be inspected at all.
    case refuted
}

/// Infers whether a function is `Effect.pure` — referentially transparent:
/// no side effects, deterministic, and total (a function of its inputs alone).
///
/// This is the **canonical** purity oracle for the ecosystem. Purity is a
/// *conjunctive* property — a function is `.pure` only when **none** of the
/// impurity / nondeterminism / partiality refuters fire — so a single narrow
/// analyzer can never establish it soundly; it can only *refute* it. This type
/// owns the I/O / nondeterminism / totality refuters. Callers that also need to
/// rule out a domain-specific effect surface (e.g. SwiftInferProperties' TCA
/// `ReducerPurity`, which refutes on `Effect`/`Task`/`await` and hidden
/// mutation) take the **meet** of their refutation with this one: claim `.pure`
/// only when both agree.
///
/// ## Soundness
///
/// On the effect lattice `pure ≤ observational ≤ … ≤ nonIdempotent`, a sound
/// inference only ever *over-approximates* — it never claims an effect below
/// the true one. `.pure` is the lattice bottom and the most dangerous place to
/// land wrongly (every downstream consumer *trusts* it: a generated property
/// test runs a `.pure` function in-process and asserts a law over random
/// inputs). So this inferrer is conservative by construction: any doubt refutes
/// purity. A missed refuter would be unsound, so the marker sets err toward
/// flagging.
///
/// ## History
///
/// Lifted from SwiftProjectLint's testability rule (`PureFunctionCandidateVisitor`)
/// during Idea #4 so the purity *inference*, not just the `Effect` *type*, lives
/// in the shared leaf. SwiftProjectLint and SwiftInferProperties now consume one
/// oracle instead of carrying parallel copies.
public struct PurityInferrer: Sendable {

    public init() {
        // Stateless — the inferrer holds no configuration.
    }

    /// Side-effect markers — I/O, logging, persistence. Any reference in the
    /// body refutes the "no side effects" clause of purity.
    private static let sideEffectMarkers: Set<String> = [
        "print", "NSLog", "FileManager", "URLSession", "UserDefaults",
        "NotificationCenter", "DispatchQueue"
    ]

    /// Nondeterminism markers — sources whose result is not a function of the
    /// inputs (the randomness family, the system clock, identity generation).
    /// Any reference refutes the "deterministic" clause of purity.
    ///
    /// Matched by bare-identifier token, so this is deliberately conservative:
    /// it refutes `Date()` *and* the deterministic `Date(timeIntervalSince1970:)`
    /// alike (the token scan can't tell them apart), and refutes injected
    /// `random(in:using:)` as well as the system-RNG form. Over-refutation is
    /// the sound direction on the effect lattice — better to withhold `.pure`
    /// than to claim it for a clock-reading function — and both consumers (the
    /// linter's candidate nudge, the inferrer's `pure`-suggestion gate) prefer
    /// to refute when unsure. The AST-precise forms live in SwiftProjectLint's
    /// `NonInjectedNondeterminismVisitor`; this token set is the leaf-level
    /// over-approximation of that rule.
    private static let nondeterministicMarkers: Set<String> = [
        "arc4random", "arc4random_uniform", "drand48", "CFAbsoluteTimeGetCurrent",
        "random", "randomElement", "shuffled",
        "Date", "UUID"
    ]

    /// Returns `.pure` when `function` is referentially transparent — its
    /// signature is synchronous and non-throwing, its body references no
    /// side-effect or nondeterminism marker, and nothing in it can trap — and
    /// `nil` (purity refuted) otherwise.
    ///
    /// `async` and `throws` both refute purity: an `async` body awaits some
    /// effect, and a `throws` function has no return value for the inputs that
    /// throw, so it is not total over its domain. A body-less declaration (a
    /// protocol requirement) is refuted — there is nothing to inspect.
    ///
    /// **The two refuters are not the same kind of thing**, and a caller that
    /// can narrow a law's domain should ask `verdict(for:)` instead: it separates
    /// the throwing case out as `.pureButPartial` rather than folding it in with
    /// the clock readers. This method's answer is deliberately unchanged — it is
    /// the right question for a claim that must hold over the whole domain.
    /// **Deliberately not `verdict(for:) == .pure`**, though the answers are
    /// identical and a test pins that they stay so.
    ///
    /// `verdict` must walk the body of a *throwing* function — separating
    /// `.pureButPartial` from `.refuted` is the only thing that walk is for. This
    /// method asks the **whole-domain** question, for which `throws` is
    /// disqualifying outright, so it can reject on the signature before any
    /// traversal. Delegating cost the two a shared hot path they do not share a
    /// question with: measured at **~2× on the whole-domain path** across five
    /// independent budgets in SwiftInferProperties (2.00–2.20×), because Swift
    /// corpora — test code especially — are dense with `throws`, and every one of
    /// those functions was paying two full body walks to reach a verdict its
    /// signature already settled. See
    /// [SwiftEffectInference#1](https://github.com/Joseph-Cursio/SwiftEffectInference/issues/1).
    ///
    /// Two entry points with different costs because they answer different
    /// questions, which is the same argument `PurityVerdict`'s own doc makes for
    /// separating them at all.
    public func inferredEffect(for function: FunctionDeclSyntax) -> Effect? {
        guard let body = function.body else { return nil }
        // The cheap rejections first, and `throws` belongs among them HERE even
        // though it cannot be there in `verdict`.
        guard function.signature.effectSpecifiers?.asyncSpecifier == nil,
              function.signature.effectSpecifiers?.throwsClause == nil else {
            return nil
        }
        guard !bodyHasRefutingMarker(body), bodyIsTotal(body) else { return nil }
        return .pure
    }

    /// Convenience boolean form of `inferredEffect(for:)`.
    public func isPure(_ function: FunctionDeclSyntax) -> Bool {
        inferredEffect(for: function) == .pure
    }

    /// The full verdict — which clause of purity `function` satisfies.
    ///
    /// Prefer this over `isPure(_:)` when the caller can narrow a law's domain
    /// to the inputs that do not throw; see `PurityVerdict`. `isPure(_:)` and
    /// `inferredEffect(for:)` remain the right question for a caller that needs
    /// a claim holding over the whole domain, and their answers are unchanged by
    /// this method's existence: both are `verdict(for:) == .pure`.
    ///
    /// `async` still refutes outright rather than yielding `.pureButPartial`.
    /// The two are not parallel: `throws` narrows a function's *domain* while
    /// leaving it a deterministic function of the inputs it accepts, whereas an
    /// `async` body awaits an effect — there is no sub-domain on which it is
    /// referentially transparent. (Clock-determinism is a separate, *declared*
    /// claim; see `EffectAnnotationParser`.)
    public func verdict(for function: FunctionDeclSyntax) -> PurityVerdict {
        guard let body = function.body else { return .refuted }
        guard function.signature.effectSpecifiers?.asyncSpecifier == nil else { return .refuted }
        guard !bodyHasRefutingMarker(body), bodyIsTotal(body) else { return .refuted }
        guard function.signature.effectSpecifiers?.throwsClause != nil else { return .pure }
        return throwsOnlyItsOwnErrors(body) ? .pureButPartial : .refuted
    }

    /// Whether a **closure literal** is referentially transparent — the same refuters as a
    /// function, applied to the closure's statements.
    ///
    /// Closures need their own answer because a great deal of pure logic in real Swift has no name.
    /// A `filter` predicate or a `sorted(by:)` comparator written inline is a pure function in
    /// everything but syntax, and being anonymous is the only thing standing between it and a
    /// property test.
    ///
    /// **A capture is not an impurity.** The closure
    ///
    ///     files.filter { file in isChild(file.path, of: currentPath) }
    ///
    /// captures `currentPath`, and `currentPath` may well be a `var`. That says nothing about this
    /// closure: lift the body into `isChild(_ path: String, of parent: String)` and the capture
    /// simply *becomes a parameter*. What the caller does with its own state is the caller's
    /// business. What refutes purity is the body **mutating** what it captured — then it is not a
    /// function of its inputs, and no extraction saves it.
    public func isPure(_ closure: ClosureExprSyntax) -> Bool {
        // A closure declaring `async` or `throws` is out for the same reason a function is.
        if let effects = closure.signature?.effectSpecifiers,
           effects.asyncSpecifier != nil || effects.throwsClause != nil {
            return false
        }

        let statements = Syntax(closure.statements)
        guard !hasRefutingMarker(in: statements), isTotal(statements) else { return false }

        return !mutatesCapturedState(closure)
    }

    /// Whether a **computed property's getter** is referentially transparent.
    ///
    /// Callers need this to answer a question the function and closure forms cannot: *is reading
    /// `self.totalChunks` an impurity?* A consumer that only knows about stored properties must
    /// answer "yes, possibly" for every computed one — a computed `var` can read anything at all —
    /// and that answer is far too coarse. `var totalChunks: Int { (byteCount + chunkSize - 1) /
    /// chunkSize }` reads two `let`s and is exactly as pure as they are. Refusing it made the linter
    /// refuse the very value type it had just told a reader to extract.
    ///
    /// **This answers only the effect question — markers and totality — and deliberately not the
    /// state question.** Whether the names the getter reads are themselves immutable is a fact about
    /// the enclosing type, which this leaf cannot see; the caller resolves that. The division matters
    /// for soundness in one specific way: `var now: Date { Date() }` reads no mutable *state* at all,
    /// so a caller checking only names would wave it through. It is the **marker** scan here that
    /// refutes it.
    ///
    /// A setter, `willSet` or `didSet` refutes outright: a property with one is either observed
    /// stored state or a two-way channel, and neither is a value derived from `self`.
    public func isPure(_ accessor: AccessorBlockSyntax) -> Bool {
        switch accessor.accessors {
        case .getter(let statements):
            // The shorthand `var x: Int { … }` — the body IS the getter.
            return isPureBody(Syntax(statements))

        case .accessors(let list):
            var getterBody: Syntax?
            for declaration in list {
                switch declaration.accessorSpecifier.tokenKind {
                case .keyword(.get):
                    guard let body = declaration.body else { return false }
                    getterBody = Syntax(body.statements)

                default:
                    // `set`, `willSet`, `didSet`, `_modify`, … — not a derived value.
                    return false
                }
            }
            guard let getterBody else { return false }
            return isPureBody(getterBody)
        }
    }

    /// The effect half of purity, over any body: no I/O, no nondeterminism, and nothing that traps.
    private func isPureBody(_ syntax: Syntax) -> Bool {
        !hasRefutingMarker(in: syntax) && isTotal(syntax)
    }

    /// Whether the closure assigns to anything it did not itself declare — the one thing a capture
    /// can do that no extraction can rescue.
    private func mutatesCapturedState(_ closure: ClosureExprSyntax) -> Bool {
        let checker = CaptureMutationChecker(closure: closure, viewMode: .sourceAccurate)
        checker.walk(closure.statements)
        return checker.mutatesCapture
    }

    // MARK: - Refutation predicates

    private func bodyHasRefutingMarker(_ body: CodeBlockSyntax) -> Bool {
        hasRefutingMarker(in: Syntax(body))
    }

    /// Any I/O, logging, persistence, clock or randomness marker anywhere in `syntax`.
    private func hasRefutingMarker(in syntax: Syntax) -> Bool {
        syntax.tokens(viewMode: .sourceAccurate).contains {
            Self.sideEffectMarkers.contains($0.text)
                || Self.nondeterministicMarkers.contains($0.text)
        }
    }

    /// Whether nothing in `syntax` can trap at runtime.
    private func isTotal(_ syntax: Syntax) -> Bool {
        let checker = TotalityChecker()
        checker.walk(syntax)
        return checker.isTotal
    }

    /// True when nothing in the body can trap (crash) at runtime — the property
    /// that lets us treat the function as total. Force-unwrap (`!`), `try!`,
    /// `as!`, and the `fatalError` / `precondition` / `assert` family all
    /// introduce inputs for which there is no return value, so a property test
    /// over generated inputs would hit a crash rather than a falsified law.
    private func bodyIsTotal(_ body: CodeBlockSyntax) -> Bool {
        isTotal(Syntax(body))
    }

    /// Whether every way `body` can throw is one it raises *itself* — a `throw`
    /// of its own, and no `try` into a callee.
    ///
    /// This is what keeps `.pureButPartial` sound, and the reason it is needed is
    /// worth stating plainly: **`throws` was doing double duty as an impurity
    /// refuter, and the marker set had come to rely on it.** Nearly all real I/O
    /// in Swift throws, so gating on `throws` masked every marker the set does
    /// not name — `Process`, `Pipe`, `FileHandle`, `String(contentsOf:)`,
    /// `Data(contentsOf:)`, the SQLite surface. Relaxing `throws` without this
    /// second gate re-admitted all of them at once: a subprocess-spawning
    /// `runSwiftLint(executable:workingDirectory:lintFile:)` was judged pure,
    /// which is the lattice-bottom mistake the type's soundness note forbids.
    ///
    /// The distinction that survives the evidence is *where the error comes from*:
    ///
    /// - `guard let value = Int(text) else { throw ParseError.bad }` — the
    ///   function rejects an input it cannot map. It is a deterministic function
    ///   of its inputs on the rest of its domain. **Partial, and pure.**
    /// - `try process.run()`, `try String(contentsOf: url)` — the throw comes
    ///   from a callee this leaf cannot see, and so does whatever else the callee
    ///   does. **Doubt, and doubt refutes.**
    ///
    /// `try?` and `try!` count as propagation too: they still call something that
    /// throws. (`try!` is separately refuted by the totality checker.) The cost of
    /// this gate is a pure function that happens to call another pure throwing
    /// function — refused for want of the cross-file view a leaf does not have.
    /// That is the sound direction, and `EffectSymbolTable` is where a caller with
    /// the whole program in hand can do better.
    private func throwsOnlyItsOwnErrors(_ body: CodeBlockSyntax) -> Bool {
        let checker = TryExpressionChecker()
        checker.walk(body)
        return !checker.sawTry
    }
}

/// Detects any `try` — the mark of a throw propagated from a callee rather than
/// raised by the function itself.
private final class TryExpressionChecker: SourceAccurateSyntaxVisitor {

    private(set) var sawTry = false

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        sawTry = true
        return .skipChildren
    }
}

/// Walks a function body looking for any runtime trap that breaks totality.
private final class TotalityChecker: SourceAccurateSyntaxVisitor {

    private(set) var isTotal = true

    /// Standard-library trap functions: reaching them means the function has no
    /// return value for some inputs.
    private static let trapFunctions: Set<String> = [
        "fatalError", "preconditionFailure", "precondition",
        "assert", "assertionFailure"
    ]

    override func visit(_ node: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
        _ = node
        isTotal = false
        return .skipChildren
    }

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" { isTotal = false }
        return .visitChildren
    }

    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" { isTotal = false }
        return .visitChildren
    }

    // Raw (unfolded) parse trees represent `x as! T` as an `UnresolvedAsExprSyntax`
    // inside a `SequenceExprSyntax`; the folded `AsExprSyntax` form only appears
    // after operator-precedence folding, which the linter doesn't run.
    override func visit(_ node: UnresolvedAsExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" { isTotal = false }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
           Self.trapFunctions.contains(callee) {
            isTotal = false
        }
        return .visitChildren
    }
}

/// Detects a closure assigning to something it captured rather than declared.
///
/// A capture that is only *read* becomes a parameter when the closure is lifted into a named
/// function, and the lifted function is pure. A capture that is *written* cannot be lifted into
/// anything pure — the closure's whole job is the side effect, and no signature change fixes that.
///
/// Names bound by the closure itself — its parameters, and any `let`/`var` in its body — are fair
/// game to assign to: they are locals, not state.
private final class CaptureMutationChecker: SourceAccurateSyntaxVisitor {

    private let locallyBound: Set<String>
    private(set) var mutatesCapture = false

    init(closure: ClosureExprSyntax, viewMode: SyntaxTreeViewMode) {
        self.locallyBound = Self.namesBound(by: closure)
        super.init()
    }

    /// The folded form — present when the tree has been through an `OperatorTable`.
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard isAssignment(node.operator) else { return .visitChildren }
        refuteIfCaptured(node.leftOperand)
        return .visitChildren
    }

    /// The *unfolded* form, which is what `Parser.parse` actually produces: an operator sequence is
    /// a flat `SequenceExprSyntax` until an `OperatorTable` folds it, so a visitor that only knows
    /// `InfixOperatorExprSyntax` sees no assignments at all.
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (index, element) in elements.enumerated()
        where index > 0 && isAssignment(element) {
            refuteIfCaptured(elements[index - 1])
        }
        return .visitChildren
    }

    /// Records a mutation when `target` writes through something the closure captured rather than
    /// declared.
    private func refuteIfCaptured(_ target: ExprSyntax) {
        if let root = rootName(of: target), !locallyBound.contains(root) {
            mutatesCapture = true
        }
    }

    /// `=`, and the compound forms (`+=`, `-=`, …) — all of which write to the left-hand side.
    private func isAssignment(_ operatorExpr: ExprSyntax) -> Bool {
        if operatorExpr.is(AssignmentExprSyntax.self) { return true }
        guard let binary = operatorExpr.as(BinaryOperatorExprSyntax.self) else { return false }
        return binary.operator.text.hasSuffix("=")
            && !["==", "!=", "<=", ">="].contains(binary.operator.text)
    }

    /// The base identifier an assignment target ultimately writes through: `a` in `a`, `a.b`,
    /// `a[0].b`. `self.x = …` yields `self`, which is never locally bound, so it refutes.
    private func rootName(of expr: ExprSyntax) -> String? {
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            return rootName(of: base)
        }
        if let subscriptExpr = expr.as(SubscriptCallExprSyntax.self) {
            return rootName(of: subscriptExpr.calledExpression)
        }
        return nil
    }

    /// The closure's own parameters, plus every name it binds in its body.
    private static func namesBound(by closure: ClosureExprSyntax) -> Set<String> {
        var names: Set<String> = []

        if let parameterClause = closure.signature?.parameterClause {
            switch parameterClause {
            case .simpleInput(let list):
                for parameter in list { names.insert(parameter.name.text) }

            case .parameterClause(let clause):
                for parameter in clause.parameters {
                    names.insert(parameter.secondName?.text ?? parameter.firstName.text)
                }
            }
        }

        let collector = BoundNameCollector()
        collector.walk(closure.statements)
        return names.union(collector.names)
    }
}

/// Every name a body binds with a pattern — `let`/`var`, `if let`, `for … in`, `case let`.
private final class BoundNameCollector: SourceAccurateSyntaxVisitor {
    var names: Set<String> = []

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text)
        return .visitChildren
    }
}
