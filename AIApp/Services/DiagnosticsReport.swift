import Foundation

/// Turns the recorded evidence into something a person can read and forward.
///
/// The one rule this file follows: **say what is known and say what is
/// inferred, separately.** A process cannot tell a crash apart from a jetsam
/// kill, a watchdog kill, or a force-quit after the fact — the difference is
/// only visible in the surrounding evidence. So a report never claims "the app
/// crashed because X" when all it has is "the app did not shut down cleanly
/// and there had been a memory warning". Getting this wrong sends someone
/// hunting a bug that was really the user swiping the app away.
enum DiagnosticsReport {

    static func render(
        previous: DiagnosticRun?,
        verdict: DiagnosticVerdict,
        metricKit: String?,
        current: DiagnosticRun,
        generatedAt: Date,
        storePurges: [MiniAppSessionStorePurgeQueue.Record] = []
    ) -> String {
        var out: [String] = []
        out.append("aiity — Diagnose")
        out.append("Erstellt: \(stamp(generatedAt))")
        out.append(contentsOf: distributionLines())
        out.append("")

        out.append(contentsOf: previousSection(previous, verdict: verdict))
        out.append("")

        if let metricKit, !metricKit.isEmpty {
            out.append("━━━ SYSTEMBERICHT (MetricKit) ━━━")
            out.append(
                String(localized: "Von iOS selbst erstellt. Enthält den symbolisierten Stack und den ")
                + String(localized: "Abbruchgrund — genauer als alles, was die App selbst mitschreiben kann.")
            )
            out.append("")
            out.append(contentsOf: metricKitHighlights(metricKit))
            out.append("")
            out.append("--- Rohdaten ---")
            out.append(metricKit)
            out.append("")
        } else {
            out.append("━━━ SYSTEMBERICHT (MetricKit) ━━━")
            out.append(
                String(localized: "Noch keiner. iOS liefert seinen Absturzbericht erst nach dem nächsten ")
                + String(localized: "Start an die App aus — meist beim übernächsten Öffnen. Bis dahin zählt ")
                + String(localized: "nur, was oben steht.")
            )
            out.append("")
        }

        out.append("━━━ AKTUELLER LAUF ━━━")
        out.append(contentsOf: runFacts(current))
        out.append(contentsOf: storePurgeLines(storePurges))
        out.append("")
        out.append("Ereignisse:")
        out.append(contentsOf: breadcrumbLines(current.breadcrumbs))

        return out.joined(separator: "\n")
    }

    // MARK: How this copy was installed

    /// Which CloudKit database this copy of the app talks to — the first
    /// question about any sync failure, and the one no report could answer
    /// until now.
    ///
    /// There is no API for it. CloudKit picks the environment from the code
    /// signature: a build signed for distribution (TestFlight or App Store)
    /// uses **Production**, a build signed for development uses
    /// **Development**. That matters because `NSPersistentCloudKitContainer`
    /// creates missing record types on the fly in Development and *cannot* in
    /// Production — so a schema that was only ever exercised by debug runs
    /// works on the developer's device and fails per-record on everyone
    /// else's, until it is promoted in the CloudKit Console.
    ///
    /// The App Store receipt tracks the same distinction closely enough to be
    /// worth reporting, and the wording stays hedged where it has to: a
    /// Release build installed straight from Xcode also carries a sandbox
    /// receipt while running against Development.
    static func distributionLines() -> [String] {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let url = Bundle.main.appStoreReceiptURL
        let name = (url.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            ? url?.lastPathComponent
            : nil
        return distributionLines(receiptName: name, isDebugBuild: isDebug)
    }

    /// Pure, so the mapping is testable without a receipt on disk.
    static func distributionLines(receiptName: String?, isDebugBuild: Bool) -> [String] {
        if isDebugBuild {
            return [
                String(localized: "Installation: Debug-Build aus Xcode"),
                String(localized: "CloudKit:     Development-Umgebung"),
            ]
        }
        switch receiptName {
        case "sandboxReceipt":
            return [
                String(localized: "Installation: TestFlight (Sandbox-Beleg) — oder Release-Build direkt aus Xcode"),
                String(localized: "CloudKit:     Production-Umgebung (bei Installation aus Xcode: Development)"),
            ]
        case "receipt":
            return [
                String(localized: "Installation: App Store"),
                String(localized: "CloudKit:     Production-Umgebung"),
            ]
        default:
            return [
                String(localized: "Installation: unbekannt (kein Kaufbeleg vorhanden)"),
                String(localized: "CloudKit:     Umgebung folgt der Signatur — Vertriebssignatur = Production"),
            ]
        }
    }

    // MARK: Previous run

    private static func previousSection(
        _ run: DiagnosticRun?, verdict: DiagnosticVerdict
    ) -> [String] {
        var out = ["━━━ LETZTER LAUF ━━━"]

        guard let run else {
            out.append(String(localized: "Kein früherer Lauf gespeichert — entweder der erste Start nach ")
                       + String(localized: "der Installation, oder die Diagnose wurde geleert."))
            return out
        }

        out.append("Ergebnis: \(headline(verdict, run: run))")
        out.append("")
        out.append(contentsOf: runFacts(run))
        out.append("")

        switch verdict {
        case .crashed(let fatal):
            out.append("Absturz:")
            out.append("  Art:     \(fatal.kind == .exception ? "Nicht abgefangene Ausnahme" : "Signal")")
            out.append("  Name:    \(fatal.name)")
            if !fatal.reason.isEmpty {
                out.append("  Bedeutung: \(fatal.reason)")
            }
            out.append("  Zeit:    \(stamp(fatal.at))")
            if fatal.frames.isEmpty {
                out.append("  Stack:   keiner erfasst")
            } else if fatal.kind == .signal {
                out.append(String(localized: "  Stack (Rückkehradressen, nicht symbolisiert —"))
                out.append(String(localized: "         der Signal-Handler darf nichts allozieren, was zum"))
                out.append(String(localized: "         Symbolisieren nötig wäre. Der MetricKit-Bericht unten"))
                out.append(String(localized: "         liefert dieselben Frames mit Namen, sobald iOS ihn ausliefert):"))
                for frame in fatal.frames.prefix(40) {
                    out.append("    \(frame)")
                }
            } else {
                out.append("  Stack:")
                for frame in fatal.frames.prefix(40) {
                    out.append("    \(frame)")
                }
            }

        case .diedUnexpectedly:
            out.append(String(localized: "Der Prozess ist beendet worden, ohne dass die App das mitbekommen hat."))
            out.append(String(localized: "Ein Prozess kann das im Nachhinein nicht sicher unterscheiden. Möglich sind:"))
            out.append(contentsOf: unexpectedCauses(run).map { "  • \($0)" })
            out.append("")
            out.append(String(localized: "Was dafür/dagegen spricht, steht in den Fakten oben und den Ereignissen unten."))

        case .clean:
            out.append(String(localized: "Sauber beendet — kein Absturz."))

        case .noPreviousRun:
            break
        }

        out.append("")
        out.append(String(localized: "Letzte Ereignisse vor dem Ende:"))
        out.append(contentsOf: breadcrumbLines(run.breadcrumbs))
        return out
    }

    /// Ordered most- to least-likely *given this run's evidence*, so the list
    /// is a ranking rather than a disclaimer.
    static func unexpectedCauses(_ run: DiagnosticRun) -> [String] {
        var causes: [String] = []

        if run.memoryWarnings > 0 {
            causes.append(
                "Speicher: \(run.memoryWarnings) Warnung(en), zuletzt "
                + String(format: "%.0f MB belegt", run.footprintMB)
                + " — iOS beendet Apps unter Speicherdruck ohne Vorwarnung (Jetsam)."
            )
        }
        if run.wasInBackground {
            causes.append(
                String(localized: "Im Hintergrund beendet — das ist normales iOS-Verhalten und kein Fehler.")
            )
        } else {
            causes.append(
                "Absturz ohne abfangbares Signal — z. B. ein Absturz im Systemcode, "
                + String(localized: "bevor der Handler greifen konnte.")
            )
            causes.append(
                String(localized: "Watchdog: die App war zu lange blockiert (Hauptthread blockiert, ")
                + "0x8BADF00D im Systembericht)."
            )
            causes.append(String(localized: "Vom Benutzer aus dem App-Switcher geworfen."))
        }
        if run.memoryWarnings == 0 && !run.wasInBackground {
            causes.append(String(localized: "Speicherdruck ist unwahrscheinlich — es gab keine Speicherwarnung."))
        }
        return causes
    }

    /// Memory warnings arriving in the seconds before the process disappears
    /// are about as close to proof of a jetsam kill as a process can get from
    /// the inside. Below this, memory is one candidate among several.
    private static let jetsamWindow: TimeInterval = 60

    /// Passing `run` lets the headline use the run's own evidence. Without it
    /// the verdict alone is reported, which is all a caller that has no run can
    /// honestly say.
    static func headline(_ verdict: DiagnosticVerdict, run: DiagnosticRun? = nil) -> String {
        switch verdict {
        case .clean:
            return "sauber beendet"
        case .crashed(let fatal):
            return "ABSTURZ · \(fatal.name)"
        case .diedUnexpectedly:
            if let run, diedUnderMemoryPressure(run) {
                // Still hedged — iOS never confirms a jetsam to the app it
                // killed — but "nicht eindeutig" would understate five
                // warnings in the last seconds and send someone hunting a
                // logic bug that isn't there.
                return "UNERWARTET BEENDET · sehr wahrscheinlich Speicher (Jetsam)"
            }
            return String(localized: "UNERWARTET BEENDET (Ursache nicht eindeutig)")
        case .noPreviousRun:
            return String(localized: "kein früherer Lauf")
        }
    }

    static func diedUnderMemoryPressure(_ run: DiagnosticRun) -> Bool {
        guard run.memoryWarnings > 0 else { return false }
        let end = run.endedCleanlyAt ?? run.lastActiveAt
        guard let lastWarning = run.breadcrumbs.last(where: { $0.category == "speicher" })
        else { return false }
        return end.timeIntervalSince(lastWarning.at) <= jetsamWindow
    }

    // MARK: Pieces

    private static func runFacts(_ run: DiagnosticRun) -> [String] {
        var out: [String] = []
        out.append("  Start:    \(stamp(run.startedAt))")
        let end = run.fatal?.at ?? run.endedCleanlyAt ?? run.lastActiveAt
        out.append("  Ende:     \(stamp(end))  (Laufzeit \(duration(from: run.startedAt, to: end)))")
        out.append("  Zustand:  \(run.wasInBackground ? "Hintergrund" : "Vordergrund")")
        out.append("  Version:  \(run.appVersion) (\(run.build))")
        out.append("  System:   iOS \(run.systemVersion) · \(run.deviceModel)")
        if !run.provider.isEmpty {
            let model = run.model.isEmpty ? String(localized: "— kein Modell gesetzt") : run.model
            out.append(String(localized: "  Anbieter: \(run.provider) · \(model)"))
        }
        out.append(String(
            format: String(localized: "  Speicher: %.0f MB belegt · %.0f MB verfügbar · %d Warnung(en)"),
            run.footprintMB, run.availableMemoryMB, run.memoryWarnings
        ))
        out.append(contentsOf: syncLines(run))
        return out
    }

    /// The iCloud block. Present only when something actually failed, and
    /// explicitly labelled as the *last* failure of that run: `syncFailure` is
    /// never cleared by a later success, so without the wording a recovered
    /// sync would read as a live one. The per-record lines below it are the
    /// point — they name the record type and carry CloudKit's own server text.
    static func syncLines(_ run: DiagnosticRun) -> [String] {
        guard let failure = run.syncFailure, !failure.isEmpty else { return [] }
        var out = ["", String(localized: "  iCloud — letzter Fehler in diesem Lauf:")]
        for line in failure.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append("  \(line)")
        }
        out.append(String(localized: "  (Ein späterer Erfolg löscht diesen Eintrag nicht — ob der Abgleich"))
        out.append(String(localized: "   danach wieder lief, steht in den Ereignissen unter \"icloud\".)"))
        return out
    }

    /// Cookie jars the app has decided to delete and not yet seen disappear.
    ///
    /// Present only when something is actually owed, and deliberately in the
    /// CURRENT-run block rather than in `runFacts`: this is device state read at
    /// export time, not a fact about the run being reported. Without it a jar
    /// WebKit keeps refusing to delete is invisible — the sweep's own breadcrumb
    /// only appears in the launch that tried, so a report exported later would
    /// show nothing at all. Untranslated, like every other technical line in
    /// this export (see docs/LOCALIZATION.md).
    static func storePurgeLines(_ purges: [MiniAppSessionStorePurgeQueue.Record]) -> [String] {
        guard !purges.isEmpty else { return [] }
        let pending = purges.filter { $0.state == .pending }
        var out = [
            "",
            "  Mini-App-Cookie-Jars, noch nicht gelöscht: "
            + "\(pending.count) offen, \(purges.count - pending.count) Rest",
        ]
        for purge in purges {
            let label = purge.state == .pending ? "offen  " : "Rest   "
            out.append(
                "    \(purge.identifier.uuidString)  \(label)"
                + "seit \(stamp(purge.firstNotedAt))  \(purge.attempts) Versuch(e)"
            )
        }
        out.append("  (\"offen\" = WebKit hat die Löschung abgelehnt, meist weil dieser Prozess")
        out.append("   den Store geöffnet hatte; der nächste Start versucht es erneut. \"Rest\" =")
        out.append("   bereits gelöscht, WebKit listet nur noch ein leeres Verzeichnis.)")
        return out
    }

    private static func breadcrumbLines(_ crumbs: [DiagnosticBreadcrumb]) -> [String] {
        guard !crumbs.isEmpty else { return [String(localized: "  (keine)")] }
        return crumbs.suffix(60).map { crumb in
            "  \(time(crumb.at))  \(crumb.category.padding(toLength: 10, withPad: " ", startingAt: 0))  \(crumb.message)"
        }
    }

    /// Pull the few fields that answer "why" out of MetricKit's large JSON, so
    /// the answer is not buried under the raw payload appended below it.
    static func metricKitHighlights(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return [String(localized: "  (nicht lesbar)")] }

        var found: [String] = []
        // The payload nests crashDiagnostics under a top-level key; walk rather
        // than model the whole schema, which changes between iOS versions.
        if let root = try? JSONSerialization.jsonObject(with: data) {
            collect(root, into: &found)
        }
        if found.isEmpty {
            // Not decodable as one object — multiple payloads are newline
            // separated, so try each line.
            for line in json.split(separator: "\n") {
                if let lineData = line.data(using: .utf8),
                   let root = try? JSONSerialization.jsonObject(with: lineData) {
                    collect(root, into: &found)
                }
            }
        }
        return found.isEmpty ? [String(localized: "  (keine Absturzfelder im Bericht)")] : found.map { "  \($0)" }
    }

    private static let interestingKeys: Set<String> = [
        "exceptionType", "exceptionCode", "signal", "terminationReason",
        "virtualMemoryRegionInfo", "appVersion", "osVersion", "deviceType",
        "hangDuration", "diagnosticType",
    ]

    private static func collect(_ node: Any, into found: inout [String]) {
        if let dict = node as? [String: Any] {
            for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                if interestingKeys.contains(key), !(value is [Any]), !(value is [String: Any]) {
                    let line = "\(key): \(value)"
                    if !found.contains(line) { found.append(line) }
                } else {
                    collect(value, into: &found)
                }
            }
        } else if let array = node as? [Any] {
            for element in array { collect(element, into: &found) }
        }
    }

    // MARK: Formatting

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SS"
        return formatter
    }()

    static func stamp(_ date: Date) -> String {
        date.timeIntervalSince1970 == 0 ? "—" : stampFormatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        date.timeIntervalSince1970 == 0 ? "—" : timeFormatter.string(from: date)
    }

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        if seconds < 3600 { return String(format: "%dm %ds", Int(seconds) / 60, Int(seconds) % 60) }
        return String(format: "%dh %dm", Int(seconds) / 3600, (Int(seconds) % 3600) / 60)
    }
}
