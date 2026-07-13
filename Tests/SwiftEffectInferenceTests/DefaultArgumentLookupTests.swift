import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Declared effects must reach call sites that omit defaulted arguments.
///
/// A declaration's signature carries every parameter; a call site's signature
/// carries only the labels actually written. When a parameter has a default, those
/// two lists differ, and a lookup keyed on the full list misses — so the annotation
/// silently fails to land and the caller falls through to the name heuristic.
///
/// This is not a corner case. `func f(a: Int, b: Int = 0)` is ordinary Swift, and the
/// failure is silent: the user annotates, nothing happens, and a name-based fallback
/// grades the function instead. `MacCloudAPIService.createRequest(endpoint:method:body:queryItems:)`
/// — a pure `URLRequest` builder with two defaulted parameters — was graded
/// `nonIdempotent` from its `create` prefix in exactly this way, which defeated the
/// `@ExternallyIdempotent` claim on every caller that builds a request.
@Suite("Declared effects reach call sites that omit defaulted arguments")
struct DefaultArgumentLookupTests {

    private static func parse(_ source: String) -> SourceFileSyntax {
        Parser.parse(source: source)
    }

    /// Every call site in `source`, in source order.
    private static func calls(in source: SourceFileSyntax) -> [FunctionCallExprSyntax] {
        final class Collector: SyntaxVisitor {
            var found: [FunctionCallExprSyntax] = []
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                found.append(node)
                return .visitChildren
            }
        }
        let collector = Collector(viewMode: .sourceAccurate)
        collector.walk(source)
        return collector.found
    }

    /// The declared effect the table resolves for the written call to `name`.
    ///
    /// Selected by callee name rather than by position: the declaration bodies below
    /// contain calls of their own (`URLRequest(...)`), and a positional pick would
    /// silently test one of those instead.
    private func declaredEffect(
        forCallTo name: String,
        in source: String
    ) throws -> Effect? {
        let tree = Self.parse(source)
        let table = EffectSymbolTable.build(from: tree)
        let call = try #require(
            Self.calls(in: tree).first { $0.calledExpression.referenceBaseName == name }
        )
        let callSite = try #require(CallSiteShape.from(call: call))
        return table.effect(for: callSite)
    }

    // MARK: - The regression

    @Test("a trailing defaulted argument may be omitted at the call site")
    func omittingOneDefaultedArgument() throws {
        let source = """
        /// @lint.effect pure
        func createRequest(endpoint: String, method: String, body: [String: Any]? = nil) -> URLRequest {
            URLRequest(url: URL(string: endpoint)!)
        }

        func caller() {
            _ = createRequest(endpoint: "/files", method: "GET")
        }
        """

        #expect(try declaredEffect(forCallTo: "createRequest", in: source) == .pure)
    }

    @Test("several defaulted arguments may be omitted — MacCloud's exact shape")
    func omittingSeveralDefaultedArguments() throws {
        let source = """
        /// @lint.effect pure
        func createRequest(
            endpoint: String,
            method: String,
            body: [String: Any]? = nil,
            queryItems: [URLQueryItem]? = nil
        ) -> URLRequest {
            URLRequest(url: URL(string: endpoint)!)
        }

        func caller() {
            _ = createRequest(endpoint: "/sync/sessions", method: "GET")
        }
        """

        // Without this, the `create` prefix grades the callee nonIdempotent and every
        // `@ExternallyIdempotent` claim upstream of a request builder is refused.
        #expect(try declaredEffect(forCallTo: "createRequest", in: source) == .pure)
    }

    @Test("a middle defaulted argument may be omitted while a later one is supplied")
    func omittingAMiddleArgument() throws {
        let source = """
        /// @lint.effect idempotent
        func fetch(path: String, page: Int = 1, limit: Int = 50) -> String { path }

        func caller() {
            _ = fetch(path: "/files", limit: 10)
        }
        """

        #expect(try declaredEffect(forCallTo: "fetch", in: source) == .idempotent)
    }

    @Test("supplying every argument still resolves")
    func supplyingEveryArgument() throws {
        let source = """
        /// @lint.effect pure
        func createRequest(endpoint: String, method: String, body: [String: Any]? = nil) -> URLRequest {
            URLRequest(url: URL(string: endpoint)!)
        }

        func caller() {
            _ = createRequest(endpoint: "/files", method: "POST", body: [:])
        }
        """

        #expect(try declaredEffect(forCallTo: "createRequest", in: source) == .pure)
    }

    // MARK: - The guard rails
    //
    // Relaxing signature matching must not make the table promiscuous. A call site
    // may only match a declaration it could actually have called.

    @Test("a call omitting a NON-defaulted argument does not resolve")
    func omittingARequiredArgumentDoesNotResolve() throws {
        let source = """
        /// @lint.effect pure
        func createRequest(endpoint: String, method: String) -> URLRequest {
            URLRequest(url: URL(string: endpoint)!)
        }

        func caller() {
            _ = createRequest(endpoint: "/files")
        }
        """

        // `method:` has no default, so this call site cannot be this declaration.
        #expect(try declaredEffect(forCallTo: "createRequest", in: source) == nil)
    }

    @Test("a call supplying an argument the declaration does not have does not resolve")
    func supplyingAnUnknownArgumentDoesNotResolve() throws {
        let source = """
        /// @lint.effect pure
        func createRequest(endpoint: String, method: String = "GET") -> URLRequest {
            URLRequest(url: URL(string: endpoint)!)
        }

        func caller() {
            _ = createRequest(endpoint: "/files", timeout: 30)
        }
        """

        #expect(try declaredEffect(forCallTo: "createRequest", in: source) == nil)
    }

    @Test("argument order is still significant")
    func reorderedArgumentsDoNotResolve() throws {
        let source = """
        /// @lint.effect pure
        func createRequest(endpoint: String, method: String = "GET") -> URLRequest {
            URLRequest(url: URL(string: endpoint)!)
        }

        func caller() {
            _ = createRequest(method: "POST", endpoint: "/files")
        }
        """

        // Swift permits no such reordering, so neither should the table.
        #expect(try declaredEffect(forCallTo: "createRequest", in: source) == nil)
    }

    @Test("an exact match beats one that would require omitting a default")
    func exactMatchWinsOverDefaultedMatch() throws {
        let source = """
        /// @lint.effect pure
        func send(to address: String, cc: String? = nil) {}

        /// @lint.effect non_idempotent
        func send(to address: String) {}

        func caller() {
            send(to: "a@b.c")
        }
        """

        // Swift's own overload resolution prefers the declaration that needs no
        // defaults, so the table must resolve the same one the compiler would call.
        #expect(try declaredEffect(forCallTo: "send", in: source) == .nonIdempotent)
    }

    @Test("two declarations reachable only by omitting defaults withdraw as a collision")
    func genuinelyAmbiguousOverloadsWithdraw() throws {
        let source = """
        /// @lint.effect pure
        func send(to address: String, cc: String? = nil) {}

        /// @lint.effect non_idempotent
        func send(to address: String, bcc: String? = nil) {}

        func caller() {
            send(to: "a@b.c")
        }
        """

        // Neither declaration matches exactly, and `send(to:)` could be either.
        // Guessing would be worse than silence: withdraw rather than pick.
        #expect(try declaredEffect(forCallTo: "send", in: source) == nil)
    }

    @Test("two ambiguous declarations that agree on the effect still resolve")
    func ambiguousOverloadsAgreeingOnEffectResolve() throws {
        let source = """
        /// @lint.effect non_idempotent
        func send(to address: String, cc: String? = nil) {}

        /// @lint.effect non_idempotent
        func send(to address: String, bcc: String? = nil) {}

        func caller() {
            send(to: "a@b.c")
        }
        """

        // Ambiguous about *which* declaration, but not about the answer. Whichever
        // the compiler picks, the effect is the same, so there is nothing to withdraw.
        #expect(try declaredEffect(forCallTo: "send", in: source) == .nonIdempotent)
    }
}
