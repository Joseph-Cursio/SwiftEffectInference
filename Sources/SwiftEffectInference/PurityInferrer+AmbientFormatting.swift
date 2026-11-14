import SwiftSyntax

extension PurityInferrer {

    /// Whether `token` names a `formatted(…)` call that formats with the user's locale, time zone
    /// or calendar: `d.formatted()`, `n.formatted(.number)`, `t.formatted(.units())`.
    ///
    /// Foundation declares `formatted` on `Date`, the integer and floating-point types, `Decimal`,
    /// `Duration`, a range of dates, string sequences, `Measurement` and `PersonNameComponents`.
    /// Each formats with the ambient settings unless locale, time zone and calendar are all
    /// pinned, and a relative style reads the clock too. The receiver's type is not visible here,
    /// so any called `formatted` with a receiver refutes, except two forms known to read nothing:
    /// an `.iso8601` style, which is always GMT and never localized, and swift-syntax's
    /// `formatted(using:)`, which lays out source text. A package's own deterministic `formatted`
    /// or style is refuted along with Foundation's, and so is swift-syntax's `formatted()` with
    /// its default. That is the sound direction.
    ///
    /// A base-less `.formatted(formatter)` is a coding strategy's case, so it does not match. Nor
    /// does a `formatted` that is not called, which is most often some other type's property. A
    /// reference to Foundation's own method, `let render: () -> String = d.formatted`, is missed.
    static func isAmbientFormatting(_ token: TokenSyntax) -> Bool {
        guard token.text == "formatted",
              let reference = token.parent?.as(DeclReferenceExprSyntax.self),
              let member = reference.parent?.as(MemberAccessExprSyntax.self),
              member.base != nil, member.declName.id == reference.id,
              let call = member.parent?.as(FunctionCallExprSyntax.self),
              call.calledExpression.id == member.id else { return false }
        if call.arguments.contains(where: { $0.label?.text == "using" }) { return false }
        guard call.arguments.count == 1, let style = call.arguments.first, style.label == nil else { return true }
        return baseLessRoot(of: style.expression) != "iso8601"
    }

    /// The member at the bottom of a chain when it is written without a base: `iso8601` for
    /// `.iso8601.year().month()`.
    private static func baseLessRoot(of expression: ExprSyntax) -> String? {
        if let call = expression.as(FunctionCallExprSyntax.self) { return baseLessRoot(of: call.calledExpression) }
        guard let member = expression.as(MemberAccessExprSyntax.self) else { return nil }
        guard let base = member.base else { return member.declName.baseName.text }
        return baseLessRoot(of: base)
    }
}
