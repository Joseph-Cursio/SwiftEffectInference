import SwiftSyntax

/// Parses declared `Effect` values from a Swift declaration's doc-comment
/// trivia (`/// @lint.effect <tier>`) and attribute list (`@Idempotent`,
/// `@NonIdempotent`, `@Observational`, `@ExternallyIdempotent(by:)`).
///
/// Bilingual by design: both grammars compile down to the same `Effect`.
/// Recognized attribute names are configurable via `AttributeRecognition`,
/// so a project that uses a different marker family (or extends the
/// `swiftidempotency`-shipped names) can pass a custom set without forking
/// the parser. The default matches `swiftidempotency`'s shipped macros.
///
/// **Collision-withdrawal semantics.** When a declaration carries both an
/// attribute-form and a doc-comment-form annotation that disagree, the
/// parser returns `nil` — same policy as cross-file collision in
/// `EffectSymbolTable`. Two conflicting user-authored signals on one
/// declaration express ambiguity the parser will not paper over.
///
/// Origin: lifted from SwiftProjectLint's `EffectAnnotationParser`
/// (`Packages/SwiftProjectLintVisitors/Sources/SwiftProjectLintVisitors/EffectAnnotationParser.swift`)
/// during migration step 3 of `docs/SwiftEffectInference Design v0.2.md` §10.
/// SPL's `ContextEffect` parsing (the `@lint.context` grammar) stays in
/// SPL — it gates which lint rules fire and is out of scope for the
/// shared core (design v0.2 §6).
public struct EffectAnnotationParser: Sendable {

    /// The set of attribute names this parser recognizes as effect markers,
    /// keyed by tier. Override when the upstream macro surface changes or
    /// when integrating a project-specific marker family.
    public struct AttributeRecognition: Sendable {

        public let pure: Set<String>
        public let idempotent: Set<String>
        public let nonIdempotent: Set<String>
        public let observational: Set<String>
        public let externallyIdempotent: Set<String>

        /// - Parameter pure: attribute names recognized as the `pure` tier
        ///   (referential transparency). Defaults to `["Pure"]`. Carries a
        ///   default so existing callers that predate the `pure` tier keep
        ///   compiling — the addition is purely additive at the lattice bottom.
        public init(
            idempotent: Set<String>,
            nonIdempotent: Set<String>,
            observational: Set<String>,
            externallyIdempotent: Set<String>,
            pure: Set<String> = ["Pure"]
        ) {
            self.pure = pure
            self.idempotent = idempotent
            self.nonIdempotent = nonIdempotent
            self.observational = observational
            self.externallyIdempotent = externallyIdempotent
        }

        /// Default recognition set, matching `swiftidempotency`'s shipped
        /// macros at the time SwiftEffectInference was tagged.
        public static let `default` = AttributeRecognition(
            idempotent: ["Idempotent"],
            nonIdempotent: ["NonIdempotent"],
            observational: ["Observational"],
            externallyIdempotent: ["ExternallyIdempotent"],
            pure: ["Pure"]
        )
    }

    public let recognition: AttributeRecognition

    public init(recognition: AttributeRecognition = .default) {
        self.recognition = recognition
    }

    // MARK: Static convenience (default-recognition shortcuts)

    /// Convenience for callers that don't customize attribute recognition.
    /// Equivalent to `EffectAnnotationParser().parseEffect(leadingTrivia:)`.
    public static func parseEffect(leadingTrivia: Trivia) -> Effect? {
        EffectAnnotationParser().parseEffect(leadingTrivia: leadingTrivia)
    }

    /// Convenience for callers that don't customize attribute recognition.
    /// Equivalent to `EffectAnnotationParser().parseEffect(declaration:)`.
    public static func parseEffect(declaration: FunctionDeclSyntax) -> Effect? {
        EffectAnnotationParser().parseEffect(declaration: declaration)
    }

    /// Convenience for callers that don't customize attribute recognition.
    /// Equivalent to `EffectAnnotationParser().parseEffect(declaration:)`.
    public static func parseEffect(declaration: VariableDeclSyntax) -> Effect? {
        EffectAnnotationParser().parseEffect(declaration: declaration)
    }

    // MARK: Public API

    /// Reads the `@lint.effect` tier declared on a node, scanning only the
    /// supplied trivia. Callers with a whole declaration should prefer
    /// `parseEffect(declaration:)`, which collects trivia from every
    /// position a doc comment can legitimately live (between attributes,
    /// before modifiers, before the `func`/`var` keyword).
    public func parseEffect(leadingTrivia: Trivia) -> Effect? {
        for line in Self.docCommentLines(from: leadingTrivia) {
            if let effect = Self.extractEffect(from: line) {
                return effect
            }
        }
        return nil
    }

    /// Reads the effect declared on a function. Considers both doc-comment
    /// annotations (`/// @lint.effect idempotent`) and attribute-form
    /// annotations (`@Idempotent`, etc.) per `recognition`.
    ///
    /// `FunctionDeclSyntax.leadingTrivia` only covers trivia before the
    /// declaration's first token — which, when attributes are present, is
    /// the first attribute's `@`. Doc comments that sit between attributes
    /// and modifiers, or between modifiers and `func`, land in different
    /// trivia positions. This overload collects from every such position
    /// so annotations are read regardless of ordering.
    ///
    /// When both attribute and doc-comment forms agree, that effect is
    /// returned. When they disagree, returns `nil` (collision-withdraw).
    public func parseEffect(declaration: FunctionDeclSyntax) -> Effect? {
        resolveDeclEffect(
            attributes: declaration.attributes,
            docTrivia: Self.combinedDocTrivia(for: declaration)
        )
    }

    /// Same combined-position parsing for variable bindings. A
    /// `let`/`var` binding can carry effect annotations when the binding's
    /// initializer is a closure literal (handler-style code); the parser
    /// is content-blind and returns whatever annotation is present.
    public func parseEffect(declaration: VariableDeclSyntax) -> Effect? {
        resolveDeclEffect(
            attributes: declaration.attributes,
            docTrivia: Self.combinedDocTrivia(for: declaration)
        )
    }

    /// Shared body for the two `parseEffect(declaration:)` overloads. Both
    /// decl kinds combine an attribute-form signal with a doc-comment signal
    /// and resolve them identically; they differ only in how the attribute
    /// list and combined doc trivia are extracted (handled by the callers'
    /// overloaded accessors).
    private func resolveDeclEffect(
        attributes: AttributeListSyntax,
        docTrivia: Trivia
    ) -> Effect? {
        let attributeEffect = effectFromAttributes(attributes)
        let docCommentEffect = parseEffect(leadingTrivia: docTrivia)
        return Self.resolveEffectSignals(attribute: attributeEffect, docComment: docCommentEffect)
    }

    // MARK: Attribute-form (instance — uses `recognition`)

    /// Scans an attribute list for any name in the configured
    /// `AttributeRecognition` set and returns the corresponding `Effect`.
    /// Returns `nil` when no recognized attribute is present.
    ///
    /// Recognises attribute names verbatim — no macro expansion is consulted.
    /// The parser works independently of whether the macro package emitting
    /// the attributes is in the build.
    func effectFromAttributes(_ attributes: AttributeListSyntax) -> Effect? {
        for element in attributes {
            guard let attr = element.as(AttributeSyntax.self) else { continue }
            guard let typeName = Self.attributeTypeName(attr.attributeName) else { continue }

            if recognition.pure.contains(typeName) {
                return .pure
            }
            if recognition.idempotent.contains(typeName) {
                return .idempotent
            }
            if recognition.nonIdempotent.contains(typeName) {
                return .nonIdempotent
            }
            if recognition.observational.contains(typeName) {
                return .observational
            }
            if recognition.externallyIdempotent.contains(typeName) {
                return .externallyIdempotent(keyParameter: Self.extractByLabel(from: attr))
            }
        }
        return nil
    }

    // MARK: Static helpers (no instance state needed)

    /// Combines trivia from every position in a function declaration's
    /// header where a user-authored doc comment can legitimately sit.
    static func combinedDocTrivia(for decl: FunctionDeclSyntax) -> Trivia {
        combinedDocTrivia(
            leadingTrivia: decl.leadingTrivia,
            attributes: decl.attributes,
            modifiers: decl.modifiers,
            // The declaration keyword closes the header; its leading trivia
            // is the last place a doc comment can sit before the signature.
            keywordLeadingTrivia: decl.funcKeyword.leadingTrivia
        )
    }

    /// Same combining strategy for variable declarations.
    static func combinedDocTrivia(for decl: VariableDeclSyntax) -> Trivia {
        combinedDocTrivia(
            leadingTrivia: decl.leadingTrivia,
            attributes: decl.attributes,
            modifiers: decl.modifiers,
            keywordLeadingTrivia: decl.bindingSpecifier.leadingTrivia
        )
    }

    /// Shared core for the `combinedDocTrivia` overloads. The two decl kinds
    /// differ only in which token closes the header (`func` vs `let`/`var`),
    /// supplied as `keywordLeadingTrivia`; everything before it — the
    /// declaration's own leading trivia, attribute trivia, and modifier
    /// leading trivia — combines identically.
    private static func combinedDocTrivia(
        leadingTrivia: Trivia,
        attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax,
        keywordLeadingTrivia: Trivia
    ) -> Trivia {
        var pieces: [TriviaPiece] = []
        pieces.append(contentsOf: leadingTrivia)
        for attribute in attributes {
            pieces.append(contentsOf: attribute.leadingTrivia)
            pieces.append(contentsOf: attribute.trailingTrivia)
        }
        for modifier in modifiers {
            pieces.append(contentsOf: modifier.leadingTrivia)
        }
        pieces.append(contentsOf: keywordLeadingTrivia)
        return Trivia(pieces: pieces)
    }

    /// Resolves a declaration's effect when both attribute-form and
    /// doc-comment-form signals may be present.
    ///
    /// - Neither present → nil
    /// - One present → that one
    /// - Both present and agree → that tier
    /// - Both present and disagree → nil (collision-withdraw)
    static func resolveEffectSignals(
        attribute: Effect?,
        docComment: Effect?
    ) -> Effect? {
        switch (attribute, docComment) {
        case (nil, nil): return nil
        case (let attr?, nil): return attr
        case (nil, let doc?): return doc
        case (let attr?, let doc?): return attr == doc ? attr : nil
        }
    }

    /// Extracts the bare identifier name from an attribute's type syntax.
    /// Returns nil for complex types (member access, generic, etc.).
    private static func attributeTypeName(_ type: TypeSyntax) -> String? {
        type.as(IdentifierTypeSyntax.self)?.name.text
    }

    /// Extracts the `by:` labelled string-literal argument from an attribute,
    /// if present. Empty-string arguments normalise to nil so
    /// `@ExternallyIdempotent(by: "")` behaves identically to the
    /// label-omitting `@ExternallyIdempotent` form.
    private static func extractByLabel(from attr: AttributeSyntax) -> String? {
        guard case .argumentList(let args) = attr.arguments else { return nil }
        for arg in args {
            guard arg.label?.text == "by",
                  let strLit = arg.expression.as(StringLiteralExprSyntax.self),
                  strLit.segments.count == 1,
                  let segment = strLit.segments.first?.as(StringSegmentSyntax.self) else {
                continue
            }
            let text = segment.content.text
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func docCommentLines(from trivia: Trivia) -> [String] {
        trivia.compactMap { piece -> String? in
            switch piece {
            case .docLineComment(let text), .docBlockComment(let text):
                return text
            default:
                return nil
            }
        }
    }

    private static func extractEffect(from line: String) -> Effect? {
        guard let range = line.range(of: "@lint.effect") else { return nil }
        let rest = line[range.upperBound...].trimmingLeadingWhitespace()
        let token = rest.firstWord()
        switch token {
        case "pure":
            return .pure
        case "idempotent":
            return .idempotent
        case "observational":
            return .observational
        case "externally_idempotent":
            let afterToken = rest.dropFirst(token.count).trimmingLeadingWhitespace()
            return .externallyIdempotent(keyParameter: extractByQualifier(from: afterToken))
        case "non_idempotent":
            return .nonIdempotent
        case "transactional_idempotent":
            // `transactional_idempotent` is a tier in SwiftIdempotency's
            // *non-linear* lattice — it sits parallel to (and incomparable
            // with) `externallyIdempotent`: both are conditionally idempotent
            // via an external mechanism (a transaction boundary vs. a dedup
            // key). SEI's `Effect` is a deliberately *linear* chain (see the
            // decision note on `Effect`), so the tier is not modelled as its
            // own case. We still recognize the doc-comment spelling rather
            // than silently dropping it, and project it conservatively onto
            // `.nonIdempotent`: without verifying the transaction boundary
            // (which needs the `@lint.txn_boundary` companion SwiftIdempotency
            // requires, and which SEI does not analyse), the sound assumption
            // is that the individually-non-idempotent effects re-fire on
            // replay. This matches SwiftIdempotency's own strict-mode
            // `transactional_idempotent → non_idempotent` degradation.
            return .nonIdempotent
        default:
            return nil
        }
    }

    /// Extracts a `(by: paramName)` qualifier if present. Tolerates whitespace
    /// variants. Returns `nil` when the qualifier is absent or malformed.
    private static func extractByQualifier(from text: Substring) -> String? {
        guard text.first == "(" else { return nil }
        let inside = text.dropFirst().trimmingLeadingWhitespace()
        guard inside.hasPrefix("by:") else { return nil }
        let afterBy = inside.dropFirst(3).trimmingLeadingWhitespace()
        let ident = afterBy.firstIdentifier()
        return ident.isEmpty ? nil : String(ident)
    }
}

// MARK: - Substring helpers

private extension Substring {

    func trimmingLeadingWhitespace() -> Substring {
        var slice = self
        while let char = slice.first, char == " " || char == "\t" { slice = slice.dropFirst() }
        return slice
    }

    func firstWord() -> String {
        var out = ""
        for char in self {
            if char.isWhitespace { break }
            if char == "(" || char == ":" { break }
            out.append(char)
        }
        return out
    }

    /// Reads the longest prefix of identifier characters (letters, digits,
    /// underscore).
    func firstIdentifier() -> Substring {
        var end = startIndex
        for idx in indices {
            let char = self[idx]
            if char.isLetter || char.isNumber || char == "_" {
                end = index(after: idx)
            } else {
                break
            }
        }
        return self[startIndex..<end]
    }
}
