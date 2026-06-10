import SwiftSyntax

/// Shared base for the package's collector visitors. Every collector walks in
/// `.sourceAccurate` mode; this base captures that single decision so each
/// subclass declares only the node type it gathers, not the view-mode init.
///
/// A shared base (rather than a generic collector) is required because
/// `SyntaxVisitor` dispatches to concrete-typed `visit(_:)` overrides; a
/// generic `visit(_ node: Node)` would match none of them. Subclasses with no
/// stored state inherit this `init()` directly; those that add state (e.g. a
/// parser) declare their own init and call `super.init()`.
class SourceAccurateSyntaxVisitor: SyntaxVisitor {
    init() {
        super.init(viewMode: .sourceAccurate)
    }
}
