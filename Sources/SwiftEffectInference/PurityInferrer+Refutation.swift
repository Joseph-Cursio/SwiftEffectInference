import SwiftSyntax

extension PurityInferrer {

    // MARK: - Refutation predicates

    /// Whether any parameter's **default value** refutes purity.
    ///
    /// A default argument is code the function runs, and it runs on exactly the
    /// calls that omit it. `func bridges(_ s: [S], now: Date = Date())` reads the
    /// system clock every time a caller writes `bridges(suggestions)` — the
    /// function is not a function of its inputs, because one of its inputs is the
    /// clock. The body says so nowhere, which is why the body scan cannot see it:
    /// `bodyHasRefutingMarker` is handed `function.body`, and a default value
    /// lives in the signature.
    ///
    /// **Measured before it was fixed**, over SwiftInferProperties' `Sources/`
    /// (2,456 non-refuted functions, tree `abbc0edb`): **15 subjects defaulted a
    /// parameter to a marker and were judged `.pure`** — fourteen `Date()`, one
    /// pair reading `FileManager.default.currentDirectoryPath`, every one of them
    /// hand-checked. Small, and unambiguous: none is a borderline call.
    ///
    /// ## Default *values*, never the whole signature
    ///
    /// The scope is the entire fix and the entire trap. `func f(_ d: Date) -> Int`
    /// mentions the `Date` marker in a parameter **type** and is perfectly pure —
    /// taking a value is not reading a clock, and a function that accepts the
    /// clock's reading as an argument is the *fixed* shape, the one every
    /// dependency-injection guide recommends. A whole-signature token scan would
    /// refute exactly the code this inferrer should be rewarding. So the walk
    /// starts at `parameter.defaultValue?.value` and nowhere else.
    ///
    /// ## Except where the default names nothing
    ///
    /// `at: Date = .init()` is `Date()`, and the default says so nowhere: `.init()`
    /// names no type, and the classifier matches `Date()` only with its callee
    /// written. (`.now` is a marker of its own.) An implicit member's type is spelled in the parameter's type and
    /// nowhere else, so a default with one is judged with that type: `Date`,
    /// `UUID` and `FileHandle` refute there as they would in front of the member,
    /// and each member is judged again with the type in front of it, so
    /// `calendar: Calendar = .current` is `Calendar.current`.
    /// A parameter whose own default has no implicit member keeps the rule above,
    /// and so does every other parameter of the same function.
    ///
    /// ## Totality travels with the markers
    ///
    /// `!isTotal` is checked here for the same reason it is checked on the body: a
    /// default of `xs.first!` traps at the call sites that omit it, and a property
    /// test over generated inputs would crash rather than falsify. Whether the
    /// trap is written inside the braces or in the parameter list is not a
    /// distinction the caller can observe.
    ///
    /// ## What this does not reach
    ///
    /// Only `FunctionDeclSyntax` — the type this inferrer takes. Initialisers and
    /// subscripts have parameter lists and defaults too, and no entry point here
    /// accepts them. Accessors have no parameters, and a closure signature cannot
    /// carry a default value, so both other entry points are unaffected by
    /// construction rather than by omission. An initialiser's defaults are judged
    /// from the other side instead: a body that *calls* it, omitting one, is
    /// refuted through `ConstructionFacts` when the inferrer was given them.
    func refutingDefaultArgument(_ signature: FunctionSignatureSyntax) -> PurityRefutation? {
        for parameter in signature.parameterClause.parameters {
            guard let defaultValue = parameter.defaultValue?.value else { continue }
            guard let cause = bodyRefutation(Syntax(defaultValue)) ?? typeRefutation(of: parameter) else {
                continue
            }
            let name = parameter.secondName?.text ?? parameter.firstName.text
            return .refutingDefaultArgument(parameter: name, cause: cause)
        }
        return nil
    }

    /// The parameter's type, judged when its default has an implicit member, which names its type
    /// only there. A closure's members count too: the closure runs when the body calls it.
    ///
    /// The type's own markers refute, and so does each implicit member judged with the type
    /// written in front of it, as a construction's default is: `calendar: Calendar = .current` is
    /// `Calendar.current`, which no token of the type says.
    private func typeRefutation(of parameter: FunctionParameterSyntax) -> PurityRefutation? {
        guard let defaultValue = parameter.defaultValue?.value else { return nil }
        let members = ImplicitMemberChecker()
        members.walk(defaultValue)
        guard members.found else { return nil }
        return refutingMarker(in: Syntax(parameter.type))
            ?? RawDeclaration.judge(defaultValue, declaredAs: parameter.type, with: self, facts: constructionFacts)
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
    func throwsOnlyItsOwnErrors(_ body: CodeBlockSyntax) -> Bool {
        let checker = TryExpressionChecker()
        checker.walk(body)
        return !checker.sawTry
    }
}
