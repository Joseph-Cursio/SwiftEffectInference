import SwiftParser
import SwiftSyntax
import Testing
@testable import SwiftEffectInference

/// Probe: every call-site sugar that makes the written label list differ from the declared one.
///
/// Default arguments were one member of this family, and their miss was silent. These probes ask
/// whether the others — trailing closures, multiple trailing closures, variadics — fail the same
/// way. A failing case here is a declared effect that never reaches its call site.
@Suite("Call-site sugar: does the declared effect reach the call?")
struct CallSiteSugarProbeTests {

    private static func calls(in tree: SourceFileSyntax) -> [FunctionCallExprSyntax] {
        final class Collector: SyntaxVisitor {
            var found: [FunctionCallExprSyntax] = []
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                found.append(node)
                return .visitChildren
            }
        }
        let collector = Collector(viewMode: .sourceAccurate)
        collector.walk(tree)
        return collector.found
    }

    private func declaredEffect(forCallTo name: String, in source: String) throws -> Effect? {
        let tree = Parser.parse(source: source)
        let table = EffectSymbolTable.build(from: tree)
        let call = try #require(
            Self.calls(in: tree).first { $0.calledExpression.referenceBaseName == name }
        )
        let callSite = try #require(CallSiteShape.from(call: call))
        return table.effect(for: callSite)
    }

    // MARK: - Trailing closures

    @Test("a trailing closure — the label is dropped at the call site")
    func trailingClosure() throws {
        let source = """
        /// @lint.effect non_idempotent
        func perform(action: () -> Void) {}

        func caller() {
            perform { }
        }
        """

        // Declared `perform(action:)`; written `perform { }`. Swift drops the label on a
        // trailing closure, so the call site's label list is ["_"].
        #expect(try declaredEffect(forCallTo: "perform", in: source) == .nonIdempotent)
    }

    @Test("a trailing closure after ordinary arguments")
    func trailingClosureAfterArguments() throws {
        let source = """
        /// @lint.effect non_idempotent
        func retry(count: Int, operation: () -> Void) {}

        func caller() {
            retry(count: 3) { }
        }
        """

        #expect(try declaredEffect(forCallTo: "retry", in: source) == .nonIdempotent)
    }

    @Test("a trailing closure plus an omitted default — both sugars at once")
    func trailingClosureAndDefault() throws {
        let source = """
        /// @lint.effect non_idempotent
        func enqueue(priority: Int = 0, work: () -> Void) {}

        func caller() {
            enqueue { }
        }
        """

        #expect(try declaredEffect(forCallTo: "enqueue", in: source) == .nonIdempotent)
    }

    @Test("multiple trailing closures")
    func multipleTrailingClosures() throws {
        let source = """
        /// @lint.effect non_idempotent
        func load(onSuccess: () -> Void, onFailure: () -> Void) {}

        func caller() {
            load { } onFailure: { }
        }
        """

        #expect(try declaredEffect(forCallTo: "load", in: source) == .nonIdempotent)
    }

    // MARK: - Variadics

    @Test("a variadic given several arguments")
    func variadicWithSeveralArguments() throws {
        let source = """
        /// @lint.effect non_idempotent
        func publish(events: String...) {}

        func caller() {
            publish(events: "a", "b", "c")
        }
        """

        #expect(try declaredEffect(forCallTo: "publish", in: source) == .nonIdempotent)
    }

    @Test("a variadic given nothing")
    func variadicWithNoArguments() throws {
        let source = """
        /// @lint.effect non_idempotent
        func publish(events: String...) {}

        func caller() {
            publish()
        }
        """

        #expect(try declaredEffect(forCallTo: "publish", in: source) == .nonIdempotent)
    }

    // MARK: - Unlabelled parameters (the control: these already worked)

    @Test("an unlabelled parameter")
    func unlabelledParameter() throws {
        let source = """
        /// @lint.effect non_idempotent
        func send(_ message: String) {}

        func caller() {
            send("hi")
        }
        """

        #expect(try declaredEffect(forCallTo: "send", in: source) == .nonIdempotent)
    }
}
