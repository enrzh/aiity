import XCTest
@testable import AIApp

/// The diagnostics record is written by one build and read by the NEXT one —
/// the crash happens before the update, the report is read after it. So the
/// property that actually matters is that an OLD record still decodes against
/// a NEWER shape. Swift's synthesized decoder treats a defaulted property as
/// REQUIRED, which has already once made every stored record in this app
/// undecodable; a diagnostics file with that flaw would fail silently at
/// exactly the moment someone wants a report.
final class DiagnosticsDecodingTests: XCTestCase {

    /// A record as an earlier build would have written it: no provider, no
    /// memory fields, no fatal.
    private let legacyRun = """
    {
      "id": "1E2F0B4A-6C1D-4B9E-9E77-9A9E5D2C4A31",
      "startedAt": 770000000,
      "appVersion": "0.5.0",
      "build": "31",
      "systemVersion": "26.0",
      "deviceModel": "iPhone17,1",
      "breadcrumbs": [
        {"at": 770000001, "category": "app", "message": "Start"}
      ]
    }
    """

    func testARecordFromAnOlderBuildStillDecodes() throws {
        let run = try JSONDecoder().decode(DiagnosticRun.self, from: Data(legacyRun.utf8))
        XCTAssertEqual(run.appVersion, "0.5.0")
        XCTAssertEqual(run.breadcrumbs.count, 1)
        XCTAssertEqual(run.memoryWarnings, 0)
        XCTAssertEqual(run.provider, "")
        XCTAssertNil(run.fatal)
    }

    /// A run with nothing but an id must still be readable — the record is
    /// flushed while the app runs, so a kill mid-life is the normal case.
    func testAnAlmostEmptyRecordDecodes() throws {
        let run = try JSONDecoder().decode(DiagnosticRun.self, from: Data("{}".utf8))
        XCTAssertEqual(run.appVersion, "?")
        XCTAssertTrue(run.breadcrumbs.isEmpty)
    }

    /// `syncFailure` was added after build 12 shipped. The first report that
    /// will ever carry it is read on a build that has it, but the PREVIOUS
    /// run's file was written by one that did not.
    func testARecordWithoutTheSyncFieldStillDecodes() throws {
        let run = try JSONDecoder().decode(DiagnosticRun.self, from: Data(legacyRun.utf8))
        XCTAssertNil(run.syncFailure)
    }

    func testTheSyncFailureSurvivesARoundTrip() throws {
        var original = DiagnosticRun(
            appVersion: "0.6.0", build: "13",
            systemVersion: "27.0", deviceModel: "iPhone18,4"
        )
        original.syncFailure = "Export (nach iCloud): …\n  • 9× CKErrorDomain 22 (batchRequestFailed)"
        let decoded = try JSONDecoder().decode(
            DiagnosticRun.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded.syncFailure, original.syncFailure)
    }

    func testBreadcrumbsSurviveARoundTrip() throws {
        let original = DiagnosticRun(
            appVersion: "0.6.0", build: "44",
            systemVersion: "26.0", deviceModel: "iPhone17,1",
            memoryWarnings: 2, footprintMB: 412, provider: "anthropic",
            model: "claude-opus-4-5",
            breadcrumbs: [DiagnosticBreadcrumb(category: "gruppe", message: "Runde 1")]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiagnosticRun.self, from: data)
        XCTAssertEqual(decoded.provider, "anthropic")
        XCTAssertEqual(decoded.memoryWarnings, 2)
        XCTAssertEqual(decoded.breadcrumbs.first?.message, "Runde 1")
    }

    func testAnUnknownFatalKindFallsBackInsteadOfThrowing() throws {
        let json = """
        {"kind":"somethingNew","at":770000000,"name":"X","reason":"Y","frames":[]}
        """
        let fatal = try JSONDecoder().decode(DiagnosticFatal.self, from: Data(json.utf8))
        XCTAssertEqual(fatal.kind, .signal)
        XCTAssertEqual(fatal.name, "X")
    }
}

/// The signal handler writes its marker with `write(2)` only — no allocation,
/// no formatter. These tests pin the format both sides agree on.
final class SignalMarkerTests: XCTestCase {

    func testParsesSignalAndFrames() throws {
        let marker = """
        sig 11
        f 0x1044e2a10
        f 0x1044e0004
        """
        let fatal = try XCTUnwrap(
            DiagnosticsRecorder.parseSignalMarker(marker, at: Date(timeIntervalSince1970: 100))
        )
        XCTAssertEqual(fatal.kind, .signal)
        XCTAssertEqual(fatal.name, "SIGSEGV")
        XCTAssertEqual(fatal.frames, ["0x1044e2a10", "0x1044e0004"])
    }

    func testAMarkerWithNoSignalLineIsNotAFatal() {
        XCTAssertNil(DiagnosticsRecorder.parseSignalMarker("f 0x1\n", at: Date()))
    }

    /// SIGTRAP/SIGILL is what a Swift runtime trap looks like — a nil
    /// force-unwrap, an out-of-range index. That is the likeliest way this app
    /// dies, so the report must not describe it as a generic "illegal
    /// instruction" the user can do nothing with.
    func testSwiftRuntimeTrapsAreExplainedAsSuch() {
        for signalNumber in [SIGTRAP, SIGILL] {
            let text = DiagnosticsRecorder.signalMeaning(signalNumber)
            XCTAssertTrue(text.contains("Swift"), DiagnosticsRecorder.signalName(signalNumber))
            XCTAssertTrue(text.contains("nil"), DiagnosticsRecorder.signalName(signalNumber))
        }
    }
}

final class DiagnosticVerdictTests: XCTestCase {

    private func run(
        endedCleanly: Bool = false, fatal: DiagnosticFatal? = nil,
        warnings: Int = 0, background: Bool = false
    ) -> DiagnosticRun {
        DiagnosticRun(
            appVersion: "0.6.0", build: "44", systemVersion: "26.0", deviceModel: "iPhone17,1",
            endedCleanlyAt: endedCleanly ? Date() : nil,
            wasInBackground: background, memoryWarnings: warnings, fatal: fatal
        )
    }

    func testACaughtSignalReadsAsACrash() {
        let fatal = DiagnosticFatal(
            kind: .signal, at: Date(), name: "SIGSEGV", reason: "…", frames: []
        )
        XCTAssertEqual(DiagnosticsRecorder.verdict(for: run(fatal: fatal)), .crashed(fatal))
    }

    func testAnOrderlyExitIsNotACrash() {
        XCTAssertEqual(DiagnosticsRecorder.verdict(for: run(endedCleanly: true)), .clean)
    }

    /// The honesty property: no clean end and no caught signal means we do NOT
    /// know. Claiming "crashed" here would send someone hunting a bug that was
    /// really the user swiping the app out of the switcher.
    func testNoEvidenceMeansUndetermined() {
        XCTAssertEqual(DiagnosticsRecorder.verdict(for: run()), .diedUnexpectedly)
    }

    /// Taken from a real device report: a 3-agent group round on a local MLX
    /// model drove the footprint to 2.8 GB and produced five memory warnings in
    /// the last eight seconds. Calling that "Ursache nicht eindeutig" sends
    /// someone hunting a logic bug that isn't there.
    func testFiveWarningsSecondsBeforeTheEndNamesJetsam() {
        let end = Date(timeIntervalSince1970: 770_000_020)
        var record = DiagnosticRun(
            appVersion: "0.6.0", build: "1", systemVersion: "27.0", deviceModel: "iPhone18,4",
            lastActiveAt: end, memoryWarnings: 5, footprintMB: 2822, availableMemoryMB: 554,
            provider: "mlx",
            breadcrumbs: (0..<5).map {
                DiagnosticBreadcrumb(
                    at: end.addingTimeInterval(Double($0) - 8),
                    category: "speicher", message: "Speicherwarnung"
                )
            }
        )
        XCTAssertTrue(DiagnosticsReport.diedUnderMemoryPressure(record))
        XCTAssertTrue(
            DiagnosticsReport.headline(.diedUnexpectedly, run: record).contains("Jetsam"),
            DiagnosticsReport.headline(.diedUnexpectedly, run: record)
        )

        // A warning long before the end is not evidence about the end.
        record.breadcrumbs = [DiagnosticBreadcrumb(
            at: end.addingTimeInterval(-600), category: "speicher", message: "Speicherwarnung"
        )]
        XCTAssertFalse(DiagnosticsReport.diedUnderMemoryPressure(record))
        XCTAssertTrue(
            DiagnosticsReport.headline(.diedUnexpectedly, run: record).contains("nicht eindeutig")
        )
    }

    /// Without a run there is nothing to reason from, so the headline must not
    /// invent confidence.
    func testTheHeadlineStaysHedgedWithoutARun() {
        XCTAssertTrue(DiagnosticsReport.headline(.diedUnexpectedly).contains("nicht eindeutig"))
    }

    func testMemoryPressureIsRankedFirstWhenThereWereWarnings() {
        let causes = DiagnosticsReport.unexpectedCauses(run(warnings: 3))
        XCTAssertTrue(causes.first?.contains("Speicher") == true, "\(causes)")
        XCTAssertTrue(causes.first?.contains("Jetsam") == true, "\(causes)")
    }

    func testMemoryPressureIsRuledOutWhenThereWereNone() {
        let causes = DiagnosticsReport.unexpectedCauses(run())
        XCTAssertTrue(
            causes.contains { $0.contains("unwahrscheinlich") },
            "a report that never rules anything out is not a diagnosis: \(causes)"
        )
    }

    /// Being killed in the background is normal iOS behaviour, not a defect —
    /// saying otherwise turns every overnight suspension into a false alarm.
    func testABackgroundKillIsCalledNormal() {
        let causes = DiagnosticsReport.unexpectedCauses(run(background: true))
        XCTAssertTrue(causes.contains { $0.contains("normales iOS-Verhalten") }, "\(causes)")
    }
}

final class DiagnosticsReportTests: XCTestCase {

    func testTheReportLeadsWithTheVerdictAndNamesTheSignal() {
        let fatal = DiagnosticFatal(
            kind: .signal, at: Date(timeIntervalSince1970: 770_000_500),
            name: "SIGSEGV", reason: "Ungültiger Speicherzugriff", frames: ["0x1"]
        )
        let previous = DiagnosticRun(
            startedAt: Date(timeIntervalSince1970: 770_000_000),
            appVersion: "0.6.0", build: "44", systemVersion: "26.0",
            deviceModel: "iPhone17,1", provider: "anthropic", model: "claude-opus-4-5",
            breadcrumbs: [DiagnosticBreadcrumb(
                at: Date(timeIntervalSince1970: 770_000_499),
                category: "gruppe", message: "Runde 2 · 3 Teilnehmer"
            )],
            fatal: fatal
        )
        let text = DiagnosticsReport.render(
            previous: previous, verdict: .crashed(fatal), metricKit: nil,
            current: DiagnosticRun(
                appVersion: "0.6.0", build: "44",
                systemVersion: "26.0", deviceModel: "iPhone17,1"
            ),
            generatedAt: Date(timeIntervalSince1970: 770_001_000)
        )
        XCTAssertTrue(text.contains("ABSTURZ · SIGSEGV"))
        XCTAssertTrue(text.contains("anthropic · claude-opus-4-5"))
        XCTAssertTrue(text.contains("Runde 2 · 3 Teilnehmer"), "breadcrumbs must survive into the export")
        XCTAssertTrue(text.contains("Laufzeit 8m 20s"))
    }

    /// Reachable on a first launch and after "Diagnose löschen" — rendering
    /// must not depend on there being a previous run.
    func testTheReportRendersWithNothingRecorded() {
        let text = DiagnosticsReport.render(
            previous: nil, verdict: .noPreviousRun, metricKit: nil,
            current: DiagnosticRun(
                appVersion: "0.6.0", build: "44",
                systemVersion: "26.0", deviceModel: "iPhone17,1"
            ),
            generatedAt: Date()
        )
        XCTAssertTrue(text.contains("Kein früherer Lauf"))
        XCTAssertTrue(text.contains("AKTUELLER LAUF"))
    }

    /// MetricKit's payload is large and nests differently between iOS
    /// versions; the fields that answer "why" have to be lifted out of it
    /// rather than left for someone to find by scrolling.
    func testMetricKitHighlightsLiftTheFieldsThatAnswerWhy() {
        let payload = """
        {"crashDiagnostics":[{"diagnosticMetaData":{
          "exceptionType":1,"signal":11,"exceptionCode":0,
          "terminationReason":"Namespace SIGNAL, Code 11",
          "appVersion":"0.6.0","osVersion":"iPhone OS 26.0"}}]}
        """
        let lines = DiagnosticsReport.metricKitHighlights(payload)
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("signal: 11"), joined)
        XCTAssertTrue(joined.contains("terminationReason: Namespace SIGNAL, Code 11"), joined)
        XCTAssertTrue(joined.contains("exceptionType: 1"), joined)
    }

    func testMetricKitHighlightsSurviveUnexpectedShapes() {
        XCTAssertFalse(DiagnosticsReport.metricKitHighlights("not json").isEmpty)
        XCTAssertFalse(DiagnosticsReport.metricKitHighlights("").isEmpty)
    }

    /// The point of the whole exercise: a report forwarded from a device has
    /// to name the record type and CloudKit's own server text, otherwise the
    /// next round of guessing starts from the same "CKErrorDomain-Fehler 2".
    func testTheReportCarriesTheUnwrappedICloudFailure() {
        var current = DiagnosticRun(
            appVersion: "0.6.0", build: "13", systemVersion: "27.0", deviceModel: "iPhone18,4"
        )
        current.syncFailure = [
            "Export (nach iCloud): iCloud lehnt das Datenformat ab",
            "Fehler: CKErrorDomain 2 (partialFailure)",
            "  • 1× CKErrorDomain 12 (invalidArguments)",
            "      Server: Cannot create new type CD_MiniApp in production schema",
        ].joined(separator: "\n")

        let text = DiagnosticsReport.render(
            previous: nil, verdict: .noPreviousRun, metricKit: nil,
            current: current, generatedAt: Date(timeIntervalSince1970: 770_001_000)
        )
        XCTAssertTrue(text.contains("CD_MiniApp"), text)
        XCTAssertTrue(text.contains("invalidArguments"))
        XCTAssertTrue(text.contains("Export (nach iCloud)"))
        // Never cleared by a later success, so it must not read as live.
        XCTAssertTrue(text.contains("letzter Fehler in diesem Lauf"))
    }

    /// Development vs Production is what separates "works on my device" from
    /// "fails for every TestFlight user", and no report so far said which one
    /// it was looking at.
    func testTheReportNamesTheCloudKitEnvironmentItWouldHaveUsed() {
        XCTAssertTrue(
            DiagnosticsReport.distributionLines(receiptName: "sandboxReceipt", isDebugBuild: false)
                .joined().contains("TestFlight")
        )
        XCTAssertTrue(
            DiagnosticsReport.distributionLines(receiptName: "receipt", isDebugBuild: false)
                .joined().contains("App Store")
        )
        // A debug build outranks whatever receipt happens to be lying around.
        XCTAssertTrue(
            DiagnosticsReport.distributionLines(receiptName: "sandboxReceipt", isDebugBuild: true)
                .joined().contains("Development")
        )
        // No receipt is not an excuse to guess.
        XCTAssertTrue(
            DiagnosticsReport.distributionLines(receiptName: nil, isDebugBuild: false)
                .joined().contains("unbekannt")
        )
        for lines in [
            DiagnosticsReport.distributionLines(receiptName: "sandboxReceipt", isDebugBuild: false),
            DiagnosticsReport.distributionLines(receiptName: "receipt", isDebugBuild: false),
            DiagnosticsReport.distributionLines(receiptName: nil, isDebugBuild: true),
        ] {
            XCTAssertEqual(lines.count, 2)
            XCTAssertTrue(lines.joined().contains("CloudKit"), "\(lines)")
        }
    }

    func testTheReportSaysNothingAboutICloudWhenNothingFailed() {
        let text = DiagnosticsReport.render(
            previous: nil, verdict: .noPreviousRun, metricKit: nil,
            current: DiagnosticRun(
                appVersion: "0.6.0", build: "13", systemVersion: "27.0", deviceModel: "iPhone18,4"
            ),
            generatedAt: Date()
        )
        XCTAssertFalse(text.contains("iCloud —"), "a healthy run must not grow an alarming empty section")
    }

    func testDurationsReadInTheRightUnit() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(DiagnosticsReport.duration(from: start, to: start.addingTimeInterval(45)), "45s")
        XCTAssertEqual(DiagnosticsReport.duration(from: start, to: start.addingTimeInterval(125)), "2m 5s")
        XCTAssertEqual(DiagnosticsReport.duration(from: start, to: start.addingTimeInterval(7_380)), "2h 3m")
        // A record recovered with no end time must not render as negative.
        XCTAssertEqual(DiagnosticsReport.duration(from: start.addingTimeInterval(10), to: start), "0s")
    }
}

/// The recorder writes to a real directory; these use a temporary one so the
/// suite never touches the app's own diagnostics.
final class DiagnosticsRecorderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheRingBufferIsBounded() {
        let recorder = DiagnosticsRecorder(directory: directory)
        for index in 0..<(DiagnosticsRecorder.maxBreadcrumbs + 50) {
            recorder.record("test", "Ereignis \(index)")
        }
        let run = recorder.currentRunSnapshot()
        XCTAssertEqual(run.breadcrumbs.count, DiagnosticsRecorder.maxBreadcrumbs)
        // Oldest are dropped, newest kept — a crash report wants the end.
        XCTAssertEqual(
            run.breadcrumbs.last?.message,
            "Ereignis \(DiagnosticsRecorder.maxBreadcrumbs + 49)"
        )
    }

    /// A recovered run reporting "0 MB belegt" reads as evidence AGAINST memory
    /// pressure, when it really means nobody sampled the field — the exact
    /// mistake the first device run of this feature made.
    func testMemoryIsSampledOnEveryWriteNotOnlyOnAWarning() throws {
        let first = DiagnosticsRecorder(directory: directory)
        first.record("app", "Arbeit")
        try waitForFlush(in: directory, named: "current-run.json", containing: "Arbeit")

        let recovered = try XCTUnwrap(DiagnosticsRecorder(directory: directory).lastRunSnapshot().run)
        XCTAssertGreaterThan(
            recovered.footprintMB, 0,
            "a run with no memory warning must still carry its footprint"
        )
        XCTAssertEqual(recovered.memoryWarnings, 0)
    }

    /// The sync failure has to survive the process that saw it. A CloudKit
    /// export failing is often followed by the app being backgrounded and
    /// killed, so it is flushed immediately and read back by the next launch.
    func testTheICloudFailureSurvivesIntoTheNextLaunch() throws {
        let first = DiagnosticsRecorder(directory: directory)
        first.noteSyncFailure("Export (nach iCloud): abgelehnt\n  • 1× CKErrorDomain 12 (invalidArguments)")
        try waitForFlush(in: directory, named: "current-run.json", containing: "invalidArguments")

        let recovered = try XCTUnwrap(DiagnosticsRecorder(directory: directory).lastRunSnapshot().run)
        XCTAssertTrue(recovered.syncFailure?.contains("invalidArguments") == true)
    }

    func testAFreshInstallHasNoPreviousRun() {
        let recorder = DiagnosticsRecorder(directory: directory)
        XCTAssertEqual(recorder.lastRunSnapshot().verdict, .noPreviousRun)
        XCTAssertNil(recorder.lastRunSnapshot().run)
    }

    /// The core mechanism: a run that never marked itself finished is picked
    /// up by the NEXT launch and reported as an unexplained death.
    func testAnUnfinishedRunIsRecoveredByTheNextLaunch() throws {
        let first = DiagnosticsRecorder(directory: directory)
        first.record("gruppe", "Runde 1 · 3 Teilnehmer")
        first.noteProvider("anthropic", model: "claude-opus-4-5")
        try waitForFlush(in: directory, named: "current-run.json", containing: "anthropic")

        let second = DiagnosticsRecorder(directory: directory)
        let snapshot = second.lastRunSnapshot()
        XCTAssertEqual(snapshot.verdict, .diedUnexpectedly)
        XCTAssertEqual(snapshot.run?.provider, "anthropic")
        XCTAssertTrue(
            snapshot.run?.breadcrumbs.contains { $0.message.contains("Runde 1") } == true
        )
    }

    func testACleanExitIsRecoveredAsClean() throws {
        let first = DiagnosticsRecorder(directory: directory)
        first.record("app", "Arbeit")
        first.markCleanExit(reason: "terminate")
        try waitForFlush(in: directory, named: "current-run.json", containing: "endedCleanlyAt")

        let second = DiagnosticsRecorder(directory: directory)
        XCTAssertEqual(second.lastRunSnapshot().verdict, .clean)
    }

    /// A marker left by the signal handler belongs to the run that died, and
    /// must be folded into it — otherwise the crash we DID catch shows up as
    /// "cause unknown".
    func testASignalMarkerIsFoldedIntoTheRecoveredRun() throws {
        let first = DiagnosticsRecorder(directory: directory)
        first.record("chat", "Senden · 20 Zeichen")
        try waitForFlush(in: directory, named: "current-run.json", containing: "Senden")
        try Data("sig 11\nf 0x1044e2a10\n".utf8)
            .write(to: directory.appendingPathComponent("fatal-signal.txt"))

        let second = DiagnosticsRecorder(directory: directory)
        let snapshot = second.lastRunSnapshot()
        guard case .crashed(let fatal) = snapshot.verdict else {
            return XCTFail("expected a crash verdict, got \(snapshot.verdict)")
        }
        XCTAssertEqual(fatal.name, "SIGSEGV")
        XCTAssertTrue(
            snapshot.run?.breadcrumbs.contains { $0.message.contains("Senden") } == true,
            "the marker must not replace the run's own record"
        )
        // Consumed, so the next launch does not re-report the same crash.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("fatal-signal.txt").path
            )
        )
    }

    func testTheExportIsAReadableFile() throws {
        let recorder = DiagnosticsRecorder(directory: directory)
        recorder.record("app", "Start")
        let url = try XCTUnwrap(recorder.exportReport())
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("aiity — Diagnose"))
        XCTAssertEqual(url.pathExtension, "txt")
    }

    func testClearingRemovesThePreviousRunButKeepsRecording() throws {
        let first = DiagnosticsRecorder(directory: directory)
        first.record("app", "Arbeit")
        try waitForFlush(in: directory, named: "current-run.json", containing: "Arbeit")

        let second = DiagnosticsRecorder(directory: directory)
        XCTAssertEqual(second.lastRunSnapshot().verdict, .diedUnexpectedly)
        second.clear()
        XCTAssertEqual(second.lastRunSnapshot().verdict, .noPreviousRun)

        second.record("app", "Weiter")
        XCTAssertTrue(
            second.currentRunSnapshot().breadcrumbs.contains { $0.message == "Weiter" }
        )
    }

    /// Writes are throttled and asynchronous, so the file appears shortly after
    /// the call rather than during it. `containing` matters: merely existing is
    /// not enough, because an earlier flush may have written a version that
    /// predates the state under test — which is exactly the bug this helper
    /// caught the first time round.
    private func waitForFlush(
        in directory: URL, named name: String, containing needle: String? = nil
    ) throws {
        let url = directory.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                guard let needle else { return }
                if String(decoding: data, as: UTF8.self).contains(needle) { return }
            }
            usleep(50_000)
        }
        XCTFail("\(name) never contained \(needle ?? "any content")")
    }
}
