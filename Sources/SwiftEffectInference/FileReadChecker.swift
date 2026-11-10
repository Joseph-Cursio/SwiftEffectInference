import SwiftSyntax

/// Detects a file read spelled `SomeType(contentsOf:)`.
///
/// `contentsOf` cannot be matched as a bare token: it is the argument label of
/// `append(contentsOf:)` and `insert(contentsOf:)`, so a token match refutes
/// every pure function that appends one collection to another. Matching the
/// *callee* separates them — `String(contentsOf: url)` names a file-reading
/// type, `array.append(contentsOf: other)` does not.
final class FileReadChecker: SourceAccurateSyntaxVisitor {

    /// Types whose `init(contentsOf:)` reads from a URL or path. `String` and
    /// `Data` are deliberately absent from `sideEffectMarkers` because naming
    /// them as bare tokens would refute nearly everything; naming them here is
    /// safe, because the match also requires the `contentsOf` label.
    private static let fileReadingTypes: Set<String> = [
        "String", "Data", "NSString", "NSData", "NSDictionary", "NSArray"
    ]

    /// The first read seen, spelled as the diagnostic wants it —
    /// `"String(contentsOf:)"`.
    private(set) var fileRead: String?

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
              Self.fileReadingTypes.contains(callee.baseName.text),
              node.arguments.contains(where: { $0.label?.text == "contentsOf" })
        else { return .visitChildren }
        if fileRead == nil { fileRead = "\(callee.baseName.text)(contentsOf:)" }
        return .visitChildren
    }
}
