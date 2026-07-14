import SwiftParser
import SwiftSyntax
import Testing

@testable import SwiftEffectInference

/// Purity, asked of a computed property's getter.
///
/// Callers need this to answer a question the function and closure forms cannot: *is reading
/// `self.totalChunks` an impurity?* A consumer that knows only about **stored** properties has to
/// answer "possibly, yes" for every computed one, and that answer is far too coarse — it made the
/// linter refuse the very value type it had just told a reader to extract.
///
/// This oracle answers only the **effect** half: markers and totality. Whether the names the getter
/// reads are themselves immutable is a fact about the enclosing type, and the caller resolves it.
/// The division is what makes `var now: Date { Date() }` interesting: it reads no mutable *state* at
/// all, so a caller checking names alone would wave it through, and only the marker scan here
/// refutes it.
@Suite("Computed-property purity")
struct AccessorPurityTests {

    /// The first computed property's accessor block in `source`.
    private func accessor(in source: String) throws -> AccessorBlockSyntax {
        final class Finder: SyntaxVisitor {
            var found: AccessorBlockSyntax?
            override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: source))
        return try #require(finder.found)
    }

    private func isPure(_ source: String) throws -> Bool {
        try PurityInferrer().isPure(accessor(in: source))
    }

    // MARK: - Derived values

    @Test("arithmetic over the type's own state is pure")
    func arithmeticGetterIsPure() throws {
        #expect(try isPure("""
        struct ChunkPlan {
            let byteCount: Int
            let chunkSize: Int
            var totalChunks: Int { (byteCount + chunkSize - 1) / chunkSize }
        }
        """))
    }

    @Test("a getter with an explicit `get { }` block is pure")
    func explicitGetterIsPure() throws {
        #expect(try isPure("""
        struct Plan {
            let count: Int
            var doubled: Int {
                get { count * 2 }
            }
        }
        """))
    }

    @Test("a getter calling min is pure — it computes, it does not reach out")
    func minIsPure() throws {
        #expect(try isPure("""
        struct Plan {
            let end: Int
            let byteCount: Int
            var upperBound: Int { min(end, byteCount) }
        }
        """))
    }

    // MARK: - Refuted

    /// **The soundness case.** `Date()` reads no mutable state, so a check that only resolved *names*
    /// would see an uppercase type reference and wave it through. The marker scan is what stops it,
    /// and removing that scan would let a clock into a "pure" function.
    @Test("a getter reading the clock is NOT pure, though it touches no stored state")
    func clockReadingGetterIsRefuted() throws {
        #expect(try isPure("""
        struct Session {
            var now: Date { Date() }
        }
        """) == false)
    }

    @Test("a getter that can trap is not pure")
    func trappingGetterIsRefuted() throws {
        #expect(try isPure("""
        struct Box {
            let value: Int?
            var unwrapped: Int { value! }
        }
        """) == false)
    }

    @Test("a getter doing I/O is not pure")
    func ioGetterIsRefuted() throws {
        #expect(try isPure("""
        struct Store {
            var cached: String { UserDefaults.standard.string(forKey: "k") ?? "" }
        }
        """) == false)
    }

    /// A property with a setter is a two-way channel, not a value derived from `self`.
    @Test("a settable property is not a derived value")
    func settablePropertyIsRefuted() throws {
        #expect(try isPure("""
        struct Box {
            var backing: Int
            var value: Int {
                get { backing }
                set { backing = newValue }
            }
        }
        """) == false)
    }

    /// `willSet`/`didSet` mark *stored* state with an observer. There is no getter to be pure.
    @Test("an observed stored property is not a derived value")
    func observedStoredPropertyIsRefuted() throws {
        #expect(try isPure("""
        struct Box {
            var count: Int = 0 {
                didSet { print(count) }
            }
        }
        """) == false)
    }
}
