/// Parses declared effects from a function declaration's leading trivia
/// (doc comments) and attribute list.
///
/// Real implementation lifted from SwiftProjectLint in migration step 3.
/// The skeleton only fixes the public type name and the `AttributeRecognition`
/// shape so the rest of the package can refer to it.
///
/// Recognized attribute names are configurable per design v0.2 §5 / Q3.
/// Default matches `swiftidempotency`'s shipped set.
public struct EffectAnnotationParser: Sendable {

    public struct AttributeRecognition: Sendable {
        public let idempotent: Set<String>
        public let nonIdempotent: Set<String>
        public let observational: Set<String>
        public let externallyIdempotent: Set<String>

        public init(
            idempotent: Set<String>,
            nonIdempotent: Set<String>,
            observational: Set<String>,
            externallyIdempotent: Set<String>
        ) {
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
            externallyIdempotent: ["ExternallyIdempotent"]
        )
    }

    public let recognition: AttributeRecognition

    public init(recognition: AttributeRecognition = .default) {
        self.recognition = recognition
    }
}
