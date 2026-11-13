@testable import SwiftEffectInference
import SwiftParser
import SwiftSyntax
import Testing

private final class FirstFunction: SyntaxVisitor {
    private(set) var found: FunctionDeclSyntax?

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if found == nil { found = node }
        return .skipChildren
    }
}

/// A function that reaches outside the process is not pure, whatever its signature looks like.
///
/// **Found by running a law, not by reading one.** SwiftLintRuleStudio's
/// `SystemXcodeLauncher.open(_ url: URL) -> Bool` is `NSWorkspace.shared.open(url)`. No marker
/// named `NSWorkspace`, so it read as a pure `(URL) -> Bool` predicate; SwiftInferProperties
/// proposed a totality law for it, and its corpus funnel ran that law about 4,500 times on
/// 2026-11-12, each trial opening a browser at a generated URL. SwiftInferProperties already
/// suppresses every law over a refuted subject that does not throw, so the marker is the whole
/// fix.
///
/// Each marker below has a witness of the effect it stands for. The controls check the two
/// places a marker's text may appear without refuting: a key-path component (`\.openURL`, which
/// declares or overrides SwiftUI's action rather than calling it) and a string literal.
@Suite("System effects outside the process refute purity")
struct SystemEffectMarkerTests {

    private let inferrer = PurityInferrer()

    private func firstFunction(in source: String) throws -> FunctionDeclSyntax {
        let tree = Parser.parse(source: source)
        let visitor = FirstFunction(viewMode: .sourceAccurate)
        visitor.walk(tree)
        return try #require(visitor.found)
    }

    // MARK: - The defect

    @Test("SystemXcodeLauncher.open(_:) is refuted by NSWorkspace")
    func theDefect() throws {
        let function = try firstFunction(in: """
        @MainActor
        public final class SystemXcodeLauncher {
            public func open(_ url: URL) -> Bool {
                NSWorkspace.shared.open(url)
            }
        }
        """)
        #expect(inferrer.verdict(for: function) == .refuted)
        #expect(inferrer.refutation(for: function) == .sideEffectMarker("NSWorkspace"))
    }

    // MARK: - One witness per marker

    @Test("Each system-effect marker refutes a function that uses it", arguments: [
        ("NSWorkspace", "NSWorkspace.shared.activateFileViewerSelecting([url])"),
        ("NSApp", "NSApp.activate(ignoringOtherApps: true)"),
        ("activateFileViewerSelecting", "workspace.activateFileViewerSelecting([url])"),
        ("urlForApplication", "_ = workspace.urlForApplication(toOpen: url)"),
        ("openURL", "openURL(url)"),
        ("LSOpenCFURLRef", "LSOpenCFURLRef(url as CFURL, nil)"),
        ("runModal", "_ = panel.runModal()"),
        ("UNUserNotificationCenter", "UNUserNotificationCenter.current().add(request)"),
        ("NSUserNotificationCenter", "NSUserNotificationCenter.default.deliver(note)"),
        ("AudioServicesPlaySystemSound", "AudioServicesPlaySystemSound(1_104)"),
        ("NSBeep", "NSBeep()"),
        ("NSAppleScript", "_ = NSAppleScript(source: text)?.executeAndReturnError(nil)"),
        ("NSUserAppleScriptTask", "_ = try? NSUserAppleScriptTask(url: url)"),
        ("NSUserUnixTask", "_ = try? NSUserUnixTask(url: url)"),
        ("OSAScript", "_ = OSAScript(source: text).executeAndReturnError(nil)"),
        ("posix_spawn", "_ = posix_spawn(&pid, path, nil, nil, argv, nil)"),
        ("execv", "_ = execv(path, argv)"),
        ("AuthorizationCreate", "_ = AuthorizationCreate(nil, nil, [], &ref)"),
        ("CFNotificationCenterPostNotification",
         "CFNotificationCenterPostNotification(center, name, nil, nil, true)"),
        ("SecItemAdd", "_ = SecItemAdd(query as CFDictionary, nil)"),
        ("SecItemUpdate", "_ = SecItemUpdate(query as CFDictionary, changes as CFDictionary)"),
        ("SecItemDelete", "_ = SecItemDelete(query as CFDictionary)"),
        ("SecItemCopyMatching", "_ = SecItemCopyMatching(query as CFDictionary, &result)"),
        ("sqlite3_open", "_ = sqlite3_open(path, &db)"),
        ("sqlite3_open_v2", "_ = sqlite3_open_v2(path, &db, flags, nil)"),
        ("sqlite3_exec", "_ = sqlite3_exec(db, sql, nil, nil, nil)"),
        ("sqlite3_prepare_v2", "_ = sqlite3_prepare_v2(db, sql, -1, &statement, nil)"),
        ("sqlite3_step", "_ = sqlite3_step(statement)"),
        ("sqlite3_close", "_ = sqlite3_close(db)"),
        ("sqlite3_close_v2", "_ = sqlite3_close_v2(db)"),
        ("sqlite3_finalize", "_ = sqlite3_finalize(statement)"),
        ("sqlite3_reset", "_ = sqlite3_reset(statement)"),
        ("sqlite3_bind_text", "_ = sqlite3_bind_text(statement, 1, text, -1, nil)"),
        ("sqlite3_column_text", "_ = sqlite3_column_text(statement, 0)"),
        ("sqlite3_errmsg", "_ = sqlite3_errmsg(db)"),
    ])
    func markerRefutes(marker: String, statement: String) throws {
        let function = try firstFunction(in: "func effect() {\n    \(statement)\n}")
        #expect(inferrer.refutation(for: function) == .sideEffectMarker(marker), "\(statement)")
    }

    // MARK: - Controls

    @Test("A key path to SwiftUI's openURL declares the action and does not refute")
    func openURLKeyPathDoesNotRefute() throws {
        let function = try firstFunction(in: """
        func installs(_ action: OpenURLAction) -> some View {
            Text("Docs").environment(\\.openURL, action)
        }
        """)
        #expect(inferrer.refutation(for: function) != .sideEffectMarker("openURL"))
    }

    @Test("A marker's name inside a string literal does not refute")
    func markerInAStringDoesNotRefute() throws {
        let function = try firstFunction(in: """
        func label() -> String {
            "Opens the URL with NSWorkspace or openURL"
        }
        """)
        #expect(inferrer.verdict(for: function) != .refuted)
    }
}
