import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// A file read is an impurity whether or not its `throws` survives to the signature.
///
/// `sideEffectMarkers` names types — `FileManager`, `FileHandle`, `Process` — and its own doc
/// argued that the URL-shaped readers needed no entry because `String(contentsOf:)` and
/// `Data(contentsOf:)` throw, so `throwsOnlyItsOwnErrors` reaches them. That holds only while
/// the throw propagates. `try?` swallows it, and a non-throwing convenience wrapper around a
/// file read is precisely the shape that then looks like a property-test candidate.
///
/// **Measured before the fix**, running SwiftProjectLint's testability rules over a probe
/// containing the four shapes below: three were reported as
/// `Pure Function Property-Test Candidate`. The fourth, which lets the throw propagate, was
/// correctly refuted — which is what identified `try?` as the hole rather than the markers
/// being wrong in general. The same gap produced a live false positive in
/// MacCloud_client_MacOS, where a `map` closure calling `resourceValues` was reported pure.
///
/// **The controls are the point of the suite, not an afterthought.** The obvious fix is to add
/// `String` and `Data` to the marker set, and that would refute nearly every pure function in
/// Swift — the set's own doc says so. The entries added instead are members and labels, so the
/// controls below check that a function merely *taking* a `String` or `Data`, or returning one,
/// stays pure. A fix that punished those would be worse than the hole it closed.
@Suite("A file read is an impurity even when `try?` hides it")
struct FileSystemReadPurityTests {

    private let inferrer = PurityInferrer()

    private func firstFunction(in source: String) throws -> FunctionDeclSyntax {
        let tree = Parser.parse(source: source)
        return try #require(
            tree.statements.lazy.compactMap { $0.item.as(FunctionDeclSyntax.self) }.first
        )
    }

    // MARK: - The hole

    @Test("a swallowed resourceValues read refutes purity")
    func swallowedResourceValues() throws {
        let function = try firstFunction(in: """
        func sizeOnDisk(of url: URL) -> Int {
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        """)
        #expect(inferrer.verdict(for: function) == .refuted)
    }

    @Test("a swallowed String(contentsOf:) read refutes purity")
    func swallowedStringContents() throws {
        let function = try firstFunction(in: """
        func text(of url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        """)
        #expect(inferrer.verdict(for: function) == .refuted)
    }

    @Test("a swallowed Data(contentsOf:) read refutes purity")
    func swallowedDataContents() throws {
        let function = try firstFunction(in: """
        func bytes(of url: URL) -> Data {
            (try? Data(contentsOf: url)) ?? Data()
        }
        """)
        #expect(inferrer.verdict(for: function) == .refuted)
    }

    @Test("a reachability probe refutes purity")
    func reachabilityProbe() throws {
        // This one never throws to begin with, so `throwsOnlyItsOwnErrors` was never going to
        // catch it under any propagation rule.
        let function = try firstFunction(in: """
        func isReachable(_ url: URL) -> Bool {
            (try? url.checkResourceIsReachable()) ?? false
        }
        """)
        #expect(inferrer.verdict(for: function) == .refuted)
    }

    @Test("a security-scoped access refutes purity")
    func securityScopedAccess() throws {
        let function = try firstFunction(in: """
        func open(_ url: URL) -> Bool {
            url.startAccessingSecurityScopedResource()
        }
        """)
        #expect(inferrer.verdict(for: function) == .refuted)
    }

    @Test("the throwing form was already refuted and still is")
    func throwingFormStillRefuted() throws {
        // The control for the fix's own necessity: this one passed before the markers were
        // added, so if it were the only test here the change would look load-bearing when it
        // was not.
        let function = try firstFunction(in: """
        func sizeOnDisk(of url: URL) throws -> Int {
            try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        """)
        #expect(inferrer.verdict(for: function) == .refuted)
    }

    // MARK: - The controls that stop the fix over-reaching

    @Test("taking a String parameter stays pure")
    func stringParameterStaysPure() throws {
        let function = try firstFunction(in: """
        func shout(_ text: String) -> String { text.uppercased() }
        """)
        #expect(inferrer.verdict(for: function) != .refuted)
    }

    @Test("taking and returning Data stays pure")
    func dataParameterStaysPure() throws {
        let function = try firstFunction(in: """
        func firstByte(_ bytes: Data) -> Data { bytes.prefix(1) }
        """)
        #expect(inferrer.verdict(for: function) != .refuted)
    }

    @Test("a function whose own name suggests contents stays pure")
    func similarlyNamedFunctionStaysPure() throws {
        // The markers are member names and argument labels. A function that merely talks about
        // contents, without reading any, must not be caught by them.
        let function = try firstFunction(in: """
        func contents(of box: [Int]) -> [Int] { box.sorted() }
        """)
        #expect(inferrer.verdict(for: function) != .refuted)
    }

    @Test("an in-memory initializer with a different label stays pure")
    func inMemoryInitializerStaysPure() throws {
        let function = try firstFunction(in: """
        func encode(_ text: String) -> Data { Data(text.utf8) }
        """)
        #expect(inferrer.verdict(for: function) != .refuted)
    }

    // MARK: - The control the original set was missing

    /// `contentsOf` was matched as a bare token, which refuted every function
    /// that appends one collection to another. The suite's controls checked
    /// functions *taking* and *returning* `String` and `Data`; none of them
    /// mentioned the label, so nothing here failed.
    ///
    /// Measured on SwiftInferProperties at the time: 49 functions newly
    /// refuted, 43 of them for a collection append and 5 for a real file read.
    @Test("append(contentsOf:) is pure -- it shares only the label")
    func collectionAppendStaysPure() throws {
        let function = try firstFunction(in: """
        func merge(_ first: [Int], _ second: [Int]) -> [Int] {
            var result = first
            result.append(contentsOf: second)
            return result
        }
        """)
        #expect(inferrer.verdict(for: function) == .pure)
    }

    @Test("insert(contentsOf:at:) is pure")
    func collectionInsertStaysPure() throws {
        let function = try firstFunction(in: """
        func prefixed(_ head: [Int], _ tail: [Int]) -> [Int] {
            var result = tail
            result.insert(contentsOf: head, at: 0)
            return result
        }
        """)
        #expect(inferrer.verdict(for: function) == .pure)
    }

    /// The other half of the pairing: removing the bare token must not lose the
    /// read it was added for. Without this, `collectionAppendStaysPure` could be
    /// satisfied by deleting the marker and closing nothing.
    @Test("a swallowed String(contentsOf:) read still refutes after the fix")
    func swallowedStringReadStillRefuted() throws {
        let function = try firstFunction(in: """
        func text(of url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        """)
        #expect(inferrer.verdict(for: function) == .refuted)
    }

    @Test("a swallowed Data(contentsOf:) read still refutes after the fix")
    func swallowedDataReadStillRefuted() throws {
        let function = try firstFunction(in: """
        func bytes(of url: URL) -> Data {
            (try? Data(contentsOf: url)) ?? Data()
        }
        """)
        #expect(inferrer.verdict(for: function) == .refuted)
    }

    /// A function doing both must refute: the append must not mask the read.
    @Test("an append alongside a real read still refutes")
    func appendDoesNotMaskARead() throws {
        let function = try firstFunction(in: """
        func lines(of url: URL, extra: [String]) -> [String] {
            var result = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            result.append(contentsOf: extra)
            return result
        }
        """)
        #expect(inferrer.verdict(for: function) == .refuted)
    }
}
