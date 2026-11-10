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

    /// What constructing each of the package's types runs — see `ConstructionFacts`. Empty by
    /// default, and an empty table leaves every answer, and its cost, exactly as it was.
    ///
    /// A consumer that judges a package should build the table once from its production sources
    /// and pass it to **every** inferrer it creates: one left at `.empty` silently disagrees with
    /// the configured ones in the same run, about any function that constructs a refuted type.
    public let constructionFacts: ConstructionFacts

    public init(constructionFacts: ConstructionFacts = .empty) {
        // No mutable state: the one piece of configuration is an immutable table.
        self.constructionFacts = constructionFacts
    }

    /// Returns `.pure` when `function` is referentially transparent — its
    /// signature is synchronous and non-throwing, neither its body nor any
    /// **default argument** references a side-effect or nondeterminism marker,
    /// and nothing in either can trap — and `nil` (purity refuted) otherwise.
    ///
    /// The default arguments are part of the answer because they are part of the
    /// function: they run on exactly the calls that omit them. See
    /// `hasRefutingDefaultArgument`, which also says why the *whole* signature is
    /// deliberately not scanned.
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
        wholeDomainRefutation(for: function) == nil ? .pure : nil
    }

    /// Convenience boolean form of `inferredEffect(for:)`.
    public func isPure(_ function: FunctionDeclSyntax) -> Bool {
        inferredEffect(for: function) == .pure
    }

    /// **Why** the whole-domain question refused `function` — the witness behind
    /// `inferredEffect(for:) == nil`, or `nil` when it returned `.pure`.
    ///
    /// This is `inferredEffect`'s own answer rather than a second opinion:
    /// `inferredEffect` is now defined as *this returned nothing*, so the two
    /// cannot drift. The signature short-circuit `inferredEffect` exists for is
    /// preserved here — a `throws` function is `.declaredThrows` without a single
    /// body walk, which is what
    /// [#1](https://github.com/Joseph-Cursio/SwiftEffectInference/issues/1) is
    /// about.
    ///
    /// **`.declaredThrows` is the only case `refutation(for:)` cannot produce**,
    /// and it is the whole difference between the two questions. Everything else
    /// is delegated, so the refuters are written once.
    public func wholeDomainRefutation(for function: FunctionDeclSyntax) -> PurityRefutation? {
        guard function.body != nil else { return .noBody }
        // The cheap rejections first, and `throws` belongs among them HERE even
        // though it cannot be there in `verdict`.
        guard function.signature.effectSpecifiers?.asyncSpecifier == nil else { return .declaredAsync }
        guard function.signature.effectSpecifiers?.throwsClause == nil else { return .declaredThrows }
        return refutation(for: function)
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
        guard refutation(for: function) == nil else { return .refuted }
        return function.signature.effectSpecifiers?.throwsClause == nil ? .pure : .pureButPartial
    }

    /// **Why** purity was refuted, or `nil` when it was not — the witness
    /// `PurityVerdict` does not carry.
    ///
    /// `nil` here means `.pure` **or** `.pureButPartial`: a function that raises
    /// only its own errors has not been refuted, it has been narrowed, and
    /// `verdict(for:)` is the method that says which. That is why this returns an
    /// optional rather than a `PurityRefutation` beside a verdict — there is no
    /// witness for "it throws, and that is fine".
    ///
    /// `verdict(for:)` is defined as *this returned nothing*, so a refuter taught
    /// to one is taught to both. The refuters run in a fixed order and the first
    /// one to fire is the answer; see `PurityRefutation` on why one witness rather
    /// than all of them.
    ///
    /// ## What this unblocks
    ///
    /// A consumer that wants to *report* an impurity rather than gate on one. The
    /// census rules downstream drop an impure closure without a word, so they
    /// publish an inventory of what is already testable and discard the
    /// complement — which is the half a reader acts on. And a caller taking the
    /// meet of its own analysis with this one no longer has to infer a witness
    /// from the `throws` clause, which was the only refutation reason visible from
    /// outside.
    public func refutation(for function: FunctionDeclSyntax) -> PurityRefutation? {
        guard let body = function.body else { return .noBody }
        guard function.signature.effectSpecifiers?.asyncSpecifier == nil else { return .declaredAsync }
        if let refutation = bodyRefutation(Syntax(body)) { return refutation }
        if let refutation = refutingDefaultArgument(function.signature) { return refutation }
        guard function.signature.effectSpecifiers?.throwsClause != nil else { return nil }
        return throwsOnlyItsOwnErrors(body) ? nil : .propagatedTry
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
        refutation(for: closure) == nil
    }

    /// **Why** `closure` is not referentially transparent, or `nil` when it is.
    ///
    /// `isPure(_ closure:)` is defined as *this returned nothing*. The reason the
    /// witness matters more here than anywhere else is that a closure has no name:
    /// a report saying *this `filter` predicate is impure* and not what makes it
    /// so leaves the reader to re-derive the analysis from the one line of source
    /// the diagnostic points at.
    ///
    /// Unlike the function form, `throws` refutes outright — there is no
    /// `.pureButPartial` for a closure, because nothing downstream narrows a law's
    /// domain to an anonymous callee's success set.
    public func refutation(for closure: ClosureExprSyntax) -> PurityRefutation? {
        // A closure declaring `async` or `throws` is out for the same reason a function is.
        if let effects = closure.signature?.effectSpecifiers {
            if effects.asyncSpecifier != nil { return .declaredAsync }
            if effects.throwsClause != nil { return .declaredThrows }
        }

        let statements = Syntax(closure.statements)
        if let refutation = bodyRefutation(statements) { return refutation }

        return mutatedCaptureName(closure).map { .mutatesCapturedState($0) }
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
        refutation(for: accessor) == nil
    }

    /// **Why** `accessor`'s getter is not a derived value, or `nil` when it is.
    ///
    /// `isPure(_ accessor:)` is defined as *this returned nothing*. `.notAGetter`
    /// names the specifier that disqualified the property, which is a different
    /// piece of advice from every other case here: a `didSet` is not a bug to fix,
    /// it is a statement that the property is observed stored state.
    public func refutation(for accessor: AccessorBlockSyntax) -> PurityRefutation? {
        switch accessor.accessors {
        case .getter(let statements):
            // The shorthand `var x: Int { … }` — the body IS the getter.
            return bodyRefutation(Syntax(statements))

        case .accessors(let list):
            var getterBody: Syntax?
            for declaration in list {
                switch declaration.accessorSpecifier.tokenKind {
                case .keyword(.get):
                    guard let body = declaration.body else { return .noBody }
                    getterBody = Syntax(body.statements)

                default:
                    // `set`, `willSet`, `didSet`, `_modify`, … — not a derived value.
                    return .notAGetter(declaration.accessorSpecifier.text)
                }
            }
            guard let getterBody else { return .noBody }
            return bodyRefutation(getterBody)
        }
    }

    /// The effect half of purity, over any body: no I/O, no nondeterminism, and nothing that traps.
    ///
    /// The order is the one every entry point relies on — markers, then totality —
    /// so the witness a consumer sees does not depend on which door it came in by.
    func bodyRefutation(_ syntax: Syntax) -> PurityRefutation? {
        if let marker = refutingMarker(in: syntax) { return marker }
        return trap(in: syntax).map { .partiality($0) }
    }

    /// Whether the closure assigns to anything it did not itself declare — the one thing a capture
    /// can do that no extraction can rescue.
    ///
    /// **Published separately from `isPure(_ closure:)` because a caller can want this clause
    /// alone.** `isPure` folds four refuters into one Bool — `async`/`throws`, impurity markers,
    /// totality, and this — which answers "may I property-test it?" and nothing else. Inverting that
    /// Bool does *not* yield this predicate: `{ print(x) }` is impure and mutates no capture.
    ///
    /// The caller this exists for is the opposite question. `isPure` uses a captured write to
    /// *refute* a claim, so over-reporting one is free — the cost is a missed candidate. A caller
    /// asking "does this closure's effect escape into captured state?" is making a **positive**
    /// claim, and pays for a wrong answer with a wrong assertion. Both need the same verdict; only
    /// one of them can afford to approximate it, which is why the flat-scope caveat on
    /// `BoundNameCollector` is worth reading before consuming this.
    ///
    /// Returns `false` for a closure that only *reads* what it captured. That is the interesting
    /// half of the definition and the reason this is not simply "does it touch a capture": a read
    /// capture becomes a parameter under extraction, and a written one does not.
    public func mutatesCapturedState(_ closure: ClosureExprSyntax) -> Bool {
        mutatedCaptureName(closure) != nil
    }

    /// The name the closure writes through, or `nil` when it writes through none —
    /// the witness form of `mutatesCapturedState(_:)`, which is defined as *this
    /// returned something*.
    ///
    /// The root name, not the whole expression: `self.cache[key] = value` yields
    /// `"self"`, because `self` is what the write escapes into and what no
    /// extraction can turn into a parameter.
    public func mutatedCaptureName(_ closure: ClosureExprSyntax) -> String? {
        let checker = CaptureMutationChecker(closure: closure, viewMode: .sourceAccurate)
        checker.walk(closure.statements)
        return checker.mutatedName
    }

    /// What constructing a type runs, judged on the **transparency half only** — markers, the
    /// classifier, file reads and nested constructions, never totality. A trap in an initializer
    /// is a trap in a callee, and no other callee's traps are followed either.
    func constructionRefutation(_ syntax: Syntax) -> PurityRefutation? {
        refutingMarker(in: syntax)
    }

    /// The first trap in `syntax`, or `nil` when nothing in it can trap at runtime.
    private func trap(in syntax: Syntax) -> PurityRefutation.Partiality? {
        let checker = TotalityChecker()
        checker.walk(syntax)
        return checker.trap
    }
}
