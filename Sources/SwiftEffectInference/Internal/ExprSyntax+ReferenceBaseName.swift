import SwiftSyntax

package extension ExprSyntax {
    /// The trailing identifier of a reference expression: the base name of a
    /// `DeclReferenceExprSyntax` (`foo` → `"foo"`) or the member name of a
    /// `MemberAccessExprSyntax` (`a.b.foo` → `"foo"`). Returns `nil` for any
    /// other expression kind.
    ///
    /// Shared by the call- and signature-walkers that pull a bare callee or
    /// type identifier from a called-expression leaf. Callers needing more
    /// (e.g. peeling a generic specialization) layer that on top.
    var referenceBaseName: String? {
        if let ref = self.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text
        }
        if let member = self.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
    }
}
