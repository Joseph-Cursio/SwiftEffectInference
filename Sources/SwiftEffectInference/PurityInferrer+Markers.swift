import SwiftSyntax

extension PurityInferrer {

    /// Side-effect markers — I/O, logging, persistence. Any reference in the
    /// body refutes the "no side effects" clause of purity.
    ///
    /// **`FileHandle` / `Process` / `Pipe` are here because `throws` was never
    /// the whole gate.** `throwsOnlyItsOwnErrors` (below) exists because gating
    /// on `throws` had been masking *"`Process`, `Pipe`, `FileHandle`,
    /// `String(contentsOf:)`, `Data(contentsOf:)`, the SQLite surface"* — and
    /// that gate re-closed the hole for **throwing** functions only. The
    /// non-throwing half stayed open, and it is not a corner:
    /// `FileHandle.standardError.write(_:)` does not throw and is the commonest
    /// I/O call in a Swift CLI.
    ///
    /// Measured before the fix, on SwiftInferProperties' `Sources/`: **7
    /// non-refuted functions wrote to standard error and were judged `.pure`**,
    /// including both of that package's own `writeDiagnostic(_:)`. A tool
    /// vouching for the purity of its own diagnostic writer.
    ///
    /// **`String` and `Data` are deliberately NOT here**, and the reason is the
    /// shape of this scan rather than the shape of the risk. This set is matched
    /// by bare identifier, and those two are among the most common pure types in
    /// Swift — admitting them would refute nearly everything.
    ///
    /// **What this doc used to claim, and why it was wrong.** It said
    /// `String(contentsOf:)` and `Data(contentsOf:)` need no entry because they
    /// throw, so `throwsOnlyItsOwnErrors` reaches them, and that the list was
    /// therefore "fully covered between the two mechanisms". That holds only
    /// while the throw propagates. `try?` swallows it, and a non-throwing
    /// convenience wrapper around a file read is exactly the shape that then
    /// looks like a candidate:
    ///
    ///     static func textSwallowed(of url: URL) -> String {
    ///         (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    ///     }
    ///
    /// Measured against SwiftProjectLint's own rule set before this fix, that
    /// function and two like it were reported as pure property-test candidates.
    /// The file-reading *members* below close it without admitting the types:
    /// they are distinctive names that no pure function has a reason to mention,
    /// so the over-refutation risk the paragraph above is guarding is not
    /// reintroduced.
    ///
    /// **`contentsOf` is the exception, and it does not belong in this set.**
    /// It was added here on the reasoning that it is "the argument label shared
    /// by the whole family -- `Data`, `String`, `NSDictionary`, `NSArray` -- and
    /// catches them all at once". It is also the label of
    /// `append(contentsOf:)`, `insert(contentsOf:)` and
    /// `replaceSubrange(_:with:)`'s family, so matching it by bare token
    /// refuted every pure function that appends one collection to another --
    /// exactly the over-refutation the paragraph above forbids, arriving
    /// through the label rather than the type. Measured on SwiftInferProperties:
    /// 49 functions newly refuted, 43 of them for a collection append.
    /// `FileReadChecker` matches the same reads on the callee instead.
    private static let sideEffectMarkers: Set<String> = [
        "print", "NSLog", "FileManager", "URLSession", "UserDefaults",
        "NotificationCenter", "DispatchQueue",
        "FileHandle", "Process", "Pipe",
        // File-system reads that never name a type in this list. Each is a
        // distinctive member or label rather than a type, which is what lets them
        // sit here without the over-refutation the `String`/`Data` note forbids.
        "resourceValues", "checkResourceIsReachable", "checkPromisedItemIsReachable",
        "startAccessingSecurityScopedResource", "stopAccessingSecurityScopedResource",
        // `contentsOfFile` and `contentsOfDirectory` are distinctive: no pure API
        // uses either label. Bare `contentsOf` is NOT, and must never be added
        // here -- see `FileReadChecker`, which matches it on the callee instead.
        "contentsOfFile", "contentsOfDirectory",
        // System effects outside the process: opening a URL or file in another
        // app, app-level state, modal UI, notifications, sounds, scripts, process
        // spawning, the keychain and SQLite. Added after a generated totality law
        // over `NSWorkspace.shared.open(url)` (SwiftLintRuleStudio's
        // `SystemXcodeLauncher.open(_:)`) was judged pure and run about 4,500
        // times, opening a browser each time (SwiftInferProperties, 2026-11-12).
        // Each token survived an adversarial search for a pure use, and has a
        // witness in `SystemEffectMarkerTests`. Measured over 13,550 functions in
        // 21 repositories (SwiftInferProperties' and SwiftProjectLint's sources
        // and the corpus they scan): 23 move to refuted, every one a real effect
        // (keychain 6, SQLite 6, `runModal` 5, `NSApp` 3, notifications 2, the
        // `NSWorkspace` open above); none is in either consumer's own sources.
        // Rejected on
        // that search because a nested value type lets a pure function name
        // them: `NSPasteboard`, `UIPasteboard`, `NSSound`, `NSAlert`, the
        // feedback generators, `NWConnection` and its family, `NSXPCConnection`,
        // `SMAppService`, `DistributedNotificationCenter`, `FetchDescriptor`.
        // `NSWorkspace` has the same exposure through its notification-name
        // constants, as `NotificationCenter` and `FileManager` do; it stays,
        // like them, because no corpus function reads one purely.
        "NSWorkspace", "NSApp", "activateFileViewerSelecting", "urlForApplication",
        "openURL", "LSOpenCFURLRef",
        "runModal", "UNUserNotificationCenter", "NSUserNotificationCenter",
        "AudioServicesPlaySystemSound", "NSBeep",
        "NSAppleScript", "NSUserAppleScriptTask", "NSUserUnixTask", "OSAScript",
        "posix_spawn", "execv", "AuthorizationCreate", "CFNotificationCenterPostNotification",
        "SecItemAdd", "SecItemUpdate", "SecItemDelete", "SecItemCopyMatching",
        "sqlite3_open", "sqlite3_open_v2", "sqlite3_exec", "sqlite3_prepare_v2", "sqlite3_step",
        "sqlite3_close", "sqlite3_close_v2", "sqlite3_finalize", "sqlite3_reset",
        "sqlite3_bind_text", "sqlite3_column_text", "sqlite3_errmsg",
    ]

    /// Nondeterminism markers — sources whose result is not a function of the
    /// inputs (the randomness family, the system clock, identity generation).
    /// Any reference refutes the "deterministic" clause of purity.
    ///
    /// Matched by bare-identifier token, so this is deliberately conservative:
    /// it refutes `Date()` *and* the deterministic `Date(timeIntervalSince1970:)`
    /// alike (the token scan can't tell them apart), and refutes injected
    /// `random(in:using:)` as well as the system-RNG form. Over-refutation is
    /// the sound direction on the effect lattice — better to withhold `.pure`
    /// than to claim it for a clock-reading function — and both consumers (the
    /// linter's candidate nudge, the inferrer's `pure`-suggestion gate) prefer
    /// to refute when unsure.
    ///
    /// **This set is no longer the whole nondeterminism answer, and its old doc
    /// pointed at the wrong repository.** It used to say the AST-precise forms
    /// lived in SwiftProjectLint's `NonInjectedNondeterminismVisitor`. They live
    /// in `NondeterminismSources`, **one file away in this module** — that type
    /// exists precisely to end *"two implementations of 'does this reach for
    /// ambient time' in two repositories"*, and this oracle was still carrying a
    /// third. `hasRefutingMarker` now consults it as well.
    ///
    /// **Union, not replacement, and the distinction is load-bearing.** The
    /// classifier is AST-precise, which makes it *narrower* here: it reads
    /// `Date(timeIntervalSince1970:)` as deterministic and would not refute it.
    /// Swapping this set out for the classifier would therefore be a *relaxation*
    /// of a gate whose over-refutation is deliberate and documented above. Both
    /// run; either one refutes.
    ///
    /// Measured before the union, on synthetic witnesses: `DispatchTime.now()`,
    /// `ContinuousClock()`, `SuspendingClock.now`, `mach_absolute_time()`,
    /// `gettimeofday()`, `Locale.current` and `TimeZone.current` all reached
    /// **`.pure`** — seven sources this module's own classifier already knew
    /// about, waved through by this module's own purity oracle.
    private static let nondeterministicMarkers: Set<String> = Set([
        "arc4random", "arc4random_uniform", "drand48", "CFAbsoluteTimeGetCurrent",
        "random", "randomElement", "shuffled",
        "Date", "UUID",
        // Compare against the current instant even when the calendar is handed in.
        "isDateInToday", "isDateInYesterday", "isDateInTomorrow",
    ]).union(propertyMarkers)

    /// Nondeterminism markers that are **properties**, so a key path reads them
    /// as well as a member access does: `ds.map(\.timeIntervalSinceNow)`.
    ///
    /// `due.timeIntervalSinceNow` reads the clock, and is the everyday spelling
    /// of "is this overdue". Nothing matched it: the name is no marker, and the
    /// classifier knows `Date(timeIntervalSinceNow:)` only as an initializer. A
    /// body that also spelled `Date` was refuted for the token, and one that
    /// took its `Date` from a parameter or a property was `.pure`.
    ///
    /// `autoupdatingCurrent` is the `Locale`, `TimeZone` or `Calendar` that follows the user's
    /// settings as they change. It is the default of every Foundation format style, so a default
    /// argument often spells it base-less: `locale: Locale = .autoupdatingCurrent`. No other type
    /// declares the name.
    private static let propertyMarkers: Set<String> = ["timeIntervalSinceNow", "autoupdatingCurrent"]

    /// Types whose static `current` reads the user's settings, beside the `Locale` and `TimeZone`
    /// the classifier knows. `Calendar.current` carries the process's time zone and the locale's
    /// calendar, so the year, the start of a day and the first weekday all move with them.
    /// `NSCalendar` and `NSLocale` are the Objective-C twins.
    ///
    /// Kept here rather than in `NondeterminismSources`. SwiftProjectLint's non-injected
    /// nondeterminism rule reports the classifier's ambient kind, and that rule's scope is
    /// declared rather than inherited: a classifier entry would widen it as a side effect. This
    /// oracle over-refutes by design, so the reading can live here alone.
    private static let ambientCurrentTypes: Set<String> = ["Calendar", "NSCalendar", "NSLocale"]

    /// Types whose initializer without arguments makes a value the inputs do not determine, beside
    /// the `Date()` and `UUID()` the token and the classifier know. `DateInterval()` starts now, and
    /// `NSDate()` and `NSUUID()` are the Objective-C twins. Their other initializers take the value
    /// or the instant as an argument, and `NSDate(timeIntervalSinceNow:)` is caught by its label, so
    /// these are matched only as a construction without arguments: `NSUUID(uuidString:)`,
    /// `NSDate.self` and `x as NSDate` read nothing.
    private static let freshConstructions: Set<String> = ["DateInterval", "NSDate", "NSUUID"]

    /// Members that ask about now when they are given no instant: a time zone's offset, its
    /// daylight-saving state and its next transition. Each has a form that takes the instant,
    /// `secondsFromGMT(for:)` and `nextDaylightSavingTimeTransition(after:)` among them, and that
    /// form reads no clock. So these match only when read as a property or called without
    /// arguments.
    private static let nowByDefaultMembers: Set<String> = [
        "secondsFromGMT", "isDaylightSavingTime", "daylightSavingTimeOffset", "nextDaylightSavingTimeTransition"
    ]

    /// Members that read a clock when written **without a base**: `base < .now`,
    /// `deadline < .now()`. Every library type with a static `now` reads a clock
    /// through it: `Date`, `DispatchTime`, `DispatchWallTime`, and the
    /// `Instant` of `ContinuousClock` and `SuspendingClock`. The classifier
    /// matches `Date.now` only with its base written, and a contextual type
    /// supplies the base without spelling it.
    ///
    /// Matched only as a base-less member. `now` alone is a name, most often the
    /// parameter that carries an injected instant, and `clock.now` reads a clock
    /// the caller handed in, which is the injection seam. A package type of its
    /// own with a `now` member is refuted along with the library's, which is the
    /// sound direction.
    private static let baseLessNondeterministicMarkers: Set<String> = ["now"]

    /// Any I/O, logging, persistence, clock or randomness marker anywhere in
    /// `syntax` — by bare token, **or** by the module's own AST-precise
    /// nondeterminism classifier.
    ///
    /// Two passes because they catch different things and neither subsumes the
    /// other. The token scan is broad and cannot read argument labels; `NondeterminismSources`
    /// is narrow and shape-aware, and knows about the monotonic clocks, the
    /// clock-acquisition types, `Task.sleep` and the ambient-environment types
    /// that no token in the set names. Running both keeps every deliberate
    /// over-refutation the token set was written for while closing what it never
    /// covered.
    ///
    /// The two token sets are reported as different cases even though they refute
    /// alike, because they carry different confidence: the nondeterminism set is
    /// deliberately blind to argument labels and refutes `Date(timeIntervalSince1970:)` along
    /// with `Date()`, while a `.nondeterminismSource` came from the classifier and
    /// read the argument labels. A consumer writing a diagnostic can say so; one
    /// that only wants a Bool never has to look.
    func refutingMarker(in syntax: Syntax) -> PurityRefutation? {
        let consultsConstruction = !constructionFacts.isEmpty
        var mentionsConstructible = false
        for token in syntax.tokens(viewMode: .sourceAccurate) {
            if let marker = Self.tokenMarker(token) { return marker }
            // A pre-filter, never a match: the fourth pass below matches only constructions.
            if consultsConstruction, !mentionsConstructible, constructionFacts.mentions(token.text) {
                mentionsConstructible = true
            }
        }
        let fileRead = FileReadChecker()
        fileRead.walk(syntax)
        if let read = fileRead.fileRead { return .fileRead(read) }
        let checker = NondeterminismChecker()
        checker.walk(syntax)
        if let source = checker.source { return .nondeterminismSource(source) }
        guard mentionsConstructible else { return nil }
        return constructionFacts.refutation(constructingIn: syntax)
    }

    /// The marker `token` refutes by itself, or `nil`: the token sets, and the shapes the
    /// predicates below recognise around a single token. The tree-wide passes stay in
    /// `refutingMarker(in:)`, which asks this first for every token, in source order.
    private static func tokenMarker(_ token: TokenSyntax) -> PurityRefutation? {
        if Self.sideEffectMarkers.contains(token.text), Self.isMarkerPosition(token) {
            return .sideEffectMarker(token.text)
        }
        if Self.nondeterministicMarkers.contains(token.text), Self.isMarkerPosition(token) {
            return .nondeterministicMarker(token.text)
        }
        if Self.baseLessNondeterministicMarkers.contains(token.text), Self.isBaseLessMember(token) {
            return .nondeterministicMarker("." + token.text)
        }
        if let type = Self.ambientCurrentType(of: token) {
            return .nondeterministicMarker(type + ".current")
        }
        if Self.isFreshConstruction(token) {
            return .nondeterministicMarker(token.text + "()")
        }
        if token.text == "now", Self.isBridgedNow(token) {
            return .nondeterministicMarker("NSDate.now")
        }
        if Self.readsNowByDefault(token) {
            return .nondeterministicMarker(token.text)
        }
        if Self.isAmbientFormatting(token) {
            return .nondeterministicMarker(token.text)
        }
        return nil
    }

    /// Whether `token` is where a marker can be: an identifier, and not a key path's component
    /// unless the marker is a property.
    ///
    /// The text of a string literal is not code: `"Date"` and `@AppStorage("shuffled")` name
    /// nothing. A key path's component names a property, read when the key path is applied —
    /// `rows.map(\.random)` reads each row's own `random` — and most markers are not properties:
    /// they name a type, a free function, a method or an argument label, none of which a key path
    /// can name. The `propertyMarkers` are the exception, and are matched there too:
    /// `ds.map(\.timeIntervalSinceNow)` reads the clock once per date. The root is still read:
    /// `\Date.timeIntervalSince1970` mentions `Date`. A member name is still matched,
    /// `rows.map { $0.random }` included, because a member can be a static method: `Int.random`.
    static func isMarkerPosition(_ token: TokenSyntax) -> Bool {
        guard case .identifier = token.tokenKind else { return false }
        if let reference = token.parent?.as(DeclReferenceExprSyntax.self),
           reference.parent?.is(KeyPathPropertyComponentSyntax.self) == true {
            return propertyMarkers.contains(token.text)
        }
        return true
    }

    /// Whether `token` is the name of a member written without a base: the `now` of `.now`.
    static func isBaseLessMember(_ token: TokenSyntax) -> Bool {
        guard let reference = token.parent?.as(DeclReferenceExprSyntax.self),
              let member = reference.parent?.as(MemberAccessExprSyntax.self) else { return false }
        return member.base == nil && member.declName.id == reference.id
    }

    /// The type whose `current` `token` names, when it is one of the `ambientCurrentTypes`:
    /// `Calendar` for the `current` of `Calendar.current`.
    static func ambientCurrentType(of token: TokenSyntax) -> String? {
        guard token.text == "current",
              let reference = token.parent?.as(DeclReferenceExprSyntax.self),
              let member = reference.parent?.as(MemberAccessExprSyntax.self),
              member.declName.id == reference.id,
              let base = member.base?.as(DeclReferenceExprSyntax.self),
              ambientCurrentTypes.contains(base.baseName.text) else { return nil }
        return base.baseName.text
    }

    /// Whether `token` is one of the `freshConstructions` called without arguments, as
    /// `DateInterval()` or `DateInterval.init()`.
    static func isFreshConstruction(_ token: TokenSyntax) -> Bool {
        guard freshConstructions.contains(token.text),
              let reference = token.parent?.as(DeclReferenceExprSyntax.self) else { return false }
        var callee = Syntax(reference)
        if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.base?.id == reference.id,
           member.declName.baseName.tokenKind == .keyword(.`init`) {
            callee = Syntax(member)
        }
        guard let call = callee.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == callee.id else {
            return false
        }
        return call.arguments.isEmpty && call.trailingClosure == nil
    }

    /// Whether `token` is the `now` of `NSDate.now`, which the classifier does not know.
    static func isBridgedNow(_ token: TokenSyntax) -> Bool {
        guard let reference = token.parent?.as(DeclReferenceExprSyntax.self),
              let member = reference.parent?.as(MemberAccessExprSyntax.self),
              member.declName.id == reference.id,
              let base = member.base?.as(DeclReferenceExprSyntax.self) else { return false }
        return base.baseName.text == "NSDate"
    }

    /// Whether `token` is one of the `nowByDefaultMembers` given no instant: read as a property,
    /// a key path's included, or called without arguments.
    static func readsNowByDefault(_ token: TokenSyntax) -> Bool {
        guard nowByDefaultMembers.contains(token.text),
              let reference = token.parent?.as(DeclReferenceExprSyntax.self) else { return false }
        if reference.parent?.is(KeyPathPropertyComponentSyntax.self) == true { return true }
        guard let member = reference.parent?.as(MemberAccessExprSyntax.self),
              member.declName.id == reference.id else { return false }
        guard let call = member.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == member.id else {
            return true
        }
        return call.arguments.isEmpty && call.trailingClosure == nil
    }

    /// Whether `token` names a `formatted(…)` call that formats with the user's locale, time zone
    /// or calendar: `d.formatted()`, `n.formatted(.number)`, `t.formatted(.units())`.
    ///
    /// Foundation declares `formatted` on `Date`, the integer and floating-point types, `Decimal`,
    /// `Duration`, a range of dates, string sequences, `Measurement` and `PersonNameComponents`.
    /// Each formats with the ambient settings unless locale, time zone and calendar are all
    /// pinned, and a relative style reads the clock too. The receiver's type is not visible here,
    /// so any called `formatted` with a receiver refutes, except two forms known to read nothing:
    /// an `.iso8601` style, which is always GMT and never localized, and swift-syntax's
    /// `formatted(using:)`, which lays out source text. A package's own deterministic `formatted`
    /// or style is refuted along with Foundation's, and so is swift-syntax's `formatted()` with
    /// its default. That is the sound direction.
    ///
    /// A base-less `.formatted(formatter)` is a coding strategy's case, so it does not match. Nor
    /// does a `formatted` that is not called, which is most often some other type's property. A
    /// reference to Foundation's own method, `let render: () -> String = d.formatted`, is missed.
    static func isAmbientFormatting(_ token: TokenSyntax) -> Bool {
        guard token.text == "formatted",
              let reference = token.parent?.as(DeclReferenceExprSyntax.self),
              let member = reference.parent?.as(MemberAccessExprSyntax.self),
              member.base != nil, member.declName.id == reference.id,
              let call = member.parent?.as(FunctionCallExprSyntax.self),
              call.calledExpression.id == member.id else { return false }
        if call.arguments.contains(where: { $0.label?.text == "using" }) { return false }
        guard call.arguments.count == 1, let style = call.arguments.first, style.label == nil else { return true }
        return baseLessRoot(of: style.expression) != "iso8601"
    }

    /// The member at the bottom of a chain when it is written without a base: `iso8601` for
    /// `.iso8601.year().month()`.
    private static func baseLessRoot(of expression: ExprSyntax) -> String? {
        if let call = expression.as(FunctionCallExprSyntax.self) { return baseLessRoot(of: call.calledExpression) }
        guard let member = expression.as(MemberAccessExprSyntax.self) else { return nil }
        guard let base = member.base else { return member.declName.baseName.text }
        return baseLessRoot(of: base)
    }
}
