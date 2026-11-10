import SwiftSyntax

public extension DeclarationShape {

    /// The shape of a function declaration: its parameters, their defaults and their variadics.
    static func from(declaration: FunctionDeclSyntax) -> DeclarationShape {
        let parameters = declaration.signature.parameterClause.parameters.map { param in
            Parameter(
                label: param.firstName.text.isEmpty ? "_" : param.firstName.text,
                hasDefault: param.defaultValue != nil,
                isVariadic: param.ellipsis != nil
            )
        }
        return DeclarationShape(name: declaration.name.text, parameters: parameters)
    }

    /// The shape of a closure-typed stored property, treated as a pseudo-method. Swift function
    /// types carry neither default arguments nor variadics, so every parameter is required.
    static func from(declaration: VariableDeclSyntax) -> DeclarationShape? {
        guard let signature = FunctionSignature.from(declaration: declaration) else {
            return nil
        }
        return DeclarationShape(
            name: signature.name,
            parameters: signature.argumentLabels.map {
                Parameter(label: $0, hasDefault: false, isVariadic: false)
            }
        )
    }
}
