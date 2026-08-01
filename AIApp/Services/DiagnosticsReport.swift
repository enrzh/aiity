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
        generatedAt: Date
    ) -> String {
        var out: [String] = []
        out.append("aiity — Diagnose")
        out.append("Erstellt: \(stamp(generatedAt))")
        out.append("")

        out.append(contentsOf: previousSection(previous, verdict: verdict))
        out.append("")

        if let metricKit, !metricKit.isEmpty {
            out.append("━━━ SYSTEMBERICHT (MetricKit) ━━━")
            out.append(
                "Von iOS selbst erstellt. Enthält den symbolisierten Stack und den "
                + "Abbruchgrund — genauer als alles, was die App selbst mitschreiben kann."
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
                "Noch keiner. iOS liefert seinen Absturzbericht erst nach dem nächsten "
                + "Start an die App aus — meist beim übernächsten Öffnen. Bis dahin zählt "
                + "nur, was oben steht."
            )
            out.append("")
        }

        out.append("━━━ AKTUELLER LAUF ━━━")
        out.append(contentsOf: runFacts(current))
        out.append("")
        out.append("Ereignisse:")
        out.append(contentsOf: breadcrumbLines(current.breadcrumbs))

        return out.joined(separator: "\n")
    }

    // MARK: Previous run

    private static func previousSection(
        _ run: DiagnosticRun?, verdict: DiagnosticVerdict
    ) -> [String] {
        var out = ["━━━ LETZTER LAUF ━━━"]

        guard let run else {
            out.append("Kein früherer Lauf gespeichert — entweder der erste Start nach "
                       + "der Installation, oder die Diagnose wurde geleert.")
            return out
        }

        out.append("Ergebnis: \(headline(verdict))")
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
                out.append("  Stack (Rückkehradressen, nicht symbolisiert —")
                out.append("         der Signal-Handler darf nichts allozieren, was zum")
                out.append("         Symbolisieren nötig wäre. Der MetricKit-Bericht unten")
                out.append("         liefert dieselben Frames mit Namen, sobald iOS ihn ausliefert):")
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
            out.append("Der Prozess ist beendet worden, ohne dass die App das mitbekommen hat.")
            out.append("Ein Prozess kann das im Nachhinein nicht sicher unterscheiden. Möglich sind:")
            out.append(contentsOf: unexpectedCauses(run).map { "  • \($0)" })
            out.append("")
            out.append("Was dafür/dagegen spricht, steht in den Fakten oben und den Ereignissen unten.")

        case .clean:
            out.append("Sauber beendet — kein Absturz.")

        case .noPreviousRun:
            break
        }

        out.append("")
        out.append("Letzte Ereignisse vor dem Ende:")
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
                "Im Hintergrund beendet — das ist normales iOS-Verhalten und kein Fehler."
            )
        } else {
            causes.append(
                "Absturz ohne abfangbares Signal — z. B. ein Absturz im Systemcode, "
                + "bevor der Handler greifen konnte."
            )
            causes.append(
                "Watchdog: die App war zu lange blockiert (Hauptthread blockiert, "
                + "0x8BADF00D im Systembericht)."
            )
            causes.append("Vom Benutzer aus dem App-Switcher geworfen.")
        }
        if run.memoryWarnings == 0 && !run.wasInBackground {
            causes.append("Speicherdruck ist unwahrscheinlich — es gab keine Speicherwarnung.")
        }
        return causes
    }

    static func headline(_ verdict: DiagnosticVerdict) -> String {
        switch verdict {
        case .clean:
            return "sauber beendet"
        case .crashed(let fatal):
            return "ABSTURZ · \(fatal.name)"
        case .diedUnexpectedly:
            return "UNERWARTET BEENDET (Ursache nicht eindeutig)"
        case .noPreviousRun:
            return "kein früherer Lauf"
        }
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
            let model = run.model.isEmpty ? "— kein Modell gesetzt" : run.model
            out.append("  Anbieter: \(run.provider) · \(model)")
        }
        out.append(String(
            format: "  Speicher: %.0f MB belegt · %.0f MB verfügbar · %d Warnung(en)",
            run.footprintMB, run.availableMemoryMB, run.memoryWarnings
        ))
        return out
    }

    private static func breadcrumbLines(_ crumbs: [DiagnosticBreadcrumb]) -> [String] {
        guard !crumbs.isEmpty else { return ["  (keine)"] }
        return crumbs.suffix(60).map { crumb in
            "  \(time(crumb.at))  \(crumb.category.padding(toLength: 10, withPad: " ", startingAt: 0))  \(crumb.message)"
        }
    }

    /// Pull the few fields that answer "why" out of MetricKit's large JSON, so
    /// the answer is not buried under the raw payload appended below it.
    static func metricKitHighlights(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return ["  (nicht lesbar)"] }

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
        return found.isEmpty ? ["  (keine Absturzfelder im Bericht)"] : found.map { "  \($0)" }
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
